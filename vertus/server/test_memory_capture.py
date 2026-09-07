"""Automatic turn-end memory capture: burst buffering, SHARED routing,
autonomous-turn addendum, per-agent policy, AgentBridge wiring, and the
profile v5 field."""

from __future__ import annotations

import threading
import time

import pytest

import fleet_memory as fm
from agent_registry import AgentRegistry, migrate_v1_profile, SCHEMA_VERSION
from memory_capture import (MemoryCapturer, classify_fact, fork_extract_facts,
                            SHARED_PREFIX, EXTRACTION_SYSTEM_PROMPT,
                            AUTONOMOUS_EXTRACTION_ADDENDUM)


@pytest.fixture
def mem_env(monkeypatch, tmp_path):
    (tmp_path / "memory").mkdir(parents=True)
    (tmp_path / "agents").mkdir()
    (tmp_path / "hermes").mkdir()
    monkeypatch.setenv("VERTUS_MEMORY_DIR", str(tmp_path / "memory"))
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_BACKUP_DIR", str(tmp_path / "backups"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "hermes"))
    return tmp_path


def _make_capturer(tmp_path, registry, extract=None, quiet_ms=0.0,
                   max_turns=10, store=None, memory=None):
    store = store or _FakeStore()
    memory = memory or fm.MemoryStore(
        emit=None, running_agents=None, poll_s=60.0,
        index_file=tmp_path / "memory" / ".hub-index.json")
    fm.shared_dir().mkdir(parents=True, exist_ok=True)
    return MemoryCapturer(
        store_provider=lambda: store,
        memory_provider=lambda: memory,
        registry=registry,
        extract=extract,
        quiet_ms=quiet_ms,
        max_turns=max_turns,
        log=lambda *a, **k: None,
    )


class _FakeStore:
    """Minimal RunStore stand-in: folded message rows per run."""

    def __init__(self):
        self.messages: dict[str, list[dict]] = {}

    def seed(self, run_id: str, user: str = "", assistant: str = ""):
        rows = []
        if user:
            rows.append({"role": "user", "text": user})
        if assistant:
            rows.append({"role": "assistant", "text": assistant})
        self.messages[run_id] = rows

    def run_messages(self, run_id: str):
        return self.messages.get(run_id, [])


class _RecordingExtract:
    """Injected extractor: records calls, returns canned facts."""

    def __init__(self, facts):
        self.facts = facts
        self.calls: list[tuple[str, str, bool]] = []
        self.done = threading.Event()

    def __call__(self, agent_id, transcript, autonomous):
        self.calls.append((agent_id, transcript, autonomous))
        self.done.set()
        return self.facts


def _wait(event: threading.Event, timeout: float = 5.0):
    assert event.wait(timeout), "capture flush never ran"


