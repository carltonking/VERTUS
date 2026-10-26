"""Routine scheduler tests (Checkpoint 2).

Exercises RoutineManager against a REAL store + registry with fake session
bridges and a controllable clock: schedule firing, trigger matching
(run_completed / bot_message), missed-fire catch-up, busy/degraded/deleted
agents, the never-concurrent rule, the failure threshold, and agent-DELETE
disabling. HTTP surface lives in test_fleet_routines_http.py.
"""

from __future__ import annotations

from agent_registry import AgentRegistry
import threading
import time

from fleet_routines import (
    CATCH_UP_STALE_S, FAILURE_THRESHOLD, RETRY_BASE_S, RETRY_MAX_S,
    RoutineManager, RoutineValidationError, parse_schedule, parse_trigger,
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

# ----------------------------------------------------------------------
# Wall-clock schedules (cron / one-shot at) through the manager
# ----------------------------------------------------------------------

from datetime import datetime  # noqa: E402
from zoneinfo import ZoneInfo  # noqa: E402

_NY = ZoneInfo("America/New_York")


def _ny(*args) -> float:
    return datetime(*args, tzinfo=_NY).timestamp()


def _mk_sched(env, schedule):
    store = env["store"]
    r = store.create_routine(env["a"], "Wall", "brief me", schedule, None)
    env["mgr"].arm(r["routine_id"], schedule)
    return store.get_routine(r["routine_id"])


def _events(store, etype):
    return [e for e in store.events_after(0) if e.get("type") == etype]


def test_cron_arm_targets_next_wall_time_and_advances_after_fire(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 6, 0)
    sched = {"cron": "0 8 * * *", "tz": "America/New_York"}
    r = _mk_sched(env, sched)
    assert store.get_routine(r["routine_id"])["next_run_at"] == _ny(2026, 10, 25, 8, 0)
    clock[0] = _ny(2026, 10, 25, 7, 59)
    mgr.catch_up()
    assert store.get_routine(r["routine_id"])["last_run_id"] is None
    clock[0] = _ny(2026, 10, 25, 8, 0, 1)
    mgr.catch_up()
    updated = store.get_routine(r["routine_id"])
    assert updated["last_run_id"]
    assert updated["next_run_at"] == _ny(2026, 10, 26, 8, 0)


def test_cron_catch_up_after_ten_hours_fires_exactly_once(tmp_path):
    """Hourly check-in, hub down 10 hours: ONE catch-up fire, then the next
    future occurrence — never a backlog of the 10 missed hours."""
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 7, 30)
    r = _mk_sched(env, {"cron": "0 * * * *", "tz": "America/New_York"})
    assert store.get_routine(r["routine_id"])["next_run_at"] == _ny(2026, 10, 25, 8, 0)
    clock[0] = _ny(2026, 10, 25, 17, 45)  # ~10 hours later
    mgr.catch_up()
    first = store.get_routine(r["routine_id"])
    assert first["last_run_id"]
    assert first["next_run_at"] == _ny(2026, 10, 25, 18, 0)
    store.finish_run(first["last_run_id"], "done", error=None)
    mgr.catch_up()
    mgr.catch_up()
    assert len(store.list_runs()) == 1
    assert len(_events(store, "routine_fired")) == 1


def test_one_shot_at_fires_once_then_disables_as_completed(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 12, 0)
    r = _mk_sched(env, {"at": "2026-10-26T09:00:00", "tz": "America/New_York"})
    rid = r["routine_id"]
    assert r["next_run_at"] == _ny(2026, 10, 26, 9, 0)
    clock[0] = _ny(2026, 10, 26, 9, 0, 1)
    mgr.catch_up()
    done = store.get_routine(rid)
    assert done["last_run_id"]
    assert done["enabled"] == 0
    assert done["next_run_at"] is None
    disabled = _events(store, "routine_disabled")
    assert len(disabled) == 1 and disabled[0].get("completed") is True
    # Never fires again — not on later ticks, not even if re-enabled.
    store.finish_run(done["last_run_id"], "done", error=None)
    store.set_routine_enabled(rid, True)
    clock[0] += 86400
    mgr.catch_up()
    assert len(store.list_runs()) == 1


