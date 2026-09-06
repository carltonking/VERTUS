"""Checkpoint 3: /api/memory HTTP surface — list/read/write/delete/search,
bearer guard, path-escape rejection, agent validation, and durable
memory_changed events on the store (store-before-fanout path)."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

sys_path_inserted = False  # noqa: F841 - see below

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vertus_server as vs  # noqa: E402
from run_store import RunStore  # noqa: E402
from test_session_manager import make_manager  # noqa: E402


@pytest.fixture()
def hub(monkeypatch, tmp_path):
    monkeypatch.setenv("VERTUS_MEMORY_DIR", str(tmp_path / "memory"))
    mgr, registry = make_manager(monkeypatch, tmp_path)
    store = RunStore(path=tmp_path / "fleet.db")
    memory = vs.MemoryStore(
        emit=lambda aid, e: store.record_event(aid, "", e),
        running_agents=lambda: set(),
        index_file=tmp_path / "memory" / ".hub-index.json",
    )
    memory.start()
    vs.VertusHandler.sessions = mgr
    vs.VertusHandler.registry = registry
    vs.VertusHandler.store = store
    vs.VertusHandler.memory = memory
    vs.VertusHandler.token = "test-token"
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield {"base": base, "store": store, "registry": registry, "db": tmp_path / "fleet.db"}
    server.shutdown()
    memory.stop()
    vs.VertusHandler.sessions = None
    vs.VertusHandler.registry = None
    vs.VertusHandler.store = None
    vs.VertusHandler.memory = None


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


def _scout_id(hub):
    ids = {a["id"]: a["name"] for a in hub["registry"].list_agents()}
    return next(i for i, n in ids.items() if n == "Scout")


def test_memory_put_get_list_search_delete(hub):
    base = hub["base"]
    code, resp = _req(base, "/api/memory/shared/prefs.md", "PUT",
                      {"content": "always use pnpm\n"})
    assert code == 200 and resp["written"] == "prefs.md"
    code, resp = _req(base, "/api/memory/shared/prefs.md")
    assert code == 200 and resp["content"] == "always use pnpm\n"
    assert resp["size"] == 16
    code, resp = _req(base, "/api/memory?scope=shared")
    assert code == 200 and any(e["path"] == "prefs.md" for e in resp["entries"])
    assert resp["entries"][0]["writer"] == "human"
    code, resp = _req(base, "/api/memory/search?q=pnpm")
    assert code == 200 and resp["results"][0]["path"] == "prefs.md"
    assert "pnpm" in resp["results"][0]["snippet"]
    code, resp = _req(base, "/api/memory/shared/prefs.md", "DELETE")
    assert code == 200 and resp["deleted"] == "prefs.md"
    code, resp = _req(base, "/api/memory/shared/prefs.md", "DELETE")
    assert code == 404


def test_memory_agent_scope_and_validation(hub):
    base = hub["base"]
    scout = _scout_id(hub)
    code, resp = _req(base, f"/api/memory/agent/{scout}/notes.md", "PUT",
                      {"content": "scout notes"})
    assert code == 200
    code, resp = _req(base, f"/api/memory/agent/{scout}/notes.md")
    assert code == 200 and resp["content"] == "scout notes"
    # Unknown agent -> 404 (memory must not be creatable for ghosts).
    code, resp = _req(base, "/api/memory/agent/nobody/notes.md", "PUT",
                      {"content": "x"})
    assert code == 404
    # Malformed scope -> 400.
    code, resp = _req(base, "/api/memory/other/notes.md")
    assert code == 400
    # Path escape -> 400, never touches anything outside.
    code, resp = _req(base, "/api/memory/shared/../profile.md", "PUT",
                      {"content": "x"})
    assert code == 400
    code, resp = _req(base, "/api/memory/shared/%2e%2e/escape.md")
    assert code in (400, 404)
    # Missing content -> 400.
    code, resp = _req(base, "/api/memory/shared/x.md", "PUT", {"nope": 1})
    assert code == 400


def test_memory_list_requires_agent_id_for_agent_scope(hub):
    base = hub["base"]
    code, resp = _req(base, "/api/memory?scope=agent")
    assert code == 400
    code, resp = _req(base, "/api/memory?scope=bogus")
    assert code == 400


def test_memory_changed_event_is_durable(hub):
    """store-before-fanout: a PUT's memory_changed event must be in the store."""
    base = hub["base"]
    _req(base, "/api/memory/shared/durable.md", "PUT", {"content": "fact"})
    con = sqlite3.connect(f"file:{hub['db']}?mode=ro", uri=True)
    try:
        row = con.execute(
            "SELECT type, payload FROM events WHERE type='memory_changed' "
            "ORDER BY seq DESC LIMIT 1"
        ).fetchone()
    finally:
        con.close()
    assert row is not None
    payload = json.loads(row[1])
    assert payload["path"] == "durable.md"
    assert payload["action"] == "created"
    assert payload["writer"] == "human"


def test_memory_requires_auth(hub):
    base = hub["base"]
    code, _ = _req(base, "/api/memory?scope=shared", token="")
    assert code == 401
    code, _ = _req(base, "/api/memory/shared/x.md", "PUT", {"content": "x"},
                   token="")
    assert code == 401


def test_memory_search_across_scopes(hub):
    base = hub["base"]
    scout = _scout_id(hub)
    _req(base, "/api/memory/shared/prefs.md", "PUT", {"content": "pnpm everywhere"})
    _req(base, f"/api/memory/agent/{scout}/fix.md", "PUT",
         {"content": "pnpm workspace fix"})
    code, resp = _req(base, "/api/memory/search?q=pnpm")
    assert code == 200
    scopes = {(r["scope"], r.get("agent_id")) for r in resp["results"]}
    assert ("shared", None) in scopes
    assert ("agent", scout) in scopes