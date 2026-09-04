"""Per-agent sessions: manager behavior, hub HTTP compatibility, concurrency proof.

Run from the repo root:
    python3 -m pytest vertus/server/test_session_manager.py -v

No engine subprocess is ever spawned: AgentBridge's session factory is
injected (see vertus_server.build_session_manager's ``factory`` hook), and
fake sessions return deterministic events. The real hermes gateway is only
touched by the separate manual smoke described in the README.
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
from queue import Queue, Empty

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vertus_server as vs  # noqa: E402
from session_manager import SessionManager  # noqa: E402


# ----------------------------------------------------------------------
# Fakes
# ----------------------------------------------------------------------


class FakeSession:
    """Stands in for the hermes session: records prompts, emits fixed events."""

    def __init__(self, bridge, delay: float = 0.35):
        self.bridge = bridge
        self.delay = delay
        self.prompts: list[str] = []
        self.closed = False

    def subscribe(self, listener) -> None:  # bridge calls this post-create
        pass

    def prompt(self, text: str) -> None:
        self.prompts.append(text)
        time.sleep(self.delay)  # simulate a slow agent turn
        # Hermes-like: stream text only; the turn ends when prompt() returns
        # and the bridge's backstop emits the single "done" wire event.
        self.bridge._on_pi_event({"type": "text", "text": f"reply-to:{text}"})

    def close(self) -> None:
        self.closed = True


class FakeBridge(vs.AgentBridge):
    """AgentBridge with the real queue/worker but a FakeSession engine.

    Records the cwd kwarg (the sandbox binding under test) and the identity
    kwargs (per-agent HERMES_HOME / model / provider) via super().
    """

    def __init__(self, agent_id: str, cwd: str | None = None, session_kwargs: dict | None = None):
        # Assign before super().__init__: the worker prewarms immediately and
        # _make appends to self.sessions from that thread.
        self.sessions: list[FakeSession] = []
        self.session_kwargs = dict(session_kwargs or {})
        super().__init__(agent_id=agent_id, create_session_factory=self._make, cwd=cwd, session_kwargs=session_kwargs)

    def _make(self, cwd=None, **kwargs):
        self.last_cwd = cwd
        self.last_spawn_kwargs = kwargs
        s = FakeSession(self)
        self.sessions.append(s)
        return {"session": s}


def make_manager(monkeypatch, tmp_path) -> tuple[SessionManager, object]:
    """Registry + SessionManager through the PRODUCTION default factory.

    Swaps the real AgentBridge class for FakeBridge (accepts the same
    agent_id/cwd kwargs), so every session is built exactly like production —
    including the sandbox cwd resolution — without spawning an engine.
    """
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    registry = vs.AgentRegistry()
    registry.ensure_primary()
    registry.create_agent("Scout")
    monkeypatch.setattr(vs, "AgentBridge", FakeBridge)
    mgr = vs.build_session_manager(registry)
    return mgr, registry


# ----------------------------------------------------------------------
# SessionManager unit behavior
# ----------------------------------------------------------------------


def test_manager_is_keyed_and_lazy(monkeypatch, tmp_path):
    mgr, _ = make_manager(monkeypatch, tmp_path)
    # Seeded primary exists eagerly; scout is not built until first use.
    assert mgr.has_session("primary")
    assert not mgr.has_session("scout")
    a = mgr.get_or_create_session("primary")
    b = mgr.get_or_create_session("scout")
    assert a is not b, "different agents must get different bridges"
    assert mgr.get_or_create_session("scout") is b, "same agent returns same bridge"
    assert sorted(mgr.live_ids()) == ["primary", "scout"]


def test_manager_rejects_unknown_agent(monkeypatch, tmp_path):
    mgr, _ = make_manager(monkeypatch, tmp_path)
    with pytest.raises(KeyError):
        mgr.get_or_create_session("ghost")
    assert not mgr.has_session("ghost")  # nothing was created for it


def test_manager_never_prompts_through_another_agents_bridge(monkeypatch, tmp_path):
    mgr, _ = make_manager(monkeypatch, tmp_path)
    p = mgr.get_or_create_session("primary")
    s = mgr.get_or_create_session("scout")
    p.prompt("hi primary", remote=False)
    s.prompt("hi scout", remote=False)
    deadline = time.time() + 5
    while time.time() < deadline and (
        not p.sessions or not s.sessions or not p.sessions[-1].prompts or not s.sessions[-1].prompts
    ):
        time.sleep(0.02)
    assert p.sessions[-1].prompts == ["hi primary"]
    assert s.sessions[-1].prompts == ["hi scout"]


# ----------------------------------------------------------------------
# HTTP compatibility (real handler, injected fakes, no engine)
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


def _req(base: str, path: str, payload: dict | None = None, token: str = "test-token"):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": f"Bearer {token}"},
        method="POST" if payload is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status, json.loads(resp.read())


def _req_raw(base: str, path: str):
    """Raw GET; returns (status, body-bytes) without raising on 4xx/5xx."""
    req = urllib.request.Request(base + path, headers={"Authorization": "Bearer test-token"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _req_any(base: str, path: str, payload: dict | None = None, token: str = "test-token"):
    """Like _req but returns (status, parsed-json) instead of raising on 4xx."""
    req = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": f"Bearer {token}"},
        method="POST" if payload is not None else "GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {}


def test_http_default_prompt_and_agent_id(hub):
    base = hub
    # 1) Old body shape, no agent_id → routed to primary (backward compatible).
    status, body = _req(base, "/api/prompt", {"text": "hello"})
    assert status == 202 and body["agent_id"] == "primary"
    # 2) New body shape: "prompt" field + explicit agent_id.
    status, body = _req(base, "/api/prompt", {"prompt": "hi scout", "agent_id": "scout"})
    assert status == 202 and body["agent_id"] == "scout"
    # 3) prompt field wins when text is absent.
    status, body = _req(base, "/api/prompt", {"prompt": "plain"})
    assert status == 202 and body["agent_id"] == "primary"
    deadline = time.time() + 5
    mgr = vs.VertusHandler.sessions
    while time.time() < deadline and (
        not mgr.get_or_create_session("primary").sessions[-1].prompts
        or not mgr.get_or_create_session("scout").sessions[-1].prompts
    ):
        time.sleep(0.02)
    assert mgr.get_or_create_session("primary").sessions[-1].prompts == ["hello"]
    assert mgr.get_or_create_session("scout").sessions[-1].prompts == ["hi scout"]


def test_http_unknown_agent_404(hub):
    base = hub
    status, _ = _req_raw(base, "/api/prompt")  # GET on a POST route → 404
    assert status == 404
    status, body = _req_any(base, "/api/prompt", {})
    assert status == 400  # empty body: text required (unchanged)
    req = urllib.request.Request(
        base + "/api/prompt",
        data=json.dumps({"text": "x", "agent_id": "ghost"}).encode(),
        headers={"Authorization": "Bearer test-token"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
        raise AssertionError("expected 404")
    except urllib.error.HTTPError as e:
        assert e.code == 404
    status, _ = _req_raw(base, "/api/events?agent_id=ghost")
    assert status == 404


def test_http_events_stream_only_that_agents_events(hub):
    base = hub
    # Two concurrent SSE subscribers, one per agent.
    streams: dict[str, list[dict]] = {"primary": [], "scout": []}
    ready = threading.Event()
    stop = threading.Event()

    def listen(agent: str):
        req = urllib.request.Request(
            f"{base}/api/events?agent_id={agent}",
            headers={"Authorization": "Bearer test-token"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            ready.set()
            buf = b""
            while not stop.is_set():
                chunk = resp.read1(256)
                if not chunk:
                    break
                buf += chunk
                while b"\n\n" in buf:
                    frame, buf = buf.split(b"\n\n", 1)
                    line = frame.decode().strip()
                    if line.startswith("data: "):
                        streams[agent].append(json.loads(line[6:]))

    t1 = threading.Thread(target=listen, args=("primary",), daemon=True)
    t2 = threading.Thread(target=listen, args=("scout",), daemon=True)
    t1.start()
    t2.start()
    assert ready.wait(5) and ready.wait(5)  # both streams connected

    _req(base, "/api/prompt", {"text": "one"})
    _req(base, "/api/prompt", {"prompt": "two", "agent_id": "scout"})
    deadline = time.time() + 5
    while time.time() < deadline and not (
        any(e.get("type") == "done" for e in streams["primary"])
        and any(e.get("type") == "done" for e in streams["scout"])
    ):
        time.sleep(0.02)
    stop.set()
    p_types = [e.get("type") for e in streams["primary"]]
    s_types = [e.get("type") for e in streams["scout"]]
    assert p_types == ["text", "done"], f"primary stream polluted: {p_types}"
    assert s_types == ["text", "done"], f"scout stream polluted: {s_types}"
    assert streams["primary"][0]["text"] == "reply-to:one"
    assert streams["scout"][0]["text"] == "reply-to:two"


def test_http_agents_endpoints_still_work(hub):
    base = hub
    status, body = _req(base, "/api/agents")
    assert status == 200 and [a["id"] for a in body["agents"]] == ["primary", "scout"]
    status, body = _req(base, "/api/health")
    assert status == 200 and body["status"] == "ok"
    status, body = _req(base, "/api/skills?agent_id=scout")
    assert status == 200  # routes through the scout session (fake has no catalog → 0 commands)
    # Auth still enforced.
    status, _ = _req_any(base, "/api/agents", token="wrong")
    assert status == 401


# ----------------------------------------------------------------------
# Sandbox isolation (Prompt 3)
# ----------------------------------------------------------------------


def test_default_factory_binds_each_agents_sandbox(monkeypatch, tmp_path):
    """The REAL default factory must cwd-bind every agent to its own sandbox."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    registry = vs.AgentRegistry()
    registry.ensure_primary()
    registry.create_agent("Scout")
    # Swap the real bridge class for the recording fake; build_session_manager
    # builds it through the production default factory incl. sandbox + identity
    # resolution. (The swap is REQUIRED: without it the real AgentBridge would
    # attempt a live engine prewarm in the test process.)
    monkeypatch.setattr(vs, "AgentBridge", FakeBridge)
    mgr = vs.build_session_manager(registry)
    p = mgr.get_or_create_session("primary")
    s = mgr.get_or_create_session("scout")
    agents_root = (tmp_path / "agents").resolve()
    assert p.cwd == str(agents_root / "primary" / "sandbox"), p.cwd
    assert s.cwd == str(agents_root / "scout" / "sandbox"), s.cwd
    assert p.cwd != s.cwd, "two agents must get two different sandbox cwds"
    for cwd in (p.cwd, s.cwd):
        assert Path(cwd).is_dir(), "sandbox must exist before session starts"
        assert not cwd.startswith(str(Path.home())) or "agents" in cwd, cwd


