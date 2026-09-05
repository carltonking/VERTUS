"""Checkpoint 3: approval ledger — read-only record, empty by design.

Nothing populates this table today: the fleet config materializes
``approvals.mode: off`` and computer_use never reaches the fork's gateable
path in gateway mode, so the hub observes zero approval requests. The
endpoint + schema exist so the contract is fixed before any future phase
writes rows. These tests pin that honest, empty behavior.
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
from run_store import RunStore  # noqa: E402


class _Hub:
    """Store-backed HTTP hub (fake AgentBridge engine, no subprocess)."""

    def __init__(self, tmp_path, monkeypatch):
        monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
        monkeypatch.setenv("VERTUS_DB_PATH", str(tmp_path / "fleet.db"))
        registry = AgentRegistry()
        registry.ensure_primary()
        self.registry = registry

        class Engine(vs.AgentBridge):
            def __init__(self, agent_id="primary", cwd=None, session_kwargs=None,
                         store=None):
                super().__init__(agent_id=agent_id, cwd=cwd,
                                 session_kwargs=session_kwargs, store=store)

        monkeypatch.setattr(vs, "AgentBridge", Engine)
        self.mgr = vs.build_session_manager(registry)
        self.store = RunStore()
        vs.VertusHandler.sessions = self.mgr
        vs.VertusHandler.registry = registry
        vs.VertusHandler.token = "test-token"
        vs.VertusHandler.store = self.store
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.server.shutdown()
        self.store.stop()
        vs.VertusHandler.store = None


@pytest.fixture()
def hub(tmp_path, monkeypatch):
    h = _Hub(tmp_path, monkeypatch)
    yield h
    h.close()


def _req(base: str, path: str, token: str = "test-token"):
    req = urllib.request.Request(
        base + path, headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status, json.loads(resp.read())


def test_approvals_endpoint_is_read_only_empty_ledger(hub):
    # Bearer-guarded.
    req = urllib.request.Request(
        hub.base + "/api/approvals", headers={"Authorization": "Bearer wrong"}
    )
    with pytest.raises(urllib.error.HTTPError) as err:
        urllib.request.urlopen(req, timeout=10)
    assert err.value.code == 401

    status, body = _req(hub.base, "/api/approvals")
    assert status == 200
    assert body == {"approvals": []}
    status, body = _req(hub.base, "/api/approvals?state=pending")
    assert status == 200
    assert body == {"approvals": []}
    # The table exists and is queryable (schema creation ran on store boot).
    assert hub.store.list_approvals(state="pending") == []
    assert hub.store.list_approvals(state="allow") == []