def test_one_shot_failed_fire_does_not_complete(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 12, 0)
    r = _mk_sched(env, {"at": "2026-10-26T09:00:00", "tz": "America/New_York"})
    env["sessions"].get_or_create_session(env["a"])._degraded = "down"
    clock[0] = _ny(2026, 10, 26, 9, 5)
    mgr.catch_up()
    row = store.get_routine(r["routine_id"])
    assert row["enabled"] == 1 and row["failure_count"] == 1
    # Still pending, retried after the backoff (not completed, not dropped).
    assert row["next_run_at"] == clock[0] + RETRY_BASE_S
    env["sessions"].get_or_create_session(env["a"])._degraded = None
    clock[0] += RETRY_BASE_S
    mgr.catch_up()
    row = store.get_routine(r["routine_id"])
    assert row["last_run_id"] and row["enabled"] == 0


def test_manual_run_before_one_shot_time_keeps_it_pending(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 12, 0)
    r = _mk_sched(env, {"at": "2026-10-26T09:00:00", "tz": "America/New_York"})
    mgr._fire(store.get_routine(r["routine_id"]), manual=True)
    row = store.get_routine(r["routine_id"])
    assert row["last_run_id"] and row["enabled"] == 1
    assert row["next_run_at"] == _ny(2026, 10, 26, 9, 0)


def test_cron_and_at_validation_through_parse_schedule():
    now = _ny(2026, 10, 25, 12, 0)
    assert parse_schedule({"cron": "0 8 * * *"}, now=now) == {"cron": "0 8 * * *"}
    for bad in ({"cron": "0 8 * *"}, {"cron": "0 8 * * *", "tz": "No/Where"},
                {"at": "2026-10-24T09:00:00", "tz": "America/New_York"}):
        try:
            parse_schedule(bad, now=now)
        except RoutineValidationError:
            continue
        raise AssertionError(f"accepted invalid schedule {bad!r}")


# ----------------------------------------------------------------------
# Retry backoff (failed scheduled fires)
# ----------------------------------------------------------------------

def _tick_for(mgr, clock, seconds, step=1.0):
    """Drive the scheduler like the live 1s tick for ``seconds``."""
    for _ in range(int(seconds / step)):
        clock[0] += step
        mgr.catch_up()


def test_degraded_gateway_backs_off_instead_of_retrying_every_tick(tmp_path):
    """A gateway blip must not burn THRESHOLD in ~3 one-second ticks: the
    retries are RETRY_BASE_S, then 2x apart, and the third strike still
    disables — just minutes later."""
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env, interval=86400)
    rid = r["routine_id"]
    mgr.arm(rid, {"interval_s": 86400})
    store.set_routine_next(rid, clock[0])  # due now
    env["sessions"].get_or_create_session(env["a"])._degraded = "gateway down"

    _tick_for(mgr, clock, 10)
    row = store.get_routine(rid)
    assert row["failure_count"] == 1 and row["enabled"] == 1
    first_fail = clock[0] - 9
    assert row["next_run_at"] == first_fail + RETRY_BASE_S

    _tick_for(mgr, clock, RETRY_BASE_S)  # second strike at +60s
    row = store.get_routine(rid)
    assert row["failure_count"] == 2 and row["enabled"] == 1
    assert row["next_run_at"] == first_fail + RETRY_BASE_S + 2 * RETRY_BASE_S

    _tick_for(mgr, clock, 2 * RETRY_BASE_S)  # third strike at +180s
    row = store.get_routine(rid)
    assert row["failure_count"] == FAILURE_THRESHOLD and row["enabled"] == 0
    assert store.list_runs() == []


def _set_failures(store, rid, n):
    store._submit(lambda c: c.execute(
        "UPDATE routines SET failure_count = ? WHERE routine_id = ?", (n, rid)), {})