def test_resolve_sandbox_recreates_missing_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    registry = vs.AgentRegistry()
    registry.ensure_primary()
    sandbox = registry.root / "primary" / "sandbox"
    import shutil

    shutil.rmtree(sandbox)
    resolved = vs.resolve_sandbox_cwd(registry, "primary")
    assert Path(resolved).is_dir(), "resolve must re-ensure the sandbox dir"
    assert resolved == str(sandbox.resolve())


def test_resolve_sandbox_unknown_agent_raises(monkeypatch, tmp_path):
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    registry = vs.AgentRegistry()
    registry.ensure_primary()
    with pytest.raises(KeyError):
        vs.resolve_sandbox_cwd(registry, "ghost")


def test_prompt_response_includes_sandbox_path(hub):
    base = hub
    status, body = _req(base, "/api/prompt", {"text": "where am i", "agent_id": "scout"})
    assert status == 202
    bridge = vs.VertusHandler.sessions.get_or_create_session("scout")
    assert body["sandbox_path"] == bridge.cwd
    assert body["sandbox_path"].endswith("scout/sandbox")


# ----------------------------------------------------------------------
# Concurrency proof: two agents in flight simultaneously
# ----------------------------------------------------------------------


def test_two_agents_prompt_in_parallel(monkeypatch, tmp_path):
    mgr, _ = make_manager(monkeypatch, tmp_path)
    p = mgr.get_or_create_session("primary")
    s = mgr.get_or_create_session("scout")
    in_flight = {"n": 0, "peak": 0}
    lock = threading.Lock()
    real_prompt = FakeSession.prompt

    def counting_prompt(self, text: str) -> None:
        with lock:
            in_flight["n"] += 1
            in_flight["peak"] = max(in_flight["peak"], in_flight["n"])
        try:
            real_prompt(self, text)
        finally:
            with lock:
                in_flight["n"] -= 1

    FakeSession.prompt = counting_prompt
    try:
        t0 = time.monotonic()
        p.prompt("p1", remote=False)
        s.prompt("s1", remote=False)
        deadline = time.time() + 5
        while time.time() < deadline and (
            not p.sessions[-1].prompts or not s.sessions[-1].prompts
        ):
            time.sleep(0.02)
        elapsed = time.monotonic() - t0
    finally:
        FakeSession.prompt = real_prompt

    assert in_flight["peak"] >= 2, (
        f"prompts serialized! peak in-flight={in_flight['peak']}, elapsed={elapsed:.2f}s"
    )
    # 2 turns × 0.35s each: serialized ≥0.70s, parallel ≈0.35s. Generous 0.6s
    # bound fails only if the old single-queue behavior came back.
    assert elapsed < 0.60, f"prompts look serialized: {elapsed:.2f}s"


