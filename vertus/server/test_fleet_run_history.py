"""Durable run history: store-before-fanout, replay, fleet stream, lifecycle.

Run from the repo root:
    python3 -m pytest vertus/server/test_fleet_run_history.py -v

Every test drives the REAL VertusHandler on a live ThreadingHTTPServer with a
REAL RunStore on a temp DB and a fake engine (no hermes gateway spawned).
AgentBridge is swapped for a scriptable fake whose sessions emit a scripted
number of text deltas and can be gated / made to crash, so run lifecycle and
replay timing are deterministic.

Coverage (Step 6 of the fleet-history prompt):
  - seq strictly monotonic across concurrent runs on 3+ agents
  - store-before-fanout: a store write failure → error run, no client event
  - replay handoff: no gap / no duplicate, incl. an event landing mid-drain
  - since= resume after a lagged drop
  - fleet stream carries all agents; agent_id filter carries exactly one
  - run lifecycle queued→running→done / →error; gateway respawns counted
  - crash recovery: rows left running come back interrupted on restart
  - history pagination boundaries (before=, empty page, limit cap)
  - run_id stream closes after its terminal event
"""

from __future__ import annotations

import json
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from queue import Queue

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vertus_server as vs  # noqa: E402
from run_store import RunStore  # noqa: E402


# ----------------------------------------------------------------------
# Fakes
# ----------------------------------------------------------------------


class ScriptedSession:
    """Engine session stand-in: emits N text deltas, then returns (the bridge
    emits the terminal done backstop). ``mode`` drives error behavior:

      normal           emit deltas, return
      raise            raise RuntimeError on prompt (turn error)
      brokenpipe-once  first prompt raises BrokenPipeError (gateway death) —
                       the worker respawns and retries successfully
    """

    def __init__(self, bridge, deltas: int = 1, delay: float = 0.0, gate=None):
        self.bridge = bridge
        self.deltas = deltas
        self.delay = delay
        self.gate = gate  # optional threading.Event held before the last delta
        self.prompts: list[str] = []
        self.closed = False

    def subscribe(self, listener) -> None:
        pass

    def prompt(self, text: str) -> None:
        mode = getattr(self.bridge, "mode", "normal")
        if mode == "raise":
            raise RuntimeError("engine exploded")
        if mode == "brokenpipe-once" and not getattr(self.bridge, "failed", False):
            self.bridge.failed = True
            raise BrokenPipeError("gateway died mid-turn")
        self.prompts.append(text)
        for i in range(self.deltas):
            if self.gate is not None and i == max(0, self.deltas - 2):
                self.gate.wait(15)  # hold mid-run so tests can observe live
            time.sleep(self.delay)
            self.bridge._on_pi_event({"type": "text", "text": f"{text}#{i}"})

    def close(self) -> None:
        self.closed = True


class ScriptedBridge(vs.AgentBridge):
    """AgentBridge with the real queue/worker/store path but fake sessions.

    Engine behavior is configured per hub via make_hub's ``mode``/``deltas``
    args (class-attribute knobs the worker reads at spawn time).
    """

    def __init__(self, agent_id: str = "primary", cwd: str | None = None,
                 session_kwargs: dict | None = None, store=None):
        # Assign before super().__init__: the worker prewarms immediately.
        self.sessions: list[ScriptedSession] = []
        self.last_spawn_kwargs: dict = {}
        self.failed = False
        super().__init__(agent_id=agent_id, create_session_factory=self._make,
                         cwd=cwd, session_kwargs=session_kwargs, store=store)

    def _make(self, cwd=None, **kwargs):
        self.last_cwd = cwd
        self.last_spawn_kwargs = kwargs
        s = ScriptedSession(self, deltas=self.deltas, delay=self.delay,
                            gate=self.gate)
        self.sessions.append(s)
        return {"session": s}


