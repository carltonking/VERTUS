"""Routine scheduler tests (Checkpoint 2).

Exercises RoutineManager against a REAL store + registry with fake session
bridges and a controllable clock: schedule firing, trigger matching
(run_completed / bot_message), missed-fire catch-up, busy/degraded/deleted
agents, the never-concurrent rule, the failure threshold, and agent-DELETE
disabling. HTTP surface lives in test_fleet_routines_http.py.
"""

from __future__ import annotations

from agent_registry import AgentRegistry
from fleet_routines import (
    FAILURE_THRESHOLD, RoutineManager, RoutineValidationError,
    parse_schedule, parse_trigger,
)
from run_store import RunStore


class FakeBridge:
    def __init__(self, agent_id: str):
        self.agent_id = agent_id
        self.store = None
        self.calls: list[dict] = []
        self._degraded = None
        self._current: str | None = None

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

    def get_or_create_unattended_session(self, agent_id):
        # In tests, unattended sessions are the same as regular sessions
        return self.bridges.setdefault(agent_id, FakeBridge(agent_id))

    def __getitem__(self, agent_id):
        return self.get_or_create_session(agent_id)


def _env(tmp_path):
    registry = AgentRegistry(root=str(tmp_path / "agents"))
    a = registry.create_agent("Alpha")
    b = registry.create_agent("Bravo")
    store = RunStore(path=tmp_path / "fleet.db")
    sessions = FakeSessions()
    clock = [1000.0]

    def now():
        return clock[0]

    mgr = RoutineManager(lambda: store, registry, lambda: sessions,
                         tick_s=0.05, now_fn=now, autostart=False)
    return {
        "registry": registry, "store": store, "sessions": sessions,
        "mgr": mgr, "clock": clock, "a": a["id"], "b": b["id"],
    }


def _drain(mgr):
    while not mgr._queue.empty():
        mgr._handle_item(mgr._queue.get_nowait())


def _mk_routine(env, agent_id=None, interval=60, trigger=None, prompt="do it"):
    store = env["store"]
    agent_id = agent_id or env["a"]
    r = store.create_routine(
        agent_id, "TestRoutine", prompt,
        {"interval_s": interval} if trigger is None else None,
        trigger,
    )
    return store.get_routine(r["routine_id"])


# ----------------------------------------------------------------------
# Schedule
# ----------------------------------------------------------------------

def test_schedule_fires_and_advances(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env)
    mgr.arm(r["routine_id"], {"interval_s": 60})
    clock[0] += 61
    mgr.catch_up()
    run_id = store.get_routine(r["routine_id"])["last_run_id"]
    assert run_id
    run = store.get_run(run_id)
    assert run["state"] == "queued"
    assert run["run_kind"] == "routine"
    assert run["routine_id"] == r["routine_id"]
    assert run["source"] == f"routine:{r['routine_id']}"
    assert run["from_agent"] is None  # routines are never bot-attributed
    bridge = env["sessions"].get_or_create_session(env["a"])
    assert bridge.calls and bridge.calls[0]["run_id"] == run_id
    assert bridge.calls[0]["run_kind"] == "routine"
    # next fire is a full interval away — not immediately due again
    updated = store.get_routine(r["routine_id"])
    assert updated["next_run_at"] == clock[0] + 60
    assert updated["failure_count"] == 0


def test_not_due_until_armed_and_interval_elapses(tmp_path):
    env = _env(tmp_path)
    store, mgr = env["store"], env["mgr"]
    r = _mk_routine(env)
    mgr.arm(r["routine_id"], {"interval_s": 60})
    mgr.catch_up()  # not due yet
    assert store.get_routine(r["routine_id"])["last_run_id"] is None


# ----------------------------------------------------------------------
# Missed-fire catch-up
# ----------------------------------------------------------------------

def test_missed_fire_runs_exactly_once_across_a_long_downtime(tmp_path):
    """next_run_at far in the past (laptop slept 10h): EXACTLY one catch-up
    fire, then the schedule is resynced to now + interval."""
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env)
    mgr.arm(r["routine_id"], {"interval_s": 60})
    clock[0] += 60 * 60 * 10  # 10 hours later
    mgr.catch_up()
    updated = store.get_routine(r["routine_id"])
    assert updated["last_run_id"]
    assert updated["next_run_at"] == clock[0] + 60  # resynced, not stacked
    # A second pass must not fire again.
    mgr.catch_up()
    assert store.get_routine(r["routine_id"])["last_run_id"] == updated["last_run_id"]