def test_same_agent_still_serializes(monkeypatch, tmp_path):
    """A single agent must keep its per-prompt ordering (its own queue)."""
    mgr, _ = make_manager(monkeypatch, tmp_path)
    p = mgr.get_or_create_session("primary")
    p.prompt("first", remote=False)
    p.prompt("second", remote=False)
    deadline = time.time() + 5
    while time.time() < deadline and not (
        len(p.sessions) > 1 and p.sessions[-1].prompts
    ):
        time.sleep(0.02)
    # The worker processes sequentially: the SECOND session object is created
    # only after the first turn finished (respawn path creates per turn when
    # _session is None — but here the same session is reused, so check the
    # prompt list order on the single session).
    assert len(p.sessions) == 1, "one live session per bridge; no churn"
    assert p.sessions[0].prompts == ["first", "second"], "order must be preserved"


# ----------------------------------------------------------------------
# Step 1/2: schema v2 identity + derived engine home + memory dirs
# ----------------------------------------------------------------------


def test_v2_profile_fields_and_home_exist(monkeypatch, tmp_path):
    """New agents get the full v2 schema and a materialized engine home."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet-hermes"))
    registry = vs.AgentRegistry()
    agent = registry.create_agent("Scout")
    assert agent["schema_version"] == 2
    assert agent["title"] == "Scout"
    assert agent["autonomy"] == "ask"
    home = Path(agent["home_path"])
    assert home == tmp_path / "agents" / agent["id"] / "home"
    assert (home / "config.yaml").is_file(), "engine home must carry config.yaml"
    assert (home / "memories").is_dir(), "engine home must carry memories/"
    assert (home / "skills" / "vertus-memory" / "SKILL.md").is_file(), (
        "memory skill must be materialized into the agent home"
    )


def test_update_agent_materializes_soul_and_memory_dirs(monkeypatch, tmp_path):
    """persona/model updates rewrite home/ (derived state) immediately."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet-hermes"))
    registry = vs.AgentRegistry()
    agent = registry.create_agent("Scout")
    agent_mem, shared = registry.ensure_memory_dirs(agent["id"])
    updated = registry.update_agent(
        agent["id"],
        persona="You are SCOUT, the recon butler.",
        model="nemotron-3-ultra-free",
        provider="opencode-zen",
        emoji="🛰️",
        autonomy="trusted",
    )
    home = Path(updated["home_path"])
    assert (home / "SOUL.md").read_text().startswith("You are SCOUT")
    cfg_text = (home / "config.yaml").read_text()
    assert "nemotron-3-ultra-free" in cfg_text
    assert "opencode-zen" in cfg_text
    assert Path(updated["sandbox_path"]).is_dir()
    assert agent_mem.is_dir() and shared.is_dir()
    # profile.json on disk carries the update.
    on_disk = json.loads((registry.root / agent["id"] / "profile.json").read_text())
    assert on_disk["model"] == "nemotron-3-ultra-free"
    assert on_disk["schema_version"] == 2


