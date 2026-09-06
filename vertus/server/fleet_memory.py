"""Hub-owned fleet memory: canonical store, fork mirror, hub index.

Memory is the model's interface — the model reads and writes FILES by tool
call, and that never changes. What changes here is ownership: the hub owns
the canonical locations, mirrors the fork's own memory files into them,
indexes everything, and broadcasts every change on the fleet stream.

Canonical layout (single source of truth):

    ~/.vertus/memory/shared/              fleet-wide, every agent reads/writes
    ~/.vertus/agents/<id>/memory/         private to that agent

The agent's engine home (``HERMES_HOME``) carries a FORK-OWNED mirror:

    ~/.vertus/agents/<id>/home/memories/  {USER.md, MEMORY.md}

MIRROR SYNC RULE (one sentence, also in the report): the fork's two files
are input, never output — home/memories -> canonical agent memory, one-way,
on every detected change, and the materializer never writes, deletes, or
overwrites anything under home/memories, so a fork write always survives.

Why one-way: the fork's memory_tool read-modify-writes its own two files
under fcntl locks, so pushing canonical edits back into the fork's files
would create a write war (hub rewrite -> fork detects drift -> rewrite) with
no winner. The skill and the API direct the model at the canonical dirs, so
the fork's files are a legacy/auxiliary input channel that enriches
canonical, never a second source.

Concurrency (cannot silently lose a write): every hub-initiated write goes
through a per-file fcntl advisory lock plus temp-file + os.replace, so two
hub writers can never interleave or truncate each other. When the watcher
sees a fork/home file change whose canonical target ALSO changed since the
last observation, it stages the incoming content as ``<name>.conflict-<ts>``
next to the target instead of overwriting — a write is never dropped
silently. The one race outside hub control: two MODELS writing the same
shared file through their file tools in the same instant; no hub can wrap
the fork's tool calls, so the skill carries a read-before-write discipline
note and the hub records both sides when it can see them.

Change detection: a poll thread (2s) compares (mtime, size, sha256) against
the hub-maintained index; hub-initiated writes are write-through (indexed
and emitted immediately). The model never maintains index.json by hand —
that expectation is deleted from the skill.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import threading
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths (env-overridable so tests can point the whole module at a temp tree)
# ---------------------------------------------------------------------------


def memory_root() -> Path:
    env = os.environ.get("VERTUS_MEMORY_DIR", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".vertus" / "memory"


def shared_dir() -> Path:
    env = os.environ.get("VERTUS_SHARED_MEMORY_DIR", "").strip()
    return Path(env).expanduser() if env else memory_root() / "shared"


def agents_dir() -> Path:
    env = os.environ.get("VERTUS_AGENTS_DIR", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".vertus" / "agents"


def agent_memory_dir(agent_id: str) -> Path:
    return agents_dir() / agent_id / "memory"


def agent_home_memories_dir(agent_id: str) -> Path:
    """The FORK-owned engine memory dir inside the agent's HERMES_HOME."""
    return agents_dir() / agent_id / "home" / "memories"


