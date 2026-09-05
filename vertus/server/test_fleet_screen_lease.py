"""Declared-target screen conflict policy (per-window computer-use ownership).

Bridge-level tests drive the REAL AgentBridge worker with a stub engine
session and a real ScreenLeaseManager — no engine subprocess, no desktop.
Manager-level tests cover acquire / FIFO grant / release / crash-release
semantics directly. HTTP tests cover GET /api/fleet/screens.
"""

from __future__ import annotations

import json
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
from screen_lease import ScreenLeaseManager, SCREEN_POLICY_CAVEAT  # noqa: E402

TARGET = "com.apple.TextEdit"


def _wait_until(pred, timeout=10.0, step=0.02):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(step)
    return False


class StubSession:
    """Stands in for the hermes gateway session inside a real AgentBridge."""

    def __init__(self, bridge, delay: float = 0.5, die: bool = False):
        self.bridge = bridge
        self.delay = delay
        self.die = die
        self.prompts: list[str] = []
        self.closed = False

    def subscribe(self, listener) -> None:
        pass

    def prompt(self, text: str) -> None:
        self.prompts.append(text)
        # Serve briefly (so the turn is observable as "running"), then either
        # reply or die the way a real dead gateway does. BrokenPipeError is
        # exactly what the bridge treats as "gateway died" (respawn once,
        # then error out of the turn).
        time.sleep(self.delay)
        if self.die:
            raise BrokenPipeError("gateway died mid-turn")
        self.bridge._on_pi_event({"type": "text", "text": f"reply-to:{text}"})

    def close(self) -> None:
        self.closed = True

    @property
    def is_dead(self) -> bool:
        return False


class LeaseBridge(vs.AgentBridge):
    """Real AgentBridge worker + stub engine + screen-lease wiring."""

    def __init__(self, agent_id, manager, resolver, *, delay: float = 0.5,
                 die: bool = False, **kwargs):
        self.sessions: list[StubSession] = []
        self._delay = delay
        self._die = die
        super().__init__(
            agent_id=agent_id,
            create_session_factory=self._make,
            cwd=kwargs.pop("cwd", None),
            session_kwargs=kwargs.pop("session_kwargs", None),
            screen_leases=manager,
            screen_targets=resolver,
            **kwargs,
        )

    def _make(self, cwd=None, **kwargs):  # create_session_factory contract
        s = StubSession(self, delay=self._delay, die=self._die)
        self.sessions.append(s)
        return {"session": s}


def _static_resolver(mapping: dict):
    def resolve(agent_id: str):
        return mapping.get(agent_id)
    return resolve


# ----------------------------------------------------------------------
# Manager semantics
# ----------------------------------------------------------------------


def test_manager_disjoint_and_overlap():
    m = ScreenLeaseManager()
    assert m.acquire("a", "r1", ["AppX"]) is True
    assert m.acquire("b", "r2", ["AppY"]) is True, "disjoint targets never block"
    assert m.acquire("b", "r3", ["AppX"]) is False, "same target blocks"


def test_manager_fifo_grant_and_release():
    m = ScreenLeaseManager()
    assert m.acquire("a", "r1", [TARGET]) is True
    got: dict = {}

    def waiter(agent, run):
        # Mirror the bridge worker: poll until granted (or forever in this
        # test — releases below are guaranteed).
        while True:
            owned = m.wait_for_grant(agent, run, [TARGET])
            if owned is not None:
                got[agent] = owned
                return
            time.sleep(0.01)

    t1 = threading.Thread(target=waiter, args=("b", "r2")); t1.start()
    t2 = threading.Thread(target=waiter, args=("c", "r3")); t2.start()
    time.sleep(0.2)
    assert m.blocked_by("b") == [{"target": TARGET, "holder_agent": "a", "holder_run": "r1"}]
    assert m.blocked_by("c") == [{"target": TARGET, "holder_agent": "a", "holder_run": "r1"}]
    m.release("a", "r1", [TARGET])  # oldest waiter (b) is granted FIFO
    assert _wait_until(lambda: got.get("b") == [TARGET]), "first waiter granted on release"
    assert got.get("c") != [TARGET], "FIFO: second waiter not granted until the first releases"
    m.release("b", "r2", [TARGET])
    assert _wait_until(lambda: got.get("c") == [TARGET]), "second waiter granted after first release"


