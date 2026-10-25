"""Pure schedule math (routine_schedule.py): cron/at parsing and next_fire.

Every expectation is written as a wall time in a named zone so the tests
are independent of the machine's own zone. DST dates are America/New_York
2026: spring forward Sun 8 Mar (02:00 -> 03:00), fall back Sun 1 Nov
(02:00 -> 01:00).
"""

from __future__ import annotations

from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import pytest

import routine_schedule as rs
from routine_schedule import RoutineValidationError, next_fire, parse

NY = "America/New_York"
NYZ = ZoneInfo(NY)


def ny(*args, fold=0) -> float:
    return datetime(*args, tzinfo=NYZ, fold=fold).timestamp()


def wall(ts: float) -> tuple:
    d = datetime.fromtimestamp(ts, NYZ)
    return (d.year, d.month, d.day, d.hour, d.minute, d.utcoffset().total_seconds() / 3600)


def cron(expr, tz=NY):
    return {"cron": expr, "tz": tz}


NOW = ny(2026, 10, 25, 12, 0)  # a Sunday


# ----------------------------------------------------------------------
# Parsing
# ----------------------------------------------------------------------

def test_parse_valid_shapes_normalize():
    assert parse({"interval_s": 60}) == {"interval_s": 60}
    assert parse(None) is None
    assert parse({"cron": "  0  8 * *   *", "tz": NY}, now=NOW) == {"cron": "0 8 * * *", "tz": NY}
    assert parse({"cron": "*/15 9-17/2 1,15 1-12 0-7"}, now=NOW) == {"cron": "*/15 9-17/2 1,15 1-12 0-7"}
    assert parse({"at": "2026-10-26T09:00:00", "tz": NY}, now=NOW) == {"at": "2026-10-26T09:00:00", "tz": NY}
    assert parse({"at": "2026-10-26T13:00:00Z"}, now=NOW) == {"at": "2026-10-26T13:00:00Z"}


@pytest.mark.parametrize("bad", [
    {"cron": "0 8 * *"},                 # 4 fields
    {"cron": "0 8 * * * *"},             # 6 fields
    {"cron": "60 8 * * *"},              # minute out of range
    {"cron": "0 24 * * *"},              # hour out of range
    {"cron": "0 8 0 * *"},               # dom 0
    {"cron": "0 8 * 13 *"},              # month 13
    {"cron": "0 8 * * 8"},               # dow 8
    {"cron": "0 8 * * MON"},             # names are outside the dialect
    {"cron": "5-1 8 * * *"},             # reversed range
    {"cron": "*/0 8 * * *"},             # zero step
    {"cron": "5/10 8 * * *"},            # bare-number step
    {"cron": "0,,5 8 * * *"},            # empty list item
    {"cron": "@daily"},
    {"cron": "0 0 31 2 *"},              # never fires (Feb 31)
    {"cron": 5},
    {"cron": "0 8 * * *", "tz": "Mars/Olympus_Mons"},
    {"cron": "0 8 * * *", "tz": "../../etc/passwd"},
    {"cron": "0 8 * * *", "tz": ""},
    {"cron": "0 8 * * *", "extra": 1},
    {"cron": "0 8 * * *", "interval_s": 60},  # two kinds at once
    {"interval_s": 60, "tz": NY},
    {"at": "2026-10-24T09:00:00", "tz": NY},  # in the past
    {"at": "not a date"},
    {"at": ""},
    {"at": "2026-10-26T09:00:00", "tz": "Nowhere/Land"},
    {"tz": NY},
    {},
    "0 8 * * *",
])
def test_parse_rejects_invalid(bad):
    with pytest.raises(RoutineValidationError):
        parse(bad, now=NOW)


def test_parse_error_messages_name_the_problem():
    with pytest.raises(RoutineValidationError, match="minute"):
        parse({"cron": "99 8 * * *"}, now=NOW)
    with pytest.raises(RoutineValidationError, match="tz"):
        parse({"cron": "0 8 * * *", "tz": "Mars/Base"}, now=NOW)
    with pytest.raises(RoutineValidationError, match="future"):
        parse({"at": "2020-01-01T00:00:00Z"}, now=NOW)


# ----------------------------------------------------------------------
# Cron next_fire
# ----------------------------------------------------------------------

def test_daily_eight_am_crosses_day_boundary():
    s = cron("0 8 * * *")
    # Before 08:00 -> today; at/after 08:00 -> tomorrow (strictly after).
    assert wall(next_fire(s, ny(2026, 10, 25, 7, 59))) == (2026, 10, 25, 8, 0, -4)
    assert wall(next_fire(s, ny(2026, 10, 25, 8, 0))) == (2026, 10, 26, 8, 0, -4)
    assert wall(next_fire(s, ny(2026, 10, 25, 23, 30))) == (2026, 10, 26, 8, 0, -4)
    # Month/year boundary.
    assert wall(next_fire(s, ny(2026, 12, 31, 9, 0))) == (2027, 1, 1, 8, 0, -5)


def test_tz_is_honored():
    s = cron("0 8 * * *", tz="Asia/Tokyo")
    t = next_fire(s, NOW)
    d = datetime.fromtimestamp(t, ZoneInfo("Asia/Tokyo"))
    assert (d.hour, d.minute) == (8, 0)
    assert 0 < t - NOW <= 24 * 3600


def test_weekday_range_skips_weekend():
    s = cron("0 9 * * 1-5")
    fri_after = ny(2026, 10, 23, 9, 30)  # Friday after the 09:00 fire
    assert wall(next_fire(s, fri_after)) == (2026, 10, 26, 9, 0, -4)  # Monday
    assert wall(next_fire(s, ny(2026, 10, 24, 12, 0))) == (2026, 10, 26, 9, 0, -4)


