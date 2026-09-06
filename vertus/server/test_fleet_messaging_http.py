"""HTTP-level message-bus tests: POST /api/messages, GET /api/messages,
GET /api/threads, thread read marking, and run parent/children on the wire.

Uses the real VertusHandler on a live ThreadingHTTPServer with real
AgentBridge/FakeSession engines (no gateway subprocess) plus a real store
and messenger — the same shape as test_fleet_http's hub fixture.
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
from run_store import RunStore  # noqa: E402
from test_session_manager import FakeBridge, make_manager  # noqa: E402


@pytest.fixture()
def hub(monkeypatch, tmp_path):
    mgr, registry = make_manager(monkeypatch, tmp_path)
    store = RunStore(path=tmp_path / "fleet.db")
    messenger = BotMessenger(lambda: store, lambda: mgr, registry)
    vs.VertusHandler.sessions = mgr
    vs.VertusHandler.registry = registry
    vs.VertusHandler.store = store
    vs.VertusHandler.messenger = messenger
    vs.VertusHandler.token = "test-token"
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield {"base": base, "store": store, "registry": registry}
    server.shutdown()


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


def test_http_message_delivery_and_threads(hub):
    base = hub["base"]
    primary, scout = _agents(hub["registry"])
    code, resp = _req(base, "/api/messages", "POST", {
        "from": primary, "to": scout, "body": "ping from primary",
        "thread_id": "http-t",
    })
    assert code == 202, resp
    assert resp["status"] == "delivered"
    assert resp["run_id"]
    run = hub["store"].get_run(resp["run_id"])
    assert run["from_agent"] == primary
    assert run["run_kind"] == "message"
    # Thread list shows the new thread with one unread.
    code, threads = _req(base, "/api/threads")
    assert code == 200
    assert threads["threads"][0]["thread_id"] == "http-t"
    assert threads["threads"][0]["unread"] == 1
    # Messages list, unread filter.
    _code, msgs = _req(base, "/api/messages?thread_id=http-t")
    assert len(msgs["messages"]) == 1
    _code, unread = _req(base, "/api/messages?unread=1&agent_id=" + scout)
    assert len(unread["messages"]) == 1
    # Mark read.
    code, marked = _req(base, "/api/threads/http-t/read", "POST", {})
    assert code == 200 and marked["marked"] == 1
    _code, threads = _req(base, "/api/threads")
    assert threads["threads"][0]["unread"] == 0


def test_http_message_failures_readable(hub):
    base = hub["base"]
    primary, scout = _agents(hub["registry"])
    code, resp = _req(base, "/api/messages", "POST", {
        "from": primary, "to": "ghost", "body": "hi",
    })
    assert code == 404
    assert "ghost" in resp["error"]
    code, resp = _req(base, "/api/messages", "POST", {
        "from": primary, "to": scout, "body": "  ",
    })
    assert code == 400
    # Deleted agent: 404 on both send directions.
    hub["registry"].delete_agent(scout)
    code, resp = _req(base, "/api/messages", "POST", {
        "from": primary, "to": scout, "body": "hi",
    })
    assert code == 404


def test_http_run_detail_carries_delegation_tree(hub):
    base = hub["base"]
    primary, scout = _agents(hub["registry"])
    # A handoff from the primary creates a child run with the primary's
    # live run as parent (parent link is best-effort: None when idle).
    code, resp = _req(base, "/api/messages", "POST", {
        "from": primary, "to": scout, "body": "do the thing",
        "kind": "handoff", "thread_id": "tree-t",
    })
    assert code == 202 and resp["status"] == "delivered"
    child = resp["run_id"]
    code, detail = _req(base, f"/api/runs/{child}")
    assert code == 200
    assert detail["run"]["from_agent"] == primary
    assert detail["run"]["run_kind"] == "handoff"
    assert "parent" in detail and "children" in detail
    assert detail["parent"] is None  # primary was idle at send time
    # The parent's children list includes the child once the parent exists:
    # give the primary its own run row and re-parent through the store to
    # simulate the delegator-running case end to end.
    parent_id = hub["store"].create_run(
        primary, "user prompt", False, source="local",
    )
    hub["store"].create_run(
        scout, "child", False, source="bot:" + primary,
        from_agent=primary, thread_id="tree-t", run_kind="handoff",
        parent_run_id=parent_id,
    )
    code, detail = _req(base, f"/api/runs/{parent_id}")
    assert code == 200
    assert detail["children"][0]["agent_id"] == scout
    assert detail["children"][0]["parent_run_id"] == parent_id