class Hub:
    """Test harness: real handler + real store + scriptable fake engine."""

    def __init__(self, tmp_path, monkeypatch, *, mode="normal", deltas=1,
                 delay=0.0, gate=None, agents=("primary", "scout")):
        monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
        monkeypatch.setenv("VERTUS_DB_PATH", str(tmp_path / "fleet.db"))
        self.agents_root = tmp_path / "agents"
        registry = vs.AgentRegistry()
        registry.ensure_primary()
        # Agents are identified by their slug; create only the missing ones so
        # a second Hub on the same tmp_path (DB-reopen tests) reuses them.
        known = {a["id"] for a in registry.list_agents()}
        for ident in agents[1:]:
            if ident not in known:
                created = registry.create_agent(ident[0].upper() + ident[1:])
                assert created["id"] == ident, created
        self.registry = registry

        class Engine(ScriptedBridge):
            def __init__(self, agent_id="primary", cwd=None, session_kwargs=None,
                         store=None):
                super().__init__(agent_id=agent_id, cwd=cwd,
                                 session_kwargs=session_kwargs, store=store)

        Engine.deltas = deltas
        Engine.delay = delay
        Engine.gate = gate
        Engine.mode = mode
        monkeypatch.setattr(vs, "AgentBridge", Engine)
        self.mgr = vs.build_session_manager(registry)

        self.store = RunStore()
        self.fleet = vs.FleetFan()
        self.store.listener = self.fleet.publish
        vs.VertusHandler.sessions = self.mgr
        vs.VertusHandler.registry = registry
        vs.VertusHandler.token = "test-token"
        vs.VertusHandler.store = self.store
        vs.VertusHandler.fleet = self.fleet
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.server.shutdown()
        self.store.stop()
        # Reset the shared handler-class attrs so other test modules (which
        # run in the same process) never see this hub's store/fleet.
        vs.VertusHandler.store = None
        vs.VertusHandler.fleet = None


@pytest.fixture()
def hub(tmp_path, monkeypatch):
    h = Hub(tmp_path, monkeypatch)
    yield h
    h.close()


def _req(base: str, path: str, method: str = "GET", payload: dict | None = None,
         token: str = "test-token"):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        base + path, data=data,
        headers={"Authorization": f"Bearer {token}"}, method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {}


def _prompt(base: str, agent_id: str, text: str) -> tuple[int, dict]:
    return _req(base, "/api/prompt", "POST",
                {"text": text, "agent_id": agent_id})


def _wait_until(pred, timeout: float = 12.0, interval: float = 0.01):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return False


