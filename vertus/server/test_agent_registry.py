"""Unit tests for the durable agent registry.

Run from the repo root:
    python3 -m pytest vertus/server/test_agent_registry.py -v

Every test points VERTUS_AGENTS_DIR at a throwaway temp dir, so the real
~/.vertus/agents store is never touched.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agent_registry import AgentRegistry  # noqa: E402


@pytest.fixture()
def registry(tmp_path, monkeypatch) -> AgentRegistry:
    """Registry rooted at a fresh temp dir (env override, not ~/.vertus)."""
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    return AgentRegistry()


def test_ensure_primary_creates_primary_once(registry: AgentRegistry):
    first = registry.ensure_primary()
    assert first["id"] == "primary"
    assert first["name"] == "Primary"
    assert first["is_primary"] is True
    # Idempotent: second call returns the same agent, not a duplicate.
    again = registry.ensure_primary()
    assert again["id"] == "primary"
    assert len(registry.list_agents()) == 1


def test_create_agent_and_sandbox_exists(registry: AgentRegistry):
    agent = registry.create_agent("Research Bot")
    assert agent["id"].startswith("research-bot")
    agent_dir = Path(agent["sandbox_path"]).parent
    assert agent_dir == registry.root / agent["id"]
    assert Path(agent["sandbox_path"]).is_dir(), "sandbox/ must exist on disk"
    profile = json.loads((agent_dir / "profile.json").read_text())
    assert profile["id"] == agent["id"]
    assert profile["name"] == "Research Bot"
    assert profile["created_at"]
    assert profile["sandbox_path"] == str(agent_dir / "sandbox")


def test_list_agents_sorted_with_primary_flag(registry: AgentRegistry):
    registry.ensure_primary()
    registry.create_agent("Zeta")
    agents = registry.list_agents()
    assert [a["id"] for a in agents] == ["primary", "zeta"]  # oldest first
    assert [a["is_primary"] for a in agents] == [True, False]


def test_get_agent(registry: AgentRegistry):
    created = registry.create_agent("Scout")
    fetched = registry.get_agent(created["id"])
    assert fetched["name"] == "Scout"
    assert fetched["sandbox_path"] == created["sandbox_path"]
    with pytest.raises(KeyError):
        registry.get_agent("does-not-exist")
    with pytest.raises(KeyError):
        registry.get_agent("../escape")  # path traversal rejected


def test_rename_agent_keeps_id_and_sandbox(registry: AgentRegistry):
    created = registry.create_agent("Scout")
    renamed = registry.rename_agent(created["id"], "Scout Prime")
    assert renamed["name"] == "Scout Prime"
    assert renamed["id"] == created["id"]  # id/dir never change on rename
    assert Path(created["sandbox_path"]).is_dir()
    assert registry.get_agent(created["id"])["name"] == "Scout Prime"
    with pytest.raises(ValueError):
        registry.rename_agent(created["id"], "   ")


def test_delete_agent_guards_and_primary_reassignment(registry: AgentRegistry):
    registry.ensure_primary()
    other = registry.create_agent("Second")
    # Deleting primary reassigns primary to the remaining agent.
    registry.delete_agent("primary")
    remaining = registry.get_agent(other["id"])
    assert remaining["is_primary"] is True
    assert registry.ensure_primary()["id"] == other["id"]
    # Deleted directory is gone from disk.
    assert not (registry.root / "primary").exists()
    # Now "second" is the last remaining agent — undeletable.
    with pytest.raises(ValueError):
        registry.delete_agent(other["id"])
    with pytest.raises(KeyError):
        registry.delete_agent("primary")  # already gone
