"""Durable multi-agent registry for VERTUS.

On-disk layout (also documented in README "Multi-agent (WIP)"):

    ~/.vertus/agents/
    ├── _primary                  # text file holding the primary agent's id
    └── <agent_id>/
        ├── profile.json          # {"id", "name", "created_at", "sandbox_path"}
        └── sandbox/              # per-agent scratch directory

``agent_id`` is the directory name and never changes; ``name`` is display
only and may change via rename_agent(). The primary marker file starts with
an underscore so it can never collide with an agent id (ids are lowercase
slugs, so ``_primary`` is not a valid id).

Deletion policy (documented choice): the last remaining agent can never be
deleted (ValueError). Deleting the primary agent reassigns primary status
to the oldest remaining agent (by created_at, then id) rather than
recreating a fresh empty "primary" while other agents still exist.

No network calls, no secrets: this is local, on-disk state only. The
storage root defaults to ~/.vertus/agents and can be overridden with the
VERTUS_AGENTS_DIR environment variable (used by tests and smoke runs).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_PROFILE_FILE = "profile.json"
_PRIMARY_MARKER = "_primary"


def _utc_now_iso() -> str:
    """Timestamp used for created_at (ISO-8601 UTC, sorts lexicographically)."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _slugify(name: str) -> str:
    """Lowercase [a-z0-9-] slug for ids/dirs; falls back to 'agent'."""
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "agent"


