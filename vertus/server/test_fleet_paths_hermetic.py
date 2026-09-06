"""Addition A pinning test: ONE root variable drives the whole hub.

The env-divergence sweep collapsed every path root in the hub into
vertus_paths.py (concept env var → VERTUS_ROOT → production default).
This test pins the property that motivated the sweep: a hub booted with
ONLY VERTUS_ROOT set to a temp dir must not read or write anything under
the real ~/.vertus — not the token (which used to be hardcoded and is
CREATED on boot if missing), not memory (the migration), not agents, not
the DB, not backups. A full boot (registry + primary + agent creation +
materialization + PATCH re-materialization + store + memory migration +
token + live HTTP handler) runs against the temp root, and the real tree
is snapshotted before and after.

The live launchd hub churns fleet.db* and logs/ legitimately while this
suite runs, so those files are excluded from the comparison; every other
file under ~/.vertus must be byte-identical (size + sha) before and after.

Also pins the resolver precedence itself: concept env var beats VERTUS_ROOT
beats production default, and every resolver derives from VERTUS_ROOT when
it is set — no module resolves a root on its own anymore.
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

import fleet_memory as fm  # noqa: E402
import vertus_paths  # noqa: E402
import vertus_server as vs  # noqa: E402

# Concept vars that used to be resolved independently per module. The point
# of this test: with NONE of them set, VERTUS_ROOT alone redirects every
# root; with one of them set, it overrides VERTUS_ROOT.
_CONCEPT_VARS = (
    "VERTUS_MEMORY_DIR",
    "VERTUS_SHARED_MEMORY_DIR",
    "VERTUS_AGENTS_DIR",
    "VERTUS_DB_PATH",
    "VERTUS_TOKEN_PATH",
    "VERTUS_BACKUP_DIR",
    "VERTUS_LOG_DIR",
    "VERTUS_FLEET_HERMES_HOME",
    "VERTUS_HERMES_REPO",
    "VERTUS_HERMES_PYTHON",
    "VERTUS_CUA_MANIFEST",
)

# Files the LIVE hub legitimately churns while this suite runs (it is
# launchd KeepAlive on this machine): the DB + its WAL sidecars and the
# rotating log. Everything else under ~/.vertus must be untouched.
def _noise(rel: str) -> bool:
    return "fleet.db" in rel or rel.startswith("logs/")


def _snapshot(root: Path) -> dict[str, tuple[int, str]]:
    snap: dict[str, tuple[int, str]] = {}
    if not root.exists():
        return snap
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = str(p.relative_to(root))
        if _noise(rel):
            continue
        data = p.read_bytes()
        snap[rel] = (len(data), hashlib.sha256(data).hexdigest()[:16])
    return snap


@pytest.fixture()
def real_vertus() -> Path:
    return Path.home() / ".vertus"


@pytest.fixture()
def hermetic_env(monkeypatch, tmp_path, real_vertus):
    """ONLY VERTUS_ROOT set — every concept var explicitly unset."""
    root = tmp_path / "fleet"
    monkeypatch.setenv("VERTUS_ROOT", str(root))
    for var in _CONCEPT_VARS:
        monkeypatch.delenv(var, raising=False)
    return root


def _req(base, path, token, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def test_resolvers_derive_from_vertus_root(hermetic_env):
    """With ONLY VERTUS_ROOT set, every resolver lands inside the temp root."""
    root = Path(os.environ["VERTUS_ROOT"])
    assert vertus_paths.vertus_root() == root
    assert vertus_paths.memory_root() == root / "memory"
    assert vertus_paths.shared_memory_dir() == root / "memory" / "shared"
    assert vertus_paths.agents_dir() == root / "agents"
    assert vertus_paths.fleet_db_path() == root / "fleet.db"
    assert vertus_paths.token_path() == root / "token"
    assert vertus_paths.backups_dir() == root / "backups"
    assert vertus_paths.logs_dir() == root / "logs"
    # The engine config root must NOT fall back to the real ~/.hermes under
    # a hermetic root — persona backfill and provider-key copies would leak.
    assert vertus_paths.fleet_hermes_home() == root / "hermes"


def test_concept_var_overrides_vertus_root(monkeypatch, tmp_path, hermetic_env):
    """Precedence: the concept's own var beats VERTUS_ROOT (temp override)."""
    override = tmp_path / "mem-override"
    monkeypatch.setenv("VERTUS_MEMORY_DIR", str(override))
    assert vertus_paths.memory_root() == override
    assert vertus_paths.shared_memory_dir() == override / "shared"
    # Unrelated roots still derive from VERTUS_ROOT.
    assert vertus_paths.agents_dir() == Path(os.environ["VERTUS_ROOT"]) / "agents"


