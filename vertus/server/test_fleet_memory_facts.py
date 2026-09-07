"""Automatic capture + recall digest (qm-style): fold_facts semantics,
facts.md capture through MemoryStore, and the hub-generated digest."""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

import fleet_memory as fm


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


def _make_store(tmp_path, emit=None, debounce: float = 0.05):
    store = fm.MemoryStore(emit=emit, running_agents=None, poll_s=60.0,
                           index_file=tmp_path / "memory" / ".hub-index.json",
                           digest_debounce_s=debounce)
    fm.shared_dir().mkdir(parents=True, exist_ok=True)
    return store


# -- fold_facts -------------------------------------------------------------

def test_fold_facts_dedupes_and_dates():
    existing, added = fm.fold_facts("", ["  prefers pnpm  ", "* uses vim"], 1_700_000_000)
    assert added == 2
    assert "- (2023-11-14) prefers pnpm" in existing
    assert "- (2023-11-14) uses vim" in existing
    assert existing.startswith(fm.FACTS_HEADER)


def test_fold_facts_dedupe_against_existing_bullets():
    existing = "# Facts\n\n- (2023-11-14) prefers pnpm\n"
    body, added = fm.fold_facts(existing, ["Prefers pnpm", "Prefers pnpm "], 1_700_000_000)
    assert added == 0
    assert body == existing


def test_fold_facts_strips_incoming_dates_and_bullets():
    existing, added = fm.fold_facts("", ["- (2020-01-01) already dated", "(2021-02-02) parens"], 1_700_000_000)
    assert added == 2
    # The incoming date is not double-stamped: normalize strips it and the
    # fold re-stamps with the capture date.
    assert "- (2023-11-14) already dated" in existing
    assert "- (2023-11-14) parens" in existing
    assert "(2020-01-01)" not in existing


def test_fold_facts_caps_at_max_facts_dropping_oldest():
    body = ""
    for i in range(fm.MAX_FACTS + 5):
        body, added = fm.fold_facts(body, [f"fact number {i}"], 1_700_000_000)
        assert added == 1
    bullets = [l for l in body.split("\n") if l.strip().startswith("- ")]
    assert len(bullets) == fm.MAX_FACTS
    # Oldest five dropped: the earliest surviving fact is #5.
    assert "- (2023-11-14) fact number 0" not in body
    assert "- (2023-11-14) fact number 5" in body
    assert "- (2023-11-14) fact number 299" in body


def test_fold_facts_handles_garbage_lines():
    body = "# Facts\n\nsome prose, not a bullet\n\n- (2023-11-14) a fact\n"
    out, added = fm.fold_facts(body, ["new fact"], 1_700_000_000)
    assert added == 1
    # Prose is preserved; the bullet count for the cap counts bullets only.
    assert "some prose, not a bullet" in out
    assert "- (2023-11-14) new fact" in out


def test_parse_facts_text():
    assert fm.parse_facts_text("NONE") == []
    assert fm.parse_facts_text("none") == []
    assert fm.parse_facts_text("") == []
    assert fm.parse_facts_text("- one\n* two\nprose") == ["one", "two"]


# -- capture_facts through MemoryStore --------------------------------------

def test_capture_facts_writes_indexes_and_broadcasts(mem_env, tmp_path):
    events = []
    store = _make_store(tmp_path, emit=lambda aid, e: events.append(e))
    added = store.capture_facts("agent", "alpha", ["Prefers pnpm", "Owns billing"], writer="alpha")
    assert added == 2
    body = store.read("agent", "alpha", fm.FACTS_FILE).decode()
    assert "- (" in body and "prefers pnpm" in body.lower()
    # Indexed and broadcast with writer attribution.
    entry = store.list_entries("agent", agent_id="alpha")[0]
    assert entry["path"] == fm.FACTS_FILE
    assert entry["writer"] == "alpha"
    assert events[-1]["type"] == "memory_changed"
    assert events[-1]["writer"] == "alpha"
    # Duplicates (case-insensitively) add nothing and don't rewrite.
    before = store.read("agent", "alpha", fm.FACTS_FILE)
    assert store.capture_facts("agent", "alpha", ["PREFERS PNPM"],
                               writer="alpha") == 0
    assert store.read("agent", "alpha", fm.FACTS_FILE) == before