class SseReader:
    """Reads one SSE stream into a list of parsed events. Optional per-frame
    throttle to simulate a slow subscriber (frame_delay). eof is set when the
    server closes the connection (run streams do this after their terminal)."""

    def __init__(self, base: str, path: str, frame_delay: float = 0.0,
                 timeout: float = 40.0):
        req = urllib.request.Request(
            base + path, headers={"Authorization": "Bearer test-token"})
        self.resp = urllib.request.urlopen(req, timeout=timeout)
        self.events: list[dict] = []
        self.eof = threading.Event()
        self.frame_delay = frame_delay
        self._buf = b""
        self._closed = False
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._closed:
            try:
                chunk = self.resp.read1(4096)
            except Exception:  # noqa: BLE001 — connection closed
                break
            if not chunk:
                break
            self._buf += chunk
            while b"\n\n" in self._buf:
                frame, self._buf = self._buf.split(b"\n\n", 1)
                for line in frame.decode(errors="replace").splitlines():
                    if line.startswith("data: "):
                        self.events.append(json.loads(line[6:]))
                if self.frame_delay:
                    time.sleep(self.frame_delay)
        self.eof.set()

    def wait(self, pred, timeout: float = 15.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if pred(self.events):
                return True
            time.sleep(0.01)
        return pred(self.events)

    def wait_eof(self, timeout: float = 15.0) -> bool:
        return self.eof.wait(timeout)

    def close(self) -> None:
        self._closed = True
        # The reader thread may be parked inside read1() on a live stream.
        # Calling resp.close() from here while it is would race the same fp,
        # so first shutdown the socket (recv returns immediately), join the
        # reader, and only then close from this thread.
        try:
            raw = self.resp.fp.raw
            sock = raw._sock if hasattr(raw, "_sock") else raw
            sock.shutdown(socket.SHUT_RDWR)
        except Exception:  # noqa: BLE001 — already closed/EOF'd
            pass
        self._thread.join(timeout=5)
        try:
            self.resp.close()
        except Exception:  # noqa: BLE001
            pass


def _seqs(events: list[dict]) -> list[int]:
    return [int(e["seq"]) for e in events]


# ----------------------------------------------------------------------
# Identity on the wire + POST /api/prompt run_id + lifecycle
# ----------------------------------------------------------------------


def test_events_carry_identity_and_prompt_returns_run_id(hub):
    base, store = hub.base, hub.store
    reader = SseReader(base, "/api/events?agent_id=scout")
    status, body = _prompt(base, "scout", "hello world")
    assert status == 202 and body["agent_id"] == "scout"
    run_id = body["run_id"]
    assert run_id and len(run_id) == 32, "202 must return the queued run id"

    assert _wait_until(lambda: store.get_run(run_id) is not None)
    assert _wait_until(lambda: store.get_run(run_id)["state"] == "done")
    assert reader.wait(lambda ev: ev and ev[-1]["type"] == "done")
    reader.close()

    run = store.get_run(run_id)
    assert run["state"] == "done" and run["agent_id"] == "scout"
    assert run["prompt"] == "hello world" and run["remote"] == 0
    # Every envelope carries the identity keys; type/text unchanged.
    for ev in reader.events:
        assert ev["agent_id"] == "scout"
        assert ev["run_id"] == run_id
        assert isinstance(ev["seq"], int) and ev["seq"] > 0
        assert isinstance(ev["ts"], float)
    types = [e["type"] for e in reader.events]
    assert types == ["text", "done"], types
    # Deltas stored one per row; assistant text folded into ONE message.
    ev_rows = store.events_after(0, run_id=run_id)
    assert len(ev_rows) == 2  # 1 delta + done
    msgs = store.run_messages(run_id)
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[0]["text"] == "hello world"
    assert msgs[1]["text"] == "hello world#0"


def test_run_lifecycle_queued_running_done(hub_factory):
    """queued -> running -> done, with terminal set exactly once.

    Determinism: run one is SLOW (0.15s per turn), so while it is running a
    second prompt is observable in the queued state."""
    h = hub_factory(deltas=1, delay=0.15)
    base, store = h.base, h.store
    status, body = _prompt(base, "scout", "slow-turn")
    assert status == 202
    run1 = body["run_id"]
    # The worker flips run1 to running (its turn sleeps 0.15s).
    assert _wait_until(lambda: (store.get_run(run1) or {})["state"] == "running")

    status, body = _prompt(base, "scout", "queued-behind")
    assert status == 202
    run2 = body["run_id"]
    # run2 cannot start: run1 holds the agent's single worker.
    assert store.get_run(run2)["state"] == "queued"

    assert _wait_until(lambda: (store.get_run(run2) or {})["state"] == "done",
                       timeout=15)
    for run_id in (run1, run2):
        run = store.get_run(run_id)
        assert run["state"] == "done"
        assert run["started_at"] is not None and run["ended_at"] is not None
        assert run["ended_at"] >= run["started_at"]
    assert store.get_run(run1)["gateway_respawns"] == 0
    # Terminal is set exactly once: finishing again is a no-op.
    assert store.finish_run(run1, "error") is False
    h.close()


def test_run_error_state_and_message(hub_factory):
    h = hub_factory(mode="raise")
    base, store = h.base, h.store
    status, body = _prompt(base, "scout", "boom")
    run_id = body["run_id"]
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "error")
    run = store.get_run(run_id)
    assert "engine exploded" in (run["error"] or "")
    rows = store.events_after(0, run_id=run_id)
    assert rows[-1]["type"] == "error", "error wire event stored"
    assert not any(e["type"] == "done" for e in rows)
    h.close()


def test_run_gateway_respawn_counted(hub_factory):
    h = hub_factory(mode="brokenpipe-once")
    base, store = h.base, h.store
    status, body = _prompt(base, "scout", "survive")
    run_id = body["run_id"]
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "done")
    run = store.get_run(run_id)
    assert run["gateway_respawns"] == 1, "a died-then-respawned turn counts one respawn"
    rows = store.events_after(0, run_id=run_id)
    assert rows[-1]["type"] == "done"
    h.close()


