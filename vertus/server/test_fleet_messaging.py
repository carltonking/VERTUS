"""Fleet message-bus + delegation tests (Checkpoints 2–3).

Exercises BotMessenger against a REAL store + registry with fake session
bridges: delivery (idle/busy), thread grouping, depth cap, rate cap,
degraded/deleted recipients, delegation parent/children, and the
hub-deterministic auto-result return path.
"""

from __future__ import annotations

import pytest

from agent_registry import AgentRegistry
from fleet_messaging import (
    BotMessageError, BotMessenger, DEPTH_MAX, RATE_MAX,
)
from run_store import RunStore


class FakeBridge:
    def __init__(self, agent_id: str):
        self.agent_id = agent_id
        self.store = None
        self.calls: list[dict] = []
        self._degraded = None
        self._current = None

    def prompt(self, text, remote=False, run_id=None, from_agent=None,
               thread_id=None, run_kind="user"):
        self.calls.append({
            "text": text, "remote": remote, "run_id": run_id,
            "from_agent": from_agent, "thread_id": thread_id,
            "run_kind": run_kind,
        })

    def status(self):
        return {
            "degraded": self._degraded,
            "state": "running" if self._current else "idle",
        }

    @property
    def current_run_id(self):
        return self._current


class FakeSessions:
    def __init__(self):
        self.bridges: dict[str, FakeBridge] = {}

    def get_or_create_session(self, agent_id):
        return self.bridges.setdefault(agent_id, FakeBridge(agent_id))

    def __getitem__(self, agent_id):
        return self.get_or_create_session(agent_id)


@pytest.fixture
def env(tmp_path):
    registry = AgentRegistry(root=str(tmp_path / "agents"))
    a = registry.create_agent("Alpha")
    b = registry.create_agent("Bravo")
    c = registry.create_agent("Charlie")
    store = RunStore(path=tmp_path / "fleet.db")
    sessions = FakeSessions()
    messenger = BotMessenger(lambda: store, lambda: sessions, registry)
    return {
        "registry": registry, "store": store, "sessions": sessions,
        "messenger": messenger,
        "a": a["id"], "b": b["id"], "c": c["id"], "tmp": tmp_path,
    }


# ----------------------------------------------------------------------
# Delivery
# ----------------------------------------------------------------------

def test_delivery_to_idle_creates_run_with_attribution(env):
    """A delivered message becomes a queued run on the recipient carrying
    from_agent/thread_id/run_kind, and the bridge gets the prompt."""
    out = env["messenger"].send(env["a"], env["b"], "hello there",
                                kind="message")
    assert out["status"] == "delivered"
    run = env["store"].get_run(out["run_id"])
    assert run["agent_id"] == env["b"]
    assert run["from_agent"] == env["a"]
    assert run["thread_id"] == out["thread_id"]
    assert run["run_kind"] == "message"
    assert run["state"] == "queued"
    assert run["source"] == f"bot:{env['a']}"
    call = env["sessions"][env["b"]].calls[0]
    assert call["run_id"] == out["run_id"]
    assert call["from_agent"] == env["a"]
    assert call["thread_id"] == out["thread_id"]
    msgs = env["store"].list_bot_messages(thread_id=out["thread_id"])
    assert len(msgs) == 1
    assert msgs[0]["run_id"] == out["run_id"]  # message linked to its run


def test_delivery_to_busy_queues_second_run(env):
    """A message to a busy agent lands as another queued run behind the
    current work — the messenger never blocks, never refuses."""
    bridge = env["sessions"][env["b"]]
    bridge._current = "run-busy-1"          # B is mid-turn
    first = env["messenger"].send(env["a"], env["b"], "one")
    second = env["messenger"].send(env["a"], env["b"], "two")
    assert first["status"] == second["status"] == "delivered"
    for run_id in (first["run_id"], second["run_id"]):
        assert env["store"].get_run(run_id)["state"] == "queued"
    assert len(bridge.calls) == 2


def test_thread_grouping_and_subject(env):
    """Messages sharing a thread_id group into one thread; subject is the
    first message's opening; participants are unioned and sorted."""
    tid = "thread-1"
    env["messenger"].send(env["a"], env["b"], "First subject line here",
                          thread_id=tid)
    env["messenger"].send(env["b"], env["a"], "reply", thread_id=tid)
    env["messenger"].send(env["a"], env["c"], "also cc", thread_id=tid)
    threads = env["store"].list_threads()
    assert len(threads) == 1
    t = threads[0]
    assert t["subject"].startswith("First subject line")
    assert t["participants"] == sorted([env["a"], env["b"], env["c"]])
    msgs = env["store"].list_bot_messages(thread_id=tid)
    assert len(msgs) == 3
    # per-agent involvement filter
    a_msgs = env["store"].list_bot_messages(agent_id=env["c"])
    assert len(a_msgs) == 1


# ----------------------------------------------------------------------
# Loop protection
# ----------------------------------------------------------------------

