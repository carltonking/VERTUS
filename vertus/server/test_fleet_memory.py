"""Checkpoint 2: canonical store, fork mirror, hub index, concurrency.

Covers: atomic hub writes never interleave, the one-way home/memories
mirror propagates fork writes into canonical, re-materialization never
clobbers fork memory, conflicts are staged not destroyed, attribution,
search, and index persistence.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

import pytest

import fleet_memory as fm
from agent_registry import AgentRegistry


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


def _make_store(tmp_path, emit=None, running=None, start=False):
    store = fm.MemoryStore(emit=emit, running_agents=running, poll_s=0.05,
                           index_file=tmp_path / "memory" / ".hub-index.json")
    if start:
        store.start()
    else:
        # start() is what ensures the canonical dirs; the manual-poll tests
        # need them too.
        fm.shared_dir().mkdir(parents=True, exist_ok=True)
    return store


def test_write_read_delete_and_index(mem_env, tmp_path):
    events = []
    store = _make_store(tmp_path, emit=lambda aid, e: events.append(e),
                        start=True)
    meta = store.write("shared", None, "profile.md", b"hello memory")
    assert store.read("shared", None, "profile.md") == b"hello memory"
    assert meta["sha"]
    entries = store.list_entries("shared")
    assert entries and entries[0]["path"] == "profile.md"
    assert entries[0]["writer"] == "human"
    assert store.search("memory")[0]["path"] == "profile.md"
    # write-through event, writer attributed
    assert events and events[-1]["type"] == "memory_changed"
    assert events[-1]["action"] == "created"
    assert store.delete("shared", None, "profile.md")
    assert store.read("shared", None, "profile.md") is None
    assert events[-1]["action"] == "deleted"
    store.stop()


def test_concurrent_hub_writes_never_interleave(mem_env, tmp_path):
    store = _make_store(tmp_path, start=True)
    a = b"x" * 4000
    b_content = b"y" * 4000

    def writer_a():
        for _ in range(40):
            store.write("shared", None, "race.md", a)

    def writer_b():
        for _ in range(40):
            store.write("shared", None, "race.md", b_content)

    t1 = threading.Thread(target=writer_a)
    t2 = threading.Thread(target=writer_b)
    t1.start(); t2.start(); t1.join(); t2.join()
    final = store.read("shared", None, "race.md")
    assert final == a or final == b_content, "interleaved or truncated write"
    store.stop()


def test_fork_mirror_propagates_one_way(mem_env, tmp_path):
    # Manual polls only (no background thread): deterministic.
    events = []
    store = _make_store(tmp_path, emit=lambda aid, e: events.append(e))
    home_mem = tmp_path / "agents" / "alpha" / "home" / "memories"
    home_mem.mkdir(parents=True)
    fork_content = b"# USER\nPrefer pnpm.\n"
    (home_mem / "USER.md").write_bytes(fork_content)
    store.poll_once()
    canonical = tmp_path / "agents" / "alpha" / "memory" / "USER.md"
    assert canonical.read_bytes() == fork_content
    assert store.read("agent", "alpha", "USER.md") == fork_content
    assert any(e["writer"] == "alpha" for e in events)
    # Second poll: no duplicate events (unchanged).
    events.clear()
    store.poll_once()
    assert events == []
    store.stop()


def test_rematerialization_never_clobbers_fork_memory(mem_env, tmp_path):
    registry = AgentRegistry()
    agent = registry.create_agent("alpha", persona="You are Alpha.")
    home_mem = tmp_path / "agents" / "alpha" / "home" / "memories"
    home_mem.mkdir(parents=True, exist_ok=True)
    fork_content = b"FORK OWNED: do not touch\n"
    (home_mem / "MEMORY.md").write_bytes(fork_content)
    # A profile update re-materializes the whole home.
    registry.update_agent(agent["id"], title="Renamed")
    assert (home_mem / "MEMORY.md").read_bytes() == fork_content
    # Canonical dirs exist after materialize (primary too via ensure_primary).
    assert (tmp_path / "agents" / "alpha" / "memory").is_dir()


def test_skill_injection_follows_memory_dir_env(mem_env, tmp_path):
    """Regression: the materialized memory skill must point at the env-
    configured memory root, never the real ~/.vertus. A hub with only
    VERTUS_MEMORY_DIR set used to materialize skills pointing at the real
    shared memory (agent_registry fell back to a hardcoded path while
    fleet_memory honored the env), which sent demo agents at the user's
    actual profile.md."""
    # mem_env sets VERTUS_MEMORY_DIR but deliberately NOT
    # VERTUS_SHARED_MEMORY_DIR: the fallback is what's under test.
    registry = AgentRegistry()
    agent = registry.create_agent("alpha", persona="You are Alpha.")
    skill = tmp_path / "agents" / "alpha" / "home" / "skills" / "vertus-memory" / "SKILL.md"
    assert skill.is_file()
    text = skill.read_text()
    assert str(tmp_path / "memory" / "shared") in text
    assert str(Path.home() / ".vertus" / "memory" / "shared") not in text
    # And the two modules must agree with each other.
    import agent_registry

    assert str(agent_registry.AgentRegistry().shared_memory_dir()) == \
        str(fm.shared_dir())


def test_mirror_conflict_is_staged_not_destroyed(mem_env, tmp_path):
    store = _make_store(tmp_path, start=True)
    home_mem = tmp_path / "agents" / "alpha" / "home" / "memories"
    home_mem.mkdir(parents=True)
    (home_mem / "USER.md").write_bytes(b"fork v1")
    time.sleep(0.05)
    store.poll_once()
    # Human edits canonical after the mirror saw it.
    store.write("agent", "alpha", "USER.md", b"human edit v2")
    # Fork rewrites its file.
    (home_mem / "USER.md").write_bytes(b"fork v3")
    time.sleep(0.05)
    store.poll_once()
    canonical = tmp_path / "agents" / "alpha" / "memory" / "USER.md"
    assert canonical.read_bytes() == b"human edit v2", "canonical was destroyed"
    conflicts = list((tmp_path / "agents" / "alpha" / "memory").glob("USER.md.conflict-*"))
    assert conflicts, "fork version was dropped silently"
    assert conflicts[0].read_bytes() == b"fork v3"
    store.stop()


def test_writer_attribution(mem_env, tmp_path):
    # No background thread: deterministic manual polls.
    store = _make_store(tmp_path, running=lambda: {"alpha"})
    (fm.shared_dir() / "note.md").write_bytes(b"fleet fact")
    emitted = store.poll_once()
    created = [e for e in emitted if e["path"] == "note.md"][0]
    assert created["writer"] == "alpha"
    # No agent running -> external.
    store._running_agents = lambda: set()
    (fm.shared_dir() / "note2.md").write_bytes(b"another")
    emitted = store.poll_once()
    ext = [e for e in emitted if e["path"] == "note2.md"][0]
    assert ext["writer"] == "external"
    store.stop()


def test_index_persists_across_instances(mem_env, tmp_path):
    store = _make_store(tmp_path, start=True)
    store.write("shared", None, "persist.md", b"durable")
    store.stop()
    store2 = _make_store(tmp_path, start=True)
    assert store2.read("shared", None, "persist.md") == b"durable"
    entries = store2.list_entries("shared")
    assert any(e["path"] == "persist.md" for e in entries)
    store2.stop()


def test_search_snippet_and_scopes(mem_env, tmp_path):
    store = _make_store(tmp_path, start=True)
    store.write("shared", None, "prefs.md", b"always use pnpm\n")
    store.write("agent", "alpha", "notes.md", b"pnpm workspace fix\n")
    hits = store.search("pnpm")
    assert len(hits) == 2
    assert "pnpm" in hits[0]["snippet"].lower()
    assert store.list_entries("shared")[0]["scope"] == "shared"
    assert store.list_entries("agent", agent_id="alpha")[0]["agent_id"] == "alpha"
    store.stop()


def test_relpath_escape_rejected(mem_env):
    for bad in ("../x", "a/../../b", "/etc/passwd", "..", ""):
        with pytest.raises(ValueError):
            fm._safe_relpath(bad)
    assert fm._safe_relpath("notes/2026-09-05-foo.md") == "notes/2026-09-05-foo.md"