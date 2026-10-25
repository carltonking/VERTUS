"""Hermes-shipped app skills reach every agent home (step 4: connect apps).

The hub spawns the gateway directly, so the engine's own bundled-skill
seeding never runs for an agent home. The registry copies the selected app
skills from the Hermes checkout instead — only when the CLI each one drives
is on PATH, only the hub's own copies are ever replaced or removed, and
VERTUS_HERMES_SKILLS opts out or in.

Every test points the registry at a temp agents dir, a fake Hermes checkout
(VERTUS_HERMES_REPO) and a PATH holding only fake CLIs, so the real machine
decides nothing here.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agent_registry  # noqa: E402
from agent_registry import AgentRegistry, hermes_skill_selection  # noqa: E402


def _skill(root: Path, rel: str, commands: list[str] | None = None, body: str = "") -> Path:
    d = root / rel
    (d / "scripts").mkdir(parents=True, exist_ok=True)
    name = rel.rsplit("/", 1)[-1]
    prereq = f"prerequisites:\n  commands: [{', '.join(commands)}]\n" if commands else ""
    (d / "SKILL.md").write_text(f"---\nname: {name}\ndescription: test\n{prereq}---\n{body}\n", encoding="utf-8")
    (d / "scripts" / "run.sh").write_text("echo hi\n", encoding="utf-8")
    return d


@pytest.fixture()
def env(tmp_path, monkeypatch):
    repo = tmp_path / "hermes-agent"
    _skill(repo / "skills", "apple/apple-notes", ["memo"], "notes v1")
    _skill(repo / "skills", "apple/imessage", ["imsg"])
    _skill(repo / "skills", "apple/apple-reminders", ["remindctl"])
    _skill(repo / "skills", "software-development/github")  # declares no prerequisites
    _skill(repo / "optional-skills", "smart-home/openhue", ["openhue"])
    _skill(repo / "skills", "productivity/google-workspace")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()

    def install(*names):
        for n in names:
            p = bin_dir / n
            p.write_text("#!/bin/sh\n", encoding="utf-8")
            p.chmod(0o755)

    monkeypatch.setenv("VERTUS_HERMES_REPO", str(repo))
    monkeypatch.setenv("PATH", str(bin_dir))
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet"))
    monkeypatch.delenv("VERTUS_HERMES_SKILLS", raising=False)
    return type("Env", (), {"repo": repo, "install": staticmethod(install),
                            "registry": AgentRegistry(), "bin": bin_dir})


def _skills(registry, agent_id="primary") -> Path:
    return registry.agent_home(agent_id) / "skills"


def test_default_skills_land_in_every_home_with_their_category_layout(env):
    env.install("memo", "gh", "imsg", "remindctl")
    env.registry.ensure_primary()
    env.registry.create_agent("Scout")
    for agent_id in ("primary", "scout"):
        skills = _skills(env.registry, agent_id)
        # The category path is kept: skills call their own scripts at
        # $HERMES_HOME/skills/<category>/<name>/scripts.
        assert (skills / "apple" / "apple-notes" / "SKILL.md").is_file()
        assert (skills / "apple" / "apple-notes" / "scripts" / "run.sh").is_file()
        assert (skills / "software-development" / "github" / "SKILL.md").is_file()
        # The hub's own skills are still there.
        assert (skills / "vertus-memory" / "SKILL.md").is_file() or not \
            (agent_registry._REPO_ROOT / "vertus" / "extensions" / "memory-skill" / "SKILL.md").is_file()


def test_send_and_delete_capable_skills_stay_off_by_default(env):
    # Their CLIs are present, but the guard does not yet stop `imsg send` or
    # `remindctl delete`; and nothing needing an account is turned on.
    env.install("memo", "gh", "imsg", "remindctl", "openhue")
    env.registry.ensure_primary()
    skills = _skills(env.registry)
    assert not (skills / "apple" / "imessage").exists()
    assert not (skills / "apple" / "apple-reminders").exists()
    assert not (skills / "smart-home" / "openhue").exists()
    assert not (skills / "productivity" / "google-workspace").exists()


def test_a_skill_whose_cli_is_missing_is_not_installed(env):
    env.install("gh")  # no memo
    env.registry.ensure_primary()
    skills = _skills(env.registry)
    assert not (skills / "apple" / "apple-notes").exists()
    assert (skills / "software-development" / "github").is_dir()


def test_github_needs_gh_even_though_its_frontmatter_lists_nothing(env):
    env.install("memo")
    env.registry.ensure_primary()
    assert not (_skills(env.registry) / "software-development" / "github").exists()


def test_uninstalling_the_cli_removes_the_skill_at_the_next_boot(env):
    env.install("memo", "gh")
    env.registry.ensure_primary()
    notes = _skills(env.registry) / "apple" / "apple-notes"
    assert notes.is_dir()
    (env.bin / "memo").unlink()
    assert env.registry.rematerialize_all() == []
    assert not notes.exists()
    assert not notes.parent.exists(), "an emptied category dir is cleaned up"


def test_opt_out_removes_only_the_hubs_copies(env, monkeypatch):
    env.install("memo", "gh")
    env.registry.ensure_primary()
    skills = _skills(env.registry)
    own = skills / "my-own-skill"
    own.mkdir()
    (own / "SKILL.md").write_text("mine\n", encoding="utf-8")
    monkeypatch.setenv("VERTUS_HERMES_SKILLS", "off")
    assert env.registry.rematerialize_all() == []
    assert not (skills / "apple" / "apple-notes").exists()
    assert not (skills / "software-development" / "github").exists()
    assert (own / "SKILL.md").read_text(encoding="utf-8") == "mine\n"


def test_opt_in_adds_a_held_back_skill(env, monkeypatch):
    env.install("memo", "gh", "imsg")
    monkeypatch.setenv("VERTUS_HERMES_SKILLS", "+imessage,-github")
    env.registry.ensure_primary()
    skills = _skills(env.registry)
    assert (skills / "apple" / "imessage" / "SKILL.md").is_file()
    assert (skills / "apple" / "apple-notes").is_dir()
    assert not (skills / "software-development" / "github").exists()


def test_optional_skills_are_found_too(env, monkeypatch):
    env.install("openhue")
    monkeypatch.setenv("VERTUS_HERMES_SKILLS", "openhue")
    env.registry.ensure_primary()
    assert (_skills(env.registry) / "smart-home" / "openhue" / "SKILL.md").is_file()


def test_an_agents_own_skill_with_the_same_name_is_never_overwritten(env):
    env.install("memo", "gh")
    home_skills = env.registry.root / "primary" / "home" / "skills"
    mine = home_skills / "apple" / "apple-notes"
    mine.mkdir(parents=True)
    (mine / "SKILL.md").write_text("my notes skill\n", encoding="utf-8")
    env.registry.ensure_primary()
    assert (mine / "SKILL.md").read_text(encoding="utf-8") == "my notes skill\n"
    env.registry.rematerialize_all()
    assert (mine / "SKILL.md").read_text(encoding="utf-8") == "my notes skill\n"


def test_an_engine_update_reaches_homes_at_the_next_boot(env):
    env.install("memo")
    env.registry.ensure_primary()
    skill_md = _skills(env.registry) / "apple" / "apple-notes" / "SKILL.md"
    assert "notes v1" in skill_md.read_text(encoding="utf-8")
    _skill(env.repo / "skills", "apple/apple-notes", ["memo"], "notes v2")
    env.registry.rematerialize_all()
    assert "notes v2" in skill_md.read_text(encoding="utf-8")


def test_a_missing_hermes_checkout_still_materializes_the_home(env, monkeypatch, tmp_path):
    monkeypatch.setenv("VERTUS_HERMES_REPO", str(tmp_path / "nowhere"))
    env.install("memo", "gh")
    agent = env.registry.ensure_primary()
    home = Path(agent["home_path"])
    assert (home / "config.yaml").is_file() and (home / "SOUL.md").is_file()


def test_the_manifest_records_what_the_hub_installed(env):
    env.install("memo", "gh")
    env.registry.ensure_primary()
    manifest = json.loads((_skills(env.registry) / agent_registry.HERMES_SKILLS_MANIFEST)
                          .read_text(encoding="utf-8"))
    assert manifest == {"apple-notes": "apple/apple-notes",
                        "github": "software-development/github"}


@pytest.mark.parametrize("spec, expected", [
    (None, list(agent_registry.HERMES_SKILLS_DEFAULT)),
    ("", []),
    ("off", []),
    ("NONE", []),
    ("imessage", ["imessage"]),
    ("apple-notes, imessage", ["apple-notes", "imessage"]),
    ("+imessage", [*agent_registry.HERMES_SKILLS_DEFAULT, "imessage"]),
    ("-github", [n for n in agent_registry.HERMES_SKILLS_DEFAULT if n != "github"]),
    ("imessage +openhue -imessage", ["openhue"]),
    ("../etc,apple-notes", ["apple-notes"]),  # never a path
])
def test_selection_spec(spec, expected):
    assert hermes_skill_selection(spec) == expected


def test_a_per_agent_skills_disabled_list_survives_rematerialization(env):
    # Hermes's own per-home opt-out (skills.disabled) is the per-agent switch;
    # the hub must not forget it when it re-derives config.yaml at boot.
    env.install("memo", "gh")
    env.registry.ensure_primary()
    cfg_path = env.registry.agent_home("primary") / "config.yaml"
    cfg = agent_registry._yaml_load(cfg_path.read_text(encoding="utf-8"))
    cfg["skills"] = {"disabled": ["github"]}
    cfg_path.write_text(agent_registry._yaml_dump(cfg), encoding="utf-8")
    assert env.registry.rematerialize_all() == []
    cfg = agent_registry._yaml_load(cfg_path.read_text(encoding="utf-8"))
    assert cfg["skills"] == {"disabled": ["github"]}
