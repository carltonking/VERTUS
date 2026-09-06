"""HTTP-level routine tests: the /api/routines surface on a live hub.

Same hub shape as test_fleet_messaging_http (real VertusHandler + real
AgentBridge with FakeSession engines + real store), plus a real
RoutineManager. The 409 already-running gate is unit-tested in
test_fleet_routines.py — here the wire surface is the subject.
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
from fleet_routines import RoutineManager  # noqa: E402
from run_store import RunStore  # noqa: E402
from test_session_manager import make_manager  # noqa: E402


@pytest.fixture()
def hub(monkeypatch, tmp_path):
    mgr, registry = make_manager(monkeypatch, tmp_path)
    store = RunStore(path=tmp_path / "fleet.db")
    routines = RoutineManager(lambda: store, registry, lambda: mgr, tick_s=0.05)
    vs.VertusHandler.sessions = mgr
    vs.VertusHandler.registry = registry
    vs.VertusHandler.store = store
    vs.VertusHandler.routines = routines
    vs.VertusHandler.token = "test-token"
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield {"base": base, "store": store, "registry": registry}
    server.shutdown()
    routines.stop()


def _req(base, path, method="GET", payload=None, token="test-token"):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def _agents(registry):
    ids = {a["id"]: a["name"] for a in registry.list_agents()}
    scout = next(i for i, n in ids.items() if n == "Scout")
    primary = next(i for i, n in ids.items() if n == "Primary")
    return primary, scout


def test_routine_crud_round_trip(hub):
    base = hub["base"]
    primary, scout = _agents(hub["registry"])
    code, body = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "name": "Nightly scan",
        "prompt": "scan the sandbox for drift",
        "schedule": {"interval_s": 3600},
        "trigger": {"type": "run_completed", "agent_id": primary},
    })
    assert code == 201, body
    rid = body["routine_id"]
    assert body["schedule"] == {"interval_s": 3600}
    assert body["trigger"] == {"type": "run_completed", "agent_id": primary}
    assert body["enabled"] is True
    # Regression: the create response is read AFTER arming, so next_run_at
    # must already be set (found live: the response used to show null).
    assert body["next_run_at"] is not None
    # GET list + GET one
    code, listing = _req(base, "/api/routines")
    assert code == 200 and len(listing["routines"]) == 1
    code, one = _req(base, f"/api/routines/{rid}")
    assert code == 200 and one["name"] == "Nightly scan"
    code, filtered = _req(base, f"/api/routines?agent_id={scout}")
    assert code == 200 and len(filtered["routines"]) == 1
    # PATCH: schedule change + disable
    code, patched = _req(base, f"/api/routines/{rid}", "PATCH", {
        "schedule": {"interval_s": 7200},
    })
    assert code == 200 and patched["schedule"] == {"interval_s": 7200}
    code, patched = _req(base, f"/api/routines/{rid}", "PATCH", {"enabled": False})
    assert code == 200 and patched["enabled"] is False
    # DELETE
    code, body = _req(base, f"/api/routines/{rid}", "DELETE")
    assert code == 200 and body["deleted"] == rid
    code, _ = _req(base, f"/api/routines/{rid}")
    assert code == 404


def test_routine_validation(hub):
    base = hub["base"]
    primary, scout = _agents(hub["registry"])
    # Missing name
    code, body = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "prompt": "x", "schedule": {"interval_s": 60},
    })
    assert code == 400
    # Bad schedule
    code, body = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "name": "R", "prompt": "x",
        "schedule": {"interval_s": -1},
    })
    assert code == 400
    # Unknown trigger type (vocabulary is small and enumerable)
    code, body = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "name": "R", "prompt": "x",
        "trigger": {"type": "file_created"},
    })
    assert code == 400
    # Neither schedule nor trigger
    code, body = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "name": "R", "prompt": "x",
    })
    assert code == 400
    # Unknown agent
    code, body = _req(base, "/api/routines", "POST", {
        "agent_id": "ghost", "name": "R", "prompt": "x",
        "schedule": {"interval_s": 60},
    })
    assert code == 404
    # PATCH unknown field
    code, body = _req(base, "/api/routines/nope", "PATCH", {"cron": "* * * * *"})
    assert code == 404  # routine doesn't exist — 404 wins over field validation


def test_routine_patch_unknown_field(hub):
    base = hub["base"]
    _, scout = _agents(hub["registry"])
    code, created = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "name": "R", "prompt": "x",
        "schedule": {"interval_s": 60},
    })
    code, body = _req(base, f"/api/routines/{created['routine_id']}", "PATCH",
                      {"cron": "* * * * *"})
    assert code == 400
    assert "cron" in body["error"]


def test_run_now_and_history(hub):
    base = hub["base"]
    _, scout = _agents(hub["registry"])
    code, created = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "name": "Manual", "prompt": "do the thing",
        "schedule": {"interval_s": 86400},  # far future — run-now ignores it
    })
    rid = created["routine_id"]
    code, body = _req(base, f"/api/routines/{rid}/run", "POST", {})
    assert code == 202, body
    assert body["fired"] is True and body["run_id"]
    run = hub["store"].get_run(body["run_id"])
    assert run["run_kind"] == "routine"
    assert run["routine_id"] == rid
    assert run["state"] in ("queued", "running", "done")  # fake engine may finish fast
    # History shows the run attributed to the routine.
    code, hist = _req(base, f"/api/routines/{rid}/history")
    assert code == 200
    assert [r["run_id"] for r in hist["runs"]] == [body["run_id"]]
    # Routine row records the last fire.
    code, one = _req(base, f"/api/routines/{rid}")
    assert one["last_run_id"] == body["run_id"]
    # Run-now on a disabled routine → 400; missing → 404.
    _req(base, f"/api/routines/{rid}", "PATCH", {"enabled": False})
    code, body = _req(base, f"/api/routines/{rid}/run", "POST", {})
    assert code == 400
    code, body = _req(base, "/api/routines/deadbeef/run", "POST", {})
    assert code == 404


def test_agent_delete_disables_routines(hub):
    base = hub["base"]
    primary, scout = _agents(hub["registry"])
    code, created = _req(base, "/api/routines", "POST", {
        "agent_id": scout, "name": "Scout's job", "prompt": "x",
        "schedule": {"interval_s": 3600},
    })
    assert code == 201
    # Scout is idle (never prompted) — DELETE proceeds.
    code, body = _req(base, f"/api/agents/{scout}", "DELETE")
    assert code == 200, body
    rows = hub["store"].list_routines(agent_id=scout)
    assert len(rows) == 1 and rows[0]["enabled"] == 0
    # The scheduler's existence gate would refuse to fire it anyway.
    result = hub["store"].get_routine(created["routine_id"])
    assert result["enabled"] == 0