def test_seq_strictly_monotonic_across_agents(hub):
    base, store = hub.base, hub.store
    # Fire concurrent turns at three agents (different bridges/queues).
    _req(base, "/api/agents", "POST", {"name": "Zephyr"})
    statuses = [
        _prompt(base, "primary", "p-1"),
        _prompt(base, "scout", "s-1"),
        _prompt(base, "zephyr", "z-1"),
    ]
    assert all(s == 202 for s, _ in statuses)
    deadline = time.time() + 12
    while time.time() < deadline:
        active = [r["state"] for r in store.list_runs()
                  if r["state"] in ("queued", "running")]
        if not active and len(store.list_runs()) == 3:
            break
        time.sleep(0.01)
    runs = store.list_runs()
    assert {r["agent_id"] for r in runs} == {"primary", "scout", "zephyr"}
    assert all(r["state"] == "done" for r in runs)
    all_events = store.events_after(0)
    seqs = _seqs(all_events)
    assert seqs == sorted(seqs), "one global sequence, ordered by commit"
    assert len(seqs) == len(set(seqs)), "seq must never repeat"
    for run in runs:
        run_events = store.events_after(0, run_id=run["run_id"])
        for e in run_events:
            assert e["agent_id"] == run["agent_id"]


# ----------------------------------------------------------------------
# Store-before-fanout
# ----------------------------------------------------------------------


def test_store_write_failure_errors_run_and_emits_nothing(hub, monkeypatch):
    base, store = hub.base, hub.store
    bridge = hub.mgr.get_or_create_session("scout")
    q = bridge.subscribe(maxsize=100)

    real_record = store.record_event

    def _failing_record(agent_id, run_id, event):
        raise RuntimeError("disk full (test)")

    monkeypatch.setattr(store, "record_event", _failing_record)
    try:
        status, body = _prompt(base, "scout", "will-not-persist")
        assert status == 202
        run_id = body["run_id"]
        assert _wait_until(
            lambda: (store.get_run(run_id) or {})["state"] == "error"
        )
        # No client event ever left the store: the subscriber got nothing.
        assert q.empty(), "fanout must not happen when the store write fails"
        # And nothing of the run is in the store's event table.
        rows = store.events_after(0, run_id=run_id)
        assert rows == [], "no event may exist in the store for a failed run"
        run = store.get_run(run_id)
        assert "event store failure" in (run["error"] or "")
    finally:
        monkeypatch.setattr(store, "record_event", real_record)


# ----------------------------------------------------------------------
# Replay: no gap, no duplicate
# ----------------------------------------------------------------------


def test_replay_handoff_since_no_gap_no_duplicate(hub):
    """Drain (since, S0] then live: nothing skipped, nothing doubled."""
    base, store = hub.base, hub.store
    # Run A completes before any subscriber exists.
    _prompt(base, "scout", "run-A")
    deadline = time.time() + 12
    while time.time() < deadline:
        runs = store.list_runs(agent_id="scout")
        if runs and runs[0]["state"] == "done":
            break
        time.sleep(0.01)
    run_a = store.list_runs(agent_id="scout")[0]
    a_events = store.events_after(0, run_id=run_a["run_id"])
    a_last_seq = a_events[-1]["seq"]

    # Connect with since=0 AFTER the run finished: the drain replays the whole
    # run from the store exactly once; nothing further arrives live.
    reader = SseReader(base, "/api/events?agent_id=scout&since=0")
    assert reader.wait(
        lambda ev: len(ev) == len(a_events) and ev[-1]["type"] == "done", 8.0
    )
    assert _seqs(reader.events) == _seqs(a_events), "full replay, exact order"

    # Run B fires while the reader is live: handed off with no gap/dupe.
    _prompt(base, "scout", "run-B")
    assert reader.wait(
        lambda ev: any(e["type"] == "done" and e["run_id"] != run_a["run_id"]
                       for e in ev), 8.0
    )
    seen = _seqs(reader.events)
    assert seen == sorted(seen) and len(seen) == len(set(seen))
    assert seen[0] == a_events[0]["seq"]
    # Exactly a_events ∪ b_events, in store order.
    all_store = store.events_after(0, agent_id="scout")
    assert seen == _seqs(all_store), "stream == store: no gap, no duplicate"
    reader.close()


