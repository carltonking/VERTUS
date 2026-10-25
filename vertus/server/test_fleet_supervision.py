"""Supervision + cancellation (Checkpoints 1–4).

Covers, against the REAL AgentBridge worker with a controllable stub engine
(no subprocess, no desktop):

  - stall detection: silence ends a run as ``timeout``; a slow-but-chatty
    turn never trips it; hard timeout catches an endless chatty turn; both
    release declared screen targets.
  - escalation ladder: interrupt → SIGTERM → SIGKILL, each rung reachable
    with a stub that ignores the earlier ones; the killpg mechanism reaps
    grandchildren (verified with a real throwaway process tree).
  - cancel API: queued (never spawns), running (ladder), terminal (409),
    drain_queue semantics, cancel during a respawn retry, cancel racing a
    natural completion (row state set exactly once), ``cancelled`` event.
  - gateway supervision: backoff sequence + respawn counting, degraded set
    on exhaustion and cleared by a successful spawn (503 at HTTP), the
    idle-gateway health check, and the thrash cap.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))  # noqa: E402

import pytest  # noqa: E402

import vertus_server as vs  # noqa: E402
from agent_registry import AgentRegistry  # noqa: E402
from run_store import RunStore  # noqa: E402
from screen_lease import ScreenLeaseManager  # noqa: E402

TARGET = "com.apple.TextEdit"


def _wait_until(pred, timeout=30.0, step=0.02):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(step)
    return False


@pytest.fixture(autouse=True)
def _fast_supervision(monkeypatch):
    """Real 10s grace / 1/4/16s backoff would make these tests crawl. The
    bridge reads the module constants at call time, so patching suffices."""
    monkeypatch.setattr(vs, "ESCALATION_GRACE_S", 0.05)
    monkeypatch.setattr(vs, "RESPAWN_BACKOFF", (0.02, 0.04, 0.08))


class SupervisedSession:
    """Engine session stand-in with a controllable interrupt/terminate/kill.

    ``behavior``:
      silent — the turn emits NOTHING until stopped (a wedged gateway).
      chatty — emits an activity ping every ~20ms until ``chat_duration``
               elapses, then returns normally (a slow-but-healthy turn).
      reply  — emits one text delta and returns immediately.
    When stopped by the ladder, prompt() raises BrokenPipeError — exactly
    how a real gateway behaves when its process is killed.
    """

    def __init__(self, bridge, *, behavior: str = "silent",
                 chat_duration: float = 3600.0, raise_on_stop: bool = True):
        self.bridge = bridge
        self.behavior = behavior
        self.chat_duration = chat_duration
        self.raise_on_stop = raise_on_stop
        self.stopped = threading.Event()
        self.interrupt_calls = 0
        self.terminate_calls = 0
        self.kill_calls = 0
        self.closed = False
        self.prompts: list[str] = []
        self._interrupted_once = False
        self.unresponsive = False  # health-check stub: active_list raises
        # Ladder-controllable: a test can make interrupt / SIGTERM
        # ineffective so the ladder must escalate further.
        self.ignore_interrupt = False
        self.ignore_terminate = False

    def subscribe(self, listener) -> None:
        pass

    def prompt(self, text: str) -> None:
        self.prompts.append(text)
        if self.behavior == "reply":
            self.bridge._on_pi_event({"type": "text", "text": f"reply:{text}"})
            return
        if self._interrupted_once:
            # A real gateway survives an RPC interrupt: the aborted turn
            # raises, but the NEXT turn on the same session runs normally.
            self.stopped.clear()
            self._interrupted_once = False
        end = time.monotonic() + self.chat_duration
        while not self.stopped.is_set():
            if self.behavior == "chatty":
                self.bridge._on_pi_event({"type": "activity", "text": "ping"})
            if time.monotonic() >= end:
                return  # a chatty turn converged
            time.sleep(0.02)
        if self.raise_on_stop:
            self._interrupted_once = True
            raise BrokenPipeError("gateway killed mid-turn")

    def active_list(self, timeout: float = 5.0) -> dict:
        if self.unresponsive:
            raise RuntimeError("gateway hung")
        return {"sessions": []}

    def interrupt(self) -> None:
        self.interrupt_calls += 1
        if not self.ignore_interrupt:
            self.stopped.set()

    def terminate_process(self) -> None:
        self.terminate_calls += 1
        if not self.ignore_terminate:
            self.stopped.set()

    def kill_process(self) -> None:
        self.kill_calls += 1
        self.stopped.set()

    def close(self) -> None:
        self.closed = True

    @property
    def is_dead(self) -> bool:
        return False


class SupervisedBridge(vs.AgentBridge):
    """Real AgentBridge worker + store + controllable stub engine."""

    def __init__(self, agent_id: str, *, store=None, stall: float = 180.0,
                 hard: float = 3600.0, behavior: str = "silent",
                 chat_duration: float = 3600.0, spawn_fail: bool = False,
                 ignore_interrupt: bool = False, ignore_terminate: bool = False,
                 screen_leases=None, screen_targets=None, agent_home=None):
        self._behavior = behavior
        self._chat_duration = chat_duration
        self._spawn_fail = spawn_fail
        self._ignore_interrupt = ignore_interrupt
        self._ignore_terminate = ignore_terminate
        self.sessions: list[SupervisedSession] = []
        kwargs: dict = {}
        if stall != 180.0:
            kwargs["stall_timeout_s"] = stall
        if hard != 3600.0:
            kwargs["hard_timeout_s"] = hard
        if agent_home is not None:
            kwargs["agent_home"] = agent_home
        super().__init__(
            agent_id=agent_id,
            create_session_factory=self._make,
            cwd=None,
            session_kwargs=kwargs,
            store=store,
            screen_leases=screen_leases,
            screen_targets=screen_targets,
        )

    def _make(self, cwd=None, **kwargs):
        if self._spawn_fail:
            raise BrokenPipeError("gateway died at startup")
        # ``behavior`` is a mutable knob: a test can flip it mid-test so the
        # NEXT spawn behaves differently (e.g. the turn after a cancel).
        behavior = getattr(self, "behavior", self._behavior)
        s = SupervisedSession(
            self,
            behavior=behavior,
            chat_duration=self._chat_duration,
        )
        s.ignore_interrupt = self._ignore_interrupt
        s.ignore_terminate = self._ignore_terminate
        self.sessions.append(s)
        return {"session": s}


def _bridge(store, **kwargs) -> SupervisedBridge:
    return SupervisedBridge("a", store=store, **kwargs)


def _run(store, bridge, text: str) -> str:
    run_id = store.create_run("a", text, False)
    bridge.prompt(text, remote=False, run_id=run_id)
    return run_id


# ----------------------------------------------------------------------
# Checkpoint 1: stall detection, not wall-clock
# ----------------------------------------------------------------------


def test_stall_timeout_fires_on_silence(monkeypatch, tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, stall=0.4, ignore_interrupt=True)
    run_id = _run(store, b, "wedged")
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "timeout"), (
        "silent turn must be killed by the stall timeout"
    )
    run = store.get_run(run_id)
    assert "stall timeout" in (run["error"] or ""), run
    assert "no agent events" in run["error"], "error names the silence"
    assert "stall_timeout_s" in run["error"], "error names the limit"
    last = store.last_event_of_run(run_id)
    assert last["type"] == "error" and "stall timeout" in last.get("message", "")
    b.close()
    store.stop()


def test_slow_but_chatty_turn_never_trips_stall(monkeypatch, tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    # 0.9s of continuous activity with a 0.3s stall limit: a healthy turn
    # must survive (any event refreshes the silence clock).
    b = _bridge(store, stall=0.3, behavior="chatty", chat_duration=0.9)
    run_id = _run(store, b, "chatty")
    # While it runs (0.9s of activity), the silence clock must stay below
    # the 0.3s stall limit — a healthy turn never trips it.
    assert _wait_until(lambda: b.status()["state"] == "running")
    time.sleep(0.4)  # longer than the stall limit, still chatty
    assert b.status()["silence_s"] < 0.3, "activity refreshes silence_s"
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "done")
    run = store.get_run(run_id)
    assert run["state"] == "done" and not run["error"], "chatty turn completes"
    b.close()
    store.stop()


def test_turn_waiting_on_an_approval_is_not_stalled(_fast_supervision, tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    # The engine asks a human and then says nothing until answered: a wait
    # far longer than the stall limit must not kill the turn.
    b = _bridge(store, stall=0.3, ignore_interrupt=True)
    run_id = _run(store, b, "delete my notes")
    assert _wait_until(lambda: b.status()["state"] == "running")
    b._on_pi_event({"type": "approval_request", "approval_id": "ap-1", "command": "rm notes.txt"})
    time.sleep(2.5)  # several watchdog ticks (1s each), far past the stall limit
    assert (store.get_run(run_id) or {})["state"] == "running", "a turn awaiting approval is not stalled"
    # Answered: silence counts again, so a gateway that then wedges is caught.
    b._on_pi_event({"type": "approval_resolved", "approval_id": "ap-1", "decision": "once"})
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "timeout"), (
        "after the approval settles, the stall watchdog is back on duty"
    )
    b.close()
    store.stop()


def test_hard_timeout_fires_on_endless_chatty_turn(monkeypatch, tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    # Emits forever (stall never trips) but exceeds the hard ceiling.
    b = _bridge(store, stall=180.0, hard=0.5, behavior="chatty")
    run_id = _run(store, b, "converge-never")
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "timeout")
    run = store.get_run(run_id)
    assert "hard timeout" in (run["error"] or ""), run
    assert "turn ran" in run["error"], "error names the elapsed duration"
    b.close()
    store.stop()


def test_status_exposes_timeout_limits_and_silence(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, stall=7.5, hard=99.0)
    run_id = _run(store, b, "watch")
    assert _wait_until(lambda: b.status()["state"] == "running")
    st = b.status()
    assert st["stall_timeout_s"] == 7.5
    assert st["hard_timeout_s"] == 99.0
    assert st["last_event_at"] is not None
    time.sleep(0.35)
    later = b.status()
    assert later["silence_s"] >= st["silence_s"], "silence grows while silent"
    assert later["silence_s"] > 0.2
    b.cancel_run(run_id)
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "cancelled")
    b.close()
    store.stop()


def test_timeouts_release_declared_targets(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    m = ScreenLeaseManager()
    b = _bridge(store, stall=0.4, ignore_interrupt=True,
                screen_leases=m, screen_targets=lambda aid: [TARGET])
    run_id = _run(store, b, "lease-holder")
    assert _wait_until(lambda: m.owners().get(TARGET) is not None), "lease held"
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "timeout")
    assert m.owners() == {}, "timeout must release the declared target"
    b.close()
    store.stop()


# ----------------------------------------------------------------------
# Checkpoint 2: the escalation ladder
# ----------------------------------------------------------------------


def test_ladder_interrupt_suffices_when_engine_cooperates(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store)
    run_id = _run(store, b, "cooperate")
    assert _wait_until(lambda: b.status()["state"] == "running")
    b.cancel_run(run_id)
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "cancelled")
    rungs = b.escalation_rungs()
    assert rungs == ["rung1:interrupt"], rungs
    assert b.sessions[-1].interrupt_calls >= 1
    assert b.sessions[-1].terminate_calls == 0, "no need to SIGTERM a cooperative engine"
    b.close()
    store.stop()


def test_ladder_escalates_to_terminate_when_interrupt_ignored(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, ignore_interrupt=True)
    run_id = _run(store, b, "stubborn")
    assert _wait_until(lambda: b.status()["state"] == "running")
    b.cancel_run(run_id)
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "cancelled")
    rungs = b.escalation_rungs()
    assert "rung1:interrupt" in rungs and "rung2:terminate" in rungs, rungs
    assert not any("rung3" in r for r in rungs), "SIGTERM sufficed"
    assert b.sessions[-1].terminate_calls >= 1
    b.close()
    store.stop()


def test_ladder_escalates_to_kill_when_interrupt_and_terminate_ignored(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, ignore_interrupt=True, ignore_terminate=True)
    run_id = _run(store, b, "defiant")
    assert _wait_until(lambda: b.status()["state"] == "running")
    b.cancel_run(run_id)
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "cancelled")
    rungs = b.escalation_rungs()
    assert "rung3:kill" in rungs, rungs
    assert b.sessions[-1].kill_calls >= 1
    b.close()
    store.stop()


def test_killpg_reaps_grandchildren(tmp_path):
    """The rung-2/3 mechanism must take the gateway's whole process tree —
    an embedded cua-driver daemon shares the group, so a killed gateway must
    not leave it orphaned. Verified with a real throwaway process tree."""
    marker = tmp_path / "grandchild.pid"
    code = (
        "import subprocess, time\n"
        "p = subprocess.Popen(['sleep', '61'])\n"
        f"open({str(marker)!r}, 'w').write(str(p.pid))\n"
        "time.sleep(60)\n"
    )
    proc = subprocess.Popen(
        [sys.executable, "-c", code], start_new_session=True
    )
    try:
        deadline = time.time() + 5
        while not marker.exists():
            assert time.time() < deadline, "grandchild never started"
            time.sleep(0.05)
        gc = int(marker.read_text().strip())
        os.kill(gc, 0)  # alive before the kill
        # Exactly what _HermesSession.terminate_process/kill_process do:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)
        deadline = time.time() + 5
        while True:
            try:
                os.kill(gc, 0)
            except ProcessLookupError:
                break  # reaped
            assert time.time() < deadline, "grandchild survived killpg — orphan!"
            time.sleep(0.05)
    finally:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


# ----------------------------------------------------------------------
# Checkpoint 3: cancel semantics (bridge level)
# ----------------------------------------------------------------------


def test_cancel_queued_run_never_spawns(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store)  # silent turns occupy the single worker
    run1 = _run(store, b, "holds-the-worker")
    assert _wait_until(lambda: b.status()["state"] == "running")
    run2 = _run(store, b, "doomed")
    assert (store.get_run(run2) or {})["state"] == "queued"
    b.cancel_run(run2)
    assert _wait_until(lambda: (store.get_run(run2) or {})["state"] == "cancelled")
    assert store.last_event_of_run(run2)["type"] == "cancelled", "cancelled event stored"
    # Never spawned: only run1's text ever reached a session.
    assert all(s.prompts == ["holds-the-worker"] for s in b.sessions), (
        "a queued cancel must never reach the engine"
    )
    # run1 keeps running undisturbed.
    assert b.status()["state"] == "running"
    b.cancel_run(run1)
    assert _wait_until(lambda: (store.get_run(run1) or {})["state"] == "cancelled")
    b.close()
    store.stop()


def test_cancel_active_run_preserves_the_rest_of_the_queue(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store)  # silent: run1 occupies the worker until cancelled
    run1 = _run(store, b, "first")
    assert _wait_until(lambda: b.status()["state"] == "running")
    run2 = _run(store, b, "second")
    assert (store.get_run(run2) or {})["state"] == "queued"
    b.cancel_run(run1, drain_queue=False)
    assert _wait_until(lambda: (store.get_run(run1) or {})["state"] == "cancelled")
    # The queue survives: run2 completes on a FRESH spawn (flip the stub to
    # a returning behavior so the new session finishes).
    b.behavior = "reply"
    assert _wait_until(lambda: (store.get_run(run2) or {})["state"] == "done")
    assert store.get_run(run2)["state"] == "done", "a cancel kills one run, not the queue"
    b.close()
    store.stop()


def test_cancel_with_drain_queue_clears_pending_runs(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store)
    run1 = _run(store, b, "first")
    assert _wait_until(lambda: b.status()["state"] == "running")
    run2 = _run(store, b, "second")
    run3 = _run(store, b, "third")
    b.cancel_run(run1, drain_queue=True)
    for rid in (run1, run2, run3):
        assert _wait_until(lambda: (store.get_run(rid) or {})["state"] == "cancelled"), rid
    # Every dequeued run got its own cancelled event; nothing spawned.
    for rid in (run2, run3):
        assert store.last_event_of_run(rid)["type"] == "cancelled"
    assert all(s.prompts == ["first"] for s in b.sessions)
    assert b.status()["state"] == "idle" and b.status()["queue_depth"] == 0
    b.close()
    store.stop()


def test_cancel_during_gateway_respawn_retry(monkeypatch, tmp_path):
    """A cancel that lands between respawn attempts must stop the respawn —
    the run goes cancelled with the respawn count it earned, never respawned."""
    monkeypatch.setattr(vs, "RESPAWN_BACKOFF", (0.5, 4.0, 16.0))
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, spawn_fail=True)
    run_id = _run(store, b, "retry-cancel")
    # First spawn failed; the worker is sleeping its backoff.
    assert _wait_until(lambda: b._run_respawns == 1)
    b.cancel_run(run_id)
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "cancelled")
    assert b.sessions == [], "no further spawn may be attempted after the cancel"
    run = store.get_run(run_id)
    assert run["gateway_respawns"] == 1, "respawns earned before the cancel are counted"
    assert not run["error"]
    b.close()
    store.stop()


def test_cancel_racing_natural_completion_sets_state_exactly_once(tmp_path):
    """Whichever side wins, the row ends in exactly one terminal state."""
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, behavior="reply")  # turns complete instantly
    for i in range(6):
        run_id = _run(store, b, f"race-{i}")
        b.cancel_run(run_id)  # race the near-instant completion
        assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] in (
            "done", "cancelled"
        )), f"run {run_id} ended in an illegal state"
        run = store.get_run(run_id)
        assert run["state"] in ("done", "cancelled"), run
        assert (run["ended_at"] or 0) > 0, "terminal row always stamps ended_at"
    b.close()
    store.stop()


# ----------------------------------------------------------------------
# Checkpoint 4: gateway supervision
# ----------------------------------------------------------------------


def test_respawn_backoff_sequence_and_counting(monkeypatch, tmp_path):
    monkeypatch.setattr(vs, "RESPAWN_BACKOFF", (0.1, 0.2, 0.4))
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, spawn_fail=True)
    run_id = _run(store, b, "exhaust")
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "error")
    run = store.get_run(run_id)
    assert run["gateway_respawns"] == 3, "4 spawn attempts = 3 respawns, counted on the row"
    assert "agent start failed" in (run["error"] or ""), run
    degraded = b.status()["degraded"]
    assert degraded and "failed to start after 4 attempts" in degraded, (
        "exhaustion degrades the agent with a readable reason"
    )
    b.close()
    store.stop()


def test_degraded_cleared_by_successful_spawn(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, spawn_fail=True, behavior="reply")
    run1 = _run(store, b, "fails")
    assert _wait_until(lambda: (store.get_run(run1) or {})["state"] == "error")
    assert b.status()["degraded"]
    # The gateway situation improves; the next turn spawns fresh.
    b._spawn_fail = False
    run2 = _run(store, b, "succeeds")
    assert _wait_until(lambda: (store.get_run(run2) or {})["state"] == "done")
    assert b.status()["degraded"] is None, "a successful spawn clears degraded"
    b.close()
    store.stop()


def test_health_check_reaps_unresponsive_idle_gateway(monkeypatch, tmp_path):
    monkeypatch.setattr(vs, "HEALTH_CHECK_INTERVAL_S", 0.2)
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, behavior="reply")
    run1 = _run(store, b, "warmup")
    assert _wait_until(lambda: (store.get_run(run1) or {})["state"] == "done")
    session = b.sessions[-1]
    assert not session.closed and b.status()["gateway_alive"] is True
    session.unresponsive = True  # gateway hangs while idle
    assert _wait_until(lambda: b.status()["gateway_alive"] is False), (
        "the idle health check must reap a hung gateway"
    )
    assert session.closed, "the reaped gateway was closed"
    assert b._session is None, "next prompt spawns fresh"
    b.close()
    store.stop()


def test_thrash_cap_trips_and_stops_respawning(monkeypatch, tmp_path):
    monkeypatch.setattr(vs, "THRASH_MAX", 2)
    monkeypatch.setattr(vs, "THRASH_WINDOW_S", 600.0)
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, spawn_fail=True)
    run_id = _run(store, b, "thrash")
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "error")
    assert b.sessions == [], "the capped agent must stop auto-respawning"
    assert b._run_respawns == 2, "cap tripped at the third attempt boundary"
    assert "thrashing" in b.status()["degraded"], b.status()
    b.close()
    store.stop()


# ----------------------------------------------------------------------
# HTTP surface: cancel + degraded 503
# ----------------------------------------------------------------------


@pytest.fixture()
def cancel_hub(monkeypatch, tmp_path):
    """HTTP hub with real bridges (stub engine) + real store."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    reg = AgentRegistry()
    reg.ensure_primary()
    reg.create_agent("Doc")
    store = RunStore(tmp_path / "fleet.db")
    fleet = vs.FleetFan()
    store.listener = fleet.publish

    def factory(agent_id):
        return SupervisedBridge(agent_id, store=store)

    vs.VertusHandler.registry = reg
    vs.VertusHandler.token = "test-token"
    vs.VertusHandler.store = store
    vs.VertusHandler.fleet = fleet
    vs.VertusHandler.screen_leases = None
    vs.VertusHandler.sessions = vs.SessionManager(reg, factory=factory)
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield base, store
    server.shutdown()
    store.stop()
    # Shared handler class: detach our state so later test files (which
    # predate the store) never inherit a stopped store or a dead bridge map.
    vs.VertusHandler.store = None
    vs.VertusHandler.fleet = None
    vs.VertusHandler.sessions = None
    vs.VertusHandler.registry = None