def test_sunday_as_seven():
    assert next_fire(cron("0 9 * * 7"), NOW) == next_fire(cron("0 9 * * 0"), NOW)
    assert wall(next_fire(cron("0 9 * * 7"), NOW)) == (2026, 11, 1, 9, 0, -5)


def test_step_every_fifteen_minutes():
    s = cron("*/15 * * * *")
    t = ny(2026, 10, 25, 10, 7)
    fires = []
    for _ in range(5):
        t = next_fire(s, t)
        fires.append(wall(t)[3:5])
    assert fires == [(10, 15), (10, 30), (10, 45), (11, 0), (11, 15)]
    # Range with step.
    assert wall(next_fire(cron("0 9-17/4 * * *"), ny(2026, 10, 25, 13, 0)))[3:5] == (17, 0)


def test_dom_and_dow_both_restricted_is_or():
    # Day 1 of the month OR any Monday.
    s = cron("0 9 1 * 1")
    t = ny(2026, 10, 25, 12, 0)  # Sun 25 Oct
    seq = []
    for _ in range(3):
        t = next_fire(s, t)
        seq.append(wall(t)[:3])
    assert seq == [(2026, 10, 26), (2026, 11, 1), (2026, 11, 2)]  # Mon, the 1st (Sun), Mon


def test_star_dom_with_restricted_dow_is_and():
    # "*/2" in DOM starts with '*' -> not "restricted" for the OR rule: AND.
    s = cron("0 9 */2 * 1")  # odd days that are Mondays
    d = datetime.fromtimestamp(next_fire(s, NOW), NYZ)
    assert d.weekday() == 0 and d.day % 2 == 1


def test_dst_spring_forward_nonexistent_time_fires_at_next_valid_minute():
    s = cron("30 2 * * *")
    assert wall(next_fire(s, ny(2026, 3, 7, 0, 0))) == (2026, 3, 7, 2, 30, -5)
    t = next_fire(s, ny(2026, 3, 7, 12, 0))
    # 02:30 does not exist on 8 Mar: fires at 03:00 EDT, the first valid minute.
    assert wall(t) == (2026, 3, 8, 3, 0, -4)
    # And the day after is back to normal, exactly one fire on the gap day.
    t2 = next_fire(s, t)
    assert wall(t2) == (2026, 3, 9, 2, 30, -4)


def test_dst_spring_forward_gap_matches_collapse_to_one_fire():
    s = cron("*/15 2 * * *")
    t = next_fire(s, ny(2026, 3, 8, 1, 59))
    assert wall(t) == (2026, 3, 8, 3, 0, -4)
    assert wall(next_fire(s, t))[:3] == (2026, 3, 9)


def test_dst_fall_back_repeated_hour_fires_once():
    s = cron("30 1 * * *")
    t = next_fire(s, ny(2026, 10, 31, 12, 0))
    assert wall(t) == (2026, 11, 1, 1, 30, -4)  # first occurrence (EDT)
    t2 = next_fire(s, t)
    assert wall(t2) == (2026, 11, 2, 1, 30, -5)  # NOT 01:30 EST an hour later
    # A scheduler that wakes during the repeated hour (01:10 EST, after the
    # first 01:30 already happened) does not fire the repeat either.
    in_repeat = ny(2026, 11, 1, 1, 10, fold=1)
    assert wall(next_fire(s, in_repeat)) == (2026, 11, 2, 1, 30, -5)


def test_dst_fall_back_hourly_fires_once_per_wall_hour():
    s = cron("0 * * * *")
    t = ny(2026, 11, 1, 0, 30)
    walls = []
    for _ in range(4):
        t = next_fire(s, t)
        walls.append(wall(t)[3:])
    assert walls == [(1, 0, -4), (2, 0, -5), (3, 0, -5), (4, 0, -5)]


def test_cron_minute_resolution_never_fires_twice_a_minute():
    s = cron("* * * * *")
    t = ny(2026, 10, 25, 10, 0, 0)
    a = next_fire(s, t)
    assert a - t == 60
    assert next_fire(s, a) - a == 60
    assert next_fire(s, t + 0.5) == a


def test_default_tz_is_local_zone(monkeypatch):
    monkeypatch.setattr(rs, "local_zone", lambda: ZoneInfo("Asia/Tokyo"))
    t = next_fire({"cron": "0 8 * * *"}, NOW)
    d = datetime.fromtimestamp(t, ZoneInfo("Asia/Tokyo"))
    assert (d.hour, d.minute) == (8, 0)


# ----------------------------------------------------------------------
# One-shot and interval next_fire
# ----------------------------------------------------------------------

def test_at_next_fire_then_never_again():
    s = {"at": "2026-10-26T09:00:00", "tz": NY}
    t = next_fire(s, NOW)
    assert wall(t) == (2026, 10, 26, 9, 0, -4)
    assert next_fire(s, t) is None
    assert next_fire(s, t + 3600) is None


def test_at_with_offset_is_absolute_regardless_of_tz():
    s = {"at": "2026-10-26T13:00:00+00:00", "tz": "Asia/Tokyo"}
    assert next_fire(s, NOW) == datetime(2026, 10, 26, 13, tzinfo=timezone.utc).timestamp()


def test_at_in_spring_forward_gap_fires_at_next_valid_minute():
    s = {"at": "2027-03-14T02:30:00", "tz": NY}  # 2027 spring forward
    assert wall(next_fire(s, NOW)) == (2027, 3, 14, 3, 0, -4)


def test_interval_unchanged():
    assert next_fire({"interval_s": 60}, 1000.0) == 1060.0
    assert next_fire(None, 1000.0) is None
