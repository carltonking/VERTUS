"""Routine schedules: parsing and "next fire after t" — pure, stdlib only.

Three shapes, exactly one per schedule (see fleet_routines for why wall-clock
schedules exist at all):

    {"interval_s": N}
        every N seconds, measured from the previous fire. N int >= 30.
    {"cron": "M H DOM MON DOW", "tz": "America/New_York"}
        standard 5-field cron. Items: ``*``, ``n``, ``a-b``, ``*/n``,
        ``a-b/n``, comma lists of those. DOW 0-7 (0 and 7 = Sunday). No
        names (MON/JAN), no ``@daily`` macros, no seconds field — keep the
        vocabulary small and enumerable. Vixie day semantics: when BOTH the
        DOM and DOW fields are restricted (do not start with ``*``) a day
        matches if EITHER matches; otherwise both must (the ``*`` one is
        trivially true).
    {"at": "2026-10-26T09:00:00", "tz": "America/New_York"}
        one-shot. Naive ISO 8601 = wall time in ``tz``; with an offset (or
        ``Z``) = that absolute instant. Must be in the future when parsed.

``tz`` is an IANA key resolved via ``zoneinfo``; optional. When absent the
schedule follows the Mac's CURRENT local zone at compute time (so a "08:00"
brief stays 08:00 wherever the laptop is) — it is deliberately not frozen to
the zone at creation time.

DST (wall-clock schedules only; intervals are plain seconds):
  * spring-forward gap — a wall time that does not exist that day (02:30 in
    America/New_York) fires at the first valid minute after the gap (03:00).
    Several gap matches collapse into that one fire.
  * fall-back repeat — a wall time that occurs twice fires once, on its
    FIRST occurrence; the repeated pass is skipped (a wall time that already
    happened today does not happen again).

A cron fires at most once per minute by construction (minute resolution,
"strictly after" search), so no minimum spacing is enforced for it.
"""

from __future__ import annotations

import os
import time
from datetime import date, datetime, time as dtime, timedelta, timezone
from zoneinfo import ZoneInfo

MIN_INTERVAL_S = 30

# A restricted cron (e.g. "0 0 29 2 *", Feb 29) may legitimately be years
# away; 8 years covers the longest leap-day gap (2096 -> 2104). Anything that
# does not match inside this window never fires and is rejected at parse.
_SEARCH_DAYS = 366 * 9

_FIELDS = (
    # name, lo, hi
    ("minute", 0, 59),
    ("hour", 0, 23),
    ("day-of-month", 1, 31),
    ("month", 1, 12),
    ("day-of-week", 0, 7),
)


class RoutineValidationError(ValueError):
    """A routine payload violates the schema (400 on the wire)."""


# ----------------------------------------------------------------------
# Parsing
# ----------------------------------------------------------------------

def parse(raw, now: float | None = None) -> dict | None:
    """Validate a schedule payload and return its normalized form.

    None = no schedule (trigger-only routine). ``now`` is the reference for
    the one-shot "must be in the future" check (default: time.time()).
    """
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise RoutineValidationError(
            'schedule must be {"interval_s": N}, {"cron": "M H DOM MON DOW", '
            '"tz": ...} or {"at": "<ISO 8601>", "tz": ...}'
        )
    kinds = [k for k in ("interval_s", "cron", "at") if k in raw]
    if len(kinds) != 1:
        raise RoutineValidationError(
            "schedule needs exactly one of interval_s, cron, at"
        )
    kind = kinds[0]
    allowed = {"interval_s"} if kind == "interval_s" else {kind, "tz"}
    extra = set(raw) - allowed
    if extra:
        raise RoutineValidationError(
            f"unknown schedule keys for {kind}: {sorted(extra)}"
        )

    if kind == "interval_s":
        interval = raw["interval_s"]
        if (not isinstance(interval, int) or isinstance(interval, bool)
                or interval < MIN_INTERVAL_S):
            raise RoutineValidationError(
                f"schedule interval_s must be an integer >= {MIN_INTERVAL_S}"
            )
        return {"interval_s": interval}

    out: dict = {}
    if "tz" in raw:
        _zone(raw["tz"])  # validates
        out["tz"] = raw["tz"]

    if kind == "cron":
        expr = raw["cron"]
        if not isinstance(expr, str):
            raise RoutineValidationError("schedule cron must be a string")
        expr = " ".join(expr.split())
        _parse_cron(expr)  # validates every field
        sched = {"cron": expr, **out}
        if next_fire(sched, now if now is not None else _time_now()) is None:
            raise RoutineValidationError(
                f"schedule cron {expr!r} never fires (no matching date)"
            )
        return sched

    # one-shot
    at = raw["at"]
    if not isinstance(at, str) or not at.strip():
        raise RoutineValidationError("schedule at must be an ISO 8601 string")
    at = at.strip()
    sched = {"at": at, **out}
    instant = _at_instant(sched)
    ref = now if now is not None else _time_now()
    if instant <= ref:
        raise RoutineValidationError(
            f"schedule at {at!r} is not in the future"
        )
    return sched