def _req(base, path, payload=None, method=None, token="test-token"):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": f"Bearer {token}"},
        method=method or ("POST" if payload is not None else "GET"),
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def test_http_cancel_queued_run_and_terminal_409(cancel_hub):
    base, store = cancel_hub
    st, body = _req(base, "/api/prompt", {"agent_id": "doc", "text": "first"})
    assert st == 202
    run1 = body["run_id"]
    assert _wait_until(lambda: (store.get_run(run1) or {})["state"] == "running")
    st, body = _req(base, "/api/prompt", {"agent_id": "doc", "text": "second"})
    assert st == 202
    run2 = body["run_id"]
    assert (store.get_run(run2) or {})["state"] == "queued"

    st, body = _req(base, f"/api/runs/{run2}/cancel", {})
    assert st == 200 and body["cancelled"] == run2 and body["drain_queue"] is False
    assert _wait_until(lambda: (store.get_run(run2) or {})["state"] == "cancelled")
    # Cancelling a terminal run is a 409.
    st, body = _req(base, f"/api/runs/{run2}/cancel", {})
    assert st == 409 and "terminal" in body["error"]
    # Unknown run → 404.
    st, _ = _req(base, "/api/runs/deadbeefdeadbeefdeadbeefdeadbeef/cancel", {})
    assert st == 404
    # Cleanup: cancel the still-running first run.
    st, _ = _req(base, f"/api/runs/{run1}/cancel", {})
    assert st == 200
    assert _wait_until(lambda: (store.get_run(run1) or {})["state"] == "cancelled")