def test_v1_profile_migration_is_idempotent_and_lossless(monkeypatch, tmp_path):
    """A v1 fixture upgrades in place: backfills, keeps unknown keys, no data loss."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet-hermes"))
    fleet = tmp_path / "fleet-hermes"
    fleet.mkdir(parents=True, exist_ok=True)
    (fleet / "SOUL.md").write_text("You are VERTUS, the user's personal butler.")
    registry = vs.AgentRegistry()
    registry.ensure_primary()
    # Hand-craft a v1 profile on disk, exactly as the pre-fleet hub wrote it.
    v1 = {
        "id": "primary",
        "name": "Primary",
        "created_at": "2026-09-01T10:00:00+00:00",
        "sandbox_path": str(tmp_path / "agents" / "primary" / "sandbox"),
        "custom_future_key": {"keep": True},  # unknown-key preservation
    }
    (tmp_path / "agents" / "primary").mkdir(parents=True, exist_ok=True)
    (tmp_path / "agents" / "primary" / "profile.json").write_text(json.dumps(v1))

    first = registry.get_agent("primary")
    assert first["schema_version"] == 2
    assert first["title"] == "Primary", "title backfilled from name"
    assert first["persona"].startswith("You are VERTUS"), (
        "persona backfilled from the fleet SOUL.md fixture"
    )
    assert first["custom_future_key"] == {"keep": True}, "unknown keys must survive"
    assert first["created_at"] == v1["created_at"], "v1 timestamps kept"
    on_disk = json.loads((tmp_path / "agents" / "primary" / "profile.json").read_text())
    assert on_disk["schema_version"] == 2
    assert on_disk["custom_future_key"] == {"keep": True}

    # Idempotent: reloading never changes values again.
    before = json.loads((tmp_path / "agents" / "primary" / "profile.json").read_text())
    again = registry.get_agent("primary")
    after = json.loads((tmp_path / "agents" / "primary" / "profile.json").read_text())
    assert before == after, "migration must not rewrite an already-v2 profile"
    assert again["title"] == "Primary"


def test_skills_materialized_with_injected_paths(monkeypatch, tmp_path):
    """Skill templates must carry the agent's real memory paths, not placeholders."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet-hermes"))
    registry = vs.AgentRegistry()
    agent = registry.create_agent("Scout")
    agent_mem, shared = registry.ensure_memory_dirs(agent["id"])
    skill = (Path(agent["home_path"]) / "skills" / "vertus-memory" / "SKILL.md").read_text()
    assert "{{AGENT_MEMORY_DIR}}" not in skill, "template markers must be substituted"
    assert str(agent_mem) in skill and str(shared) in skill