def test_replay_event_landing_mid_drain(hub_factory):
    """Events committed WHILE a since= drain is running arrive exactly once.

    Run C is gated mid-flight; the replay subscriber connects with
    since=<end of history> and drains the store's older rows (more than one
    500-row chunk, so the drain is still active when C's tail commits). C's
    tail lands after the S0 snapshot, so it may only arrive via the live
    tail; the reader must end holding exactly the store's rows — no gap, no
    duplicate, regardless of where the drain/live boundary fell.
    """
    gate = threading.Event()
    # 1) Seed enough finished history that the drain spans >1 chunk.
    h = hub_factory(deltas=60, delay=0.0)
    base, store = h.base, h.store
    for i in range(10):
        _prompt(base, "scout", f"history-{i}")
    assert _wait_until(
        lambda: len(store.list_runs(agent_id="scout")) == 10
        and all(r["state"] == "done" for r in store.list_runs(agent_id="scout")),
        timeout=30,
    )
    history_events = len(store.events_after(0, agent_id="scout"))
    assert history_events > 500, (
        f"need >500 history events for a multi-chunk drain, got {history_events}"
    )
    h.close()

    # 2) Same DB file, fresh hub with a gated engine for run C.
    h2 = hub_factory(deltas=8, delay=0.002, gate=gate)
    base2, store2 = h2.base, h2.store
    hist = store2.events_after(0, agent_id="scout")
    since_seq = hist[-1]["seq"]

    _prompt(base2, "scout", "run-C")
    run_c = [r for r in store2.list_runs(agent_id="scout")
             if r["prompt"] == "run-C"][0]
    c_id = run_c["run_id"]
    # Run C holds before delta index 6 (6 of its 8 deltas are committed).
    assert _wait_until(
        lambda: len(store2.events_after(0, run_id=c_id)) >= 6, 10.0
    )

    # 3) Connect with since=<end of history> while C is mid-flight; the drain
    # replays the 600+ history rows (multi-chunk).
    reader = SseReader(base2, f"/api/events?agent_id=scout&since={since_seq}")
    time.sleep(0.2)  # the drain is (very likely) still draining when released
    gate.set()  # C's remaining deltas + done commit during/after the drain
    assert reader.wait(lambda ev: ev and ev[-1]["type"] == "done", 15.0)
    reader.close()

    # 4) Reader == store after since: mid-drain commits were not missed or
    # doubled, and older history was not replayed twice.
    expected = store2.events_after(since_seq, agent_id="scout")
    got = reader.events
    assert _seqs(got) == _seqs(expected), (
        f"handoff mismatch: got {len(got)} vs store {len(expected)}"
    )
    assert all(e["run_id"] == c_id for e in got)
    assert expected[-1]["type"] == "done"
    h2.close()


# ----------------------------------------------------------------------
# Lagged drop + since= resume
# ----------------------------------------------------------------------


def test_lagged_marker_emitted_on_overflow(hub):
    """A subscriber that can't keep up is told (best effort) then dropped."""
    base, store = hub.base, hub.store
    bridge = hub.mgr.get_or_create_session("scout")

    class _FitsLagged(Queue):
        """Simulates a client draining concurrently: the ordinary event hits a
        full queue, then the small lagged marker fits."""

        def __init__(self):
            super().__init__(maxsize=10)
            self.overflowed = False

        def put_nowait(self, item):
            if item.get("type") != "lagged" and not self.overflowed:
                self.overflowed = True
                raise __import__("queue").Full
            super().put_nowait(item)

    q = _FitsLagged()
    bridge.subscribers.append(q)
    bridge._fanout({"type": "text", "text": "x", "seq": 7,
                    "agent_id": "scout", "run_id": "r", "ts": 1.0})
    marker = q.get_nowait()
    assert marker["type"] == "lagged"
    assert marker["last_seq"] == 7, "lagged carries the seq the client missed"
    assert q not in bridge.subscribers, "the laggard is dropped after the marker"
    # Other subscribers were unaffected.
    assert len(bridge.subscribers) == 0


