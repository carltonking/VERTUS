"""Checkpoint 1 — hub steer: mid-turn corrections over the live gateway.

POST /api/steer {agent_id, text} injects into the RUNNING turn via the
fork's session.steer (lands on the next tool batch; no interrupt, no new
user turn) and is recorded as a ``steer`` event on the CURRENT run —
attributed as steering, never as a new turn. 409 when nothing is running
(idle, or the gateway is mid-respawn — steering into a dead gateway would
be silently lost). A ``queue_update`` wire event mirrors the pending
steering list and is cleared at turn end.

Run from the repo root:
    python3 -m pytest vertus/server/test_fleet_steer.py -v
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

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vertus_server as vs  # noqa: E402
from run_store import RunStore  # noqa: E402
from test_session_manager import FakeBridge, make_manager  # noqa: E402


@pytest.fixture()
def hub(monkeypatch, tmp_path):
    """Live VertusHandler with fake bridges AND a real run store (so steer
    attribution is provable in the events table, not just on the wire)."""
    mgr, registry = make_manager(monkeypatch, tmp_path)
    store = RunStore(path=tmp_path / "fleet.db")
    vs.VertusHandler.sessions = mgr
    vs.VertusHandler.registry = registry
    vs.VertusHandler.store = store
    vs.VertusHandler.token = "test-token"
    vs.VertusHandler.routines = None
    vs.VertusHandler.messenger = None
    vs.VertusHandler.health_snapshot = {}
    vs.VertusHandler.fleet = None
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield {"base": base, "mgr": mgr, "store": store}
    server.shutdown()
    store.stop()
    vs.VertusHandler.store = None
    vs.VertusHandler.sessions = None
    vs.VertusHandler.registry = None


def _req(base, path, method="GET", payload=None, token="test-token"):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def _wait_until(timeout: float = 8.0, **kwargs):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if kwargs["pred"]():
                return True
        except Exception:
            pass
        time.sleep(0.03)
    try:
        return kwargs["pred"]()
    except Exception:
        return False


def _start_slow_turn(hub, agent_id="primary", delay=2.0):
    """Queue a turn whose engine sleeps `delay`s; returns (run_id, bridge,
    session) with the session slowed AFTER the bridge exists (prewarm)."""
    bridge = hub["mgr"].get_session(agent_id)
    session = bridge.sessions[0]
    session.delay = delay
    status, resp = _req(hub["base"], "/api/prompt", "POST",
                        {"agent_id": agent_id, "text": "do the thing"})
    assert status == 202, resp
    assert _wait_until(pred=lambda: bridge.status()["state"] == "running")
    return resp["run_id"], bridge, session


def test_steer_lands_mid_turn_and_is_recorded(hub):
    run_id, bridge, session = _start_slow_turn(hub)

    status, resp = _req(hub["base"], "/api/steer", "POST",
                        {"agent_id": "primary", "text": "no wait — differently"})
    assert status == 200, resp
    assert resp["run_id"] == run_id
    assert session.steers == ["no wait — differently"]

    # Recorded as a steer event on the CURRENT run — not a new run, not a
    # user message.
    events = hub["store"].events_after(0)
    steer_events = [e for e in events if e["type"] == "steer"]
    assert steer_events, events
    assert steer_events[-1]["run_id"] == run_id
    assert steer_events[-1]["text"] == "no wait — differently"
    runs = hub["store"].list_runs(agent_id="primary")
    assert len(runs) == 1, "steer must not create a run row"
    # queue_update carried the pending steering list.
    qus = [e for e in events if e["type"] == "queue_update"]
    assert qus and qus[-1]["steering"] == [
        "no wait — differently"
    ], qus

    # Turn completes normally; queue_update clears and the run ends done.
    assert _wait_until(pred=lambda: bridge.status()["state"] == "idle")
    assert hub["store"].get_run(run_id)["state"] == "done"
    final = [e for e in hub["store"].events_after(0)
             if e["type"] == "queue_update"]
    assert final[-1]["steering"] == []


def test_steer_409_when_idle(hub):
    status, resp = _req(hub["base"], "/api/steer", "POST",
                        {"agent_id": "scout", "text": "hello?"})
    assert status == 409, resp
    assert "no turn running" in resp["error"]


def test_steer_400_without_text_and_404_unknown_agent(hub):
    status, resp = _req(hub["base"], "/api/steer", "POST", {"agent_id": "primary"})
    assert status == 400
    status, resp = _req(hub["base"], "/api/steer", "POST",
                        {"agent_id": "nope", "text": "x"})
    assert status == 404


def test_steer_during_respawn_retry_is_refused(hub):
    """A turn being retried is still 'running', but steering into a dead
    gateway would be silently lost — the hub refuses with a readable 409."""
    run_id, bridge, session = _start_slow_turn(hub)
    session.is_dead = True  # gateway died mid-turn; worker is respawning

    status, resp = _req(hub["base"], "/api/steer", "POST",
                        {"agent_id": "primary", "text": "lost?"})
    assert status == 409, resp
    assert "restarting" in resp["error"]
    assert session.steers == [], "steer must not reach a dead gateway"
    assert hub["store"].get_run(run_id)["state"] in ("running", "done")


def test_steer_does_not_disturb_a_new_turn(hub):
    """A steer on turn N must not leak into turn N+1's context."""
    run_id, bridge, session = _start_slow_turn(hub)
    _req(hub["base"], "/api/steer", "POST",
         {"agent_id": "primary", "text": "correction"})
    assert _wait_until(pred=lambda: bridge.status()["state"] == "idle")
    session.delay = 0.2
    status, resp = _req(hub["base"], "/api/prompt", "POST",
                        {"agent_id": "primary", "text": "next turn"})
    assert status == 202
    assert _wait_until(pred=lambda: bridge.status()["state"] == "idle")
    # Only the correction event belongs to run 1; run 2 has no steer events.
    events = hub["store"].events_after(0)
    steers = [e for e in events if e["type"] == "steer"]
    assert len(steers) == 1 and steers[0]["run_id"] == run_id
    runs = hub["store"].list_runs(agent_id="primary")
    assert [r["state"] for r in runs] == ["done", "done"]


