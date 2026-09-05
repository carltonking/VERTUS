"""Durable multi-agent registry for VERTUS.

On-disk layout (also documented in README "Multi-agent (WIP)"):

    ~/.vertus/agents/
    ├── _primary                    # text file holding the primary agent's id
    └── <agent_id>/
        ├── profile.json            # schema_version 3 — the SINGLE SOURCE OF TRUTH
        ├── sandbox/                # per-agent scratch directory (session cwd)
        ├── memory/                 # this bot's own working notes
        └── home/                   # per-agent ENGINE config root (HERMES_HOME);
            ├── config.yaml         #   materialized from profile.model/provider
            ├── SOUL.md             #   materialized from profile.persona
            ├── memories/           #   engine-side memory (USER.md / MEMORY.md)
            ├── auth.json           #   copied from the fleet home at create time
            ├── .env                #   copied from the fleet home at create time
            └── skills/             #   templated VERTUS skills (injected paths)

    ~/.vertus/memory/shared/        # fleet-wide notes every bot can read/write

``home/`` is DERIVED STATE: profile.json is authoritative and ``home/`` is
re-materialized on every profile write (see ``_materialize_home_locked``).
Hand edits under ``home/`` are lost on the next profile update — by design.

Profile schema v4 (``schema_version: 4``):

    id, name, title, description   # identity; title/description drive delegation
    persona        : str           # the bot's system identity text (→ home/SOUL.md)
    model, provider: str | None    # None = inherit the fleet default
    color, emoji   : str | None    # client affordance
    autonomy       : "ask" | "trusted"   # spawn-time GUI permission mapping
    computer_use   : bool          # whether this bot may drive the desktop (v3)
    cua_targets    : [str] | None  # allowed app bundle ids / window titles it
                                   # works in; null = unrestricted (v3)
    stall_timeout_s: number        # silence (no engine event) that ends a turn (v4)
    hard_timeout_s : number        # absolute ceiling for a non-converging turn (v4)
    created_at, updated_at, is_primary, sandbox_path, home_path

Migration: profiles older than v4 (no ``schema_version``, or v1–v3) are
upgraded in place on load — stepwise v1→v2→v3→v4 so every intermediate rule
applies exactly once. v1 backfills ``title`` from ``name`` and ``persona``
from the fleet's current ``~/.hermes/SOUL.md`` when readable; v3 adds
``computer_use: False`` and ``cua_targets: None`` (existing fleet behavior
is unchanged: no bot acquires desktop capability on upgrade); v4 adds the
supervision timeouts (defaults 180s / 3600s — a slow-but-chatty CUA turn is
never touched). All old keys are kept and unknown keys preserved. Migration
is idempotent (a current-schema profile is never rewritten by it). The
fleet hermes home is ``VERTUS_FLEET_HERMES_HOME`` or ``~/.hermes``.

Deletion policy (documented choice): the last remaining agent can never be
deleted (ValueError). Deleting the primary agent reassigns primary status to
the oldest remaining agent (by created_at, then id) rather than recreating a
fresh empty "primary" while other agents still exist.

Deletion is destructive by default (``delete_agent``); the hub's DELETE
endpoint passes ``archive=True``, which MOVES the agent directory to
``<root>/.trash/<id>-<timestamp>/`` instead of destroying it (a tombstone
with profile.json intact). The trash root is excluded from every scan.

Agent creation accepts the full v2 editable field set (see
``create_agent(name, **fields)``); validation of those fields is shared with
``update_agent`` via ``_validate_fields``. ``create_agent``'s id scheme:
``_slugify(name)`` (lowercase [a-z0-9-]) with a deterministic short uuid
suffix only when the slug is already taken — never a random id on first
try, so "create Scout" yields "scout" unless "scout" exists.

No network calls, no secrets of its own: this is local, on-disk state. The
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

SCHEMA_VERSION = 4

# Free-form identity/config fields an update_agent() caller may set. Paths,
# timestamps, and the id are managed by the registry, never by callers.
EDITABLE_FIELDS = (
    "title",
    "description",
    "persona",
    "model",
    "provider",
    "color",
    "emoji",
    "autonomy",
    "computer_use",
    "cua_targets",
    "stall_timeout_s",
    "hard_timeout_s",
)
AUTONOMY_VALUES = ("ask", "trusted")


def _utc_now_iso() -> str:
    """Timestamp used for created_at/updated_at (ISO-8601 UTC, sorts lexicographically)."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _slugify(name: str) -> str:
    """Lowercase [a-z0-9-] slug for ids/dirs; falls back to 'agent'."""
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "agent"


