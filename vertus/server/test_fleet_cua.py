"""v2→v4 profile schema + per-agent computer-use spawn-time mapping.

Covers the schema migrations (idempotent, lossless, unknown keys survive),
the derived home materialization (config.yaml ``computer_use`` block), and
the gateway env mapping (HERMES_COMPUTER_USE_BACKEND=noop for disabled
agents) via the production ``resolve_session_kwargs``.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))  # noqa: E402

from agent_registry import AgentRegistry, SCHEMA_VERSION  # noqa: E402


def _registry(tmp_path, monkeypatch) -> AgentRegistry:
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(tmp_path / "agents"))
    monkeypatch.setenv("VERTUS_FLEET_HERMES_HOME", str(tmp_path / "fleet-hermes"))
    return AgentRegistry()


# ----------------------------------------------------------------------
# Migration: v2 → v5
# ----------------------------------------------------------------------


def test_v2_profile_migrates_to_v5_idempotent_and_lossless(monkeypatch, tmp_path):
    reg = _registry(tmp_path, monkeypatch)
    reg.ensure_primary()
    # Hand-write a v2 profile exactly as the previous hub version wrote it.
    v2 = {
        "id": "primary",
        "name": "Primary",
        "title": "Primary",
        "description": "",
        "persona": "You are VERTUS.",
        "model": None,
        "provider": None,
        "color": None,
        "emoji": None,
        "autonomy": "ask",
        "created_at": "2026-09-03T22:40:39+00:00",
        "updated_at": "2026-09-03T22:40:39+00:00",
        "sandbox_path": str(tmp_path / "agents" / "primary" / "sandbox"),
        "home_path": str(tmp_path / "agents" / "primary" / "home"),
        "schema_version": 2,
        "custom_future_key": {"keep": True},  # unknown-key preservation
    }
    (tmp_path / "agents" / "primary").mkdir(parents=True, exist_ok=True)
    (tmp_path / "agents" / "primary" / "profile.json").write_text(json.dumps(v2))

    first = reg.get_agent("primary")
    assert first["schema_version"] == SCHEMA_VERSION
    assert first["computer_use"] is False, "v3 upgrade must NOT enable CUA by default"
    assert first["cua_targets"] is None
    assert first["stall_timeout_s"] == 180, "v4 stall default"
    assert first["hard_timeout_s"] == 3600, "v4 hard-timeout default"
    assert first["memory_capture"] == "automatic", "v5 capture default is on"
    assert first["custom_future_key"] == {"keep": True}
    assert first["persona"] == "You are VERTUS.", "v2 persona must not be clobbered"

    # Idempotent + persisted: a second read changes nothing on disk.
    disk_before = json.loads((tmp_path / "agents" / "primary" / "profile.json").read_text())
    reg.get_agent("primary")
    disk_after = json.loads((tmp_path / "agents" / "primary" / "profile.json").read_text())
    assert disk_before == disk_after
    assert disk_after["schema_version"] == SCHEMA_VERSION
    assert disk_after["custom_future_key"] == {"keep": True}


def test_v3_profile_migrates_to_v5(monkeypatch, tmp_path):
    """v3 → v5 adds supervision timeouts + capture; CUA fields untouched."""
    reg = _registry(tmp_path, monkeypatch)
    reg.ensure_primary()
    v3 = {
        "id": "primary",
        "name": "Primary",
        "title": "Primary",
        "description": "",
        "persona": "",
        "model": None,
        "provider": None,
        "color": None,
        "emoji": None,
        "autonomy": "trusted",
        "computer_use": True,
        "cua_targets": ["com.apple.TextEdit"],
        "created_at": "2026-09-03T22:40:39+00:00",
        "updated_at": "2026-09-03T22:40:39+00:00",
        "sandbox_path": str(tmp_path / "agents" / "primary" / "sandbox"),
        "home_path": str(tmp_path / "agents" / "primary" / "home"),
        "schema_version": 3,
        "vendor_x": 1,
    }
    (tmp_path / "agents" / "primary").mkdir(parents=True, exist_ok=True)
    (tmp_path / "agents" / "primary" / "profile.json").write_text(json.dumps(v3))

    loaded = reg.get_agent("primary")
    assert loaded["schema_version"] == SCHEMA_VERSION
    assert loaded["computer_use"] is True, "v3 CUA enablement survives"
    assert loaded["cua_targets"] == ["com.apple.TextEdit"]
    assert loaded["stall_timeout_s"] == 180
    assert loaded["hard_timeout_s"] == 3600
    assert loaded["memory_capture"] == "automatic"
    assert loaded["vendor_x"] == 1
    disk = json.loads((tmp_path / "agents" / "primary" / "profile.json").read_text())
    assert disk["schema_version"] == SCHEMA_VERSION and disk["vendor_x"] == 1


def test_existing_v5_profile_never_rewritten(monkeypatch, tmp_path):
    reg = _registry(tmp_path, monkeypatch)
    reg.ensure_primary()
    # A profile that already declares the v5 fields must pass through
    # untouched on load (custom timeouts and capture included).
    v5 = {
        "id": "primary",
        "name": "Primary",
        "title": "Primary",
        "description": "",
        "persona": "",
        "model": None,
        "provider": None,
        "color": None,
        "emoji": None,
        "autonomy": "trusted",
        "computer_use": True,
        "cua_targets": ["com.apple.TextEdit"],
        "stall_timeout_s": 45,
        "hard_timeout_s": 900,
        "memory_capture": "off",
        "created_at": "2026-09-03T22:40:39+00:00",
        "updated_at": "2026-09-03T22:40:39+00:00",
        "sandbox_path": str(tmp_path / "agents" / "primary" / "sandbox"),
        "home_path": str(tmp_path / "agents" / "primary" / "home"),
        "schema_version": SCHEMA_VERSION,
        "vendor_x": 1,
    }
    (tmp_path / "agents" / "primary").mkdir(parents=True, exist_ok=True)
    (tmp_path / "agents" / "primary" / "profile.json").write_text(json.dumps(v5))

    loaded = reg.get_agent("primary")
    assert loaded["computer_use"] is True
    assert loaded["stall_timeout_s"] == 45, "custom v5 timeouts survive"
    assert loaded["hard_timeout_s"] == 900
    assert loaded["memory_capture"] == "off", "custom capture policy survives"
    assert loaded["vendor_x"] == 1
    disk = json.loads((tmp_path / "agents" / "primary" / "profile.json").read_text())
    assert disk == v5, "a current-schema profile must never be rewritten"


def test_v1_profile_steps_through_all_migrations(monkeypatch, tmp_path):
    reg = _registry(tmp_path, monkeypatch)
    fleet = tmp_path / "fleet-hermes"
    fleet.mkdir(parents=True, exist_ok=True)
    (fleet / "SOUL.md").write_text("FLEET SOUL")
    reg.ensure_primary()
    v1 = {
        "id": "primary",
        "name": "Old",
        "created_at": "2026-09-01T00:00:00+00:00",
        "sandbox_path": str(tmp_path / "agents" / "primary" / "sandbox"),
    }
    (tmp_path / "agents" / "primary").mkdir(parents=True, exist_ok=True)
    (tmp_path / "agents" / "primary" / "profile.json").write_text(json.dumps(v1))
    loaded = reg.get_agent("primary")
    assert loaded["schema_version"] == SCHEMA_VERSION
    assert loaded["title"] == "Old", "v1→v2 title backfill"
    assert loaded["persona"] == "FLEET SOUL", "v1→v2 persona backfill"
    assert loaded["computer_use"] is False, "v2→v3 CUA default"
    assert loaded["stall_timeout_s"] == 180, "v3→v4 stall default"
    assert loaded["hard_timeout_s"] == 3600, "v3→v4 hard-timeout default"
    assert loaded["memory_capture"] == "automatic", "v4→v5 capture default"
    assert loaded["autonomy"] == "ask"


# ----------------------------------------------------------------------
# Materialization: config.yaml computer_use block
# ----------------------------------------------------------------------


def _create_cua_agent(reg, *, autonomy="ask", name="Cua", targets=None, manifest=False):
    fleet = reg.agent_home("_").parent.parent / "fleet-hermes" if False else None
    if manifest:
        # Fleet-level manifest the resolver copies into the agent home.
        fleet_home = reg.root.parent / "fleet-hermes"
        fleet_home.mkdir(parents=True, exist_ok=True)
        (fleet_home / "cua-manifest.yaml").write_text(
            "version: 3\nname: fleet-ceiling\n"
        )
    agent = reg.create_agent(
        name,
        computer_use=True,
        cua_targets=targets,
        autonomy=autonomy,
    )
    return agent


def test_materialization_disabled_has_no_computer_use_block(monkeypatch, tmp_path):
    reg = _registry(tmp_path, monkeypatch)
    agent = reg.create_agent("Doc")
    cfg = (Path(agent["home_path"]) / "config.yaml").read_text()
    assert "computer_use" not in cfg, "disabled agents carry no computer_use config"


def test_materialization_ask_maps_to_standard(monkeypatch, tmp_path):
    reg = _registry(tmp_path, monkeypatch)
    agent = reg.create_agent("AskBot", computer_use=True, autonomy="ask")
    cfg = (Path(agent["home_path"]) / "config.yaml").read_text()
    assert "computer_use:" in cfg
    assert "permission_mode: standard" in cfg, "ask → driver standard mode"


def test_materialization_trusted_without_manifest_degrades_to_standard(
    monkeypatch, tmp_path
):
    reg = _registry(tmp_path, monkeypatch)
    agent = reg.create_agent("TrustBot", computer_use=True, autonomy="trusted")
    cfg = (Path(agent["home_path"]) / "config.yaml").read_text()
    assert "permission_mode: standard" in cfg, (
        "trusted without a manifest degrades safely to standard (bounded "
        "requires a driver-validated manifest; none exists on this host)"
    )


def test_materialization_trusted_with_manifest_maps_to_bounded(monkeypatch, tmp_path):
    fleet_home = tmp_path / "fleet-hermes"
    fleet_home.mkdir(parents=True, exist_ok=True)
    (fleet_home / "cua-manifest.yaml").write_text("version: 3\nname: fleet-ceiling\n")
    reg = _registry(tmp_path, monkeypatch)
    agent = reg.create_agent("BoundedBot", computer_use=True, autonomy="trusted")
    cfg = (Path(agent["home_path"]) / "config.yaml").read_text()
    assert "permission_mode: bounded" in cfg
    assert "capability_manifest:" in cfg
    home = Path(agent["home_path"])
    manifest_path = home / "cua-manifest.yaml"
    assert manifest_path.is_file(), "manifest copied into the derived home"
    assert str(manifest_path) in cfg, "manifest path is the self-contained home copy"


def test_rematerialize_on_disable_removes_computer_use_block(monkeypatch, tmp_path):
    reg = _registry(tmp_path, monkeypatch)
    agent = reg.create_agent("FlipBot", computer_use=True, autonomy="ask")
    cfg = (Path(agent["home_path"]) / "config.yaml").read_text()
    assert "permission_mode: standard" in cfg
    updated = reg.update_agent(agent["id"], computer_use=False)
    cfg2 = (Path(updated["home_path"]) / "config.yaml").read_text()
    assert "computer_use" not in cfg2, "home/ is derived; disable removes the block"


# ----------------------------------------------------------------------
# Spawn-time env mapping (resolve_session_kwargs, production path)
# ----------------------------------------------------------------------


def test_disabled_agent_spawns_with_noop_backend(monkeypatch, tmp_path):
    from vertus_server import resolve_session_kwargs  # noqa: PLC0415

    reg = _registry(tmp_path, monkeypatch)
    reg.ensure_primary()
    agent = reg.create_agent("Plain")
    kwargs = resolve_session_kwargs(reg, agent["id"])
    assert kwargs["extra_env"]["HERMES_COMPUTER_USE_BACKEND"] == "noop", (
        "computer_use OFF must cut capability at spawn"
    )


def test_enabled_agent_spawns_without_noop_backend(monkeypatch, tmp_path):
    from vertus_server import resolve_session_kwargs  # noqa: PLC0415

    reg = _registry(tmp_path, monkeypatch)
    reg.ensure_primary()
    agent = reg.create_agent("Driver", computer_use=True)
    kwargs = resolve_session_kwargs(reg, agent["id"])
    assert "HERMES_COMPUTER_USE_BACKEND" not in kwargs.get("extra_env", {}), (
        "computer_use ON uses the fork's default cua backend"
    )


def test_http_validation_of_new_fields(monkeypatch, tmp_path):
    """Bad types for computer_use/cua_targets 400 via the HTTP validator."""
    from vertus_server import _validate_profile_payload  # noqa: PLC0415

    for bad in (
        {"computer_use": "yes"},
        {"computer_use": 1},
        {"cua_targets": "TextEdit"},
        {"cua_targets": [1, 2]},
        {"cua_targets": ["ok", ""]},
    ):
        try:
            _validate_profile_payload(bad, allow_name=False)
        except ValueError:
            continue
        raise AssertionError(f"payload {bad} should have been rejected")
    ok = _validate_profile_payload(
        {"computer_use": True, "cua_targets": None}, allow_name=False
    )
    assert ok == {"computer_use": True, "cua_targets": None}