def test_full_boot_with_vertus_root_touches_nothing_real(hermetic_env,
                                                        real_vertus):
    """A full hub boot + agent creation + materialization leaves the real
    ~/.vertus byte-identical (minus live-hub churn) and puts everything in
    the temp root."""
    root = Path(os.environ["VERTUS_ROOT"])
    before = _snapshot(real_vertus)

    # -- the boot, exactly like serve() but through the real classes --------
    registry = vs.AgentRegistry()  # no root arg: VERTUS_ROOT/agents
    registry.ensure_primary()
    registry.create_agent("Hermetic Probe")

    store = vs.RunStore()  # no path arg: VERTUS_ROOT/fleet.db
    migrated = fm.migrate_legacy_memory()  # reads/writes under temp only
    token = vs.ensure_token()  # CREATES root/token, must not touch real one

    memory = vs.MemoryStore(emit=lambda aid, e: store.record_event(aid, "", e),
                            running_agents=lambda: set())
    memory.start()

    # SessionManager without any env override — bridges spawn lazily and
    # never in this test; its agent registry is the VERTUS_ROOT one above.
    sessions = vs.build_session_manager(registry)
    vs.VertusHandler.sessions = sessions
    vs.VertusHandler.registry = registry
    vs.VertusHandler.store = store
    vs.VertusHandler.memory = memory
    vs.VertusHandler.token = token
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"

    try:
        # Agent creation through the real HTTP path (materializes skills with
        # the injected shared-memory path) …
        status, created = _req(base, "/api/agents", token, "POST",
                               {"name": "Via HTTP"})
        assert status == 201, created
        agent_id = created["id"]
        # … and a PATCH, which re-materializes the home.
        status, patched = _req(base, f"/api/agents/{agent_id}", token,
                               "PATCH", {"title": "patched title"})
        assert status == 200, patched
        # Memory list + a hub write prove the store is live against the
        # temp root (the write also creates the hub index there).
        status, listing = _req(base, "/api/memory", token)
        assert status == 200, listing
        status, written = _req(
            base, "/api/memory/shared/notes/from-boot.md", token, "PUT",
            {"content": "booted under VERTUS_ROOT"})
        assert status == 200, written
    finally:
        server.shutdown()
        memory.stop()
        for agent_id in sessions.live_ids():
            sessions.drop(agent_id)
        vs.VertusHandler.sessions = None
        vs.VertusHandler.registry = None
        vs.VertusHandler.store = None
        vs.VertusHandler.memory = None

    # -- everything landed under the temp root ------------------------------
    assert (root / "agents" / "primary" / "profile.json").is_file()
    assert (root / "agents" / agent_id / "profile.json").is_file()
    assert (root / "fleet.db").is_file()
    assert (root / "token").read_text().strip() == token
    assert (root / "memory" / "shared" / "notes" / "from-boot.md").is_file()
    assert (root / "memory" / ".hub-index.json").is_file()
    assert (root / "memory" / fm._MIGRATION_MARKER).is_file(), (
        "migration marker must land under the temp root, not the real one"
    )
    # Migration was a no-op on an empty temp tree (every legacy entry
    # "missing") — but its backup and marker landed under the temp root, and
    # it must never have consulted the real tree.
    assert migrated["backup_path"].startswith(str(root)), migrated
    assert all(st == "missing" for st in migrated["entries"].values()), migrated

    # -- the real tree is byte-identical ------------------------------------
    after = _snapshot(real_vertus)
    assert before == after, (
        "boot touched the real ~/.vertus; differing files:\n"
        + "\n".join(sorted(set(before) ^ set(after))[:10])
    )


def test_resolved_roots_never_point_at_real_state(hermetic_env, real_vertus):
    """The resolver set contains no real-user-state fallback while
    VERTUS_ROOT is set — the exact class of bug the sweep fixed."""
    for resolved in (
        vertus_paths.memory_root(),
        vertus_paths.shared_memory_dir(),
        vertus_paths.agents_dir(),
        vertus_paths.fleet_db_path(),
        vertus_paths.token_path(),
        vertus_paths.backups_dir(),
        vertus_paths.logs_dir(),
        vertus_paths.fleet_hermes_home(),
    ):
        assert not str(resolved).startswith(str(real_vertus)), (
            f"{resolved} resolves into the real ~/.vertus under VERTUS_ROOT"
        )
        assert not str(resolved).startswith(str(Path.home() / ".hermes")), (
            f"{resolved} resolves into the real ~/.hermes under VERTUS_ROOT"
        )