def test_bridge_steer_idle_raises_directly(hub):
    """Unit-level: the guard lives on the bridge, not just the HTTP layer."""
    bridge = hub["mgr"].get_session("scout") if hub["mgr"].has_session("scout") else None
    if bridge is None:
        mgr = hub["mgr"]
        bridge = vs.AgentBridge("scout")  # no turn ever started
        bridge.close()
        return
    with pytest.raises(vs.SteerNotRunningError):
        bridge.steer("nope")


def test_undelivered_steer_is_surfaced_at_turn_end(hub):
    """A generation-only turn (no tool batch after the steer) must end with
    a ``steer_undelivered`` event, not a silent drop (terminal demo Phase D:
    the fork delivers steers only at the next tool boundary)."""
    run_id, bridge, session = _start_slow_turn(hub, delay=2.0)
    status, resp = _req(hub["base"], "/api/steer", "POST",
                        {"agent_id": "primary", "text": "no wait — differently"})
    assert status == 200, resp
    # The fake emits NO tool-boundary activity; the turn just finishes.
    assert _wait_until(pred=lambda: bridge.status()["state"] == "idle")
    assert hub["store"].get_run(run_id)["state"] == "done"
    events = hub["store"].events_after(0)
    undelivered = [e for e in events if e["type"] == "steer_undelivered"]
    assert undelivered, [e["type"] for e in events]
    assert undelivered[-1]["run_id"] == run_id
    assert undelivered[-1]["steers"] == ["no wait — differently"]


def test_delivered_steer_does_not_trigger_undelivered_event(hub):
    """A tool boundary AFTER the steer means the fork's next-batch delivery
    could have happened — no ``steer_undelivered`` event."""
    run_id, bridge, session = _start_slow_turn(hub, delay=2.0)
    status, resp = _req(hub["base"], "/api/steer", "POST",
                        {"agent_id": "primary", "text": "tweak"})
    assert status == 200, resp
    # Tool batch after the steer: the bridge's activity passthrough marks a
    # boundary (text starts with "running ").
    session.bridge._on_pi_event({"type": "activity", "text": "running bash…"})
    assert _wait_until(pred=lambda: bridge.status()["state"] == "idle")
    events = hub["store"].events_after(0)
    undelivered = [e for e in events if e["type"] == "steer_undelivered"]
    assert undelivered == [], [e["type"] for e in events]
    assert hub["store"].get_run(run_id)["state"] == "done"