def kind_of(schedule: dict | None) -> str | None:
    """'interval' | 'cron' | 'at' | None for a normalized schedule."""
    if not schedule:
        return None
    if "interval_s" in schedule:
        return "interval"
    if "cron" in schedule:
        return "cron"
    if "at" in schedule:
        return "at"
    return None


def _zone(key) -> ZoneInfo:
    if not isinstance(key, str) or not key:
        raise RoutineValidationError("schedule tz must be an IANA zone name string")
    try:
        return ZoneInfo(key)
    except Exception:  # noqa: BLE001 — ZoneInfoNotFoundError, ValueError on bad keys
        raise RoutineValidationError(f"unknown schedule tz: {key!r}") from None


def _parse_cron(expr: str) -> tuple:
    """-> (minutes, hours, doms, months, dows, dom_restricted, dow_restricted)
    with each value set a frozenset of ints; DOW 7 is folded to 0."""
    parts = expr.split(" ")
    if len(parts) != 5:
        raise RoutineValidationError(
            f"schedule cron must have 5 fields (M H DOM MON DOW), got {len(parts)}"
        )
    sets = []
    for text, (name, lo, hi) in zip(parts, _FIELDS):
        sets.append(_parse_field(text, name, lo, hi))
    dows = frozenset(0 if d == 7 else d for d in sets[4])
    return (sets[0], sets[1], sets[2], sets[3], dows,
            not parts[2].startswith("*"), not parts[4].startswith("*"))


def _parse_field(text: str, name: str, lo: int, hi: int) -> frozenset:
    values: set[int] = set()
    for item in text.split(","):
        if not item:
            raise RoutineValidationError(f"cron {name} field {text!r} has an empty item")
        base, sep, step_txt = item.partition("/")
        step = 1
        if sep:
            step = _int(step_txt, name, item)
            if step < 1:
                raise RoutineValidationError(f"cron {name} step must be >= 1 in {item!r}")
        if base == "*":
            start, end = lo, hi
        elif "-" in base:
            a_txt, _, b_txt = base.partition("-")
            start, end = _int(a_txt, name, item), _int(b_txt, name, item)
            if start > end:
                raise RoutineValidationError(f"cron {name} range {item!r} is reversed")
        else:
            if sep:
                # "5/10" is a Vixie-ism outside the contract: be explicit.
                raise RoutineValidationError(
                    f"cron {name} step needs '*' or a range before '/': {item!r}"
                )
            start = end = _int(base, name, item)
        if start < lo or end > hi:
            raise RoutineValidationError(
                f"cron {name} value out of range {lo}-{hi} in {item!r}"
            )
        values.update(range(start, end + 1, step))
    return frozenset(values)


def _int(txt: str, name: str, item: str) -> int:
    if not txt.isdigit():  # rejects '', '-1', names like MON
        raise RoutineValidationError(f"cron {name} item {item!r} is not a number")
    return int(txt)


# ----------------------------------------------------------------------
# Next fire
# ----------------------------------------------------------------------