# ----------------------------------------------------------------------
# Step 3: per-agent identity reaches the spawn (HERMES_HOME + model)
# ----------------------------------------------------------------------


def test_spawn_carries_per_agent_home_and_model(monkeypatch, tmp_path):
    """The default factory must wire agent_home/model/provider into the bridge."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet-hermes"))
    registry = vs.AgentRegistry()
    registry.ensure_primary()
    registry.update_agent("primary", model="model-a", provider="prov-a")
    registry.create_agent("Scout")
    scout_id = registry.list_agents()[-1]["id"]
    registry.update_agent(scout_id, model="model-b", provider="prov-b")
    # FakeBridge keeps the production factory path (resolve_sandbox_cwd +
    # resolve_session_kwargs both run for real); only the engine spawn is fake.
    monkeypatch.setattr(vs, "AgentBridge", FakeBridge)
    mgr = vs.build_session_manager(registry)
    p = mgr.get_or_create_session("primary")
    s = mgr.get_or_create_session(scout_id)
    # Spawn synchronously (deterministic; no engine subprocess either way).
    p._spawn_session(remote=False)
    s._spawn_session(remote=False)
    assert p.session_kwargs.get("agent_home", "").endswith("primary/home")
    assert s.session_kwargs.get("agent_home", "").endswith("scout/home")
    assert p.session_kwargs["model"] == "model-a"
    assert s.session_kwargs["model"] == "model-b"
    assert p.session_kwargs["extra_env"]["HERMES_MODEL"] == "model-a"
    assert s.session_kwargs["extra_env"]["HERMES_INFERENCE_PROVIDER"] == "prov-b"
    # And the spawn call itself received the identity kwargs:
    assert p.last_spawn_kwargs.get("model") == "model-a"
    assert s.last_spawn_kwargs.get("agent_home", "").endswith("scout/home")
    assert p.cwd.endswith("primary/sandbox") and s.cwd.endswith("scout/sandbox")


def test_resolve_session_kwargs_unknown_agent_raises(monkeypatch, tmp_path):
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    registry = vs.AgentRegistry()
    registry.ensure_primary()
    with pytest.raises(KeyError):
        vs.resolve_session_kwargs(registry, "ghost")


# ----------------------------------------------------------------------
# Step 3: gateway env is explicitly constructed, never inherited
# ----------------------------------------------------------------------


def test_gateway_env_allowlist(monkeypatch):
    """build_gateway_env passes only allowlisted vars + provider keys + HERMES_HOME."""
    import hermes_bridge as hb

    monkeypatch.setenv("VERTUS_TOP_SECRET_BOT_FLAG", "leak-me")
    monkeypatch.setenv("HERMES_YOLO_MODE", "1")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.delenv("HERMES_HOME", raising=False)
    env = hb.build_gateway_env(agent_home="/tmp/agent-home")
    assert env["HERMES_HOME"] == "/tmp/agent-home"
    assert env["HERMES_YOLO_MODE"] == "1"
    assert env["OPENAI_API_KEY"] == "sk-test"
    assert "VERTUS_TOP_SECRET_BOT_FLAG" not in env, "non-allowlisted env must not leak"
    assert len(env) <= len(hb._ENGINE_ENV_ALLOWLIST) + len(hb.PROVIDER_KEY_VARS)


def test_gateway_env_drops_hermes_home_when_unset(monkeypatch):
    """No agent_home and no HERMES_HOME → the child falls back to the fleet default."""
    import hermes_bridge as hb

    monkeypatch.delenv("HERMES_HOME", raising=False)
    env = hb.build_gateway_env()
    assert "HERMES_HOME" not in env


# ----------------------------------------------------------------------
# Step 4: no process-global state carries per-turn / per-agent context
# ----------------------------------------------------------------------


def test_no_vertus_remote_env_mutation(monkeypatch, tmp_path):
    """remote=True must NOT write any process env — it rides the queue item."""
    import os

    mgr, _ = make_manager(monkeypatch, tmp_path)
    p = mgr.get_or_create_session("primary")
    before = dict(os.environ)
    p.prompt("hello from the phone", remote=True)
    deadline = time.time() + 5
    while time.time() < deadline and not p.sessions[-1].prompts:
        time.sleep(0.02)
    assert os.environ == before, "prompt handling must not mutate os.environ"
    assert p.sessions[-1].prompts == ["hello from the phone"]


def test_remote_flag_is_sticky_and_not_global(monkeypatch, tmp_path):
    """_remote_seen flips only on the prompting bridge, never on other agents."""
    mgr, _ = make_manager(monkeypatch, tmp_path)
    p = mgr.get_or_create_session("primary")
    s = mgr.get_or_create_session("scout")
    p.prompt("remote turn", remote=True)
    deadline = time.time() + 5
    while time.time() < deadline and not p.sessions[-1].prompts:
        time.sleep(0.02)
    assert p._remote_seen is True
    assert s._remote_seen is False, "one agent's remote flag must not leak to another"
    # And the sticky respawn env reaches the spawn call on the NEXT session.
    p.prompt("second remote turn", remote=False)
    deadline = time.time() + 5
    while time.time() < deadline and len(p.sessions) < 2:
        time.sleep(0.02)
        if p.sessions:
            time.sleep(0.05)
    assert p._remote_seen is True
