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

# Dual import like vertus_server.py: plain for script-dir invocation, package-relative for -m.
try:
    import vertus_paths  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore

# ---------------------------------------------------------------------------
# Paths — thin wrappers over vertus_paths, the ONE resolver for every root.
# No fallback logic lives here (see vertus_paths.py for the precedence rule:
# concept env var → VERTUS_ROOT → production default). The env-divergence bug
# that sent a temp hub's bots at the real ~/.vertus was this file resolving
# its own roots; keep it that way.
# ---------------------------------------------------------------------------


def memory_root() -> Path:
    return vertus_paths.memory_root()


def shared_dir() -> Path:
    return vertus_paths.shared_memory_dir()


def agents_dir() -> Path:
    return vertus_paths.agents_dir()


def agent_memory_dir(agent_id: str) -> Path:
    return agents_dir() / agent_id / "memory"


def agent_home_memories_dir(agent_id: str) -> Path:
    """The FORK-owned engine memory dir inside the agent's HERMES_HOME."""
    return agents_dir() / agent_id / "home" / "memories"


def fleet_hermes_home() -> Path:
    """The fleet default engine config root. Its memories/ dir is OUTSIDE
    mirror scope: no fleet gateway ever uses it as HERMES_HOME (every gateway
    gets a per-agent home); only the legacy CLI touches it. Resolution lives
    in vertus_paths (under VERTUS_ROOT a hermetic hub derives it from the
    temp root rather than consulting the real ~/.hermes)."""
    return vertus_paths.fleet_hermes_home()


def backups_dir() -> Path:
    return vertus_paths.backups_dir()


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
    rel = rel.replace("\\", "/")
    if rel.startswith("/") or rel.startswith("~"):
        raise ValueError(f"invalid memory path: {rel!r}")
    rel = rel.strip("/")
    if not rel or rel in (".", "..") or ".." in rel.split("/"):
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


# ---------------------------------------------------------------------------
# Checkpoint 2: canonical store + fork mirror + hub index + watcher
# ---------------------------------------------------------------------------

# Fork-owned files inside each agent's HERMES_HOME/memories/ — the mirror
# scope is exactly these two files (see the module docstring's sync rule).
_FORK_MEMORY_FILES = ("USER.md", "MEMORY.md")