# ----------------------------------------------------------------------
# Triggers
# ----------------------------------------------------------------------

def test_run_completed_trigger_fires_on_right_agent_only(tmp_path):
    env = _env(tmp_path)
    store, mgr = env["store"], env["mgr"]
    watches_b = _mk_routine(env,
                    trigger={"type": "run_completed", "agent_id": env["b"]})
    watches_a = _mk_routine(env,
                    trigger={"type": "run_completed", "agent_id": env["a"]})
    # A run of agent A completes: only watches_a fires (watches_b is silent).
    mgr.on_event({"type": "done", "agent_id": env["a"], "run_id": "r1", "seq": 1})
    _drain(mgr)
    assert store.get_routine(watches_a["routine_id"])["last_run_id"]
    assert store.get_routine(watches_b["routine_id"])["last_run_id"] is None
    # A run of agent B completes: only watches_b fires.
    mgr.on_event({"type": "error", "agent_id": env["b"], "run_id": "r2", "seq": 2})
    _drain(mgr)
    assert store.get_routine(watches_b["routine_id"])["last_run_id"]


def test_bot_message_trigger_matches_filters(tmp_path):
    env = _env(tmp_path)
    store, mgr = env["store"], env["mgr"]
    r_all = _mk_routine(env, trigger={"type": "bot_message"})
    r_from = _mk_routine(env, trigger={"type": "bot_message", "from_agent": env["a"]})
    # Message from B: r_all fires, r_from does not.
    mgr.on_event({"type": "bot_message", "from_agent": env["b"],
                  "thread_id": "t1", "status": "delivered", "seq": 3})
    _drain(mgr)
    assert store.get_routine(r_all["routine_id"])["last_run_id"]
    assert store.get_routine(r_from["routine_id"])["last_run_id"] is None
    # Message from A: both fire.
    mgr.on_event({"type": "bot_message", "from_agent": env["a"],
                  "thread_id": "t2", "status": "delivered", "seq": 4})
    _drain(mgr)
    assert store.get_routine(r_from["routine_id"])["last_run_id"]
    # A DROPPED message (depth/rate cap) must never wake a bot.
    before = store.get_routine(r_all["routine_id"])["last_run_id"]
    mgr.on_event({"type": "bot_message", "from_agent": env["a"],
                  "thread_id": "t3", "status": "dropped_depth", "seq": 5})
    _drain(mgr)
    assert store.get_routine(r_all["routine_id"])["last_run_id"] == before


def test_trigger_only_routine_never_fires_on_tick(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env, trigger={"type": "bot_message"})
    clock[0] += 10000  # no schedule: even a far-future tick must not fire it
    mgr.catch_up()
    assert store.get_routine(r["routine_id"])["last_run_id"] is None
    mgr.on_event({"type": "bot_message", "from_agent": env["b"],
                  "thread_id": "t", "status": "delivered", "seq": 6})
    _drain(mgr)
    assert store.get_routine(r["routine_id"])["last_run_id"]


def test_schedule_only_routine_ignores_events(tmp_path):
    env = _env(tmp_path)
    store, mgr = env["store"], env["mgr"]
    r = _mk_routine(env, interval=60)
    mgr.on_event({"type": "done", "agent_id": env["a"], "run_id": "r", "seq": 7})
    mgr.on_event({"type": "bot_message", "from_agent": env["b"],
                  "thread_id": "t", "status": "delivered", "seq": 8})
    _drain(mgr)
    assert store.get_routine(r["routine_id"])["last_run_id"] is None


# ----------------------------------------------------------------------
# Gates: busy / degraded / deleted / never-concurrent
# ----------------------------------------------------------------------

def test_fire_while_busy_queues_behind_current_work(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env)
    mgr.arm(r["routine_id"], {"interval_s": 60})
    bridge = env["sessions"].get_or_create_session(env["a"])
    bridge._current = "running-now"  # agent busy with a human turn
    clock[0] += 61
    mgr.catch_up()
    run = store.get_run(store.get_routine(r["routine_id"])["last_run_id"])
    assert run["state"] == "queued"  # queued behind, never dropped
    assert bridge.calls[0]["text"] == "do it"