def test_http_cancel_drain_queue(cancel_hub):
    base, store = cancel_hub
    run_ids = []
    for i, text in enumerate(("one", "two", "three")):
        st, body = _req(base, "/api/prompt", {"agent_id": "doc", "text": text})
        assert st == 202, body
        run_ids.append(body["run_id"])
    assert _wait_until(lambda: (store.get_run(run_ids[0]) or {})["state"] == "running")
    st, body = _req(base, f"/api/runs/{run_ids[0]}/cancel", {"drain_queue": True})
    assert st == 200 and body["drain_queue"] is True
    for rid in run_ids:
        assert _wait_until(lambda: (store.get_run(rid) or {})["state"] == "cancelled"), rid
    assert store.get_run(run_ids[2])["gateway_respawns"] == 0


def test_http_agent_cancel(cancel_hub):
    base, store = cancel_hub
    st, body = _req(base, "/api/prompt", {"agent_id": "doc", "text": "busy"})
    assert st == 202
    run_id = body["run_id"]
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "running")
    st, body = _req(base, "/api/agents/doc/cancel", {})
    assert st == 200 and body["cancelled"] == run_id
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "cancelled")
    # Idle agent → 409.
    st, body = _req(base, "/api/agents/doc/cancel", {})
    assert st == 409 and "idle" in body["error"]
    # Unknown agent → 404.
    st, _ = _req(base, "/api/agents/nope/cancel", {})
    assert st == 404