def test_backoff_is_capped_and_never_passes_the_next_regular_occurrence(tmp_path, monkeypatch):
    import fleet_routines

    # Raise the threshold so the doubling can reach the cap in this test.
    monkeypatch.setattr(fleet_routines, "FAILURE_THRESHOLD", 100)
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    env["sessions"].get_or_create_session(env["a"])._degraded = "down"
    # Daily cron: the 9th strike would be 60 * 2**8 s uncapped; it is 15 min.
    clock[0] = _ny(2026, 10, 25, 8, 0, 1)
    cron = _mk_sched(env, {"cron": "0 8 * * *", "tz": "America/New_York"})
    store.set_routine_next(cron["routine_id"], clock[0])
    _set_failures(store, cron["routine_id"], 8)
    mgr.catch_up()
    row = store.get_routine(cron["routine_id"])
    assert row["failure_count"] == 9
    assert row["next_run_at"] == clock[0] + RETRY_MAX_S
    # A 45s interval: its next regular occurrence comes before the 60s retry.
    short = _mk_routine(env, interval=45)
    store.set_routine_next(short["routine_id"], clock[0])
    mgr.catch_up()
    assert store.get_routine(short["routine_id"])["next_run_at"] == clock[0] + 45
    # An hourly cron at 08:59:30: the retry lands on 09:00, not 09:00:30.
    clock[0] = _ny(2026, 10, 25, 8, 59, 30)
    hourly = _mk_sched(env, {"cron": "0 * * * *", "tz": "America/New_York"})
    store.set_routine_next(hourly["routine_id"], clock[0])
    mgr.catch_up()
    assert store.get_routine(hourly["routine_id"])["next_run_at"] == _ny(2026, 10, 25, 9, 0)


def test_failed_manual_run_of_a_routine_not_due_keeps_its_schedule(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env, interval=3600)
    mgr.arm(r["routine_id"], {"interval_s": 3600})
    armed = store.get_routine(r["routine_id"])["next_run_at"]
    env["sessions"].get_or_create_session(env["a"])._degraded = "down"
    mgr._fire(store.get_routine(r["routine_id"]), manual=True)
    row = store.get_routine(r["routine_id"])
    assert row["failure_count"] == 1
    assert row["next_run_at"] == armed  # not pulled in to now + 60s


def test_never_concurrent_skip_does_not_spin_or_count_as_failure(tmp_path):
    """A routine blocked by its own in-flight turn is re-checked each tick
    but writes nothing, emits nothing and never trips THRESHOLD — then fires
    on the first tick after the turn ends."""
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env, interval=30)
    rid = r["routine_id"]
    mgr.arm(rid, {"interval_s": 30})
    clock[0] += 31
    mgr.catch_up()
    first = store.get_routine(rid)
    assert first["last_run_id"]
    events_before = len(store.events_after(0))
    _tick_for(mgr, clock, 300)  # 5 minutes of 1s ticks while in flight
    row = store.get_routine(rid)
    assert row["failure_count"] == 0 and row["enabled"] == 1
    assert row["next_run_at"] == first["next_run_at"]  # due time not advanced
    assert len(store.events_after(0)) == events_before
    assert len(store.list_runs()) == 1
    store.finish_run(first["last_run_id"], "done", error=None)
    clock[0] += 1
    mgr.catch_up()
    assert len(store.list_runs()) == 2


# ----------------------------------------------------------------------
# Stale catch-up (wall-clock kinds)
# ----------------------------------------------------------------------

def test_stale_daily_cron_is_not_caught_up_hours_later(tmp_path):
    """Asleep from before 08:00 until 21:00: the 08:00 brief does NOT fire at
    21:00 — it is armed for tomorrow's 08:00 instead."""
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 6, 0)
    r = _mk_sched(env, {"cron": "0 8 * * *", "tz": "America/New_York"})
    clock[0] = _ny(2026, 10, 25, 21, 0)
    mgr.catch_up()
    row = store.get_routine(r["routine_id"])
    assert row["last_run_id"] is None and store.list_runs() == []
    assert row["enabled"] == 1 and row["failure_count"] == 0
    assert row["next_run_at"] == _ny(2026, 10, 26, 8, 0)


