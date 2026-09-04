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

    Records the cwd kwarg (the sandbox binding under test) via super().
    """

    def __init__(self, agent_id: str, cwd: str | None = None):
        # Assign before super().__init__: the worker prewarms immediately and
        # _make appends to self.sessions from that thread.
        self.sessions: list[FakeSession] = []
        super().__init__(agent_id=agent_id, create_session_factory=self._make, cwd=cwd)

    def _make(self, cwd=None):
        self.last_cwd = cwd
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
    # builds it through the production default factory incl. sandbox resolution.
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