def test_degraded_skips_and_counts_failure(tmp_path):
    env = _env(tmp_path)
    store, mgr = env["store"], env["mgr"]
    r = _mk_routine(env)
    env["sessions"].get_or_create_session(env["a"])._degraded = "gateway down"
    mgr._fire(store.get_routine(r["routine_id"]))
    updated = store.get_routine(r["routine_id"])
    assert updated["failure_count"] == 1
    assert updated["last_run_id"] is None  # nothing spawned
    assert store.list_runs() == []  # no run row at all


def test_never_concurrent_with_itself(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env, interval=1)
    mgr.arm(r["routine_id"], {"interval_s": 1})
    clock[0] += 2
    mgr.catch_up()  # first fire
    first = store.get_routine(r["routine_id"])["last_run_id"]
    assert first
    # The first run is still queued: the next due tick must NOT fire again.
    clock[0] += 2
    mgr.catch_up()
    assert store.get_routine(r["routine_id"])["last_run_id"] == first
    assert len(store.list_runs()) == 1
    # Once the first run goes terminal, the next tick fires again (re-arm).
    store.finish_run(first, "done", error=None)
    clock[0] += 2
    mgr.catch_up()
    second = store.get_routine(r["routine_id"])["last_run_id"]
    assert second != first
    assert len(store.list_runs()) == 2


def test_deleted_agent_disables_routine(tmp_path):
    env = _env(tmp_path)
    store, mgr = env["store"], env["mgr"]
    r = _mk_routine(env)
    env["registry"].delete_agent(env["a"], archive=False)
    env["store"].disable_routines_for(env["a"])
    # The scheduler's existence gate would disable it anyway; the DELETE
    # handler disables BEFORE that so no zombie routine can race a re-add.
    assert store.get_routine(r["routine_id"])["enabled"] == 0
    mgr._fire(store.get_routine(r["routine_id"]))
    assert store.list_runs() == []


# ----------------------------------------------------------------------
# Failure threshold
# ----------------------------------------------------------------------

def test_failure_threshold_disables_and_emits(tmp_path):
    env = _env(tmp_path)
    store, mgr = env["store"], env["mgr"]
    r = _mk_routine(env)
    env["sessions"].get_or_create_session(env["a"])._degraded = "down"
    for _ in range(FAILURE_THRESHOLD):
        mgr._fire(store.get_routine(r["routine_id"]))
    updated = store.get_routine(r["routine_id"])
    assert updated["failure_count"] == FAILURE_THRESHOLD
    assert updated["enabled"] == 0
    # Idempotent: further fires do nothing, no extra runs, no double events.
    mgr._fire(store.get_routine(r["routine_id"]))
    assert store.list_runs() == []


def test_success_resets_failure_history(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env, interval=1)
    mgr.arm(r["routine_id"], {"interval_s": 1})
    env["sessions"].get_or_create_session(env["a"])._degraded = "down"
    mgr._fire(store.get_routine(r["routine_id"]))
    assert store.get_routine(r["routine_id"])["failure_count"] == 1
    env["sessions"].get_or_create_session(env["a"])._degraded = None
    clock[0] += 2
    mgr.catch_up()  # success resets to 0
    assert store.get_routine(r["routine_id"])["failure_count"] == 0


# ----------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------

def test_schedule_validation():
    assert parse_schedule({"interval_s": 60}) == {"interval_s": 60}
    assert parse_schedule(None) is None
    # The 30s floor is the EXTERNAL contract: the parser rejects anything
    # below it. Tests bypass the parser via store.create_routine (internal
    # path), so sub-30s intervals remain testable.
    for bad in ({"interval_s": 0}, {"interval_s": 1}, {"interval_s": 15},
                {"interval_s": 29}, {"interval_s": -5}, {"interval_s": "60"},
                {"interval_s": True}, {"every": 60}, {}):
        _expect_validation(bad, parse_schedule)
    assert parse_schedule({"interval_s": 30}) == {"interval_s": 30}


def test_trigger_validation():
    assert parse_trigger({"type": "run_completed", "agent_id": "x"}) == {
        "type": "run_completed", "agent_id": "x"}
    assert parse_trigger({"type": "bot_message"})["type"] == "bot_message"
    assert parse_trigger(None) is None
    for bad in ({"type": "run_completed"}, {"type": "file_created"},
                {"type": "bot_message", "from_agent": 7},
                {"type": "bot_message", "thread_id": 7},
                {"type": "bot_message", "depth": 3}):
        _expect_validation(bad, parse_trigger)


def _expect_validation(payload, fn):
    try:
        fn(payload)
    except RoutineValidationError:
        return
    raise AssertionError(f"should have rejected {payload}")