def test_recent_missed_cron_still_catches_up_once(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 6, 0)
    r = _mk_sched(env, {"cron": "0 8 * * *", "tz": "America/New_York"})
    clock[0] = _ny(2026, 10, 25, 8, 0) + CATCH_UP_STALE_S - 60  # inside window
    mgr.catch_up()
    row = store.get_routine(r["routine_id"])
    assert row["last_run_id"]
    assert row["next_run_at"] == _ny(2026, 10, 26, 8, 0)


def test_stale_one_shot_is_disabled_as_missed_not_fired(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    clock[0] = _ny(2026, 10, 25, 12, 0)
    r = _mk_sched(env, {"at": "2026-10-26T09:00:00", "tz": "America/New_York"})
    clock[0] = _ny(2026, 10, 26, 9, 0) + CATCH_UP_STALE_S + 60
    mgr.catch_up()
    row = store.get_routine(r["routine_id"])
    assert store.list_runs() == []
    assert row["enabled"] == 0 and row["next_run_at"] is None
    disabled = _events(store, "routine_disabled")
    assert len(disabled) == 1 and not disabled[0].get("completed")
    assert "missed" in disabled[0]["reason"]


def test_interval_catch_up_has_no_staleness_window(tmp_path):
    env = _env(tmp_path)
    store, mgr, clock = env["store"], env["mgr"], env["clock"]
    r = _mk_routine(env, interval=3600)
    mgr.arm(r["routine_id"], {"interval_s": 3600})
    clock[0] += 3 * 86400
    mgr.catch_up()
    assert store.get_routine(r["routine_id"])["last_run_id"]


# ----------------------------------------------------------------------
# Boot: one thread owns every fire
# ----------------------------------------------------------------------

class _LockstepStore:
    """Store proxy that makes two concurrent scheduler passes meet: each of
    routines_due/active_routine_run waits (briefly) for a second caller, so
    a boot-thread catch_up racing the manager thread's own tick reliably
    reads the routine as due and idle in BOTH. Serialized passes never meet;
    the barrier times out once and stays broken (no further waiting)."""

    def __init__(self, store):
        self._inner = store
        self._due = threading.Barrier(2, timeout=0.5)
        self._active = threading.Barrier(2, timeout=0.5)

    def routines_due(self, now):
        rows = self._inner.routines_due(now)
        if rows:
            try:
                self._due.wait()
            except threading.BrokenBarrierError:
                pass
        return rows

    def active_routine_run(self, rid):
        out = self._inner.active_routine_run(rid)
        try:
            self._active.wait()
        except threading.BrokenBarrierError:
            pass
        return out

    def __getattr__(self, name):
        return getattr(self._inner, name)


def test_due_routine_fires_exactly_once_at_boot_with_a_live_thread(tmp_path):
    registry = AgentRegistry(root=str(tmp_path / "agents"))
    aid = registry.create_agent("Alpha")["id"]
    store = RunStore(path=tmp_path / "fleet.db")
    r = store.create_routine(aid, "Due", "do it", {"interval_s": 3600}, None)
    store.set_routine_next(r["routine_id"], time.time() - 600)  # missed
    proxy = _LockstepStore(store)
    mgr = RoutineManager(lambda: proxy, registry, lambda: FakeSessions(),
                         tick_s=0.01)  # thread running, ticking
    try:
        mgr.catch_up()  # the boot catch-up, from the boot thread
        time.sleep(1.5)  # let the manager thread tick past the barriers
    finally:
        mgr.stop()
    try:
        assert len(store.list_runs()) == 1
        assert len([e for e in store.events_after(0)
                    if e.get("type") == "routine_fired"]) == 1
    finally:
        store.stop()


def test_start_is_deferred_until_asked(tmp_path):
    env = _env(tmp_path)
    mgr = env["mgr"]
    assert mgr._thread is None
    mgr.start()
    mgr.start()  # idempotent
    try:
        assert mgr._thread.is_alive()
    finally:
        mgr.stop()