def fleet_hermes_home() -> Path:
    """The fleet default engine config root (~/.hermes). Its memories/ dir is
    OUTSIDE mirror scope: no fleet gateway ever uses it as HERMES_HOME (every
    gateway gets a per-agent home); only the legacy CLI touches it."""
    env = os.environ.get("VERTUS_FLEET_HERMES_HOME", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".hermes"


def backups_dir() -> Path:
    env = os.environ.get("VERTUS_BACKUP_DIR", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".vertus" / "backups"


def index_path() -> Path:
    """Hub-owned memory index (a dotfile, never a model-visible entry)."""
    return memory_root() / ".hub-index.json"


# Legacy locations that predate the fleet (Checkpoint 1 migration).
_LEGACY_ENTRIES = ("profile.md", "schedule.md", "notes", "index.json")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _files_identical(a: Path, b: Path) -> bool:
    """Byte-identical for files; recursively identical for directories."""
    if a.is_file() and b.is_file():
        return _sha256(a) == _sha256(b)
    if a.is_dir() and b.is_dir():
        rels_a = sorted(str(p.relative_to(a)) for p in a.rglob("*") if p.is_file())
        rels_b = sorted(str(p.relative_to(b)) for p in b.rglob("*") if p.is_file())
        if rels_a != rels_b:
            return False
        return all(_sha256(a / r) == _sha256(b / r) for r in rels_a)
    return False


def _safe_relpath(rel: str) -> str:
    """Normalize and reject any path escaping the memory root."""
    rel = rel.replace("\\", "/").strip("/")
    if not rel or rel in (".", "..") or rel.startswith("../") or ".." in rel.split("/"):
        raise ValueError(f"invalid memory path: {rel!r}")
    return rel


# ---------------------------------------------------------------------------
# Checkpoint 1: one-time migration of the legacy single-agent memory
# ---------------------------------------------------------------------------

_MIGRATION_MARKER = ".migrated_v1"


def migrate_legacy_memory() -> dict:
    """Back up and fold the legacy pre-fleet memory into the canonical store.

    - backs up ~/.vertus/memory/ and ~/.hermes/memories/ to a timestamped
      archive under ~/.vertus/backups/ BEFORE touching anything;
    - copies each legacy entry into ~/.vertus/memory/shared/ byte-for-byte;
    - replaces the legacy paths with symlinks into canonical so anything
      still reading the old location keeps working;
    - seeds shared/USER.md from ~/.hermes/memories/USER.md (a COPY — the
      fork keeps its own file, which is outside mirror scope);
    - idempotent: a marker file plus per-entry symlink checks make a second
      run a no-op; a canonical target that exists with DIFFERENT content is
      a conflict and refuses rather than overwrite.
    """
    root = memory_root()
    shared = shared_dir()
    fleet_mem = fleet_hermes_home() / "memories"
    marker = root / _MIGRATION_MARKER

    report: dict = {"backup_path": None, "entries": {}, "seeded": [], "skipped": False}
    if marker.is_file():
        report["skipped"] = True
        report["reason"] = "already migrated (marker present)"
        return report

    # 1. Backup everything, byte-for-byte, before any change.
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = backups_dir() / f"memory-{ts}"
    shared.mkdir(parents=True, exist_ok=True)
    if root.is_dir():
        shutil.copytree(root, backup / "vertus-memory",
                        copy_function=shutil.copy2, dirs_exist_ok=True)
    if fleet_mem.is_dir():
        shutil.copytree(fleet_mem, backup / "hermes-memories",
                        copy_function=shutil.copy2, dirs_exist_ok=True)
    report["backup_path"] = str(backup)

    # 2. Fold legacy entries into shared/, preserving bytes exactly.
    for name in _LEGACY_ENTRIES:
        src = root / name
        dst = shared / name
        if src.is_symlink():
            report["entries"][name] = "symlink-already"
            continue
        if not src.exists():
            report["entries"][name] = "missing"
            continue
        if dst.exists():
            if _files_identical(src, dst):
                report["entries"][name] = "identical"
            else:
                report["entries"][name] = "conflict"
                continue  # never overwrite differing content
        if src.is_dir():
            shutil.copytree(src, dst, copy_function=shutil.copy2,
                            dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)
        if not _files_identical(src, dst):
            raise RuntimeError(f"migration verification failed for {name}")
        # The backup archive holds the originals; remove the source and
        # symlink the legacy path to canonical so anything still reading the
        # old location keeps working against the single source of truth.
        if src.is_dir() and not src.is_symlink():
            shutil.rmtree(src)
        else:
            src.unlink()
        os.symlink(os.path.relpath(dst, start=root), src)
        report["entries"][name] = "migrated"

    # 3. Seed the fleet-wide user preference from the fork's legacy home.
    seed = fleet_mem / "USER.md"
    if seed.is_file():
        dst = shared / "USER.md"
        if not dst.exists() or _files_identical(seed, dst):
            shutil.copy2(seed, dst)
            report["seeded"].append("USER.md")
        elif not _files_identical(seed, dst):
            report["seeded"].append("USER.md (conflict, not overwritten)")

    # 4. Mark migrated so a second run refuses to redo the work.
    marker.write_text(
        json.dumps({"at": ts, "backup": str(backup), "report": report},
                   indent=2),
        encoding="utf-8",
    )
    return report