"""Approvals: the engine asks, any client answers, the ledger records it.

Since Oct 2026 every materialized agent runs with ``approvals.mode: manual``
and the vertus-guard plugin, so the gateway sends ``approval`` requests. The
bridge turns them into ``approval_request`` events, POST /api/approvals/<id>
answers them, and the ledger keeps who decided what. A hub that has seen no
request still shows an empty ledger.
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
        vs.VertusHandler.approver_token = "approver-test"
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


def test_approvals_ledger_starts_empty(hub):
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


# --- the bridge speaks the gateway's approval protocol --------------------

class _FakeGateway:
    """A gateway process: lines written to stdout reach the bridge's reader;
    whatever the bridge writes to stdin is kept for inspection."""

    def __init__(self):
        import os
        read_fd, self._write_fd = os.pipe()
        self.stdout = os.fdopen(read_fd, "r")
        self.written: list[dict] = []
        outer = self

        class _Stdin:
            def write(self, text):
                for line in text.splitlines():
                    if line.strip():
                        outer.written.append(json.loads(line))

            def flush(self):
                pass

        self.stdin = _Stdin()
        self.pid = 0

    def send(self, frame: dict) -> None:
        import os
        os.write(self._write_fd, (json.dumps(frame) + "\n").encode())

    def poll(self):
        return None


def _bridge_session():
    import hermes_bridge as hb
    gateway = _FakeGateway()
    session = hb._HermesSession(gateway, lambda *a: None)
    events: list[dict] = []
    session.subscribe(events.append)
    return gateway, session, events


def _wait(predicate, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return False


def test_gateway_approval_request_becomes_an_answerable_event():
    gateway, session, events = _bridge_session()
    gateway.send({"jsonrpc": "2.0", "id": "srv-7", "method": "approval", "params": {
        "session_id": "s", "request_id": "req-1", "command": "git push origin main",
        "description": "VERTUS wants to push to a remote repository",
        "choices": ["once", "session", "always", "deny", "bogus"]}})
    assert _wait(lambda: any(e["type"] == "approval_request" for e in events))
    request = next(e for e in events if e["type"] == "approval_request")
    assert request["approval_id"] == "req-1"
    assert request["command"] == "git push origin main"
    assert request["choices"] == ["once", "session", "always", "deny"]

    assert session.respond_approval("req-1", "session") is True
    assert gateway.written[-1] == {"jsonrpc": "2.0", "id": "srv-7", "result": {"choice": "session"}}
    assert events[-1] == {"type": "approval_resolved", "approval_id": "req-1", "decision": "session"}
    # Answered once: a second answer (another surface, a double tap) is refused.
    assert session.respond_approval("req-1", "deny") is False
    with pytest.raises(ValueError):
        session.respond_approval("req-1", "maybe")


def test_withdrawn_approval_is_announced_and_cannot_be_answered():
    gateway, session, events = _bridge_session()
    gateway.send({"jsonrpc": "2.0", "id": "srv-9", "method": "approval",
                  "params": {"session_id": "s", "request_id": "req-2", "command": "rm notes.txt"}})
    assert _wait(lambda: any(e["type"] == "approval_request" for e in events))
    gateway.send({"jsonrpc": "2.0", "method": "event", "params": {
        "type": "request.cancel", "payload": {"id": "srv-9", "method": "approval", "reason": "timeout"}}})
    assert _wait(lambda: events[-1]["type"] == "approval_resolved")
    assert events[-1]["decision"] == "withdrawn" and events[-1]["approval_id"] == "req-2"
    assert session.respond_approval("req-2", "once") is False


def test_requests_the_hub_cannot_show_are_declined_at_once():
    gateway, session, events = _bridge_session()
    gateway.send({"jsonrpc": "2.0", "id": "srv-3", "method": "clarify", "params": {"session_id": "s"}})
    assert _wait(lambda: gateway.written)
    assert gateway.written[-1]["id"] == "srv-3"
    assert gateway.written[-1]["error"]["code"] == -32601
    assert not any(e["type"].startswith("approval") for e in events)


# --- HTTP: answering routes to the waiting agent and settles the ledger ---

def _post(base: str, path: str, body: dict, token: str = "test-token", approver: str | None = "approver-test"):
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
               "X-Vertus-Client": "island"}
    if approver is not None:
        headers["X-Vertus-Approver"] = approver
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read())


def test_answering_an_approval_reaches_the_engine_and_the_ledger(hub):
    bridge = hub.mgr.get_or_create_session("primary")
    bridge.store = hub.store   # the hub binds it per prompt; approvals arrive mid-run
    answered: list[tuple[str, str]] = []

    class _Engine:
        def respond_approval(self, approval_id, choice):
            answered.append((approval_id, choice))
            bridge._on_pi_event({"type": "approval_resolved", "approval_id": approval_id, "decision": choice})
            return True

    bridge._session = _Engine()
    bridge._on_pi_event({"type": "approval_request", "approval_id": "a1", "command": "rm notes.txt",
                         "description": "VERTUS wants to delete files", "choices": ["once", "deny"]})
    assert _wait(lambda: hub.store.list_approvals(state="pending"))

    assert _post(hub.base, "/api/approvals/a1", {"choice": "nope"})[0] == 400
    assert _post(hub.base, "/api/approvals/unknown", {"choice": "once"})[0] == 404
    status, body = _post(hub.base, "/api/approvals/a1", {"choice": "deny"})
    assert status == 200 and body == {"approval_id": "a1", "decision": "deny"}
    assert answered == [("a1", "deny")]
    assert _wait(lambda: hub.store.get_approval("a1")["decision"] == "deny")
    row = hub.store.get_approval("a1")
    assert row["decided_by"] == "island" and row["target"] == "rm notes.txt"
    # Settled: nothing is offered again, and a late answer is refused.
    assert hub.store.list_approvals(state="pending") == []
    assert _post(hub.base, "/api/approvals/a1", {"choice": "once"})[0] == 409


def test_an_approval_the_engine_forgot_is_settled_not_left_pending(hub):
    bridge = hub.mgr.get_or_create_session("primary")
    bridge.store = hub.store   # the hub binds it per prompt; approvals arrive mid-run

    class _Engine:
        def respond_approval(self, approval_id, choice):
            return False   # gateway respawned; nothing waits any more

    bridge._session = _Engine()
    bridge._on_pi_event({"type": "approval_request", "approval_id": "a2", "command": "git push"})
    assert _wait(lambda: hub.store.get_approval("a2") is not None)
    assert _post(hub.base, "/api/approvals/a2", {"choice": "once"})[0] == 409
    assert _wait(lambda: hub.store.get_approval("a2")["decision"] == "withdrawn")


# --- every agent home is materialized with approvals on --------------------

def test_agents_are_materialized_with_approvals_and_the_guard(hub):
    import agent_registry
    home = hub.registry.agent_home("primary")
    cfg = agent_registry._yaml_load((home / "config.yaml").read_text(encoding="utf-8"))
    assert cfg["approvals"]["mode"] == "manual"
    assert cfg["approvals"]["timeout"] == agent_registry.APPROVAL_TIMEOUT_S
    assert "vertus-guard" in cfg["plugins"]["enabled"]
    plugin = home / "plugins" / "vertus-guard"
    assert plugin.is_symlink() and (plugin / "plugin.yaml").is_file()
    assert plugin.resolve() == agent_registry.GUARD_PLUGIN_DIR.resolve()


def test_existing_agents_pick_up_the_policy_at_boot(hub):
    import agent_registry
    home = hub.registry.agent_home("primary")
    # A home written before approvals existed.
    (home / "config.yaml").write_text("approvals:\n  mode: false\n  timeout: 15\n", encoding="utf-8")
    assert hub.registry.rematerialize_all() == []
    cfg = agent_registry._yaml_load((home / "config.yaml").read_text(encoding="utf-8"))
    assert cfg["approvals"]["mode"] == "manual"


def test_always_allow_answers_survive_rematerialization(hub):
    # "Always allow" is written by the engine into the agent's own config;
    # re-deriving the home (every hub boot) must keep it.
    import agent_registry
    home = hub.registry.agent_home("primary")
    cfg_path = home / "config.yaml"
    cfg = agent_registry._yaml_load(cfg_path.read_text(encoding="utf-8"))
    cfg["command_allowlist"] = ["delete in root path"]
    cfg_path.write_text(agent_registry._yaml_dump(cfg), encoding="utf-8")
    assert hub.registry.rematerialize_all() == []
    again = agent_registry._yaml_load(cfg_path.read_text(encoding="utf-8"))
    assert again["command_allowlist"] == ["delete in root path"]
    assert again["approvals"]["mode"] == "manual"


def test_the_bearer_token_alone_cannot_answer(hub):
    # Every agent can read the hub's bearer token; answering also needs the
    # approver credential, which agents are never given.
    bridge = hub.mgr.get_or_create_session("primary")
    bridge.store = hub.store
    answered: list = []

    class _Engine:
        def respond_approval(self, approval_id, choice):
            answered.append(choice)
            return True

    bridge._session = _Engine()
    bridge._on_pi_event({"type": "approval_request", "approval_id": "a5", "command": "git push"})
    assert _wait(lambda: hub.store.get_approval("a5") is not None)
    assert _post(hub.base, "/api/approvals/a5", {"choice": "once"}, approver=None)[0] == 403
    assert _post(hub.base, "/api/approvals/a5", {"choice": "once"}, approver="guess")[0] == 403
    assert answered == [] and hub.store.get_approval("a5")["decision"] is None


def test_a_losing_second_answer_learns_what_actually_happened(hub):
    bridge = hub.mgr.get_or_create_session("primary")
    bridge.store = hub.store

    class _Engine:
        def respond_approval(self, approval_id, choice):
            return False                      # the first answer already won

        def settled_approval(self, approval_id):
            return "once"

    bridge._session = _Engine()
    bridge._on_pi_event({"type": "approval_request", "approval_id": "a6", "command": "git push"})
    assert _wait(lambda: hub.store.get_approval("a6") is not None)
    status, body = _post(hub.base, "/api/approvals/a6", {"choice": "deny"})
    assert status == 409 and body["error"].endswith("settled: once")
    # The loser does not overwrite the ledger: the winner's event settles it.
    assert hub.store.get_approval("a6")["decision"] is None
    bridge._on_pi_event({"type": "approval_resolved", "approval_id": "a6", "decision": "once"})
    assert _wait(lambda: hub.store.get_approval("a6")["decision"] == "once")


def test_bridge_refuses_an_answer_the_engine_did_not_offer():
    gateway, session, events = _bridge_session()
    gateway.send({"jsonrpc": "2.0", "id": "srv-4", "method": "approval", "params": {
        "session_id": "s", "request_id": "req-4", "command": "rm -rf /", "choices": ["once", "deny"]}})
    assert _wait(lambda: any(e["type"] == "approval_request" for e in events))
    with pytest.raises(ValueError):
        session.respond_approval("req-4", "always")
    assert session.respond_approval("req-4", "deny") is True
    assert session.settled_approval("req-4") == "deny"


def test_approvals_left_open_are_withdrawn_not_offered_forever(tmp_path):
    store = RunStore(tmp_path / "fleet.db")
    try:
        store.record_approval_request("x1", None, "primary", "a", "")
        store.record_approval_request("x2", None, "primary", "b", "")
        store.record_approval_request("x3", None, "primary", "c", "")
        assert store.withdraw_pending_approvals(["x1"]) == 1          # a turn ended
        assert store.get_approval("x1")["decision"] == "withdrawn"
        assert store.withdraw_pending_approvals(decided_by="hub restart") == 2   # boot
        assert store.list_approvals(state="pending") == []
    finally:
        store.stop()


def test_an_agents_own_settings_survive_rematerialization(hub):
    import agent_registry
    home = hub.registry.agent_home("primary")
    cfg_path = home / "config.yaml"
    cfg = agent_registry._yaml_load(cfg_path.read_text(encoding="utf-8"))
    cfg["mcp_servers"] = {"linear": {"url": "https://mcp.linear.app"}}
    cfg_path.write_text(agent_registry._yaml_dump(cfg), encoding="utf-8")
    assert hub.registry.rematerialize_all() == []
    again = agent_registry._yaml_load(cfg_path.read_text(encoding="utf-8"))
    assert again["mcp_servers"] == {"linear": {"url": "https://mcp.linear.app"}}


def test_no_gateway_runs_with_the_approval_bypass(hub, monkeypatch):
    monkeypatch.setenv("HERMES_YOLO_MODE", "1")
    for unattended in (False, True):
        kwargs = vs.resolve_session_kwargs(hub.registry, "primary", unattended=unattended)
        assert kwargs["extra_env"]["HERMES_YOLO_MODE"] == "0"


def test_sites_are_served_without_the_token_and_never_outside_their_folder(hub, tmp_path, monkeypatch):
    sites = tmp_path / "sites"
    (sites / "trip-1a2b3c4d").mkdir(parents=True)
    (sites / "trip-1a2b3c4d" / "index.html").write_text("<h1>Lisbon</h1>")
    (tmp_path / "secret.txt").write_text("nope")
    monkeypatch.setenv("VERTUS_SITES_DIR", str(sites))
    with urllib.request.urlopen(hub.base + "/sites/trip-1a2b3c4d/", timeout=10) as resp:
        assert resp.status == 200 and b"Lisbon" in resp.read()
        assert resp.headers["Content-Type"].startswith("text/html")
    for bad in ("/sites/../secret.txt", "/sites/%2e%2e/secret.txt", "/sites/missing/"):
        with pytest.raises(urllib.error.HTTPError) as err:
            urllib.request.urlopen(hub.base + bad, timeout=10)
        assert err.value.code == 404


def test_calendar_and_sites_skills_reach_every_agent_with_the_link(hub, monkeypatch):
    monkeypatch.setenv("VERTUS_SITES_URL", "http://100.1.2.3:8787/sites/")
    assert hub.registry.rematerialize_all() == []
    skills = hub.registry.agent_home("primary") / "skills"
    assert "vertus-events" in (skills / "vertus-calendar" / "SKILL.md").read_text()
    sites = (skills / "vertus-sites" / "SKILL.md").read_text()
    assert "http://100.1.2.3:8787/sites/" in sites and "{{" not in sites
