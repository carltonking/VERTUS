"""Default proactive routines: the work that makes VERTUS reach out first.

Three routines are seeded for the primary agent at hub boot, each a thin
prompt that invokes a skill (vertus/skills/<name>/SKILL.md, materialized into
every agent home by agent_registry) where the actual procedure lives:

    morning-brief         08:00 daily          vertus-morning-brief
    check-in              11:00/14:00/17:00    vertus-check-in
                          on weekdays
    memory-consolidation  03:00 daily          vertus-memory-consolidation

Schedules use the clock-time schedule contract of fleet_routines
(``{"cron": "M H DOM MON DOW"}``) with ``tz`` OMITTED: an omitted zone
follows the Mac's current zone at compute time (routine_schedule), so the
08:00 brief stays 08:00 after the user travels or changes System Settings.
Pinning the boot-time zone would freeze it to wherever the hub first ran.
Routines seeded by older builds with a pinned ``tz`` are left as they are —
seeding never rewrites user state; PATCH the schedule to unpin one.

Prepare and suggest, never act outward. Routines run unattended, and every
hub agent asks before sending, posting or deleting (vertus-guard + approvals
mode manual), so a routine that tried would just stall on an approval nobody
is awake to give. The skills read, rank and offer; the user says yes later.

SILENCE SENTINEL. A check-in (or a consolidation that changed nothing) that
finds nothing worth the user's attention replies with exactly
``NOTHING_TO_REPORT`` and nothing else. Clients (the island, the phone) must
treat a final reply equal to it — see ``is_nothing_to_report`` — as "stay
silent": no notification, no badge. The skill text carries the same literal;
a test pins the two together.

SEEDING POLICY (idempotent, never overrides the user):
  * A ledger file next to the run store (``proactive-routines.json``)
    records each default once it exists. A default in the ledger is never
    seeded again — whatever the user did to it since (edited, disabled,
    deleted) stands. Deleting a seeded routine is how a user opts out of one.
  * Without a ledger entry, an existing routine of the agent carrying the
    default's marker in its prompt, or its exact name, is ADOPTED into the
    ledger untouched (a lost ledger never produces duplicates and never
    rewrites a user's edit or re-enables a disabled routine).
  * Only then is the routine created (enabled) and armed.
  * A schedule the running scheduler rejects (the clock-time contract not
    yet supported by this build) is skipped WITHOUT a ledger entry, so the
    next boot on a build that understands it seeds it.

OPT-OUT: ``VERTUS_PROACTIVE_ROUTINES=0`` (or off/false/no) in the hub's
environment skips seeding entirely. Already-seeded routines are untouched —
disable or delete them through /api/routines.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

log = logging.getLogger("vertus.proactive")

# The exact reply that means "nothing worth saying" — clients stay silent.
CHECK_IN_SENTINEL = "NOTHING_TO_REPORT"

OPT_OUT_ENV = "VERTUS_PROACTIVE_ROUTINES"
_OFF_VALUES = frozenset({"0", "off", "false", "no", "disabled"})

LEDGER_FILE = "proactive-routines.json"
MARKER_PREFIX = "vertus-proactive:"


def is_nothing_to_report(reply: str | None) -> bool:
    """True when a routine's final reply is the silence sentinel.

    Tolerates surrounding whitespace and a stray code fence/backticks or
    quotes (models occasionally wrap a bare token), nothing more: a reply
    that merely CONTAINS the sentinel among other words is a real message.
    """
    if not reply:
        return False
    text = reply.strip()
    if text.startswith("```") and text.endswith("```"):
        text = text[3:-3].strip()
    return text.strip("`'\" \n\t") == CHECK_IN_SENTINEL


@dataclass(frozen=True)
class DefaultRoutine:
    key: str      # stable identity: ledger key + prompt marker
    name: str     # routine name as created (also the adoption fallback)
    skill: str    # skill the prompt invokes (agent_registry.PROACTIVE_SKILLS)
    cron: str     # "M H DOM MON DOW", local time
    task: str     # one line of routine-specific instruction

    @property
    def marker(self) -> str:
        return f"[{MARKER_PREFIX}{self.key}]"


DEFAULT_ROUTINES: tuple[DefaultRoutine, ...] = (
    DefaultRoutine(
        key="morning-brief", name="morning-brief", skill="vertus-morning-brief",
        cron="0 8 * * *",
        task="Prepare this morning's brief.",
    ),
    DefaultRoutine(
        key="check-in", name="check-in", skill="vertus-check-in",
        cron="0 11,14,17 * * 1-5",
        task=("Look for loose ends worth raising now. If nothing clears the "
              f"bar, reply with exactly {CHECK_IN_SENTINEL} and nothing else."),
    ),
    DefaultRoutine(
        key="memory-consolidation", name="memory-consolidation",
        skill="vertus-memory-consolidation", cron="0 3 * * *",
        task=("Consolidate memory, keeping a record of every change. If nothing "
              "changed and nothing needs flagging, reply with exactly "
              f"{CHECK_IN_SENTINEL}."),
    ),
)


def routine_prompt(default: DefaultRoutine) -> str:
    """The seeded prompt: marker, the skill to follow, and the outward-action
    boundary restated (the skill says it too; a user-edited skill must not be
    the only thing between an unattended run and an outward action)."""
    return (
        f"{default.marker} Scheduled routine, running unattended. "
        f"Load your `{default.skill}` skill (skill_view) and follow it exactly. "
        f"{default.task} Prepare and suggest only: do not send, reply, post, "
        "accept, delete or change anything outside your own memory directory — "
        "offer those steps as suggested actions instead."
    )


def default_schedule(default: DefaultRoutine, tz: Optional[str] = None) -> dict:
    """The seeded schedule: no ``tz`` (follow the Mac's zone) unless a caller
    explicitly pins one."""
    return {"cron": default.cron, "tz": tz} if tz else {"cron": default.cron}


def seeding_enabled(env: Optional[dict] = None) -> bool:
    value = (env if env is not None else os.environ).get(OPT_OUT_ENV, "")
    return value.strip().lower() not in _OFF_VALUES


def _default_validator() -> Callable[[dict], object]:
    """The running scheduler's own schedule parser — the authority on which
    schedule shapes this build can fire."""
    try:
        from fleet_routines import parse_schedule  # type: ignore
    except ImportError:  # pragma: no cover - package invocation
        from .fleet_routines import parse_schedule  # type: ignore
    return parse_schedule


def _ledger_path_for(store) -> Path:
    return Path(store.path).parent / LEDGER_FILE


def _read_ledger(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"version": 1, "seeded": {}}
    if not isinstance(data, dict) or not isinstance(data.get("seeded"), dict):
        return {"version": 1, "seeded": {}}
    return data


def _write_ledger(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _find_existing(routines: list[dict], default: DefaultRoutine) -> dict | None:
    for row in routines:
        if default.marker in str(row.get("prompt") or ""):
            return row
    for row in routines:
        if str(row.get("name") or "") == default.name:
            return row
    return None


def seed_default_routines(store, registry, manager=None, *,
                          agent_id: Optional[str] = None,
                          tz: Optional[str] = None,
                          ledger_path: Optional[Path] = None,
                          validate_schedule: Optional[Callable[[dict], object]] = None,
                          env: Optional[dict] = None) -> dict:
    """Seed the default proactive routines for the primary agent, once.

    Call at hub boot after the store and RoutineManager exist and before
    ``routines.catch_up()``. Returns a summary
    ``{"opted_out", "agent_id", "created", "adopted", "kept", "skipped"}``
    (lists of routine keys; ``skipped`` holds ``(key, reason)`` pairs).
    Never raises for one bad routine — the others still seed.
    """
    summary: dict = {"opted_out": False, "agent_id": None, "created": [],
                     "adopted": [], "kept": [], "skipped": []}
    if not seeding_enabled(env):
        summary["opted_out"] = True
        return summary
    if agent_id is None:
        agent_id = registry.ensure_primary()["id"]
    summary["agent_id"] = agent_id
    validate = validate_schedule or _default_validator()
    path = ledger_path or _ledger_path_for(store)
    ledger = _read_ledger(path)
    seeded: dict = ledger["seeded"]
    existing = store.list_routines(agent_id=agent_id)
    dirty = False

    for default in DEFAULT_ROUTINES:
        slot = f"{agent_id}:{default.key}"
        if slot in seeded:
            summary["kept"].append(default.key)  # the user's choices stand
            continue
        found = _find_existing(existing, default)
        if found is not None:
            seeded[slot] = {"routine_id": found["routine_id"], "adopted": True,
                            "at": time.time()}
            summary["adopted"].append(default.key)
            dirty = True
            continue
        schedule = default_schedule(default, tz)
        try:
            validate(schedule)
        except ValueError as exc:  # RoutineValidationError subclasses ValueError
            # No ledger entry: a later build that understands the schedule
            # seeds it on its first boot.
            summary["skipped"].append((default.key, f"schedule unsupported: {exc}"))
            continue
        try:
            row = store.create_routine(agent_id, default.name, routine_prompt(default),
                                       schedule, None, enabled=True)
        except Exception as exc:  # noqa: BLE001
            log.exception("seeding routine %s failed", default.key)
            summary["skipped"].append((default.key, f"create failed: {exc}"))
            continue
        if manager is not None:
            manager.arm(row["routine_id"], schedule)
        seeded[slot] = {"routine_id": row["routine_id"], "at": time.time()}
        existing.append(row)
        summary["created"].append(default.key)
        dirty = True

    if dirty:
        try:
            _write_ledger(path, ledger)
        except OSError:
            # Adoption by marker/name keeps the next boot from duplicating.
            log.exception("could not write proactive routine ledger %s", path)
    return summary