def test_resume_after_lagged_drop(hub_factory):
    """A slow subscriber overflows and is dropped; reconnecting with since=
    replays exactly the missed events — no gap, no duplicate."""
    h = hub_factory(deltas=3000, delay=0.0)
    base, store = h.base, h.store
    slow = SseReader(base, "/api/events?agent_id=scout", frame_delay=0.02)
    # Wait until the slow reader is subscribed (headers + a beat) then fire.
    time.sleep(0.3)
    status, body = _prompt(base, "scout", "firehose")
    assert status == 202
    run_id = body["run_id"]
    # Let the burst finish in the store (the slow reader overflows meanwhile).
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "done",
                       timeout=30)
    time.sleep(0.5)
    # Stop the slow reader NOW: its queued backlog dies with the connection,
    # so its event list is a stable prefix of the stream (no concurrent tail
    # can keep growing past the snapshot point).
    slow.close()
    slow.wait_eof(5)
    got = list(slow.events)
    assert got, "slow reader must have received a prefix before the drop"
    assert len(got) < 3001, "slow reader must not have kept up with the burst"
    last_seen = max(_seqs(got))

    # Ground truth of everything the reader has NOT seen.
    missing = store.events_after(last_seen, agent_id="scout")
    assert missing, "the drop must have skipped some events"

    # Resume with since=<the last seq the client processed>.
    resumer = SseReader(
        base, f"/api/events?agent_id=scout&since={last_seen}")
    assert resumer.wait(
        lambda ev: len(ev) == len(missing) and ev[-1]["type"] == "done",
        timeout=25,
    )
    assert _seqs(resumer.events) == _seqs(missing), (
        "resume must replay exactly the missed events, once"
    )
    # The two streams are disjoint and together cover the whole run.
    combined = _seqs(got) + _seqs(resumer.events)
    assert len(combined) == len(set(combined)), "no duplicate across streams"
    store_seq = _seqs(store.events_after(0, agent_id="scout"))
    assert sorted(combined) == store_seq, (
        "slow prefix + resume must equal the store, no gaps"
    )
    resumer.close()
    h.close()


# ----------------------------------------------------------------------
# Fleet stream + per-agent filter
# ----------------------------------------------------------------------


def test_fleet_stream_carries_all_agents_agent_filter_carries_one(hub):
    base, store = hub.base, hub.store
    fleet = SseReader(base, "/api/events")
    agent_only = SseReader(base, "/api/events?agent_id=scout")
    time.sleep(0.2)  # both subscribers attached
    _prompt(base, "primary", "from-primary")
    _prompt(base, "scout", "from-scout")
    assert fleet.wait(
        lambda ev: any(e["agent_id"] == "primary" and e["type"] == "done"
                       for e in ev)
        and any(e["agent_id"] == "scout" and e["type"] == "done" for e in ev),
        10.0,
    )
    assert agent_only.wait(
        lambda ev: any(e["type"] == "done" for e in ev), 10.0
    )
    fleet.close()
    time.sleep(0.1)  # let the agent stream catch the scout turn
    seen_agents = {e["agent_id"] for e in agent_only.events}
    assert seen_agents == {"scout"}, (
        f"agent-filtered stream leaked other agents: {seen_agents}"
    )
    assert {"primary", "scout"} <= {e["agent_id"] for e in fleet.events}
    agent_only.close()


def test_run_stream_closes_after_terminal(hub_factory):
    """?run_id= streams that run's events only and closes on its terminal."""
    gate = threading.Event()
    h = hub_factory(deltas=6, delay=0.004, gate=gate)
    base, store = h.base, h.store
    _prompt(base, "scout", "streamed-run")
    run = store.list_runs(agent_id="scout")[0]
    run_id = run["run_id"]
    # Connect while the run is mid-flight (gate holds before the last delta).
    assert _wait_until(
        lambda: len(store.events_after(0, run_id=run_id)) >= 4, 10.0
    )
    reader = SseReader(base, f"/api/events?run_id={run_id}")
    time.sleep(0.15)
    gate.set()
    assert reader.wait(lambda ev: ev and ev[-1]["type"] == "done", 10.0)
    assert reader.wait_eof(10.0), "run stream must close after its terminal"
    reader.close()
    assert _seqs(reader.events) == _seqs(store.events_after(0, run_id=run_id))
    # No events from other agents/runs leaked into the stream.
    assert all(e["run_id"] == run_id for e in reader.events)
    h.close()