def _wait_for(predicate, timeout: float = 5.0, what: str = "condition"):
    """Poll until ``predicate()`` is truthy — the flush runs on a background
    thread, so the extract call finishing is not the write finishing."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {what}")


# -- classification ---------------------------------------------------------

def test_classify_fact_routes_shared():
    assert classify_fact(f"  {SHARED_PREFIX} always use pnpm") == ("always use pnpm", True)
    assert classify_fact("owns billing") == ("owns billing", False)


def test_extraction_prompts_include_autonomous_addendum():
    assert "autonomous" in AUTONOMOUS_EXTRACTION_ADDENDUM.lower()
    assert "FLEET-WIDE" in EXTRACTION_SYSTEM_PROMPT.upper()


# -- capture flow -----------------------------------------------------------

def test_capture_routes_shared_and_private(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("Scout")
    extract = _RecordingExtract([f"{SHARED_PREFIX} always use pnpm", "owns billing"])
    store = _FakeStore()
    store.seed("r1", user="hi", assistant="hello")
    capturer = _make_capturer(tmp_path, registry, extract=extract, store=store)
    capturer.on_run_done("r1", agent["id"], None, None, "user", "done")
    _wait(extract.done)

    def _agent_facts():
        return capturer._memory().read("agent", agent["id"], fm.FACTS_FILE)

    _wait_for(lambda: _agent_facts() is not None, what="agent facts file")
    agent_facts = _agent_facts().decode()
    shared_facts = capturer._memory().read("shared", None, fm.FACTS_FILE).decode()
    assert "owns billing" in agent_facts
    assert SHARED_PREFIX not in agent_facts
    assert "always use pnpm" in shared_facts
    assert SHARED_PREFIX not in shared_facts
    # Transcript carries the folded user/assistant pair.
    agent_id, transcript, autonomous = extract.calls[0]
    assert agent_id == agent["id"]
    assert "User said:\nhi" in transcript
    assert "Assistant replied:\nhello" in transcript
    assert autonomous is False


def test_autonomous_runs_use_addendum(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("RoutineBot")
    extract = _RecordingExtract(["state: deployed"])
    store = _FakeStore()
    store.seed("r2", user="tick", assistant="done")
    capturer = _make_capturer(tmp_path, registry, extract=extract, store=store)
    capturer.on_run_done("r2", agent["id"], None, None, "routine", "done")
    _wait(extract.done)
    assert extract.calls[0][2] is True  # autonomous
    # A bot-message run is autonomous too (from_agent set).
    store.seed("r3", user="delegate", assistant="ok")
    capturer.on_run_done("r3", agent["id"], "primary", "t1", "message", "done")
    _wait_for(lambda: len(extract.calls) >= 2, what="second extraction")
    assert extract.calls[1][2] is True


def test_non_done_runs_never_capture(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("ErrBot")
    extract = _RecordingExtract(["fact"])
    store = _FakeStore()
    store.seed("r4", user="x", assistant="y")
    capturer = _make_capturer(tmp_path, registry, extract=extract, store=store)
    for state in ("error", "cancelled", "timeout", "interrupted"):
        capturer.on_run_done("r4", agent["id"], None, None, "user", state)
    assert extract.calls == []


def test_capture_respects_profile_off(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("MuteBot", memory_capture="off")
    extract = _RecordingExtract(["fact"])
    store = _FakeStore()
    store.seed("r5", user="x", assistant="y")
    capturer = _make_capturer(tmp_path, registry, extract=extract, store=store)
    capturer.on_run_done("r5", agent["id"], None, None, "user", "done")
    assert extract.calls == []


def test_capture_global_kill_switch(mem_env, tmp_path, monkeypatch):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("GlobalBot")
    extract = _RecordingExtract(["fact"])
    store = _FakeStore()
    store.seed("r7", user="x", assistant="y")
    capturer = _make_capturer(tmp_path, registry, extract=extract, store=store)
    monkeypatch.setenv("VERTUS_MEMORY_CAPTURE", "0")
    capturer.on_run_done("r7", agent["id"], None, None, "user", "done")
    assert extract.calls == []


def test_burst_max_turns_flushes_immediately(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("BurstBot")
    extract = _RecordingExtract(["fact"])
    store = _FakeStore()
    store.seed("r1", user="a", assistant="1")
    store.seed("r2", user="b", assistant="2")
    capturer = _make_capturer(tmp_path, registry, extract=extract, store=store,
                              quiet_ms=60_000, max_turns=2)
    capturer.on_run_done("r1", agent["id"], None, None, "user", "done")
    assert extract.calls == []  # buffered, timer pending
    capturer.on_run_done("r2", agent["id"], None, None, "user", "done")
    _wait(extract.done)
    # Both runs folded into ONE extraction call, in order.
    assert len(extract.calls) == 1
    assert "User said:\na" in extract.calls[0][1]
    assert "User said:\nb" in extract.calls[0][1]


def test_burst_quiet_timer_flushes(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("TimerBot")
    extract = _RecordingExtract(["fact"])
    store = _FakeStore()
    store.seed("r1", user="a", assistant="1")
    capturer = _make_capturer(tmp_path, registry, extract=extract, store=store,
                              quiet_ms=50)
    capturer.on_run_done("r1", agent["id"], None, None, "user", "done")
    _wait(extract.done, timeout=5.0)


def test_capture_failure_is_best_effort(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("BoomBot")
    store = _FakeStore()
    store.seed("r1", user="a", assistant="1")

    def boom(agent_id, transcript, autonomous):
        raise RuntimeError("provider down")

    capturer = _make_capturer(tmp_path, registry, extract=boom, store=store)
    capturer.on_run_done("r1", agent["id"], None, None, "user", "done")
    time.sleep(0.1)  # flush runs on a background thread; must not raise
    assert capturer._memory().read("agent", agent["id"], fm.FACTS_FILE) is None


def test_empty_messages_never_extract(mem_env, tmp_path):
    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("EmptyBot")
    extract = _RecordingExtract(["fact"])
    capturer = _make_capturer(tmp_path, registry, extract=extract,
                              store=_FakeStore())
    capturer.on_run_done("r1", agent["id"], None, None, "user", "done")
    time.sleep(0.1)
    assert extract.calls == []


# -- fork extractor (no subprocess: no model/provider → []) ------------------

def test_fork_extract_without_model_returns_empty(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / "config.yaml").write_text("model: {}\n", encoding="utf-8")
    assert fork_extract_facts(home, "transcript", False) == []
    assert fork_extract_facts(home, "transcript", True) == []


# -- AgentBridge wiring ------------------------------------------------------

class ReplySession:
    """Engine-session stand-in: one text delta per prompt, then turn end."""

    def __init__(self, bridge):
        self.bridge = bridge

    def subscribe(self, listener) -> None:
        pass

    def prompt(self, text: str) -> None:
        self.bridge._on_pi_event({"type": "text", "text": f"reply:{text}"})

    def active_list(self, timeout: float = 5.0) -> dict:
        return {"sessions": []}

    def interrupt(self) -> None:
        pass

    def terminate_process(self) -> None:
        pass

    def kill_process(self) -> None:
        pass

    def close(self) -> None:
        pass


def test_agent_bridge_fires_on_run_done(mem_env, tmp_path):
    """A completed run on a real AgentBridge (fake engine) reaches the
    capturer hook with the run's terminal state — user and bot runs alike."""
    import vertus_server as vs
    from run_store import RunStore

    registry = AgentRegistry(root=tmp_path / "agents")
    agent = registry.create_agent("WiredBot")
    store = RunStore(tmp_path / "fleet.db")
    done: list[tuple] = []

    def on_done(run_id, agent_id, from_agent, thread_id, run_kind, state):
        done.append((run_id, agent_id, from_agent, thread_id, run_kind, state))

    # The factory closes over a holder so the fake session can reach back
    # into the bridge (same pattern as test_fleet_supervision).
    holder: dict = {}

    def factory(cwd=None, **kwargs):
        return {"session": ReplySession(holder["bridge"])}

    bridge = vs.AgentBridge(
        agent_id=agent["id"],
        create_session_factory=factory,
        cwd=None,
        store=store,
        on_run_done=on_done,
    )
    holder["bridge"] = bridge
    run_id = store.create_run(agent["id"], "hello", False)
    bridge.prompt("hello", remote=False, run_id=run_id)
    deadline = time.time() + 5.0
    while time.time() < deadline and not done:
        time.sleep(0.02)
    assert done, "on_run_done never fired"
    assert done[0][0] == run_id
    assert done[0][1] == agent["id"]
    assert done[0][2] is None
    assert done[0][4] == "user"
    assert done[0][5] == "done"
    bridge.close()