class AgentRegistry:
    """File-backed registry of VERTUS agents, each with its own sandbox.

    All mutating/reading operations take a process-wide lock — the hub is a
    threaded HTTP server, so concurrent requests must not interleave writes.
    """

    def __init__(self, root: str | Path | None = None) -> None:
        env = os.environ.get("VERTUS_AGENTS_DIR")
        self.root = Path(root or env or (Path.home() / ".vertus" / "agents")).expanduser()
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def ensure_primary(self) -> dict:
        """Guarantee at least one agent exists and exactly one is primary.

        On first use this creates the agent with id ``primary`` named
        ``Primary`` so the existing single-agent behavior can keep working
        unchanged. Idempotent; safe to call before every registry read.
        """
        with self._lock:
            return self._ensure_primary_locked()

    def create_agent(self, name: str) -> dict:
        """Create an agent (profile.json + empty sandbox) and return it."""
        name = str(name).strip()
        if not name:
            raise ValueError("agent name must be non-empty")
        with self._lock:
            self.root.mkdir(parents=True, exist_ok=True)
            agent_id = self._fresh_id(_slugify(name))
            return self._create_locked(agent_id, name)

    def list_agents(self) -> list[dict]:
        """All agents sorted oldest-first, each dict carrying is_primary."""
        with self._lock:
            primary = self._read_marker()
            agents = [
                self._load(agent_id) | {"is_primary": agent_id == primary}
                for agent_id in self._scan_ids()
            ]
        agents.sort(key=lambda a: (a["created_at"], a["id"]))
        return agents

    def get_agent(self, agent_id: str) -> dict:
        """One agent by id; raises KeyError when unknown."""
        with self._lock:
            agent_id = self._validated_id(agent_id)
            agent = self._load(agent_id)
        agent["is_primary"] = agent_id == self._read_marker()
        return agent

    def rename_agent(self, agent_id: str, name: str) -> dict:
        """Update the display name; id, directory, and sandbox are kept."""
        name = str(name).strip()
        if not name:
            raise ValueError("agent name must be non-empty")
        with self._lock:
            agent_id = self._validated_id(agent_id)
            agent = self._load(agent_id)
            agent["name"] = name
            self._write_profile(agent_id, agent)
        agent["is_primary"] = agent_id == self._read_marker()
        return agent

    def delete_agent(self, agent_id: str) -> None:
        """Delete an agent directory (profile + sandbox).

        Refuses to delete the last remaining agent (ValueError). Deleting
        the primary reassigns primary status to the oldest remaining agent
        (see module docstring for the policy rationale).
        """
        with self._lock:
            agent_id = self._validated_id(agent_id)
            ids = self._scan_ids()
            if agent_id not in ids:
                raise KeyError(agent_id)
            if len(ids) <= 1:
                raise ValueError("cannot delete the last remaining agent")
            shutil.rmtree(self.root / agent_id)
            if self._read_marker() == agent_id:
                oldest = sorted(
                    (self._load(aid)["created_at"], aid) for aid in ids if aid != agent_id
                )[0][1]
                self._write_marker(oldest)

    # ------------------------------------------------------------------
    # Internals (callers must hold self._lock)
    # ------------------------------------------------------------------

    def _ensure_primary_locked(self) -> dict:
        self.root.mkdir(parents=True, exist_ok=True)
        ids = self._scan_ids()
        primary = self._read_marker()
        if primary in ids:
            agent = self._load(primary)
        elif ids:
            # Marker lost or dangling (deleted out-of-band): reassign to the
            # oldest agent instead of creating a duplicate "primary".
            oldest = sorted((self._load(aid)["created_at"], aid) for aid in ids)[0][1]
            self._write_marker(oldest)
            agent = self._load(oldest)
        else:
            agent = self._create_locked("primary", "Primary")
        agent["is_primary"] = True
        return agent

    def _create_locked(self, agent_id: str, name: str) -> dict:
        agent_dir = self.root / agent_id
        sandbox = agent_dir / "sandbox"
        sandbox.mkdir(parents=True, exist_ok=True)
        profile = {
            "id": agent_id,
            "name": name,
            "created_at": _utc_now_iso(),
            "sandbox_path": str(sandbox),
        }
        self._write_profile(agent_id, profile)
        # First agent ever created becomes primary automatically.
        if self._read_marker() not in self._scan_ids():
            self._write_marker(agent_id)
        return profile | {"is_primary": self._read_marker() == agent_id}

    def _fresh_id(self, slug: str) -> str:
        """Unique id = slug, with a short uuid suffix only on collision."""
        taken = {p.name for p in self.root.iterdir()} if self.root.exists() else set()
        if slug not in taken:
            return slug
        while True:
            candidate = f"{slug}-{uuid.uuid4().hex[:6]}"
            if candidate not in taken:
                return candidate

    def _validated_id(self, agent_id: str) -> str:
        """Reject malformed ids and anything that could escape the root."""
        agent_id = str(agent_id).strip()
        if not _ID_RE.match(agent_id):
            raise KeyError(agent_id)
        return agent_id

    def _scan_ids(self) -> list[str]:
        if not self.root.exists():
            return []
        return sorted(
            p.name
            for p in self.root.iterdir()
            if p.is_dir() and not p.name.startswith("_") and (p / _PROFILE_FILE).is_file()
        )

    def _agent_dir(self, agent_id: str) -> Path:
        return self.root / agent_id

    def _load(self, agent_id: str) -> dict:
        profile_path = self._agent_dir(agent_id) / _PROFILE_FILE
        try:
            profile = json.loads(profile_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise KeyError(agent_id) from exc
        if not isinstance(profile, dict) or profile.get("id") != agent_id:
            raise KeyError(agent_id)
        return profile

    def _write_profile(self, agent_id: str, profile: dict) -> None:
        self._atomic_write(self._agent_dir(agent_id) / _PROFILE_FILE, profile)

    def _read_marker(self) -> str:
        try:
            return self.root.joinpath(_PRIMARY_MARKER).read_text().strip()
        except OSError:
            return ""

    def _write_marker(self, agent_id: str) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        self._atomic_write(self.root / _PRIMARY_MARKER, agent_id + "\n", text=True)

    def _atomic_write(self, path: Path, data, text: bool = False) -> None:
        """Write via a temp file + os.replace so readers never see a torn file."""
        path.parent.mkdir(parents=True, exist_ok=True)
        if text:
            payload = data.encode()
        else:
            payload = json.dumps(data, indent=2).encode()
        tmp = path.with_name(f".{path.name}.{uuid.uuid4().hex[:8]}.tmp")
        tmp.write_bytes(payload)
        os.replace(tmp, path)
