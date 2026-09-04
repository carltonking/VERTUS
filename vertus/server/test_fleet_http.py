"""Step 5 HTTP surface + in-flight tracking: status, POST/PATCH/DELETE agents.

Run from the repo root:
    python3 -m pytest vertus/server/test_fleet_http.py -v

Everything goes through the REAL VertusHandler on a live ThreadingHTTPServer
with fake engine sessions (FakeBridge — imported from test_session_manager,
which never spawns a real gateway). Coverage:

  Step A — bridge.status()/SessionManager.status(); GET /api/agents/<id>/status
           (no bridge side effect); status stays "running" across a respawn.
  Step B — POST full field set + validation; PATCH (deferred mid-turn, stale
           coalescing, respawn_pending); DELETE (primary/busy 409, archive).
  Step C — concurrency hammer: PATCH + DELETE + prompt across agents with no
           deadlock and no lost registry updates.
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
from agent_registry import AgentRegistry  # noqa: E402
from test_session_manager import FakeBridge, FakeSession, make_manager  # noqa: E402


# ----------------------------------------------------------------------
# HTTP plumbing
# ----------------------------------------------------------------------


@pytest.fixture()
def hub(monkeypatch, tmp_path):
    """A real ThreadingHTTPServer running VertusHandler with fake bridges."""
    mgr, registry = make_manager(monkeypatch, tmp_path)
    vs.VertusHandler.sessions = mgr
    vs.VertusHandler.registry = registry
    vs.VertusHandler.token = "test-token"
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    yield base
    server.shutdown()


def _req(base: str, path: str, method: str = "GET", payload: dict | None = None,
         token: str = "test-token"):
    """Request helper; returns (status, parsed-json) without raising on 4xx/5xx."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        base + path,
        data=data,
        headers={"Authorization": f"Bearer {token}"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {}


def _wait_until(predicate, timeout: float = 8.0, interval: float = 0.01):
    """Poll until predicate() is truthy or the deadline passes."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def _post_prompt(base: str, agent_id: str, text: str) -> tuple[int, dict]:
    return _req(base, "/api/prompt", "POST", {"text": text, "agent_id": agent_id})


def _status_of(hub_base: str, agent_id: str) -> dict:
    _, body = _req(hub_base, f"/api/agents/{agent_id}/status")
    return body


# ----------------------------------------------------------------------
# Step A: status() / GET /api/agents/<id>/status
# ----------------------------------------------------------------------


def test_status_bridge_level_idle_running_idle(monkeypatch, tmp_path):
    """bridge.status(): idle -> running (turn_started_at set) -> idle."""
    mgr, _ = make_manager(monkeypatch, tmp_path)
    p = mgr.get_or_create_session("primary")
    _wait_until(lambda: p.status()["gateway_alive"])  # prewarm finished
    idle = p.status()
    assert idle["state"] == "idle" and idle["turn_started_at"] is None
    assert idle["queue_depth"] == 0 and idle["gateway_alive"] is True

    p.prompt("hello", remote=False)
    saw_running = _wait_until(lambda: p.status()["state"] == "running")
    assert saw_running, "running marker must be visible during a slow turn"
    while p.status()["state"] == "running":
        st = p.status()
        assert st["turn_started_at"] is not None, "turn_started_at set while running"
        time.sleep(0.005)
    done = p.status()
    assert done["state"] == "idle" and done["turn_started_at"] is None
    assert done["queue_depth"] == 0


def test_status_never_creates_bridge(hub):
    """GET status on a never-run agent reports idle and does NOT build a bridge."""
    base = hub
    status, body = _req(base, "/api/agents/scout/status")
    assert status == 200
    assert body == {
        "state": "idle",
        "queue_depth": 0,
        "turn_started_at": None,
        "gateway_alive": False,
    }
    mgr = vs.VertusHandler.sessions
    assert not mgr.has_session("scout"), "status endpoint must not instantiate a bridge"


def test_status_http_lifecycle_and_unknown(hub):
    base = hub
    # Never-run agent → idle payload (already proven above); then prompt and
    # watch idle → running → idle over HTTP, ending with a live gateway.
    _post_prompt(base, "scout", "status check")
    saw_running = _wait_until(lambda: _status_of(base, "scout")["state"] == "running")
    assert saw_running, "running must be observable through the HTTP endpoint"
    _wait_until(lambda: _status_of(base, "scout")["state"] == "idle")
    st = _status_of(base, "scout")
    assert st["state"] == "idle" and st["gateway_alive"] is True
    assert vs.VertusHandler.sessions.has_session("scout")
    # Unknown agent and auth.
    status, _ = _req(base, "/api/agents/ghost/status")
    assert status == 404
    status, _ = _req(base, "/api/agents/scout/status", token="wrong")
    assert status == 401


class FlakySession(FakeSession):
    """FakeSession whose first prompt raises BrokenPipeError once (gateway death)."""

    def prompt(self, text: str) -> None:
        if self.bridge.fail_next_prompt:
            self.bridge.fail_next_prompt = False
            raise BrokenPipeError("gateway died mid-turn")
        super().prompt(text)


class FlakyBridge(FakeBridge):
    """FakeBridge that can kill its gateway exactly once, forcing the respawn path."""

    def __init__(self, agent_id: str = "primary", cwd: str | None = None,
                 session_kwargs: dict | None = None):
        super().__init__(agent_id, cwd=cwd, session_kwargs=session_kwargs)
        self.fail_next_prompt = False

    def _make(self, cwd=None, **kwargs):
        self.last_cwd = cwd
        self.last_spawn_kwargs = kwargs
        s = FlakySession(self, delay=0.25)
        self.sessions.append(s)
        return {"session": s}


def test_status_running_across_respawn_retry():
    """A turn being retried (gateway died mid-turn) stays 'running' throughout."""
    b = FlakyBridge("primary")
    _wait_until(lambda: b.status()["gateway_alive"])  # prewarmed session up
    assert len(b.sessions) == 1
    b.fail_next_prompt = True
    b.prompt("turn-that-dies", remote=False)
    # The first prompt raises BrokenPipe on the prewarmed session; the worker
    # respawns and retries — the running marker must stay set across BOTH
    # attempts (one status() call, one bridge status() → one respawn retry).
    saw_running = _wait_until(lambda: b.status()["state"] == "running")
    assert saw_running
    spawned_twice = _wait_until(lambda: len(b.sessions) >= 2)
    assert spawned_twice, "respawn must have created a second session"
    assert b.status()["state"] == "running", "retry is still one running turn"
    assert b.status()["turn_started_at"] is not None
    _wait_until(lambda: b.status()["state"] == "idle")
    done = b.status()
    assert done["state"] == "idle" and done["turn_started_at"] is None
    assert done["queue_depth"] == 0
    assert b.sessions[-1].prompts == ["turn-that-dies"], "retried turn completed"
    assert b.status()["gateway_alive"] is True


# ----------------------------------------------------------------------
# Step B: POST /api/agents — full field set, validation
# ----------------------------------------------------------------------


def test_post_full_field_set_round_trips(hub):
    base = hub
    payload = {
        "name": "Sage",
        "title": "The Sage",
        "description": "recon butler, wiser edition",
        "persona": "You are SAGE. Slow, steady, deliberate.",
        "model": "model-sage",
        "provider": "prov-sage",
        "color": "#123456",
        "emoji": "🧙",
        "autonomy": "trusted",
    }
    status, body = _req(base, "/api/agents", "POST", payload)
    assert status == 201, body
    assert body["id"] == "sage"
    for key, value in payload.items():
        if key != "name":
            assert body[key] == value, f"{key} round-trip failed"
    assert body["schema_version"] == 2
    assert body["is_primary"] is False
    # GET returns the identical v2 profile.
    status, fetched = _req(base, "/api/agents/sage")
    assert status == 200 and fetched == body
    # The derived home was materialized from the create fields, not the defaults.
    home = Path(body["home_path"])
    assert (home / "SOUL.md").read_text().startswith("You are SAGE")
    cfg = (home / "config.yaml").read_text()
    assert "model-sage" in cfg and "prov-sage" in cfg
    # Every listed agent is v2-shaped after all of the above.
    _, listed = _req(base, "/api/agents")
    for agent in listed["agents"]:
        assert agent["schema_version"] == 2
        assert "title" in agent and "autonomy" in agent and "home_path" in agent


def test_post_validation(hub):
    base = hub
    cases = [
        ({}, "name required"),
        ({"name": "   "}, "name required"),
        ({"name": ["not-a-string"]}, "name required"),
        ({"name": "X", "autonomy": "sometimes"}, "autonomy"),
        ({"name": "X", "autonomy": None}, "autonomy"),
        ({"name": "X", "soul": "unknown key"}, "unknown field"),
        ({"name": "X", "model": 5}, "string or null"),
        ({"name": "X", "model": ["a"]}, "string or null"),
        ({"name": "X", "persona": "p" * (vs.PERSONA_MAX_CHARS + 1)}, "persona exceeds"),
    ]
    for payload, needle in cases:
        status, body = _req(base, "/api/agents", "POST", payload)
        assert status == 400, (payload, status, body)
        assert needle in str(body.get("error", "")).lower(), (payload, body)
    # None on identity fields is legal (inherit); none on persona clears to "".
    status, body = _req(base, "/api/agents", "POST", {"name": "Nully", "model": None, "persona": None})
    assert status == 201
    assert body["model"] is None and body["persona"] == ""


def test_post_collision_id_is_deterministic(monkeypatch, tmp_path):
    """Same name twice → slug then deterministic slug-uuid suffix (registry-level)."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    registry = AgentRegistry()
    registry.ensure_primary()
    first = registry.create_agent("Research Bot")
    second = registry.create_agent("Research Bot")
    assert first["id"] == "research-bot"
    assert second["id"].startswith("research-bot-")
    assert second["id"] != first["id"]
    assert len(registry.list_agents()) == 3


# ----------------------------------------------------------------------
# Step B: PATCH /api/agents/<id>
# ----------------------------------------------------------------------


def test_patch_inflight_turn_completes_then_respawn(hub):
    """PATCH during a turn: old gateway finishes it; the NEXT turn respawns new."""
    base = hub
    mgr = vs.VertusHandler.sessions

    # Turn one creates the scout bridge (prewarmed with default identity).
    _post_prompt(base, "scout", "turn-one")
    b = mgr.get_or_create_session("scout")
    assert _wait_until(lambda: b.sessions and b.sessions[0].prompts == ["turn-one"])
    _wait_until(lambda: b.status()["state"] == "idle")
    assert len(b.sessions) == 1
    old_session = b.sessions[0]

    # Turn two is in flight on the OLD gateway when the PATCH lands.
    _post_prompt(base, "scout", "turn-two")
    assert _wait_until(lambda: b.status()["state"] == "running")
    status, body = _req(base, "/api/agents/scout", "PATCH", {"model": "brand-new-model"})
    assert status == 200, body
    assert body["model"] == "brand-new-model"
    assert body["respawn_pending"] is True

    # The in-flight turn completes undisturbed on the old gateway: still the
    # same session object, still no respawn yet.
    _wait_until(lambda: b.status()["state"] == "idle")
    assert len(b.sessions) == 1, "no respawn may happen mid-turn"
    assert b.sessions[0] is old_session
    assert b.sessions[0].prompts == ["turn-one", "turn-two"]

    # Second PATCH before any turn: stale flag coalesces → still ONE respawn.
    status, body = _req(base, "/api/agents/scout", "PATCH", {"provider": "prov-x"})
    assert status == 200 and body["respawn_pending"] is True

    _post_prompt(base, "scout", "turn-three")
    assert _wait_until(lambda: len(b.sessions) == 2 and b.sessions[-1].prompts)
    assert len(b.sessions) == 2, "two PATCHes before the next turn = one respawn"
    new_session = b.sessions[1]
    assert new_session is not old_session
    assert new_session.prompts == ["turn-three"]
    assert b.last_spawn_kwargs.get("model") == "brand-new-model"
    assert b.last_spawn_kwargs.get("provider") == "prov-x"
    # The old gateway never saw turn three.
    assert old_session.prompts == ["turn-one", "turn-two"]
    # And the next status shows the new gateway alive.
    _wait_until(lambda: b.status()["state"] == "idle")
    assert b.status()["gateway_alive"] is True


def test_patch_never_prompted_agent_needs_no_respawn(hub):
    """An agent with no live bridge picks up the PATCH at first spawn: no respawn."""
    base = hub
    status, body = _req(base, "/api/agents", "POST", {"name": "Sigma"})
    assert status == 201
    # PATCH before any prompt → no bridge exists → respawn_pending False.
    status, body = _req(base, "/api/agents/sigma", "PATCH", {"model": "sigma-model"})
    assert status == 200
    assert body["model"] == "sigma-model" and body["respawn_pending"] is False
    # First prompt: the factory reads the ALREADY-updated registry, so the
    # bridge is born with the new config — no respawn needed, no churn.
    _post_prompt(base, "sigma", "hello")
    b = vs.VertusHandler.sessions.get_or_create_session("sigma")
    _wait_until(lambda: b.sessions and b.sessions[-1].prompts)
    assert len(b.sessions) == 1, "fresh bridge must not respawn"
    assert b.last_spawn_kwargs.get("model") == "sigma-model"


def test_patch_validation(hub):
    base = hub
    cases = [
        ({"name": "renamed"}, "not editable"),
        ({"soul": "x"}, "unknown field"),
        ({"autonomy": "sometimes"}, "autonomy"),
        ({"persona": "p" * (vs.PERSONA_MAX_CHARS + 1)}, "persona exceeds"),
        ({"model": 7}, "string or null"),
    ]
    for payload, needle in cases:
        status, body = _req(base, "/api/agents/scout", "PATCH", payload)
        assert status == 400, (payload, status, body)
        assert needle in str(body.get("error", "")).lower(), (payload, body)
    # PATCH {} is a no-op read.
    status, body = _req(base, "/api/agents/scout", "PATCH", {})
    assert status == 200 and body["respawn_pending"] is False
    # PATCH clears with null / "".
    status, body = _req(base, "/api/agents/scout", "PATCH",
                        {"persona": "hi", "model": "m"})
    assert status == 200 and body["persona"] == "hi" and body["model"] == "m"
    status, body = _req(base, "/api/agents/scout", "PATCH",
                        {"persona": None, "model": ""})
    assert status == 200 and body["persona"] == "" and body["model"] is None
    # Unknown agent and auth.
    status, _ = _req(base, "/api/agents/ghost", "PATCH", {"model": "x"})
    assert status == 404
    status, _ = _req(base, "/api/agents/scout", "PATCH", {"model": "x"}, token="wrong")
    assert status == 401


# ----------------------------------------------------------------------
# Step B: DELETE /api/agents/<id>
# ----------------------------------------------------------------------


def test_delete_refuses_primary_and_busy(hub):
    base = hub
    status, body = _req(base, "/api/agents/primary", "DELETE")
    assert status == 409 and "primary" in str(body.get("error", "")).lower()
    # Prompt scout and delete while the (slow fake) turn is running.
    _post_prompt(base, "scout", "long turn")
    b = vs.VertusHandler.sessions.get_or_create_session("scout")
    assert _wait_until(lambda: b.status()["state"] == "running")
    status, body = _req(base, "/api/agents/scout", "DELETE")
    assert status == 409 and "busy" in str(body.get("error", "")).lower()
    # Queue depth also blocks deletion: two more prompts behind the running one.
    _post_prompt(base, "scout", "queued-a")
    _post_prompt(base, "scout", "queued-b")
    assert _wait_until(lambda: b.status()["queue_depth"] >= 2)
    status, _ = _req(base, "/api/agents/scout", "DELETE")
    assert status == 409
    # Let it drain; now delete succeeds.
    assert _wait_until(lambda: b.status()["state"] == "idle"
                       and b.status()["queue_depth"] == 0, timeout=15)
    status, body = _req(base, "/api/agents/scout", "DELETE")
    assert status == 200, body


def test_delete_archives_and_removes_from_registry(hub):
    base = hub
    mgr = vs.VertusHandler.sessions
    # Give scout a live (idle) bridge first, then delete it.
    _post_prompt(base, "scout", "one")
    b = mgr.get_or_create_session("scout")
    _wait_until(lambda: b.sessions and b.sessions[-1].prompts and b.status()["state"] == "idle")
    registry = vs.VertusHandler.registry
    agents_root = registry.root

    status, body = _req(base, "/api/agents/scout", "DELETE")
    assert status == 200, body
    assert body["deleted"] == "scout"
    archived = body["archived_to"]
    assert ".trash" in archived and archived.startswith(str(agents_root))
    assert Path(archived).is_dir(), "archive dir must exist"
    assert (Path(archived) / "profile.json").is_file(), "archive keeps profile.json"
    assert not (agents_root / "scout").exists(), "live dir must be gone"

    # Registry no longer lists it; getters 404.
    _, listed = _req(base, "/api/agents")
    assert "scout" not in [a["id"] for a in listed["agents"]]
    status, _ = _req(base, "/api/agents/scout")
    assert status == 404
    # The bridge was dropped and its worker stopped.
    assert not mgr.has_session("scout")
    assert not b._worker.is_alive()
    # A subsequent prompt 404s instead of resurrecting the agent.
    status, body = _post_prompt(base, "scout", "zombie?")
    assert status == 404
    assert not mgr.has_session("scout"), "prompt must not recreate a deleted agent"
    # Status for the deleted agent 404s too.
    status, _ = _req(base, "/api/agents/scout/status")
    assert status == 404


def test_delete_never_prompted_agent(hub):
    base = hub
    status, body = _req(base, "/api/agents", "POST", {"name": "Ephemeral"})
    assert status == 201
    status, body = _req(base, "/api/agents/ephemeral", "DELETE")
    assert status == 200
    assert Path(body["archived_to"]).is_dir()
    status, body = _post_prompt(base, "ephemeral", "gone")
    assert status == 404


# ----------------------------------------------------------------------
# Step C: lock discipline hammer — no deadlock, no lost updates
# ----------------------------------------------------------------------


def test_lock_hammer_concurrent_patch_delete_prompt(hub):
    """PATCH + DELETE + prompt hammer: no deadlock, no lost registry updates."""
    base = hub
    status, body = _req(base, "/api/agents", "POST", {"name": "Hammer"})
    assert status == 201
    hammer_id = body["id"]

    errors: list[str] = []
    barrier = threading.Barrier(7)  # 4 patch threads + 2 prompt threads + 1 lifecycle
    workers: list[threading.Thread] = []

    def _run(fn):
        try:
            barrier.wait(timeout=10)
            fn()
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{exc!r}")

    def patch_thread(field: str):
        for i in range(8):
            status, body = _req(base, f"/api/agents/{hammer_id}", "PATCH",
                                {field: f"{field}-{i}"})
            assert status == 200, body
            assert body["respawn_pending"] in (True, False)

    def prompt_thread(tag: str):
        for i in range(6):
            status, body = _post_prompt(base, hammer_id, f"pt-{tag}-{i}")
            assert status == 202, body

    def lifecycle_thread():
        for cycle in range(3):
            status, body = _req(base, "/api/agents", "POST", {"name": "Zephyr"})
            assert status == 201, body
            _post_prompt(base, "zephyr", f"lifecycle-{cycle}")
            # DELETE retries until the in-flight turn drains (409 → retry).
            deleted = False
            deadline = time.time() + 20
            while time.time() < deadline:
                status, body = _req(base, "/api/agents/zephyr", "DELETE")
                if status == 200:
                    deleted = True
                    break
                if status != 409:
                    errors.append(f"unexpected DELETE status {status}: {body}")
                    break
                time.sleep(0.05)
            assert deleted, "zephyr never became deletable"
            assert Path(body["archived_to"]).is_dir()

    for field in ("title", "description", "persona", "emoji"):
        t = threading.Thread(target=_run, args=(lambda f=field: patch_thread(f),), daemon=True)
        workers.append(t)
    for tag in ("a", "b"):
        t = threading.Thread(target=_run, args=(lambda t=tag: prompt_thread(t),), daemon=True)
        workers.append(t)
    t = threading.Thread(target=_run, args=(lifecycle_thread,), daemon=True)
    workers.append(t)

    for t in workers:
        t.start()
    for t in workers:
        t.join(timeout=90)
    alive = [t.name for t in workers if t.is_alive()]
    assert not alive, f"deadlock: threads still running: {alive}"
    assert not errors, f"worker errors: {errors}"

    # No lost updates: every thread's LAST write (field-7) must have survived.
    status, body = _req(base, f"/api/agents/{hammer_id}")
    assert status == 200
    for field in ("title", "description", "persona", "emoji"):
        assert body[field] == f"{field}-7", f"lost update on {field}: {body[field]!r}"
    # Lifecycle agent is gone; hammer still present.
    _, listed = _req(base, "/api/agents")
    ids = [a["id"] for a in listed["agents"]]
    assert hammer_id in ids and "zephyr" not in ids


# ----------------------------------------------------------------------
# Registry-level delete archive semantics (no HTTP)
# ----------------------------------------------------------------------


def test_registry_delete_archive_and_destroy(monkeypatch, tmp_path):
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    registry = AgentRegistry()
    registry.ensure_primary()
    agent = registry.create_agent("Doomed")
    doomed_dir = registry.root / agent["id"]

    archived = registry.delete_agent(agent["id"], archive=True)
    assert archived is not None and ".trash" in archived
    assert not doomed_dir.exists()
    assert (Path(archived) / "profile.json").is_file()
    with pytest.raises(KeyError):
        registry.get_agent(agent["id"])
    with pytest.raises(KeyError):
        registry.delete_agent(agent["id"], archive=True)
    # Non-archive still destroys, and the last agent stays protected.
    second = registry.create_agent("AlsoDoomed")
    assert registry.delete_agent(second["id"], archive=False) is None
    assert not (registry.root / second["id"]).exists()
    with pytest.raises(ValueError):
        registry.delete_agent("primary", archive=True)