def test_http_status_exposes_supervision_fields(cancel_hub):
    base, _store = cancel_hub
    st, body = _req(base, "/api/agents/doc/status")
    assert st == 200
    assert body["stall_timeout_s"] == 180
    assert body["hard_timeout_s"] == 3600
    assert body["silence_s"] == 0.0 and body["degraded"] is None
    assert "last_event_at" in body


def test_http_degraded_agent_gets_503(monkeypatch, tmp_path):
    """After spawn exhaustion, further prompts are refused 503 with the
    reason until a successful spawn clears the degraded state."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    reg = AgentRegistry()
    reg.ensure_primary()
    reg.create_agent("Doc")
    store = RunStore(tmp_path / "fleet.db")
    fleet = vs.FleetFan()
    store.listener = fleet.publish

    def factory(agent_id):
        return SupervisedBridge(agent_id, store=store, spawn_fail=True)

    vs.VertusHandler.registry = reg
    vs.VertusHandler.token = "test-token"
    vs.VertusHandler.store = store
    vs.VertusHandler.fleet = fleet
    vs.VertusHandler.screen_leases = None
    vs.VertusHandler.sessions = vs.SessionManager(reg, factory=factory)
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        # First prompt exhausts the spawn backoff (4 attempts) → error run.
        st, body = _req(base, "/api/prompt", {"agent_id": "doc", "text": "exhaust"})
        assert st == 202
        run_id = body["run_id"]
        assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "error")
        # Degraded now: the next prompt is refused without enqueueing.
        st, body = _req(base, "/api/prompt", {"agent_id": "doc", "text": "refused"})
        assert st == 503, body
        assert "degraded" in body["error"] and "failed to start" in body["error"]
        runs = store.list_runs(agent_id="doc")
        assert all(r["prompt"] != "refused" for r in runs), (
            "a 503 must never leave a run row behind"
        )
    finally:
        server.shutdown()
        store.stop()
        vs.VertusHandler.store = None
        vs.VertusHandler.fleet = None
        vs.VertusHandler.sessions = None
        vs.VertusHandler.registry = None

# --------------------------------------------------------------------------
# Stall reap names WHY: the gateway log look-back (Sept 6 incident)
# --------------------------------------------------------------------------


def test_stall_reap_includes_gateway_provider_error(tmp_path):
    """A silent turn whose gateway log shows a provider retry is reaped as a
    stall WITH the provider error in the run error — not an opaque silence.
    This is the Sept 6 case: the fork sleeps 600s between 429 retries and
    emits nothing, so a retrying-but-doomed agent is otherwise killed as a
    bare stall with no clue why."""
    store = RunStore(tmp_path / "fleet.db")
    home = tmp_path / "home"
    (home / "logs").mkdir(parents=True)
    (home / "logs" / "agent.log").write_text(
        "2026-09-06 16:46:39 WARNING conversation_loop: API call failed "
        "(attempt 1/3) error_type=RateLimitError summary=HTTP 429: Rate "
        "limit exceeded. Please try again later.\n"
        "2026-09-06 16:46:39 WARNING conversation_loop: Retrying API call in "
        "600s (attempt 1/3) error=Error code: 429 - {'type': 'error', "
        "'error': {'type': 'FreeUsageLimitError', 'message': 'Rate limit "
        "exceeded.'}}\n",
        encoding="utf-8",
    )
    b = _bridge(store, stall=0.4, ignore_interrupt=True, agent_home=str(home))
    run_id = _run(store, b, "wedged")
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "timeout")
    run = store.get_run(run_id)
    assert "stall timeout" in (run["error"] or ""), run
    assert "Retrying API call in 600s" in run["error"], \
        "the reap must name the gateway's own provider error, not silence only"
    assert "429" in run["error"], run
    b.close()
    store.stop()


def test_stall_reap_without_gateway_log_stays_plain(tmp_path):
    """No agent.log (or no provider-error lines): the message is unchanged —
    the enrichment is best-effort and must never fail supervision."""
    store = RunStore(tmp_path / "fleet.db")
    b = _bridge(store, stall=0.4, ignore_interrupt=True)
    run_id = _run(store, b, "wedged")
    assert _wait_until(lambda: (store.get_run(run_id) or {})["state"] == "timeout")
    run = store.get_run(run_id)
    assert "stall timeout" in (run["error"] or ""), run
    assert "gateway log" not in run["error"], run
    b.close()
    store.stop()