def test_depth_cap_halts_ping_pong(env):
    """A↔B alternating replies: depth grows per sender; the next hop past
    DEPTH_MAX is stored as dropped_depth and never delivered."""
    tid = "ping-pong"
    expected = [1, 1, 2, 2, 3, 3, 4, 4, 5, 5]
    for i, sender in enumerate([env["a"], env["b"]] * 5):
        out = env["messenger"].send(sender, env["b"] if sender == env["a"] else env["a"],
                                    f"hop {i}", thread_id=tid)
        assert out["status"] == "delivered", (i, out)
        assert out["depth"] == expected[i]
        assert out["run_id"], "delivered messages must create a run"
    # The 11th hop exceeds the cap for sender A.
    out = env["messenger"].send(env["a"], env["b"], "hop 11", thread_id=tid)
    assert out["status"] == "dropped_depth"
    assert "depth 6" in out["reason"]
    assert "run_id" not in out
    # The attempt is still recorded.
    msgs = env["store"].list_bot_messages(thread_id=tid)
    assert msgs[0]["status"] == "dropped_depth"
    # And no extra run appeared for it.
    runs = env["store"].list_runs(agent_id=env["b"])
    assert len(runs) == 5


def test_cycle_stopped_by_depth_cap_via_handoffs(env):
    """A delegation cycle (A→B→A→B...) is stopped by the same cap."""
    tid = "cycle"
    sender, recipient = env["a"], env["b"]
    depths = []
    # Alternating senders: A's depth grows only on A's own turns, so 11
    # iterations reach A's 6th message (depth 6 > cap 5 → dropped).
    for i in range(DEPTH_MAX * 2 + 1):
        out = env["messenger"].send(sender, recipient, f"handoff {i}",
                                    thread_id=tid, kind="handoff")
        depths.append(out["depth"])
        sender, recipient = recipient, sender
        if out["status"] != "delivered":
            break
    assert depths[-1] == DEPTH_MAX + 1
    assert depths[-2] == DEPTH_MAX


def test_rate_cap_trips_cleanly(env):
    """The 11th message to the same recipient in the window is stored as
    dropped_rate; the first ten are all delivered."""
    statuses = []
    for i in range(RATE_MAX + 1):
        out = env["messenger"].send(env["a"], env["b"], f"msg {i}")
        statuses.append(out["status"])
    assert statuses[:RATE_MAX] == ["delivered"] * RATE_MAX
    assert statuses[RATE_MAX] == "dropped_rate"
    dropped = env["store"].list_bot_messages(agent_id=env["b"])[0]
    assert dropped["status"] == "dropped_rate"


# ----------------------------------------------------------------------
# Auto-result (delegation return path)
# ----------------------------------------------------------------------

def test_result_reuses_triggering_depth_and_wakes_idle_delegator(env):
    """A completed handoff run produces a kind=result message back to the
    delegator with the TRIGGERING depth (not +1), and the result wakes the
    idle delegator with a run of its own (uniform delivery)."""
    tid = "deleg"
    handoff = env["messenger"].send(env["a"], env["b"], "do the thing",
                                    thread_id=tid, kind="handoff")
    assert handoff["depth"] == 1
    run_id = handoff["run_id"]
    env["store"].finish_run(run_id, "done")
    env["store"].add_message(run_id, env["b"], "assistant", "done: 42")
    env["messenger"].run_terminal(
        run_id, env["b"], env["a"], tid, "handoff", "done", "done: 42"
    )
    results = env["store"].list_bot_messages(thread_id=tid)
    result = next(m for m in results if m["kind"] == "result")
    assert result["from_agent"] == env["b"]
    assert result["to_agent"] == env["a"]
    assert result["depth"] == 1, "result must reuse the triggering depth"
    assert result["body"].startswith("[done]")
    # The result woke the idle delegator: a run on A whose prompt is the
    # result body, run_kind=result (which never auto-sends another result).
    wake = env["store"].list_runs(agent_id=env["a"])
    assert len(wake) == 1
    assert wake[0]["run_kind"] == "result"
    assert wake[0]["from_agent"] == env["b"]
    assert env["sessions"][env["a"]].calls[0]["run_kind"] == "result"


def test_result_run_does_not_auto_result(env):
    """A run created FROM a result must not emit another result — chains
    terminate by construction."""
    tid = "no-loop"
    out = env["messenger"].send(env["a"], env["b"], "job", thread_id=tid,
                                kind="handoff")
    env["store"].finish_run(out["run_id"], "done")
    env["messenger"].run_terminal(out["run_id"], env["b"], env["a"], tid,
                                  "handoff", "done", "result payload")
    # The delegator's wake-up run (kind=result) completes:
    wake = env["store"].list_runs(agent_id=env["a"])[0]
    env["store"].finish_run(wake["run_id"], "done")
    env["messenger"].run_terminal(wake["run_id"], env["a"], env["b"], tid,
                                  "result", "done", "ack")
    results = env["store"].list_bot_messages(thread_id=tid)
    results = [m for m in results if m["kind"] == "result"]
    assert len(results) == 1, "no second result may be sent"