def test_run_stream_fully_terminated_run_replays_then_closes(hub):
    base, store = hub.base, hub.store
    _prompt(base, "scout", "already-done")
    assert _wait_until(
        lambda: (store.list_runs(agent_id="scout")[0])["state"] == "done")
    run = store.list_runs(agent_id="scout")[0]
    reader = SseReader(base, f"/api/events?run_id={run['run_id']}")
    # The drain replays everything (incl. the terminal) and the stream closes.
    assert reader.wait(lambda ev: ev and ev[-1]["type"] == "done", 8.0)
    assert reader.wait_eof(8.0)
    expected = store.events_after(0, run_id=run["run_id"])
    assert _seqs(reader.events) == _seqs(expected)
    reader.close()


# ----------------------------------------------------------------------
# History endpoints
# ----------------------------------------------------------------------


def test_history_endpoints_and_pagination(hub):
    base, store = hub.base, hub.store
    for i in range(3):
        _prompt(base, "scout", f"message-run-{i}")
    assert _wait_until(
        lambda: len(store.list_runs(agent_id="scout")) == 3
        and all(r["state"] == "done" for r in store.list_runs(agent_id="scout")),
        15.0,
    )
    # messages: newest-first, before= message id, empty page, limit cap.
    status, body = _req(base, "/api/agents/scout/messages")
    assert status == 200
    all_msgs = body["messages"]
    assert len(all_msgs) == 6  # 3 user + 3 assistant
    ids = [m["id"] for m in all_msgs]
    assert ids == sorted(ids, reverse=True), "newest first"

    status, body = _req(base, "/api/agents/scout/messages?limit=2")
    assert status == 200 and len(body["messages"]) == 2
    assert body["messages"][0]["id"] == ids[0]

    before = ids[0]
    status, body = _req(base, f"/api/agents/scout/messages?before={before}&limit=2")
    assert status == 200
    assert [m["id"] for m in body["messages"]] == ids[1:3], "exact before= cursor"

    status, body = _req(base, "/api/agents/scout/messages?before=1")
    assert status == 200 and body["messages"] == [], "empty page past the start"

    # The limit is a server-side cap (200): seed >200 rows and confirm.
    for i in range(220):
        store.add_message("seed-run", "scout", "assistant", f"noise-{i}")
    status, body = _req(base, "/api/agents/scout/messages?limit=999999")
    assert status == 200 and len(body["messages"]) == 200, "limit capped at 200"

    # runs list filters + before (created_at) cursor.
    status, body = _req(base, "/api/runs?agent_id=scout&state=done")
    assert status == 200 and len(body["runs"]) == 3
    created = [r["created_at"] for r in body["runs"]]
    assert created == sorted(created, reverse=True)
    status, body = _req(base, f"/api/runs?agent_id=scout&before={created[0]}")
    assert status == 200 and len(body["runs"]) == 2
    status, body = _req(base, "/api/runs?agent_id=scout&state=bogus")
    assert status == 400
    # run detail: row + chronological messages.
    run_id = store.list_runs(agent_id="scout")[0]["run_id"]
    status, body = _req(base, f"/api/runs/{run_id}")
    assert status == 200 and body["run"]["run_id"] == run_id
    msgs = body["messages"]
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[0]["created_at"] <= msgs[1]["created_at"]
    # fleet activity: newest runs across all agents.
    _prompt(base, "primary", "activity-run")
    assert _wait_until(lambda: any(
        r["agent_id"] == "primary" and r["state"] == "done"
        for r in store.list_runs()), 10.0)
    status, body = _req(base, "/api/fleet/activity?limit=3")
    assert status == 200
    acts = body["activity"]
    assert len(acts) == 3
    assert {"primary", "scout"} <= {a["agent_id"] for a in acts}
    assert all("run_id" in a and "state" in a and "prompt" in a for a in acts)
    # unknown agent messages → 404; history endpoints never build bridges.
    status, body = _req(base, "/api/agents/ghost/messages")
    assert status == 404
    status, body = _req(base, "/api/runs/not-a-real-run")
    assert status == 404
    assert not hub.mgr.has_session("ghost")