def test_manager_release_agent_grants_waiter():
    """DELETE path: dropping a holder's leases wakes its waiters."""
    m = ScreenLeaseManager()
    assert m.acquire("a", "r1", [TARGET]) is True
    done = threading.Event()

    def waiter():
        m.wait_for_grant("b", "r2", [TARGET])
        done.set()

    t = threading.Thread(target=waiter); t.start()
    time.sleep(0.2)
    m.release_agent("a")
    assert done.wait(3), "release_agent must grant the waiter"
    assert m.owners() == {TARGET: ("b", "r2", m.owners()[TARGET][2])}


def test_manager_cancel_wait_lets_later_waiters_proceed():
    m = ScreenLeaseManager()
    assert m.acquire("a", "r1", [TARGET]) is True
    b_done, c_done = threading.Event(), threading.Event()
    t_b = threading.Thread(target=lambda: (m.wait_for_grant("b", "r2", [TARGET]), b_done.set()))
    t_c = threading.Thread(target=lambda: (m.wait_for_grant("c", "r3", [TARGET]), c_done.set()))
    t_b.start(); t_c.start()
    time.sleep(0.2)
    assert m.cancel_wait("b", "r2") is True, "waiter removed"
    assert m.acquire("d", "r4", [TARGET]) is False, "c (FIFO) now owns the wait slot"
    m.release("a", "r1", [TARGET])
    assert c_done.wait(3), "next waiter in FIFO order is granted"
    assert not b_done.is_set(), "cancelled waiter never granted"
    t_b.join(timeout=1); t_c.join(timeout=1)


# ----------------------------------------------------------------------
# Bridge-level: the worker gates real turns
# ----------------------------------------------------------------------


def _make_env(monkeypatch, tmp_path):
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet-hermes"))
    return AgentRegistry()


def test_overlap_waits_then_runs(monkeypatch, tmp_path):
    reg = _make_env(monkeypatch, tmp_path)
    m = ScreenLeaseManager()
    a = LeaseBridge("a", m, _static_resolver({"a": [TARGET]}), delay=0.4)
    b = LeaseBridge("b", m, _static_resolver({"b": [TARGET]}), delay=0.2)
    a.prompt("turn-a", remote=False)
    # A must be running (holding the lease) before B is queued, so the test
    # never races which worker wins the free target first.
    assert _wait_until(lambda: a.status()["state"] == "running")
    b.prompt("turn-b", remote=False)
    # B is gated on the same declared target, holder named.
    assert _wait_until(lambda: b.status().get("blocked_on_target"))
    blk = b.status()["blocked_on_target"]
    assert blk == [{"target": TARGET, "holder_agent": "a", "holder_run": ""}]
    assert b.status()["state"] == "queued", "blocked bot is queued, never idle"
    assert b.status()["queue_depth"] >= 1, "blocked turn counts toward depth"
    # A finishes → B runs.
    assert _wait_until(lambda: a.status()["state"] == "idle")
    assert _wait_until(lambda: b.status()["state"] == "idle")
    assert b.sessions[-1].prompts == ["turn-b"]
    assert a.sessions[-1].prompts == ["turn-a"]
    assert m.owners() == {}, "all leases released at terminal state"
    a.close(); b.close()


def test_disjoint_targets_run_in_parallel(monkeypatch, tmp_path):
    _ = _make_env(monkeypatch, tmp_path)
    m = ScreenLeaseManager()
    a = LeaseBridge("a", m, _static_resolver({"a": ["AppA"]}), delay=0.6)
    b = LeaseBridge("b", m, _static_resolver({"b": ["AppB"]}), delay=0.6)
    a.prompt("turn-a", remote=False)
    b.prompt("turn-b", remote=False)
    # Both must be mid-turn at the same moment (parallel, never gated).
    assert _wait_until(
        lambda: a.status()["state"] == "running"
        and b.sessions
        and b.sessions[-1].prompts
    )
    assert "blocked_on_target" not in b.status()
    assert _wait_until(lambda: a.status()["state"] == "idle" and b.status()["state"] == "idle")
    a.close(); b.close()


def test_holder_gateway_crash_releases_waiter(monkeypatch, tmp_path):
    """A holding run whose gateway dies must release; its waiter proceeds."""
    _ = _make_env(monkeypatch, tmp_path)
    m = ScreenLeaseManager()
    a = LeaseBridge("a", m, _static_resolver({"a": [TARGET]}), die=True)  # dies mid-turn
    b = LeaseBridge("b", m, _static_resolver({"b": [TARGET]}), delay=0.2)
    a.prompt("will-crash", remote=False)
    # A acquires the target before dying, so the crash path is deterministic.
    assert _wait_until(lambda: a.status()["state"] == "running")
    b.prompt("turn-b", remote=False)
    # B waits while A's gateway dies + respawns + dies again.
    assert _wait_until(lambda: b.status().get("blocked_on_target"))
    # A's turn ends in error (both spawn attempts dead) and releases the lease.
    assert _wait_until(
        lambda: a.status()["state"] == "idle" and not a.status().get("blocked_on_target")
    )
    assert _wait_until(lambda: b.sessions and b.sessions[-1].prompts), (
        "waiter must proceed after the holder's gateway death"
    )
    assert _wait_until(lambda: b.status()["state"] == "idle")
    assert m.owners() == {}, "no lease may outlive its holder"
    assert a.sessions[-1].prompts == ["will-crash"], "the crashed turn did reach the gateway"
    a.close(); b.close()


