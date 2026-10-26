"""Proactive routines: default seeding, the skills behind them, the sentinel.

Seeding is exercised against a REAL RunStore + AgentRegistry. Most tests
inject an accept-all validator and pin the stored schedule JSON — the
contract — never cron-parsing internals; one runs the real parser and
requires all three defaults to be accepted and created.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from agent_registry import PROACTIVE_SKILLS, AgentRegistry
from proactive_routines import (
    CHECK_IN_SENTINEL, DEFAULT_ROUTINES, LEDGER_FILE, OPT_OUT_ENV,
    is_nothing_to_report, seed_default_routines,
)
from run_store import RunStore

REPO_ROOT = Path(__file__).resolve().parents[2]
TZ = "America/New_York"
EXPECTED = {
    "morning-brief": "0 8 * * *",
    "check-in": "0 11,14,17 * * 1-5",
    "memory-consolidation": "0 3 * * *",
}


def _accept(schedule):
    return schedule


class FakeManager:
    def __init__(self):
        self.armed: list[tuple[str, dict]] = []

    def arm(self, routine_id, schedule):
        self.armed.append((routine_id, schedule))


@pytest.fixture()
def hub(tmp_path, monkeypatch):
    monkeypatch.setenv("VERTUS_ROOT", str(tmp_path / "vertus"))
    monkeypatch.delenv(OPT_OUT_ENV, raising=False)
    registry = AgentRegistry(root=str(tmp_path / "agents"))
    primary = registry.ensure_primary()["id"]
    store = RunStore(path=tmp_path / "fleet.db")
    yield {"registry": registry, "store": store, "primary": primary,
           "ledger": tmp_path / LEDGER_FILE}
    store.stop()


def _seed(hub, **kw):
    kw.setdefault("validate_schedule", _accept)
    kw.setdefault("env", {})
    return seed_default_routines(hub["store"], hub["registry"], kw.pop("manager", None), **kw)


def _rows(hub):
    return {r["name"]: r for r in hub["store"].list_routines(agent_id=hub["primary"])}


# --------------------------------------------------------------------------
# Seeding
# --------------------------------------------------------------------------

def test_seeding_creates_the_three_defaults_once(hub):
    mgr = FakeManager()
    first = _seed(hub, manager=mgr)
    assert sorted(first["created"]) == sorted(EXPECTED)
    rows = _rows(hub)
    assert set(rows) == set(EXPECTED)
    for name, cron in EXPECTED.items():
        row = rows[name]
        assert row["agent_id"] == hub["primary"]
        # No tz: the routine follows the Mac's CURRENT zone at compute time.
        assert json.loads(row["schedule"]) == {"cron": cron}
        assert row["trigger"] is None
        assert row["enabled"] == 1
    assert sorted(rid for rid, _ in mgr.armed) == sorted(r["routine_id"] for r in rows.values())

    mgr2 = FakeManager()
    again = _seed(hub, manager=mgr2)
    assert again["created"] == [] and sorted(again["kept"]) == sorted(EXPECTED)
    assert len(hub["store"].list_routines()) == 3
    assert mgr2.armed == []


def test_seeding_never_pins_the_boot_time_zone(hub, monkeypatch):
    """Even with a resolvable local zone, nothing is frozen into the row;
    pinning happens only when a caller passes tz explicitly."""
    monkeypatch.setenv("TZ", "Europe/Paris")
    _seed(hub)
    for row in hub["store"].list_routines():
        assert "tz" not in json.loads(row["schedule"])


def test_explicit_tz_is_pinned(hub):
    _seed(hub, tz=TZ)
    for name, cron in EXPECTED.items():
        assert json.loads(_rows(hub)[name]["schedule"]) == {"cron": cron, "tz": TZ}


def test_each_routine_prompt_invokes_its_materialized_skill(hub):
    _seed(hub)
    rows = _rows(hub)
    for default in DEFAULT_ROUTINES:
        assert default.skill in PROACTIVE_SKILLS
        assert default.skill in rows[default.name]["prompt"]
    assert CHECK_IN_SENTINEL in rows["check-in"]["prompt"]


def test_user_disabled_or_edited_routine_is_never_overridden(hub):
    _seed(hub)
    rows = _rows(hub)
    store = hub["store"]
    store.update_routine(rows["check-in"]["routine_id"], enabled=False)
    store.update_routine(rows["morning-brief"]["routine_id"], prompt="my own brief",
                         name="brief", schedule={"cron": "30 6 * * *", "tz": TZ})

    _seed(hub)
    after = {r["routine_id"]: r for r in store.list_routines()}
    assert len(after) == 3
    assert after[rows["check-in"]["routine_id"]]["enabled"] == 0
    brief = after[rows["morning-brief"]["routine_id"]]
    assert (brief["name"], brief["prompt"]) == ("brief", "my own brief")
    assert json.loads(brief["schedule"]) == {"cron": "30 6 * * *", "tz": TZ}


def test_deleted_default_is_not_recreated(hub):
    _seed(hub)
    hub["store"].delete_routine(_rows(hub)["check-in"]["routine_id"])
    _seed(hub)
    assert set(_rows(hub)) == {"morning-brief", "memory-consolidation"}


def test_lost_ledger_adopts_existing_routines_untouched(hub):
    _seed(hub)
    rows = _rows(hub)
    hub["store"].update_routine(rows["memory-consolidation"]["routine_id"], enabled=False)
    hub["ledger"].unlink()

    out = _seed(hub)
    assert out["created"] == [] and sorted(out["adopted"]) == sorted(EXPECTED)
    after = _rows(hub)
    assert len(hub["store"].list_routines()) == 3
    assert after["memory-consolidation"]["enabled"] == 0


def test_existing_user_routine_with_a_default_name_is_adopted(hub):
    hub["store"].create_routine(hub["primary"], "morning-brief", "user's own",
                                {"interval_s": 3600}, None, enabled=False)
    out = _seed(hub)
    assert out["adopted"] == ["morning-brief"]
    rows = _rows(hub)
    assert len(hub["store"].list_routines()) == 3
    assert rows["morning-brief"]["prompt"] == "user's own"
    assert rows["morning-brief"]["enabled"] == 0


@pytest.mark.parametrize("value", ["0", "off", "false", "NO"])
def test_opt_out_env_seeds_nothing(hub, monkeypatch, value):
    monkeypatch.setenv(OPT_OUT_ENV, value)
    out = seed_default_routines(hub["store"], hub["registry"], None,
                                validate_schedule=_accept)
    assert out["opted_out"] is True
    assert hub["store"].list_routines() == []
    assert not hub["ledger"].exists()


def test_opt_out_leaves_already_seeded_routines_alone(hub):
    _seed(hub)
    _seed(hub, env={OPT_OUT_ENV: "0"})
    assert len(hub["store"].list_routines()) == 3


def test_unsupported_schedule_is_skipped_then_seeded_by_a_later_build(hub):
    def reject(schedule):
        raise ValueError("schedule must be {\"interval_s\": N}")

    out = _seed(hub, validate_schedule=reject)
    assert out["created"] == [] and len(out["skipped"]) == 3
    assert hub["store"].list_routines() == []

    later = _seed(hub)
    assert sorted(later["created"]) == sorted(EXPECTED)


def test_seeding_with_the_running_parser_creates_all_three(hub):
    """The real scheduler parser (cron supported) accepts every default:
    all three are created, armed, and stored exactly as the parser
    normalizes them — none silently skipped."""
    from fleet_routines import parse_schedule

    mgr = FakeManager()
    out = seed_default_routines(hub["store"], hub["registry"], mgr, env={})
    assert out["skipped"] == []
    assert sorted(out["created"]) == sorted(EXPECTED)
    rows = _rows(hub)
    assert set(rows) == set(EXPECTED)
    for name, cron in EXPECTED.items():
        stored = json.loads(rows[name]["schedule"])
        assert stored == {"cron": cron}
        assert parse_schedule(stored) == stored
    assert len(mgr.armed) == 3


# --------------------------------------------------------------------------
# Skills
# --------------------------------------------------------------------------

def test_skills_are_materialized_into_a_fresh_agent_home(hub):
    agent = hub["registry"].create_agent("Scout")
    home = Path(agent["home_path"])
    mem_dir = str(hub["registry"].agent_memory_dir(agent["id"]))
    for name in PROACTIVE_SKILLS:
        text = (home / "skills" / name / "SKILL.md").read_text(encoding="utf-8")
        assert re.search(rf"^name: {re.escape(name)}$", text, re.M)
        assert "{{" not in text, f"unreplaced placeholder in {name}"
        assert mem_dir in text


def test_sentinel_matches_what_the_check_in_skill_instructs():
    text = (REPO_ROOT / "vertus" / "skills" / "vertus-check-in" / "SKILL.md").read_text()
    # The skill shows the exact reply on a line of its own.
    assert re.search(rf"^{re.escape(CHECK_IN_SENTINEL)}$", text, re.M)
    assert f"{len(CHECK_IN_SENTINEL)} characters" in text
    consolidation = (REPO_ROOT / "vertus" / "skills" / "vertus-memory-consolidation"
                     / "SKILL.md").read_text()
    assert f"`{CHECK_IN_SENTINEL}`" in consolidation


@pytest.mark.parametrize("reply,silent", [
    (CHECK_IN_SENTINEL, True),
    (f"  {CHECK_IN_SENTINEL}\n", True),
    (f"`{CHECK_IN_SENTINEL}`", True),
    (f"```\n{CHECK_IN_SENTINEL}\n```", True),
    (f"Sir, {CHECK_IN_SENTINEL} except one thing: the 3pm call.", False),
    ("", False),
    (None, False),
])
def test_is_nothing_to_report(reply, silent):
    assert is_nothing_to_report(reply) is silent
