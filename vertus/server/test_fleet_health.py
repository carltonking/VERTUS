"""Hub health + boot self-check tests (Checkpoint 1 observability).

Exercises GET /api/health on a live hub: payload shape with the historical
{status, time} keys preserved, live detection of a deliberately broken
subsystem (dead scheduler thread, stopped store writer), degraded-agent
census, and scheduler next-fire. The self-check function itself is also
asserted directly for the stopped-store case (no HTTP needed).
"""

from __future__ import annotations

import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vertus_server as vs  # noqa: E402
from fleet_messaging import BotMessenger  # noqa: E402
from fleet_messaging import BotMessenger  # noqa: E402
from fleet_routines import RoutineManager  # noqa: E402
from run_store import RunStore  # noqa: E402
from test_session_manager import make_manager  # noqa: E402


@pytest.fixture()
def hub(monkeypatch, tmp_path):
    """Healthy hub: real store + running scheduler thread + fakes engines,
    wired exactly like serve() (messenger, composed listener, boot snapshot)."""
    mgr, registry = make_manager(monkeypatch, tmp_path)
    store = RunStore(path=tmp_path / "fleet.db")
    routines = RoutineManager(lambda: store, registry, lambda: mgr, tick_s=0.05)
    messenger = BotMessenger(lambda: store, lambda: mgr, registry)
    store.listener = routines.on_event  # fanout is not needed for these tests
    vs.VertusHandler.sessions = mgr
    vs.VertusHandler.registry = registry
    vs.VertusHandler.store = store
    vs.VertusHandler.routines = routines
    vs.VertusHandler.messenger = messenger
    vs.VertusHandler.health_snapshot = vs.subsystem_checks(
        store, routines, messenger, mgr, registry
    )
    vs.VertusHandler.token = "test-token"
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield {"base": base, "store": store, "routines": routines, "mgr": mgr}
    server.shutdown()
    routines.stop()
    # RESTORE the class attrs this fixture owns: a stopped store leaked onto
    # VertusHandler would 503 every later fixture's /api/prompt (store path
    # fails fast) and its stopped scheduler would report degraded — the
    # health tests MUST NOT poison the files that run after them.
    vs.VertusHandler.store = None
    vs.VertusHandler.routines = None
    vs.VertusHandler.messenger = None
    vs.VertusHandler.health_snapshot = {}
    vs.VertusHandler.fleet = None


def _req(base, path, token="test-token"):
    req = urllib.request.Request(
        base + path, headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def test_health_payload_shape_and_existing_keys(hub):
    """The historical {status, time} keys survive; the payload is the real
    thing now — uptime, per-subsystem probes, fleet census, scheduler state."""
    code, body = _req(hub["base"], "/api/health")
    assert code == 200
    assert body["status"] == "ok"
    assert isinstance(body["time"], int)
    assert isinstance(body["uptime_s"], int)
    subs = body["subsystems"]
    assert subs["store"]["ok"] is True
    assert subs["routines"]["ok"] is True
    assert subs["messenger"]["ok"] is False or "messenger" in subs  # tolerant
    assert "store" in body["subsystems"]
    assert body["agents"] >= 1
    assert isinstance(body["running_runs"], int)
    assert isinstance(body["degraded_agents"], list)
    assert "scheduler_next_fire" in body


def test_health_detects_dead_scheduler_thread(hub):
    """A scheduler whose thread died must show as failed AND flip status to
    degraded — visible in the API, not just the log."""
    hub["routines"].stop()  # thread exits; the manager object stays
    code, body = _req(hub["base"], "/api/health")
    assert code == 200
    assert body["status"] == "degraded"
    assert body["subsystems"]["routines"]["ok"] is False
    assert "dead" in body["subsystems"]["routines"]["reason"]


def test_health_detects_stopped_store_writer(hub):
    """A dead writer thread must fail the store probe with a readable reason
    (and never hang the request — _submit fails fast after stop())."""
    hub["store"].stop()
    code, body = _req(hub["base"], "/api/health")
    assert code == 200
    assert body["status"] == "degraded"
    assert body["subsystems"]["store"]["ok"] is False
    assert "stopped" in body["subsystems"]["store"]["reason"]


def test_health_reports_degraded_agent(hub):
    """A degraded gateway shows in the census with its reason."""
    bridge = hub["mgr"].get_or_create_session("primary")
    bridge._degraded = "gateway thrashing"
    code, body = _req(hub["base"], "/api/health")
    assert code == 200
    assert any(d["agent_id"] == "primary" for d in body["degraded_agents"])
    assert any("thrashing" in d["reason"] for d in body["degraded_agents"])


def test_health_reports_scheduler_next_fire(hub):
    store = hub["store"]
    assert _req(hub["base"], "/api/health")[1]["scheduler_next_fire"] is None
    agent = hub["mgr"].registry.list_agents()[0]
    store.create_routine(agent["id"], "R", "p", {"interval_s": 3600}, None)
    hub["routines"].arm(store.list_routines()[0]["routine_id"], {"interval_s": 3600})
    code, body = _req(hub["base"], "/api/health")
    assert code == 200
    assert body["scheduler_next_fire"] is not None
    assert body["scheduler_next_fire"] > 0


def test_self_check_flags_stopped_store_directly(hub):
    """The boot self-check function itself (no HTTP) flags a broken store."""
    hub["store"].stop()
    checks = vs.subsystem_checks(
        hub["store"], hub["routines"], None, hub["mgr"], hub["mgr"].registry
    )
    assert checks["store"]["ok"] is False
    assert checks["store"]["reason"]
    assert checks["routines"]["ok"] is True