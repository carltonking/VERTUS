"""One resolver per path root — the only place the hub derives state paths.

Why this module exists (the env-divergence sweep): each hub concept used to be
resolved independently by whichever module needed it, each with its own env
var and its own fallback. One of those fallbacks was a hardcoded
``~/.vertus`` (agent_registry's shared-memory dir) while the store resolved
the same concept from ``VERTUS_MEMORY_DIR`` — a hub pointed at a temp root
materialized skills that sent bots at the REAL user memory. The fix is
structural, not just that one line: no module resolves a root on its own
anymore; every fallback either derives from the configured root or is the
production default, and every resolver lives here.

Precedence rule, uniform across every resolver:
    1. the concept's own env var (VERTUS_MEMORY_DIR, VERTUS_AGENTS_DIR, …)
    2. ``VERTUS_ROOT`` if set — everything derives from it (temp hubs,
       hermetic tests)
    3. the production default (~/.vertus/…, ~/.hermes/…)

All resolvers read env at CALL time, never import time, so tests and temp
hubs can repoint the whole fleet with one export before boot.
"""

from __future__ import annotations

import os
from pathlib import Path

# The fork's per-agent config root env var (hermes fork: hermes_constants
# get_hermes_home → $HERMES_HOME → ~/.hermes). The hub injects it per agent;
# it is NOT a hub-side path resolver, listed here only as documentation.
HERMES_HOME_ENV = "HERMES_HOME"

_ROOT_ENV = "VERTUS_ROOT"


def _env(name: str) -> str:
    return os.environ.get(name, "").strip()


def vertus_root() -> Path:
    """The fleet state root: ~/.vertus, or VERTUS_ROOT for temp/hermetic hubs.

    Every default below derives from this when VERTUS_ROOT is set, so a hub
    booted with only VERTUS_ROOT pointed at a temp dir touches NOTHING under
    the real ~/.vertus (pinned by test_fleet_paths_hermetic).
    """
    env = _env(_ROOT_ENV)
    return Path(env).expanduser() if env else Path.home() / ".vertus"


def memory_root() -> Path:
    """Canonical memory root. VERTUS_MEMORY_DIR → root/memory."""
    env = _env("VERTUS_MEMORY_DIR")
    return Path(env).expanduser() if env else vertus_root() / "memory"


def shared_memory_dir() -> Path:
    """Fleet-wide shared memory. VERTUS_SHARED_MEMORY_DIR → memory/shared."""
    env = _env("VERTUS_SHARED_MEMORY_DIR")
    return Path(env).expanduser() if env else memory_root() / "shared"


def agents_dir() -> Path:
    """Per-agent state root. VERTUS_AGENTS_DIR → root/agents."""
    env = _env("VERTUS_AGENTS_DIR")
    return Path(env).expanduser() if env else vertus_root() / "agents"


def fleet_db_path() -> Path:
    """Run store. VERTUS_DB_PATH → root/fleet.db."""
    env = _env("VERTUS_DB_PATH")
    return Path(env).expanduser() if env else vertus_root() / "fleet.db"


def token_path() -> Path:
    """Bearer token file. VERTUS_TOKEN_PATH → root/token."""
    env = _env("VERTUS_TOKEN_PATH")
    return Path(env).expanduser() if env else vertus_root() / "token"


def approver_token_path() -> Path:
    """Approver credential. VERTUS_APPROVER_TOKEN_PATH → root/approver-token.

    Answering an approval needs it on top of the bearer token. Agents are
    told the bearer token (bot messaging) and never this one; the guard
    plugin blocks any tool call that names it or the approvals endpoint."""
    env = _env("VERTUS_APPROVER_TOKEN_PATH")
    return Path(env).expanduser() if env else vertus_root() / "approver-token"


def backups_dir() -> Path:
    """Migration backups. VERTUS_BACKUP_DIR → root/backups."""
    env = _env("VERTUS_BACKUP_DIR")
    return Path(env).expanduser() if env else vertus_root() / "backups"


def logs_dir() -> Path:
    """Hub logs. VERTUS_LOG_DIR → root/logs."""
    env = _env("VERTUS_LOG_DIR")
    return Path(env).expanduser() if env else vertus_root() / "logs"


def fleet_hermes_home() -> Path:
    """The fleet default engine config root (persona backfill + key copies).

    VERTUS_FLEET_HERMES_HOME → root/hermes when VERTUS_ROOT is set (hermetic
    hubs) → ~/.hermes (the real hermes install). Under VERTUS_ROOT the fork's
    legacy home must NOT be consulted, or a temp hub would backfill persona
    and copy provider keys from the user's real install.
    """
    env = _env("VERTUS_FLEET_HERMES_HOME")
    if env:
        return Path(env).expanduser()
    if _env(_ROOT_ENV):
        return vertus_root() / "hermes"
    return Path.home() / ".hermes"


def hub_url() -> str:
    """The URL the hub writes into per-agent FLEET.md (for bot-to-hub curl)."""
    return _env("VERTUS_HUB_URL") or "http://127.0.0.1:8787"


def fork_repo() -> Path:
    """The hermes fork checkout the gateway runs from (an install, not state;
    identical for every hub, so it never derives from VERTUS_ROOT)."""
    env = _env("VERTUS_HERMES_REPO")
    return Path(env).expanduser() if env else Path.home() / ".hermes" / "hermes-agent"


def venv_python() -> Path:
    """Python interpreter inside the fork's venv.

    Hermes updates (Oct 2026) stopped keeping ``venv/`` in the checkout: the
    installer builds the environment under ``~/.hermes/installs/<id>/
    environments/<id>/venv`` and the old path vanishes, which left every
    gateway spawn failing and every run ending as an empty ``done``. For the
    production fork only (no repo override), fall back to the newest managed
    venv; an overridden fork (tests, temp hubs) keeps the strict path so a
    missing venv still fails loudly.
    """
    env = _env("VERTUS_HERMES_PYTHON")
    if env:
        return Path(env).expanduser()
    legacy = fork_repo() / "venv" / "bin" / "python"
    if legacy.exists() or _env("VERTUS_HERMES_REPO"):
        return legacy
    # Newest environment by the venv directory's own mtime: the python inside
    # is a symlink to one shared interpreter, so its mtime ties for all.
    managed = sorted(
        (Path.home() / ".hermes" / "installs").glob("*/environments/*/venv/bin/python"),
        key=lambda p: p.parents[1].lstat().st_mtime if p.exists() else 0.0,
    )
    return managed[-1] if managed else legacy


def cua_manifest_override() -> str:
    """VERTUS_CUA_MANIFEST — the per-agent capability-manifest source, or \"\"."""
    return _env("VERTUS_CUA_MANIFEST")