def test_delegation_chain_three_deep_with_parents(env):
    """A→B→C handoff chain: child runs carry parent_run_id; results flow
    back each level; the chain survives to depth 3."""
    tid = "chain"
    # A (running) hands off to B → child with parent = A's live run.
    env["sessions"][env["a"]]._current = "run-A-1"
    h1 = env["messenger"].send(env["a"], env["b"], "level 1", thread_id=tid,
                               kind="handoff")
    assert h1["depth"] == 1
    run_b = env["store"].get_run(h1["run_id"])
    assert run_b["parent_run_id"] == "run-A-1"
    # B's completion → result wakes A (which is still running: queued run).
    env["store"].finish_run(h1["run_id"], "done")
    env["store"].add_message(h1["run_id"], env["b"], "assistant", "b done")
    env["messenger"].run_terminal(h1["run_id"], env["b"], env["a"], tid,
                                  "handoff", "done", "b done")
    # A (running) delegates onward to C with the result as context.
    env["sessions"][env["a"]]._current = "run-A-2"
    h2 = env["messenger"].send(env["a"], env["c"], "level 2", thread_id=tid,
                               kind="handoff")
    assert h2["depth"] == 2
    run_c = env["store"].get_run(h2["run_id"])
    assert run_c["parent_run_id"] == "run-A-2"
    env["store"].finish_run(h2["run_id"], "done")
    env["store"].add_message(h2["run_id"], env["c"], "assistant", "c done")
    env["messenger"].run_terminal(h2["run_id"], env["c"], env["a"], tid,
                                  "handoff", "done", "c done")
    # Third hop still under the cap.
    h3 = env["messenger"].send(env["a"], env["b"], "level 3", thread_id=tid,
                               kind="handoff")
    assert h3["depth"] == 3 and h3["status"] == "delivered"
    # Run graph: children_of each parent. h3 also parents to run-A-2 (A
    # is still "running" when it delegates onward), newest first.
    children = env["store"].children_of("run-A-1")
    assert [r["agent_id"] for r in children] == [env["b"]]
    children2 = env["store"].children_of("run-A-2")
    assert sorted(r["agent_id"] for r in children2) == [env["b"], env["c"]]


# ----------------------------------------------------------------------
# Failure modes
# ----------------------------------------------------------------------

def test_message_to_degraded_agent_fails_readably(env):
    """A message/handoff to a degraded agent raises a 503-carrying error
    BEFORE anything is stored; auto results skip the check."""
    env["sessions"][env["b"]]._degraded = "gateway thrashing"
    with pytest.raises(BotMessageError) as exc:
        env["messenger"].send(env["a"], env["b"], "hi")
    assert exc.value.status == 503
    assert "degraded" in str(exc.value)
    assert env["store"].list_bot_messages() == []
    # Auto results are informational and must not wedge the worker.
    out = env["messenger"].send(env["a"], env["b"], "auto", kind="result",
                                depth=1, auto=True)
    assert out["status"] == "delivered"


def test_message_to_deleted_agent_fails_404(env):
    env["registry"].delete_agent(env["b"])
    with pytest.raises(BotMessageError) as exc:
        env["messenger"].send(env["a"], env["b"], "hi")
    assert exc.value.status == 404
    with pytest.raises(BotMessageError) as exc:
        env["messenger"].send(env["b"], env["a"], "hi")
    assert exc.value.status == 404


def test_bad_kind_and_empty_body_are_400(env):
    with pytest.raises(BotMessageError) as exc:
        env["messenger"].send(env["a"], env["b"], "x", kind="telepathy")
    assert exc.value.status == 400
    with pytest.raises(BotMessageError) as exc:
        env["messenger"].send(env["a"], env["b"], "   ")
    assert exc.value.status == 400


# ----------------------------------------------------------------------
# Storage guarantees
# ----------------------------------------------------------------------

def test_message_stored_before_delivery(env):
    """The message row exists and the run is queued by the time send()
    returns — store-before-fanout holds for the bus too."""
    out = env["messenger"].send(env["a"], env["b"], "durable")
    msg = next(m for m in env["store"].list_bot_messages() if m["msg_id"] == out["msg_id"])
    assert msg["status"] == "delivered"
    assert env["store"].get_run(out["run_id"]) is not None
    # The fleet-stream event is also durable.
    assert env["store"].latest_seq() >= 1


def test_mark_thread_read(env):
    tid = "read-me"
    env["messenger"].send(env["a"], env["b"], "one", thread_id=tid)
    env["messenger"].send(env["b"], env["a"], "two", thread_id=tid)
    assert env["store"].list_threads()[0]["unread"] == 2
    assert env["messenger"].mark_thread_read(tid) == 2
    assert env["store"].list_threads()[0]["unread"] == 0