# -- profile v5 --------------------------------------------------------------

def test_profile_v4_migrates_to_v5_with_capture_default():
    v4 = {"id": "old", "name": "Old", "schema_version": 4}
    upgraded, changed = migrate_v1_profile(v4, persona_backfill="")
    assert changed
    assert upgraded["schema_version"] == 5
    assert upgraded["memory_capture"] == "automatic"


def test_profile_v5_validation(mem_env):
    from agent_registry import AgentRegistry
    registry = AgentRegistry(root=mem_env / "agents")
    agent = registry.create_agent("ValBot")
    assert agent["memory_capture"] == "automatic"
    with pytest.raises(ValueError):
        registry.update_agent(agent["id"], memory_capture="sometimes")
    updated = registry.update_agent(agent["id"], memory_capture="off")
    assert updated["memory_capture"] == "off"
    cleared = registry.update_agent(agent["id"], memory_capture=None)
    assert cleared["memory_capture"] == "automatic"


def test_http_payload_validation_rejects_bad_capture(mem_env, tmp_path):
    from vertus_server import _validate_profile_payload
    with pytest.raises(ValueError):
        _validate_profile_payload({"memory_capture": "sometimes"},
                                  allow_name=False)
    assert _validate_profile_payload({"memory_capture": "off"},
                                     allow_name=False)["memory_capture"] == "off"
    assert SCHEMA_VERSION == 5