def next_fire(schedule: dict | None, after: float) -> float | None:
    """Epoch seconds of the first fire STRICTLY after ``after``; None when
    the schedule will never fire again (a one-shot whose time has passed,
    no schedule, or an unrecognized/corrupt one)."""
    kind = kind_of(schedule)
    if kind == "interval":
        try:
            interval = int(schedule["interval_s"])
        except (ValueError, TypeError):
            return None
        return after + interval if interval > 0 else None
    if kind == "at":
        instant = _at_instant(schedule)
        return instant if instant > after else None
    if kind == "cron":
        return _cron_next(schedule, after)
    return None


def _schedule_zone(schedule: dict):
    key = schedule.get("tz")
    return _zone(key) if key else local_zone()


def local_zone():
    """The Mac's current zone: $TZ, then the /etc/localtime symlink target
    (how macOS records the System Settings zone), then the C library's fixed
    current offset as a last resort (no DST knowledge, but never wrong *now*)."""
    key = os.environ.get("TZ", "").lstrip(":")
    if key:
        try:
            return ZoneInfo(key)
        except Exception:  # noqa: BLE001
            pass
    try:
        target = os.path.realpath("/etc/localtime")
        marker = "zoneinfo/"
        if marker in target:
            return ZoneInfo(target.split(marker, 1)[1])
    except Exception:  # noqa: BLE001
        pass
    return datetime.now().astimezone().tzinfo or timezone.utc


def _at_instant(schedule: dict) -> float:
    try:
        when = datetime.fromisoformat(schedule["at"])
    except (ValueError, TypeError):
        raise RoutineValidationError(
            f"schedule at {schedule.get('at')!r} is not ISO 8601"
        ) from None
    if when.tzinfo is not None:
        return when.timestamp()
    return _wall_instant(when, _schedule_zone(schedule))


def _wall_instant(wall: datetime, zone) -> float:
    """Absolute time of a naive wall time in ``zone``.

    Ambiguous (fall-back) -> first occurrence (fold=0). Nonexistent
    (spring-forward gap) -> the first existing minute after it, i.e. the
    instant the clocks jumped."""
    if _exists(wall, zone):
        return wall.replace(tzinfo=zone, fold=0).timestamp()
    probe = wall.replace(second=0, microsecond=0)
    for _ in range(60 * 48):  # gaps are <= 1 day (Samoa 2011); bounded anyway
        probe += timedelta(minutes=1)
        if _exists(probe, zone):
            return probe.replace(tzinfo=zone, fold=0).timestamp()
    return wall.replace(tzinfo=zone, fold=0).timestamp()  # pragma: no cover


def _exists(wall: datetime, zone) -> bool:
    aware = wall.replace(tzinfo=zone, fold=0)
    back = aware.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None)
    return back == wall


def _cron_next(schedule: dict, after: float) -> float | None:
    try:
        mins, hours, doms, months, dows, dom_r, dow_r = _parse_cron(schedule["cron"])
        zone = _schedule_zone(schedule)
    except (RoutineValidationError, TypeError, KeyError):
        return None
    minutes = sorted(mins)
    hours_sorted = sorted(hours)
    start = datetime.fromtimestamp(after, zone).replace(tzinfo=None)
    # Strictly after: the first candidate is the next whole wall minute.
    first = start.replace(second=0, microsecond=0) + timedelta(minutes=1)
    day: date = first.date()
    for _ in range(_SEARCH_DAYS):
        if day.month in months and _day_matches(day, doms, dows, dom_r, dow_r):
            for h in hours_sorted:
                for m in minutes:
                    wall = datetime.combine(day, dtime(h, m))
                    if wall < first:
                        continue
                    # Candidates are visited in wall order and _wall_instant
                    # is monotonic in wall order, so the first one strictly
                    # after ``after`` is the earliest fire. A fall-back wall
                    # time whose first occurrence already passed lands <=
                    # after here and is skipped: repeated hours fire once.
                    instant = _wall_instant(wall, zone)
                    if instant > after:
                        return instant
        day += timedelta(days=1)
    return None


def _day_matches(day: date, doms, dows, dom_r: bool, dow_r: bool) -> bool:
    dom_ok = day.day in doms
    dow_ok = ((day.weekday() + 1) % 7) in dows  # cron: Sunday = 0
    if dom_r and dow_r:
        return dom_ok or dow_ok  # Vixie: both restricted -> either
    return dom_ok and dow_ok


def _time_now() -> float:
    return time.time()