def test_history_survives_agent_delete(hub):
    """DELETE keeps run/message rows — they are the record of what the bot did."""
    base, store = hub.base, hub.store
    _req(base, "/api/agents", "POST", {"name": "Doomed"})
    _prompt(base, "doomed", "last words")
    assert _wait_until(lambda: any(
        r["agent_id"] == "doomed" and r["state"] == "done"
        for r in store.list_runs()), 10.0)
    run = [r for r in store.list_runs(agent_id="doomed")][0]
    status, body = _req(base, "/api/agents/doomed", "DELETE")
    assert status == 200
    # History is still queryable and complete.
    status, body = _req(base, f"/api/runs/{run['run_id']}")
    assert status == 200 and len(body["messages"]) == 2
    status, body = _req(base, "/api/runs?agent_id=doomed")
    assert status == 200 and len(body["runs"]) == 1
    status, body = _req(base, "/api/agents/doomed/messages")
    assert status == 404, "agent-scoped endpoint 404s once the agent is gone"
    # A deleted id prompts fresh (new registry entry) without old history merge.
    _req(base, "/api/agents", "POST", {"name": "Doomed"})
    _prompt(base, "doomed", "second life")
    assert _wait_until(lambda: len(store.list_runs(agent_id="doomed")) == 2, 10.0)


# ----------------------------------------------------------------------
# Crash recovery
# ----------------------------------------------------------------------


def test_crash_recovery_interrupts_leftover_runs(tmp_path, monkeypatch):
    monkeypatch.setenv("VERTUS_DB_PATH", str(tmp_path / "fleet.db"))
    store_a = RunStore()
    # Two runs written as running (hub died mid-turn), one done, one queued.
    r1 = store_a.create_run("primary", "was-running", remote=False)
    store_a.mark_running(r1, "primary")
    r2 = store_a.create_run("scout", "still-queued", remote=False)
    store_a.mark_running(r2, "scout")
    r3 = store_a.create_run("primary", "finished", remote=False)
    store_a.mark_running(r3, "primary")
    store_a.finish_run(r3, "done")
    store_a.stop()

    # Simulate a hub restart: a fresh store on the same DB + boot recovery.
    store_b = RunStore(tmp_path / "fleet.db")
    try:
        assert store_b.get_run(r1)["state"] == "running"
        assert store_b.get_run(r2)["state"] == "running"
        count = store_b.recover_interrupted()
        assert count == 2, f"expected 2 interrupted, got {count}"
        assert store_b.get_run(r1)["state"] == "interrupted"
        assert store_b.get_run(r1)["ended_at"] is not None
        assert store_b.get_run(r2)["state"] == "interrupted"
        assert store_b.get_run(r3)["state"] == "done", "terminal runs untouched"
        # Idempotent: nothing else to recover.
        assert store_b.recover_interrupted() == 0
    finally:
        store_b.stop()


def test_retention_prunes_events_only(tmp_path, monkeypatch):
    monkeypatch.setenv("VERTUS_DB_PATH", str(tmp_path / "fleet.db"))
    store = RunStore()
    try:
        run_id = store.create_run("primary", "old", remote=False)
        store.mark_running(run_id, "primary")
        store.record_event("primary", run_id, {"type": "text", "text": "old"})
        store.finish_run(run_id, "done")
        # Age the event well beyond the TTL (committed via its own connection).
        import sqlite3

        conn = sqlite3.connect(str(store.path))
        try:
            conn.execute("UPDATE events SET ts = ts - 10000000")
            conn.commit()
        finally:
            conn.close()
        pruned = store.prune_events(ttl_days=30)
        assert pruned == 1
        assert store.events_after(0) == []
        # runs/messages are never pruned.
        assert store.get_run(run_id) is not None
    finally:
        store.stop()


# ----------------------------------------------------------------------
# Fixture helpers as plain functions for parameterized hubs
# ----------------------------------------------------------------------


@pytest.fixture()
def hub_factory(tmp_path, monkeypatch):
    created = []

    def _make(*, mode="normal", deltas=1, delay=0.0, gate=None):
        h = Hub(tmp_path, monkeypatch, mode=mode, deltas=deltas,
                delay=delay, gate=gate)
        created.append(h)
        return h

    yield _make
    for h in created:
        h.close()
