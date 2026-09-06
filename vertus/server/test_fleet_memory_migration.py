"""Checkpoint 1: legacy memory migration tests.

The migration runs against a COPY of the real tree, never the real tree
(this suite's env points every path at tmp_path). Assertions: byte-for-byte
preservation, backup archive correctness, symlink replacement, idempotency,
and conflict refusal.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
from pathlib import Path

import pytest

import fleet_memory as fm


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@pytest.fixture
def legacy_tree(monkeypatch, tmp_path):
    """A faithful copy of the real pre-fleet memory layout."""
    memory = tmp_path / "memory"
    (memory / "notes").mkdir(parents=True)
    (memory / "profile.md").write_text("# profile\nName: Carlton King\n", encoding="utf-8")
    (memory / "schedule.md").write_text("# schedule\nSleep 22:00-06:00\n", encoding="utf-8")
    (memory / "notes" / "default_calendar_instruction.md").write_text(
        "Default calendar: VERTUS calendar.\n", encoding="utf-8")
    (memory / "index.json").write_text('{"topics": {}}', encoding="utf-8")
    hermes = tmp_path / "hermes"
    (hermes / "memories").mkdir(parents=True)
    (hermes / "memories" / "USER.md").write_text(
        "User preference: Only ask permission before rm.\n", encoding="utf-8")
    (hermes / "memories" / "MEMORY.md").write_text("# comms\n", encoding="utf-8")
    (tmp_path / "agents").mkdir()

    monkeypatch.setenv("VERTUS_MEMORY_DIR", str(memory))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(hermes))
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_BACKUP_DIR", str(tmp_path / "backups"))
    return tmp_path


def _originals(tree: Path) -> dict[str, bytes]:
    memory = tree / "memory"
    return {
        "profile.md": (memory / "profile.md").read_bytes(),
        "schedule.md": (memory / "schedule.md").read_bytes(),
        "notes/default_calendar_instruction.md": (
            memory / "notes" / "default_calendar_instruction.md").read_bytes(),
        "index.json": (memory / "index.json").read_bytes(),
        "hermes/USER.md": (tree / "hermes" / "memories" / "USER.md").read_bytes(),
    }


def test_migration_preserves_bytes_and_backs_up(legacy_tree, tmp_path):
    before = _originals(legacy_tree)
    report = fm.migrate_legacy_memory()

    assert report["skipped"] is False
    backup = Path(report["backup_path"])
    assert backup.is_dir()
    # Backup is byte-identical, including the source of every entry.
    assert (backup / "vertus-memory" / "profile.md").read_bytes() == before["profile.md"]
    assert (backup / "vertus-memory" / "notes" / "default_calendar_instruction.md").read_bytes() \
        == before["notes/default_calendar_instruction.md"]
    assert (backup / "hermes-memories" / "USER.md").read_bytes() == before["hermes/USER.md"]

    # Canonical copies are byte-identical to the originals.
    shared = legacy_tree / "memory" / "shared"
    for rel, data in before.items():
        if rel.startswith("hermes/"):
            continue
        assert (shared / rel).read_bytes() == data, rel
    assert (shared / "USER.md").read_bytes() == before["hermes/USER.md"]

    # Legacy paths are now symlinks into canonical.
    for name in ("profile.md", "schedule.md", "notes", "index.json"):
        p = legacy_tree / "memory" / name
        assert p.is_symlink(), name
        assert (legacy_tree / "memory" / "shared" / name).exists()

    # The seed copy leaves the fork's own file in place.
    assert (legacy_tree / "hermes" / "memories" / "USER.md").is_file()
    assert not (legacy_tree / "hermes" / "memories" / "USER.md").is_symlink()


def test_migration_idempotent_second_run_skips(legacy_tree):
    first = fm.migrate_legacy_memory()
    second = fm.migrate_legacy_memory()
    assert second["skipped"] is True
    # Content untouched by the second run.
    assert (legacy_tree / "memory" / "shared" / "profile.md").read_bytes() \
        == b"# profile\nName: Carlton King\n"
    assert first["backup_path"]  # first run created the archive


def test_migration_refuses_conflict(legacy_tree):
    shared = legacy_tree / "memory" / "shared"
    shared.mkdir(parents=True)
    (shared / "profile.md").write_text("DIFFERENT content that must survive\n", encoding="utf-8")
    report = fm.migrate_legacy_memory()
    assert report["entries"]["profile.md"] == "conflict"
    # The conflicting target is untouched; the original legacy file too.
    assert (shared / "profile.md").read_bytes() == b"DIFFERENT content that must survive\n"
    assert (legacy_tree / "memory" / "profile.md").read_bytes() == b"# profile\nName: Carlton King\n"
    # Other entries still migrate.
    assert report["entries"]["schedule.md"] == "migrated"


def test_migration_marker_records_manifest(legacy_tree):
    fm.migrate_legacy_memory()
    marker = legacy_tree / "memory" / ".migrated_v1"
    assert marker.is_file()
    data = json.loads(marker.read_text())
    assert data["backup"].startswith(str(legacy_tree / "backups"))
    assert data["report"]["entries"]["profile.md"] == "migrated"


def test_migration_skips_missing_entries(monkeypatch, tmp_path):
    memory = tmp_path / "memory"
    memory.mkdir(parents=True)
    monkeypatch.setenv("VERTUS_MEMORY_DIR", str(memory))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "hermes"))
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_BACKUP_DIR", str(tmp_path / "backups"))
    (tmp_path / "agents").mkdir()
    report = fm.migrate_legacy_memory()
    assert report["entries"]["profile.md"] == "missing"
    assert report["backup_path"]