def fleet_hermes_home() -> Path:
    """The fleet default engine config root (source for persona backfill + key copies).

    ``VERTUS_FLEET_HERMES_HOME`` overrides; default ``~/.hermes`` — the same
    root the un-profiled hermes engine resolves (hermes fork:
    hermes_constants.get_hermes_home → $HERMES_HOME → ~/.hermes).
    """
    env = os.environ.get("VERTUS_FLEET_HERMES_HOME", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".hermes"


def _read_fleet_soul() -> str:
    """Best-effort read of the fleet SOUL.md, for v1 persona backfill."""
    try:
        return (fleet_hermes_home() / "SOUL.md").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def migrate_v1_profile(profile: dict, persona_backfill: str = "") -> tuple[dict, bool]:
    """Upgrade a profile dict to the current schema (v3). Pure — no I/O.

    Applies the stepwise v1→v2→v3 rules in order so every migration is
    idempotent and lossless: ``schema_version >= 3`` returns unchanged,
    unknown keys always survive, old keys are never dropped. v1 lacks the
    identity extras; v2 lacks the computer-use fields.
    """
    version = int(profile.get("schema_version") or 0)
    if version >= SCHEMA_VERSION:
        return profile, False
    upgraded = dict(profile)  # unknown keys survive the copy
    # v1 → v2 (only when the profile predates v2).
    if version < 2:
        name = str(profile.get("name") or "")
        upgraded.setdefault("title", name)
        upgraded.setdefault("description", "")
        upgraded.setdefault("persona", persona_backfill or "")
        upgraded.setdefault("model", None)
        upgraded.setdefault("provider", None)
        upgraded.setdefault("color", None)
        upgraded.setdefault("emoji", None)
        upgraded.setdefault("autonomy", "ask")
        upgraded.setdefault("updated_at", profile.get("created_at") or _utc_now_iso())
    # v2 → v3: computer-use capability defaults OFF so an upgraded fleet keeps
    # today's behavior exactly (no bot gains desktop control by accident).
    upgraded.setdefault("computer_use", False)
    upgraded.setdefault("cua_targets", None)
    # v3 → v4: supervision timeouts. stall = silence that kills the turn;
    # hard = absolute ceiling for a turn that emits forever without
    # converging. Both only take effect once the hub's supervisor runs — a
    # slow-but-chatty CUA turn (the GUI demo took 251s legitimately) is
    # untouched by stall_timeout_s and far inside hard_timeout_s.
    upgraded.setdefault("stall_timeout_s", 180)
    upgraded.setdefault("hard_timeout_s", 3600)
    upgraded["schema_version"] = SCHEMA_VERSION
    return upgraded, True


def _yaml_dump(data: dict) -> str:
    """Serialize a config dict to YAML, falling back to JSON if PyYAML is absent."""
    try:
        import yaml

        return yaml.safe_dump(data, default_flow_style=False, sort_keys=False)
    except ImportError:  # pragma: no cover - PyYAML present on all fleet hosts
        return json.dumps(data, indent=2)


def _yaml_load(text: str):
    """Parse YAML text, falling back to JSON; returns None on any failure."""
    try:
        import yaml

        return yaml.safe_load(text)
    except Exception:
        try:
            return json.loads(text)
        except Exception:
            return None


class AgentRegistry:
    """File-backed registry of VERTUS agents, each with its own sandbox + engine home.

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

    def create_agent(self, name: str, **fields) -> dict:
        """Create an agent (profile + sandbox + engine home + memory) and return it.

        ``fields`` are optional v2 editable profile fields (title,
        description, persona, model, provider, color, emoji, autonomy) —
        validated exactly like ``update_agent``'s (unknown key → TypeError,
        bad autonomy → ValueError), applied before the derived home tree is
        materialized so config.yaml/SOUL.md reflect them from the start.
        """
        name = str(name).strip()
        if not name:
            raise ValueError("agent name must be non-empty")
        self._validate_fields(fields)
        with self._lock:
            self.root.mkdir(parents=True, exist_ok=True)
            agent_id = self._fresh_id(_slugify(name))
            return self._create_locked(agent_id, name, fields)

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
        """One agent by id; raises KeyError when unknown.

        Loading also applies the v1→v2 migration in place when needed.
        """
        with self._lock:
            agent_id = self._validated_id(agent_id)
            agent = self._load(agent_id)
        agent["is_primary"] = agent_id == self._read_marker()
        return agent

    def update_agent(self, agent_id: str, **fields) -> dict:
        """Update editable profile fields; re-materialize the derived home tree.

        Only fields in EDITABLE_FIELDS are accepted (TypeError otherwise, so a
        typo'd field can never silently no-op). ``autonomy`` is validated.
        ``model``/``provider``/``color``/``emoji`` set to None mean "unset"
        (model/provider → inherit the fleet default); None on the free-form
        text fields (title/description/persona) clears them to "".
        """
        self._validate_fields(fields)
        with self._lock:
            agent_id = self._validated_id(agent_id)
            agent = self._load(agent_id)
            for key, value in fields.items():
                if value is None:
                    # null clears: nullable identity fields → None, list field
                    # cua_targets → None (unrestricted), timeout fields → None
                    # (hub default), text fields → ""
                    agent[key] = (
                        None
                        if key in ("model", "provider", "color", "emoji", "cua_targets",
                                   "stall_timeout_s", "hard_timeout_s")
                        else ""
                    )
                elif key in ("model", "provider"):
                    agent[key] = value
                elif key == "computer_use":
                    agent[key] = bool(value)  # validated above; stored as bool
                elif key == "cua_targets":
                    agent[key] = [str(t).strip() for t in value]
                elif key in ("stall_timeout_s", "hard_timeout_s"):
                    agent[key] = float(value)
                else:
                    agent[key] = str(value)
            agent["updated_at"] = _utc_now_iso()
            self._write_profile(agent_id, agent)
            self._materialize_home_locked(agent_id, agent)
        agent["is_primary"] = agent_id == self._read_marker()
        return agent

    @staticmethod
    def _validate_fields(fields: dict) -> None:
        """Shared schema guard for create_agent/update_agent field dicts."""
        unknown = set(fields) - set(EDITABLE_FIELDS)
        if unknown:
            raise TypeError(f"unknown profile field(s): {', '.join(sorted(unknown))}")
        if "autonomy" in fields and fields["autonomy"] not in AUTONOMY_VALUES:
            raise ValueError(f"autonomy must be one of {AUTONOMY_VALUES}")
        if "computer_use" in fields and not isinstance(fields["computer_use"], bool):
            raise TypeError("computer_use must be a boolean")
        targets = fields.get("cua_targets")
        if targets is not None and (
            not isinstance(targets, list)
            or not all(isinstance(t, str) and t.strip() for t in targets)
        ):
            raise TypeError("cua_targets must be a list of non-empty strings or null")
        for key in ("stall_timeout_s", "hard_timeout_s"):
            value = fields.get(key)
            if value is not None and (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or value <= 0
            ):
                raise TypeError(f"{key} must be a positive number or null")

    def rename_agent(self, agent_id: str, name: str) -> dict:
        """Update the display name; id, directory, sandbox, and home are kept.

        ``rename_agent`` does not re-materialize home/ (the name is a display
        affordance, not engine state).
        """
        name = str(name).strip()
        if not name:
            raise ValueError("agent name must be non-empty")
        with self._lock:
            agent_id = self._validated_id(agent_id)
            agent = self._load(agent_id)
            agent["name"] = name
            agent["updated_at"] = _utc_now_iso()
            self._write_profile(agent_id, agent)
        agent["is_primary"] = agent_id == self._read_marker()
        return agent

    def delete_agent(self, agent_id: str, *, archive: bool = False) -> str | None:
        """Delete an agent directory; returns the trash path when archiving.

        Refuses to delete the last remaining agent (ValueError). Deleting
        the primary reassigns primary status to the oldest remaining agent
        (see module docstring for the policy rationale). With
        ``archive=True`` the directory is MOVED (not destroyed) to
        ``<root>/.trash/<id>-<timestamp>/`` — the hub's DELETE endpoint uses
        this so nothing is ever lost; the registry then no longer lists the
        agent and ``get_agent`` raises KeyError for it.
        """
        with self._lock:
            agent_id = self._validated_id(agent_id)
            ids = self._scan_ids()
            if agent_id not in ids:
                raise KeyError(agent_id)
            if len(ids) <= 1:
                raise ValueError("cannot delete the last remaining agent")
            if archive:
                trash_root = self.root / ".trash"
                trash_root.mkdir(parents=True, exist_ok=True)
                stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
                dest = trash_root / f"{agent_id}-{stamp}"
                suffix = 1
                while dest.exists():  # two deletes of the same id in one second
                    dest = trash_root / f"{agent_id}-{stamp}-{suffix}"
                    suffix += 1
                shutil.move(str(self.root / agent_id), str(dest))
                archived = str(dest)
            else:
                shutil.rmtree(self.root / agent_id)
                archived = None
            if self._read_marker() == agent_id:
                oldest = sorted(
                    (self._load(aid)["created_at"], aid) for aid in ids if aid != agent_id
                )[0][1]
                self._write_marker(oldest)
            return archived

    def agent_home(self, agent_id: str) -> Path:
        """The agent's engine config root (HERMES_HOME for its gateway)."""
        return self.root / agent_id / "home"

    # ------------------------------------------------------------------
    # Computer-use capability manifest (v3, bounded-mode ceiling)
    # ------------------------------------------------------------------

    def _cua_manifest_for(self, agent_id: str, home: Path) -> Path | None:
        """Resolve a cua-driver capability manifest for a trusted CUA agent.

        Candidate order: ``VERTUS_CUA_MANIFEST`` env → ``<home>/cua-manifest.yaml``
        → fleet hermes home → ``~/.vertus/cua-manifest.yaml``. The first file
        that exists is copied into the agent home (home/ is derived state) so
        the engine's ``computer_use.capability_manifest`` path is always a
        self-contained per-agent file. Returns None when no manifest exists —
        the caller then falls back to ``standard`` permission mode.
        """
        env = os.environ.get("VERTUS_CUA_MANIFEST", "").strip()
        candidates: list[Path] = []
        if env:
            candidates.append(Path(env).expanduser())
        candidates.append(home / "cua-manifest.yaml")
        candidates.append(fleet_hermes_home() / "cua-manifest.yaml")
        candidates.append(Path.home() / ".vertus" / "cua-manifest.yaml")
        for cand in candidates:
            if not cand.is_file():
                continue
            try:
                dest = home / "cua-manifest.yaml"
                dest.write_bytes(cand.read_bytes())
                return dest
            except OSError:
                return None
        return None

    def cua_manifest_path(self, agent_id: str) -> Path | None:
        """Public read of the per-agent manifest path if one is materialized."""
        p = self.agent_home(agent_id) / "cua-manifest.yaml"
        return p if p.is_file() else None

    def agent_memory_dir(self, agent_id: str) -> Path:
        """This bot's own notes directory (skill-injected, never hardcoded)."""
        return self.root / agent_id / "memory"

    def shared_memory_dir(self) -> Path:
        """Fleet-wide notes directory every bot reads/writes.

        ``VERTUS_SHARED_MEMORY_DIR`` overrides; default ``~/.vertus/memory/shared``
        (sibling of the legacy single-agent ``~/.vertus/memory`` store).
        """
        env = os.environ.get("VERTUS_SHARED_MEMORY_DIR", "").strip()
        return Path(env).expanduser() if env else Path.home() / ".vertus" / "memory" / "shared"

    def ensure_memory_dirs(self, agent_id: str) -> tuple[Path, Path]:
        """Create (if missing) and return ``(agent_memory, shared_memory)``."""
        agent_mem = self.agent_memory_dir(agent_id)
        agent_mem.mkdir(parents=True, exist_ok=True)
        shared = self.shared_memory_dir()
        shared.mkdir(parents=True, exist_ok=True)
        return agent_mem, shared

    # ------------------------------------------------------------------
    # Derived state: the per-agent engine home (HERMES_HOME)
    # ------------------------------------------------------------------

    def _materialize_home_locked(self, agent_id: str, profile: dict) -> None:
        """(Re)write everything under ``home/`` from the profile.

        Called on create and on every profile update so the tree always
        mirrors profile.json. Per-bot copies of auth.json / .env are seeded
        once (only when the target is missing) — they may hold per-bot
        credentials and are NOT clobbered by fleet-wide updates.
        """
        home = self.agent_home(agent_id)
        home.mkdir(parents=True, exist_ok=True)

        # config.yaml — per-agent model/provider override, else the fleet
        # default config (model section included). If the fleet config is
        # unreadable and no override exists, write a minimal file so the
        # engine falls back to its own silent default rather than inheriting
        # a stale one.
        fleet_cfg_path = fleet_hermes_home() / "config.yaml"
        cfg = _yaml_load(fleet_cfg_path.read_text(encoding="utf-8")) if fleet_cfg_path.is_file() else None
        if not isinstance(cfg, dict):
            cfg = {}
        cfg.pop("model_aliases", None)  # aliases resolve against fleet credentials we may not copy
        if profile.get("model"):
            model_section = {"default": str(profile["model"])}
            if profile.get("provider"):
                model_section["provider"] = str(profile["provider"])
            cfg["model"] = model_section
        elif profile.get("provider"):
            cfg.setdefault("model", {})["provider"] = str(profile["provider"])
        # computer_use (v3). Enabled agents get an explicit driver permission
        # mode materialized at SPAWN time (the fork reads config.yaml per
        # HERMES_HOME; the driver mode is immutable per daemon):
        #   autonomy=ask    -> standard  (driver default; watched mode)
        #   autonomy=trusted-> bounded   ONLY when a capability manifest is
        #                        available (see _cua_manifest_path) — bounded
        #                        requires one and the fork raises at first
        #                        CUA call otherwise. No manifest on this host
        #                        -> trusted degrades to standard (documented
        #                        compromise: a valid v3 manifest schema is
        #                        driver-validated and none ships in the fork
        #                        or on this machine, so none is fabricated).
        # Disabled agents carry no computer_use block: capability is cut at
        # the hub's spawn layer (HERMES_COMPUTER_USE_BACKEND=noop) instead.
        if profile.get("computer_use"):
            cu_cfg: dict = {"permission_mode": "standard"}
            if str(profile.get("autonomy") or "ask") == "trusted":
                manifest = self._cua_manifest_for(agent_id, home)
                if manifest is not None:
                    cu_cfg["permission_mode"] = "bounded"
                    cu_cfg["capability_manifest"] = str(manifest)
            cfg["computer_use"] = cu_cfg
        else:
            cfg.pop("computer_use", None)
        (home / "config.yaml").write_text(_yaml_dump(cfg), encoding="utf-8")

        # SOUL.md — the bot's persona. Empty persona removes any stale file so
        # the tree stays derived (the engine re-seeds its default identity).
        soul = home / "SOUL.md"
        persona = str(profile.get("persona") or "").strip()
        if persona:
            soul.write_text(persona + "\n", encoding="utf-8")
        elif soul.exists():
            soul.unlink()

        # Engine-side memories dir (USER.md / MEMORY.md are engine-managed).
        (home / "memories").mkdir(parents=True, exist_ok=True)

        # Templated VERTUS skills with this agent's paths injected (the skill
        # files in the repo carry {{PLACEHOLDER}} markers — see
        # vertus/extensions/memory-skill/SKILL.md). Missing repo skill files
        # are skipped silently (tests run from a bare checkout).
        substitutions = {
            "{{AGENT_ID}}": agent_id,
            "{{AGENT_NAME}}": str(profile.get("name") or agent_id),
            "{{AGENT_MEMORY_DIR}}": str(self.agent_memory_dir(agent_id)),
            "{{SHARED_MEMORY_DIR}}": str(self.shared_memory_dir()),
            "{{AGENT_SOUL_PATH}}": str(home / "SOUL.md"),
        }
        for skill_name, source in (
            ("vertus-memory", _REPO_ROOT / "vertus" / "extensions" / "memory-skill" / "SKILL.md"),
            ("vertus-persona", _REPO_ROOT / "vertus-persona" / "SKILL.md"),
        ):
            try:
                text = source.read_text(encoding="utf-8")
            except OSError:
                continue
            for marker, value in substitutions.items():
                text = text.replace(marker, value)
            skill_dir = home / "skills" / skill_name
            skill_dir.mkdir(parents=True, exist_ok=True)
            (skill_dir / "SKILL.md").write_text(text, encoding="utf-8")

        # Seed per-bot credentials once from the fleet home. Never overwrite:
        # a bot's keys may have been edited per-bot after creation.
        for secret in ("auth.json", ".env"):
            src = fleet_hermes_home() / secret
            dst = home / secret
            if src.is_file() and not dst.exists():
                try:
                    shutil.copy2(src, dst)
                except OSError:
                    pass  # best-effort; the engine falls back to env vars

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

    def _create_locked(self, agent_id: str, name: str, fields: dict | None = None) -> dict:
        fields = fields or {}
        agent_dir = self.root / agent_id
        sandbox = agent_dir / "sandbox"
        sandbox.mkdir(parents=True, exist_ok=True)
        profile = {
            "id": agent_id,
            "name": name,
            "title": name,
            "description": "",
            "persona": "",
            "model": None,
            "provider": None,
            "color": None,
            "emoji": None,
            "autonomy": "ask",
            "computer_use": False,
            "cua_targets": None,
            "stall_timeout_s": 180,
            "hard_timeout_s": 3600,
            "created_at": _utc_now_iso(),
            "updated_at": _utc_now_iso(),
            "sandbox_path": str(sandbox),
            "home_path": str(agent_dir / "home"),
            "schema_version": SCHEMA_VERSION,
        }
        # Overlay validated create fields onto the defaults BEFORE the first
        # materialization so the derived tree is born correct. Null text
        # fields keep their defaults (title falls back to the name).
        for key, value in fields.items():
            if value is None:
                continue
            if key in ("model", "provider"):
                profile[key] = value
            elif key == "computer_use":
                profile[key] = bool(value)
            elif key == "cua_targets":
                profile[key] = [str(t).strip() for t in value]
            elif key in ("stall_timeout_s", "hard_timeout_s"):
                profile[key] = float(value)
            else:
                profile[key] = str(value)
        self._write_profile(agent_id, profile)
        self._materialize_home_locked(agent_id, profile)
        self.agent_memory_dir(agent_id).mkdir(parents=True, exist_ok=True)
        self.shared_memory_dir().mkdir(parents=True, exist_ok=True)
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
        """Read a profile, migrating v1 → v2 in place when needed.

        Migration rewrites profile.json (idempotently) so every reader after
        the first sees v2 on disk. Unknown keys are preserved through both
        the read and the rewrite.
        """
        profile_path = self._agent_dir(agent_id) / _PROFILE_FILE
        try:
            profile = json.loads(profile_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise KeyError(agent_id) from exc
        if not isinstance(profile, dict) or profile.get("id") != agent_id:
            raise KeyError(agent_id)
        migrated, changed = migrate_v1_profile(profile, persona_backfill=_read_fleet_soul())
        if changed:
            # Reuse updated_at set by the migration; persist before returning.
            self._write_profile(agent_id, migrated)
            try:
                self._materialize_home_locked(agent_id, migrated)
            except OSError:
                pass  # home materialization is best-effort during load
        return migrated

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


# Repo root, resolved from this file: <root>/vertus/server/agent_registry.py.
# Used only to locate the templated skill files for home materialization.
_REPO_ROOT = Path(__file__).resolve().parents[2]