def test_capture_facts_shared_scope(mem_env, tmp_path):
    store = _make_store(tmp_path)
    store.capture_facts("shared", None, ["SHARED fact"], writer="beta")
    body = store.read("shared", None, fm.FACTS_FILE).decode()
    assert "SHARED fact" in body


# -- recall digest -----------------------------------------------------------

def _seed_agent(tmp_path, agent_id="alpha"):
    agent_mem = tmp_path / "agents" / agent_id / "memory"
    agent_mem.mkdir(parents=True)
    (tmp_path / "agents" / agent_id / "home").mkdir(parents=True)
    (agent_mem / fm.FACTS_FILE).write_text(
        "# Facts\n\n- (2023-11-14) prefers pnpm\n- (2023-11-14) owns billing\n",
        encoding="utf-8")
    (agent_mem / "profile.md").write_text("the user is Carlton", encoding="utf-8")
    notes = agent_mem / "notes"
    notes.mkdir(parents=True)
    (notes / "2023-11-14-deploy.md").write_text("deploy notes", encoding="utf-8")
    shared = tmp_path / "memory" / "shared"
    shared.mkdir(parents=True)
    (shared / fm.FACTS_FILE).write_text(
        "# Facts\n\n- (2023-11-14) fleet-wide fact\n", encoding="utf-8")
    return agent_mem, shared


def test_build_digest_sections_and_order(mem_env, tmp_path):
    _seed_agent(tmp_path)
    store = _make_store(tmp_path)
    digest = store.build_digest("alpha")
    assert digest.startswith("# Memory digest for alpha")
    # Facts first (most important), then fleet facts, profile, notes.
    assert digest.index("## Your facts") < digest.index("## Fleet facts")
    assert digest.index("## Fleet facts") < digest.index("## Profile")
    assert digest.index("## Profile") < digest.index("## Recent notes")
    assert "prefers pnpm" in digest
    assert "fleet-wide fact" in digest
    assert "the user is Carlton" in digest
    assert "deploy notes" in digest


def test_build_digest_respects_cap_dropping_trailing_sections(mem_env, tmp_path):
    _seed_agent(tmp_path)
    store = _make_store(tmp_path)
    digest = store.build_digest("alpha", max_chars=120)
    assert len(digest) <= 120
    # The header and the first section survive; trailing sections were cut.
    assert digest.startswith("# Memory digest for alpha")
    assert "prefers pnpm" in digest


def test_refresh_digest_writes_home_file(mem_env, tmp_path):
    _seed_agent(tmp_path)
    store = _make_store(tmp_path)
    path = store.refresh_digest("alpha")
    assert path == tmp_path / "agents" / "alpha" / "home" / fm.DIGEST_FILE
    assert path.is_file()
    assert "prefers pnpm" in path.read_text(encoding="utf-8")


def test_capture_schedules_digest_refresh(mem_env, tmp_path):
    """A capture writes canonical facts.md AND (debounced) refreshes the
    agent's home digest — the recall side stays fresh automatically."""
    _seed_agent(tmp_path)
    store = _make_store(tmp_path, emit=lambda aid, e: None)
    store.capture_facts("agent", "alpha", ["brand new fact"], writer="alpha")
    deadline = time.time() + 2.0
    digest_path = tmp_path / "agents" / "alpha" / "home" / fm.DIGEST_FILE
    while time.time() < deadline:
        if digest_path.is_file() and "brand new fact" in digest_path.read_text(
                encoding="utf-8"):
            break
        time.sleep(0.02)
    assert digest_path.is_file()
    assert "brand new fact" in digest_path.read_text(encoding="utf-8")