class MemoryStore:
    """Hub-owned view over the canonical memory files.

    - ``write``/``delete`` are the ONLY hub write paths: per-file fcntl
      advisory lock + temp file + ``os.replace``, so two hub writers can
      never interleave or truncate (a write is atomic or absent).
    - the watcher polls (2s default) canonical dirs + every agent's
      ``home/memories`` pair; fork-file changes propagate ONE-WAY into
      canonical agent memory, and canonical changes emit ``memory_changed``
      fleet events with writer attribution.
    - the index (``~/.vertus/memory/.hub-index.json``) is hub-maintained;
      the model never updates an index by hand — that expectation is
      deleted from the skill.
    """

    def __init__(self, emit=None, running_agents=None, poll_s: float = 2.0,
                 index_file: Path | None = None):
        self._emit = emit  # callable(agent_id: str, event: dict)
        self._running_agents = running_agents  # callable() -> set[str]
        self._poll_s = poll_s
        self._index_file = index_file or index_path()
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._index: dict[str, dict] = {}
        # Per-mirrored-file state: {key: {"src_mtime", "src_size", "dst_sha"}}
        # — what the fork source looked like and what WE last wrote to
        # canonical. In-memory by design: after a crash the next poll simply
        # re-mirrors once (byte-identical copy, one spurious event), which is
        # safer than persisting state that could mask a real fork change.
        self._mirror_state: dict[str, dict] = {}
        self._load_index()

    # -- index -------------------------------------------------------------

    def _key(self, scope: str, agent_id: str | None, rel: str) -> str:
        if scope == "shared":
            return f"shared/{rel}"
        return f"agent/{agent_id}/{rel}"

    def _load_index(self) -> None:
        try:
            if self._index_file.is_file():
                self._index = json.loads(self._index_file.read_text(encoding="utf-8"))
        except Exception:
            self._index = {}
        if not isinstance(self._index, dict):
            self._index = {}

    def _save_index(self) -> None:
        tmp = self._index_file.with_name(self._index_file.name + ".tmp")
        tmp.write_text(json.dumps(self._index, indent=1), encoding="utf-8")
        os.replace(tmp, self._index_file)

    # -- canonical writes (hub-only) ---------------------------------------

    @staticmethod
    def _locked_atomic_write(path: Path, content: bytes) -> None:
        """Per-file fcntl lock + temp file + os.replace: atomic, never
        interleaved, never truncated. Mirrors the fork's own discipline."""
        path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = path.with_name(path.name + ".lock")
        fd = open(lock_path, "a+", encoding="utf-8")
        try:
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_EX)
            tmp = path.with_name(path.name + ".tmp")
            tmp.write_bytes(content)
            os.replace(tmp, path)
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            fd.close()

    def _scope_root(self, scope: str, agent_id: str | None) -> Path:
        if scope == "shared":
            return shared_dir()
        if scope == "agent":
            if not agent_id:
                raise ValueError("agent scope requires agent_id")
            return agent_memory_dir(agent_id)
        raise ValueError(f"unknown scope: {scope}")

    def list_entries(self, scope: str = "all", agent_id: str | None = None,
                     agent_ids: list[str] | None = None) -> list[dict]:
        """Index-backed listing: relpath, size, mtime, sha, writer."""
        with self._lock:
            items = []
            for key, meta in self._index.items():
                parts = key.split("/", 1)
                key_scope, rest = parts[0], parts[1] if len(parts) > 1 else ""
                if key_scope == "agent":
                    agent = rest.split("/", 1)[0]
                    rel = rest.split("/", 1)[1] if "/" in rest else ""
                else:
                    agent, rel = None, rest
                if scope == "shared" and key_scope != "shared":
                    continue
                if scope == "agent" and (key_scope != "agent"
                                         or (agent_id and agent != agent_id)):
                    continue
                if agent_ids is not None and key_scope == "agent" \
                        and agent not in agent_ids:
                    continue
                items.append({
                    "scope": key_scope, "agent_id": agent, "path": rel,
                    "size": meta.get("size"), "mtime": meta.get("mtime"),
                    "sha": meta.get("sha"), "writer": meta.get("writer"),
                    "updated_at": meta.get("updated_at"),
                })
        return sorted(items, key=lambda i: (i["scope"], i.get("agent_id") or "", i["path"]))

    def read(self, scope: str, agent_id: str | None, rel: str) -> bytes | None:
        rel = _safe_relpath(rel)
        path = self._scope_root(scope, agent_id) / rel
        try:
            return path.read_bytes()
        except FileNotFoundError:
            return None

    def write(self, scope: str, agent_id: str | None, rel: str, content: bytes,
              writer: str = "human") -> dict:
        """Atomic hub write + index update + fleet event."""
        rel = _safe_relpath(rel)
        path = self._scope_root(scope, agent_id) / rel
        with self._lock:
            existed = self._key(scope, agent_id, rel) in self._index
        self._locked_atomic_write(path, content)
        meta = self._observe(path, writer)
        with self._lock:
            self._index[self._key(scope, agent_id, rel)] = meta
            self._save_index()
        self._changed(scope, agent_id, rel,
                      "updated" if existed else "created", writer)
        return meta

    def delete(self, scope: str, agent_id: str | None, rel: str,
               writer: str = "human") -> bool:
        rel = _safe_relpath(rel)
        path = self._scope_root(scope, agent_id) / rel
        if not path.exists():
            return False
        with self._lock:
            self._index.pop(self._key(scope, agent_id, rel), None)
            self._save_index()
        path.unlink()
        self._changed(scope, agent_id, rel, "deleted", writer)
        return True

    def search(self, q: str, agent_ids: list[str] | None = None) -> list[dict]:
        """Simple substring search over file contents, not a vector db."""
        needle = q.lower()
        hits = []
        for entry in self.list_entries("all", agent_ids=agent_ids):
            try:
                data = self.read(entry["scope"], entry.get("agent_id"), entry["path"])
            except Exception:
                continue
            if data is None:
                continue
            text = data.decode("utf-8", errors="replace")
            if needle in text.lower():
                hits.append({**entry, "snippet": self._snippet(data, q)})
        return hits

    @staticmethod
    def _snippet(data: bytes, needle: str, width: int = 120) -> str:
        text = data.decode("utf-8", errors="replace")
        idx = text.lower().find(needle.lower())
        if idx < 0:
            return text[:width]
        start = max(0, idx - width // 2)
        return text[start:start + width].replace("\n", " ")

    # -- observation / change detection ------------------------------------

    @staticmethod
    def _observe(path: Path, writer: str) -> dict:
        st = path.stat()
        return {
            "size": st.st_size, "mtime": st.st_mtime,
            "sha": _sha256(path), "writer": writer,
            "updated_at": time.time(),
        }

    def _changed(self, scope: str, agent_id: str | None, rel: str,
                 action: str, writer: str) -> None:
        if self._emit is None:
            return
        try:
            self._emit(agent_id or "", {
                "type": "memory_changed", "scope": scope,
                "agent_id": agent_id or "", "path": rel, "action": action,
                "writer": writer,
            })
        except Exception:
            pass

    def _writer_for(self, rel_scope: str, agent_id: str | None) -> str:
        """Attribute a poll-detected change: the single running agent, else
        external (human edit on disk / legacy tool)."""
        try:
            running = self._running_agents() if self._running_agents else set()
        except Exception:
            return "external"
        if rel_scope == "agent" and agent_id and agent_id in running:
            return agent_id
        if rel_scope == "shared" and len(running) == 1:
            return next(iter(running))
        return "external"

    # -- watcher -----------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        # Canonical dirs are hub-owned: ensure they exist so the watcher and
        # API have somewhere to scan even on a fresh machine.
        shared_dir().mkdir(parents=True, exist_ok=True)
        self._index_file.parent.mkdir(parents=True, exist_ok=True)
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True,
                                        name="fleet-memory-watcher")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _loop(self) -> None:
        while not self._stop.wait(self._poll_s):
            try:
                self.poll_once()
            except Exception:
                pass

    def poll_once(self) -> list[dict]:
        """One scan: canonical dirs + every agent's fork mirror. Returns the
        events emitted this pass (handy for tests)."""
        emitted: list[dict] = []
        events: list[tuple[str, str | None, str, str, str]] = []
        shared = shared_dir()
        self._scan_dir(shared, "shared", None, events)
        if agents_dir().is_dir():
            for agent in sorted(p.name for p in agents_dir().iterdir()
                                if p.is_dir() and not p.name.startswith(".")):
                self._scan_dir(agent_memory_dir(agent), "agent", agent, events)
                self._mirror_home_memories(agent, events)
        with self._lock:
            self._save_index()
        for scope, agent, rel, action, writer in events:
            self._changed(scope, agent, rel, action, writer)
            emitted.append({"scope": scope, "agent_id": agent, "path": rel,
                            "action": action, "writer": writer})
        return emitted

    def _scan_dir(self, root: Path, scope: str, agent_id: str | None,
                  events: list) -> None:
        """Diff one canonical dir against the index; anything new or changed
        is indexed and reported. Deletions are dropped from the index."""
        if not root.is_dir():
            return
        known = {k: v for k, v in self._index.items()
                 if k.startswith(self._key(scope, agent_id, ""))}
        seen: set[str] = set()
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = str(path.relative_to(root))
            if path.name.endswith((".lock", ".tmp")) or path.name.startswith("."):
                continue
            seen.add(rel)
            key = self._key(scope, agent_id, rel)
            meta = self._observe(path, self._writer_for(scope, agent_id))
            prev = known.get(key)
            if prev is None:
                events.append((scope, agent_id, rel, "created", meta["writer"]))
            elif prev.get("mtime") != meta["mtime"] or prev.get("size") != meta["size"]:
                # content changed: keep the OLD writer only for hub-written
                # files; a detected change means a bot/external wrote it
                meta["writer"] = self._writer_for(scope, agent_id)
                events.append((scope, agent_id, rel, "updated", meta["writer"]))
            self._index[key] = meta
        for key in set(known) - {self._key(scope, agent_id, r) for r in seen}:
            self._index.pop(key, None)
            rel = key.split("/", 1)[1]
            if scope == "agent":
                rel = rel.split("/", 1)[1] if "/" in rel else ""
            events.append((scope, agent_id, rel, "deleted", "external"))

    def _mirror_home_memories(self, agent_id: str, events: list) -> None:
        """ONE-WAY fork mirror: home/memories/{USER.md, MEMORY.md} -> canonical
        agent memory.

        Conflict rule (never destroy a write): the mirror tracks what the
        fork source looked like AND what the hub last wrote to canonical. A
        fork change is copied only when canonical still equals what the hub
        last wrote; if canonical moved in between (a human edit, another
        write), the fork's version is staged as ``<name>.conflict-<ts>``
        instead of overwriting — both sides survive, nobody loses a write.
        """
        src_dir = agent_home_memories_dir(agent_id)
        if not src_dir.is_dir():
            return
        for name in _FORK_MEMORY_FILES:
            src = src_dir / name
            if not src.is_file():
                continue
            rel = name
            dst = agent_memory_dir(agent_id) / rel
            key = self._key("agent", agent_id, rel)
            with self._lock:
                prev = self._mirror_state.get(key)
            src_stat = src.stat()
            src_fp = (src_stat.st_mtime, src_stat.st_size)
            if prev is not None and src_fp == (prev["src_mtime"], prev["src_size"]):
                continue  # fork file unchanged since last mirror
            dst_sha = _sha256(dst) if dst.is_file() else None
            if prev is not None and dst_sha != prev["dst_sha"]:
                # canonical moved since the hub last wrote it: stage, never
                # destroy the newer canonical content
                conflict = dst.with_name(f"{name}.conflict-{int(time.time())}")
                shutil.copy2(src, conflict)
                with self._lock:
                    self._mirror_state[key] = {
                        "src_mtime": src_stat.st_mtime, "src_size": src_stat.st_size,
                        "dst_sha": dst_sha,
                    }
                events.append(("agent", agent_id, conflict.name,
                               "created", agent_id))
                continue
            self._locked_atomic_write(dst, src.read_bytes())
            new_sha = _sha256(dst)
            with self._lock:
                self._index[key] = self._observe(dst, agent_id)
                self._mirror_state[key] = {
                    "src_mtime": src_stat.st_mtime, "src_size": src_stat.st_size,
                    "dst_sha": new_sha,
                }
            events.append(("agent", agent_id, rel,
                           "created" if prev is None else "updated", agent_id))