def test_wait_is_released_on_agent_close(monkeypatch, tmp_path):
    """A waiting bridge closed while gated cancels its wait (no hang)."""
    _ = _make_env(monkeypatch, tmp_path)
    m = ScreenLeaseManager()
    a = LeaseBridge("a", m, _static_resolver({"a": [TARGET]}), delay=0.6)
    b = LeaseBridge("b", m, _static_resolver({"b": [TARGET]}), delay=0.2)
    a.prompt("turn-a", remote=False)
    assert _wait_until(lambda: a.status()["state"] == "running")
    b.prompt("turn-b", remote=False)
    assert _wait_until(lambda: b.status().get("blocked_on_target"))
    b.close()  # DELETE refuses busy agents; close here simulates a raced delete
    assert _wait_until(lambda: b.status()["state"] == "idle" and b.status()["queue_depth"] == 0)
    assert not b.sessions[-1].prompts, "closed-while-blocked run never started"
    # A still owns its lease and completes undisturbed.
    assert _wait_until(lambda: a.status()["state"] == "idle")
    a.close()


# ----------------------------------------------------------------------
# HTTP: GET /api/fleet/screens
# ----------------------------------------------------------------------


@pytest.fixture()
def screens_hub(monkeypatch, tmp_path):
    """HTTP hub with real AgentBridges (stub engine) wired to a lease manager."""
    reg = _make_env(monkeypatch, tmp_path)
    reg.ensure_primary()
    reg.create_agent("Doc", computer_use=True, cua_targets=[TARGET], autonomy="ask")
    reg.create_agent("Scout", computer_use=True, cua_targets=[TARGET], autonomy="ask")
    reg.create_agent("Plain")  # no CUA: never appears on the roster
    manager = ScreenLeaseManager()

    def resolver(agent_id):
        try:
            agent = reg.get_agent(agent_id)
        except KeyError:
            return None
        if not bool(agent.get("computer_use")):
            return None
        return agent.get("cua_targets") or None

    def factory(agent_id):
        return LeaseBridge(agent_id, manager, resolver, delay=0.4)

    vs.VertusHandler.registry = reg
    vs.VertusHandler.token = "test-token"
    vs.VertusHandler.screen_leases = manager
    vs.VertusHandler.sessions = vs.SessionManager(reg, factory=factory)
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield base, manager
    server.shutdown()
    vs.VertusHandler.screen_leases = None


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


def test_screens_http_shows_declared_running_waiting_and_caveat(screens_hub):
    base, manager = screens_hub
    # Doc runs (holds the TextEdit target); Scout queues behind it.
    st, body = _req(base, "/api/prompt", {"agent_id": "doc", "text": "drive TextEdit"})
    assert st == 202, body
    st, body = _req(base, "/api/prompt", {"agent_id": "scout", "text": "also TextEdit"})
    assert st == 202, body
    assert _wait_until(lambda: manager.owners().get(TARGET) is not None)
    assert _wait_until(lambda: manager.is_waiting("scout"))
    st, screens = _req(base, "/api/fleet/screens")
    assert st == 200
    assert screens["caveat"] == SCREEN_POLICY_CAVEAT
    entry = next(s for s in screens["screens"] if s["target"] == TARGET)
    assert sorted(entry["declared_by"]) == ["doc", "scout"]
    assert entry["running"]["agent_id"] == "doc"
    assert entry["waiting"] == ["scout"]
    plain_entries = [s for s in screens["screens"] if "TextEdit" not in s["target"]]
    assert plain_entries == [], "agents without CUA/targets never appear"
    # After Doc finishes, Scout runs and the roster empties of activity.
    assert _wait_until(lambda: not manager.owners() and not manager.is_waiting("scout"))
    st, screens = _req(base, "/api/fleet/screens")
    assert st == 200
    entry = next(s for s in screens["screens"] if s["target"] == TARGET)
    assert entry["running"] is None and entry["waiting"] == []
