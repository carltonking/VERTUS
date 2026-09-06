"""``vertus doctor`` tests: every fail path with the dependency deliberately
broken, the dialect checks against a REAL stub gateway process speaking the
same JSON-RPC framing (never the model), --json shape, exit codes, and the
no-state-mutation guarantee (doctor must be read-only)."""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

import vertus_doctor as vd

# A stub gateway: real JSON-RPC-over-stdio process, no model anywhere. Emits
# gateway.ready, answers every method the doctor probes EXCEPT
# session.interrupt (which it 404s with -32601, as a fork would after
# renaming the method). --never-ready omits the ready event entirely.
_STUB_GATEWAY = (
    "import json, sys\n"
    "def send(o):\n"
    "    sys.stdout.write(json.dumps(o) + '\\n'); sys.stdout.flush()\n"
    "if '--never-ready' not in sys.argv:\n"
    "    send({'jsonrpc': '2.0', 'method': 'event',\n"
    "          'params': {'type': 'gateway.ready'}})\n"
    "OMITTED = {'session.interrupt'}\n"
    "for line in sys.stdin:\n"
    "    line = line.strip()\n"
    "    if not line:\n"
    "        continue\n"
    "    try:\n"
    "        msg = json.loads(line)\n"
    "    except Exception:\n"
    "        continue\n"
    "    rid = msg.get('id')\n"
    "    method = msg.get('method')\n"
    "    if not rid or method == 'event':\n"
    "        continue\n"
    "    if method in OMITTED:\n"
    "        send({'jsonrpc': '2.0', 'id': rid,\n"
    "              'error': {'code': -32601, 'message': 'Method not found'}})\n"
    "        continue\n"
    "    if method == 'session.create':\n"
    "        result = {'session_id': 'stub-session'}\n"
    "    elif method == 'commands.catalog':\n"
    "        result = {'pairs': [], 'skill_count': 0}\n"
    "    elif method == 'command.dispatch':\n"
    "        send({'jsonrpc': '2.0', 'id': rid,\n"
    "              'error': {'code': -32000,\n"
    "                        'message': 'unknown command: __doctor_nonexistent__'}})\n"
    "        continue\n"
    "    elif method == 'session.active_list':\n"
    "        result = {'sessions': []}\n"
    "    elif method == 'config.get':\n"
    "        result = {'ok': True}\n"
    "    elif method == 'approval.pending':\n"
    "        result = {'pending': []}\n"
    "    elif method == 'approval.respond':\n"
    "        result = {'ok': True}\n"
    "    else:\n"
    "        result = {'ok': True}\n"
    "    send({'jsonrpc': '2.0', 'id': rid, 'result': result})\n"
)


def _stub_spawner(never_ready: bool = False, omit_interrupt: bool = True):
    def spawn(log):
        stub = _STUB_GATEWAY
        if not omit_interrupt:
            stub = stub.replace("OMITTED = {'session.interrupt'}", "OMITTED = set()")
        args = [sys.executable, "-u", "-c", stub]
        if never_ready:
            args.append("--never-ready")
        proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
            start_new_session=True,
        )
        session = vd._HermesSession(proc, log)
        return session, Path(tempfile.mkdtemp()), Path(tempfile.mkdtemp())
    return spawn


def _git_dir(tmp_path: Path, name: str = "fork") -> Path:
    fork = tmp_path / name
    fork.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(fork)], check=True)
    return fork


def _fake_venv_python(fork: Path) -> Path:
    venv_py = fork / "venv" / "bin" / "python"
    venv_py.parent.mkdir(parents=True)
    venv_py.write_text("#!/bin/sh\necho 'Python 3.11.9'\n")
    venv_py.chmod(0o755)
    return venv_py


def _status(results: list[dict], name: str) -> str:
    return next(c["status"] for c in results if c["name"] == name)


def _by_name(results: list[dict]) -> dict[str, dict]:
    return {c["name"]: c for c in results}


@pytest.fixture
def isolated_env(monkeypatch, tmp_path):
    """Point every fleet path at temp dirs and silence launchd + hub."""
    agents = tmp_path / "agents"
    agents.mkdir()
    monkeypatch.setenv("VERTUS_AGENTS_DIR", str(agents))
    monkeypatch.setenv("VERTUS_DB_PATH", str(tmp_path / "fleet.db"))
    monkeypatch.setenv("VERTUS_TOKEN_PATH", str(tmp_path / "token"))
    monkeypatch.setenv("VERTUS_MEMORY_DIR", str(tmp_path / "memory"))
    monkeypatch.setenv("VERTUS_SHARED_MEMORY_DIR", str(tmp_path / "memory" / "shared"))
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "1")
    monkeypatch.setenv("VERTUS_PORT", "59999")  # nothing listens here
    return tmp_path


def _make_profile(agents_dir: Path, agent_id: str, schema_version: int) -> None:
    d = agents_dir / agent_id
    d.mkdir(parents=True, exist_ok=True)
    (d / "profile.json").write_text(json.dumps({
        "id": agent_id, "name": agent_id, "schema_version": schema_version,
        "created_at": "2026-01-01T00:00:00+00:00",
    }), encoding="utf-8")


def _make_db(path: Path, tables: bool = True) -> None:
    sqlite3 = "/usr/bin/sqlite3"
    all_tables = (
        ("runs", "run_id TEXT PRIMARY KEY, agent_id TEXT, state TEXT"),
        ("events", "seq INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, agent_id TEXT"),
        ("messages", "id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, agent_id TEXT, role TEXT"),
        ("bot_messages", "from_agent TEXT, to_agent TEXT"),
        ("threads", "thread_id TEXT"),
        ("approvals", "approval_id TEXT, run_id TEXT"),
        ("routines", "routine_id TEXT, agent_id TEXT"),
    )
    sql = ";".join(
        f"CREATE TABLE {t} ({cols});"
        for t, cols in (all_tables if tables else ())
    )
    sql += " PRAGMA journal_mode=WAL;"
    subprocess.run([sqlite3, str(path), sql], check=True, timeout=10)


# -- environment fail paths -------------------------------------------------

def test_bad_fork_path_fails(monkeypatch, isolated_env):
    monkeypatch.setenv("VERTUS_HERMES_REPO", "/nonexistent/fork")
    results = vd.env_checks()
    assert _status(results, "env.fork_checkout") == "fail"
    assert _by_name(results)["env.fork_checkout"]["remediation"]  # a fail must say what to DO


def test_missing_venv_fails(monkeypatch, isolated_env, tmp_path):
    fork = _git_dir(tmp_path)
    monkeypatch.setenv("VERTUS_HERMES_REPO", str(fork))
    monkeypatch.delenv("VERTUS_HERMES_PYTHON", raising=False)
    results = vd.env_checks()
    # No venv python -> the gateway entry cannot import -> the fork is not
    # functionally resolvable, and the venv check fails on its own.
    assert _status(results, "env.fork_checkout") == "fail"
    assert "venv python" in _by_name(results)["env.fork_checkout"]["reason"]
    assert _status(results, "env.venv_python") == "fail"


def test_fork_git_sha_ok_and_dirty_warn(monkeypatch, isolated_env, tmp_path):
    fork = _git_dir(tmp_path)
    monkeypatch.setenv("VERTUS_HERMES_REPO", str(fork))
    (fork / "touched.txt").write_text("x")
    results = vd.env_checks()
    assert _status(results, "env.fork_git_sha") == "warn"  # uncommitted drift
    subprocess.run(["git", "-C", str(fork), "add", "touched.txt"], check=True)
    subprocess.run(["git", "-C", str(fork), "commit", "-qm", "x"], check=True)
    results = vd.env_checks()
    assert _status(results, "env.fork_git_sha") == "ok"


def _make_venv_with_editable(fork: Path, target: Path, editable: bool = True,
                             url: str | None = None) -> None:
    """A venv-only fork dir whose site-packages holds one dist-info with a
    direct_url.json pointing at `target` (or `url`, percent-encoded)."""
    py = fork / "venv" / "lib" / "python3.11" / "site-packages"
    py.mkdir(parents=True)
    info = py / "hermes_agent-0.20.2.dist-info"
    info.mkdir()
    if url is None:
        url = "file://" + str(target)
    direct = {"url": url, "dir_info": {"editable": editable}}
    (info / "direct_url.json").write_text(json.dumps(direct))
    (py / "hermes_agent-0.20.2.dist-info" / "METADATA").write_text("Name: hermes-agent\n")
    venv_py = fork / "venv" / "bin" / "python"
    venv_py.parent.mkdir(parents=True)
    venv_py.write_text("#!/bin/sh\necho 'Python 3.11.9'\n")
    venv_py.chmod(0o755)


def test_fork_git_sha_editable_install_resolves_real_checkout(monkeypatch, isolated_env, tmp_path):
    """The blind spot this whole change exists for: fork dir is venv-only
    (no .git), the venv holds an editable install, and the REAL checkout is
    dirty — the doctor must see the real checkout's drift."""
    fork = tmp_path / "fork"
    fork.mkdir()
    real = _git_dir(tmp_path, name="real-fork")
    _make_venv_with_editable(fork, real)
    (real / "touched.txt").write_text("x")  # dirty
    monkeypatch.setenv("VERTUS_HERMES_REPO", str(fork))
    results = vd.env_checks()
    by = _by_name(results)
    assert by["env.fork_git_sha"]["status"] == "warn"
    assert "editable install →" in by["env.fork_git_sha"]["reason"]
    assert str(real) in by["env.fork_git_sha"]["reason"]
    assert "1 uncommitted change(s)" in by["env.fork_git_sha"]["reason"]
    # Clean the real checkout -> ok with its SHA and branch.
    subprocess.run(["git", "-C", str(real), "add", "touched.txt"], check=True)
    subprocess.run(["git", "-C", str(real), "commit", "-qm", "x"], check=True)
    results = vd.env_checks()
    by = _by_name(results)
    assert by["env.fork_git_sha"]["status"] == "ok"
    assert "on master" in by["env.fork_git_sha"]["reason"] or "on main" in by["env.fork_git_sha"]["reason"]


def test_fork_git_sha_editable_url_with_space_decodes(monkeypatch, isolated_env, tmp_path):
    """The real machine's checkout lives under '01 - PROJECTS/...'; the
    direct_url.json stores it percent-encoded — decoding must be exact."""
    fork = tmp_path / "fork"
    fork.mkdir()
    real = _git_dir(tmp_path, name="01 - PROJECTS/real-fork")
    _make_venv_with_editable(fork, real,
                             url="file://" + str(tmp_path) + "/01%20-%20PROJECTS/real-fork")
    monkeypatch.setenv("VERTUS_HERMES_REPO", str(fork))
    results = vd.env_checks()
    assert _status(results, "env.fork_git_sha") == "ok"
    assert "01 - PROJECTS/real-fork" in _by_name(results)["env.fork_git_sha"]["reason"]


def test_fork_git_sha_editable_failure_modes_distinct(monkeypatch, isolated_env, tmp_path):
    real = _git_dir(tmp_path, name="real-fork")
    cases = [
        ("no site-packages", None, "venv has no site-packages"),
        ("no dist-info", "empty", "no dist-info"),
        ("no direct_url.json", "nourl", "no direct_url.json"),
        ("non-editable", "noneditable", "not editable installs"),
        ("target missing", "missing", "editable install target missing"),
    ]
    for name, variant, needle in cases:
        fork = tmp_path / name
        fork.mkdir()
        if variant is None:
            pass  # venv exists but has no lib/ -> no site-packages
        else:
            py = fork / "venv" / "lib" / "python3.11" / "site-packages"
            py.mkdir(parents=True)
            if variant != "empty":
                info = py / "hermes_agent-0.20.2.dist-info"
                info.mkdir()
                if variant == "nourl":
                    pass  # dist-info with no direct_url.json
                elif variant == "noneditable":
                    (info / "direct_url.json").write_text(
                        json.dumps({"url": "file://" + str(real),
                                    "dir_info": {"editable": False}}))
                elif variant == "missing":
                    (info / "direct_url.json").write_text(
                        json.dumps({"url": "file:///nonexistent/target",
                                    "dir_info": {"editable": True}}))
            venv_py = fork / "venv" / "bin" / "python"
            venv_py.parent.mkdir(parents=True)
            venv_py.write_text("#!/bin/sh\necho 'Python 3.11.9'\n")
            venv_py.chmod(0o755)
        monkeypatch.setenv("VERTUS_HERMES_REPO", str(fork))
        results = vd.env_checks()
        by = _by_name(results)
        assert by["env.fork_git_sha"]["status"] == "unverified", name
        assert needle in by["env.fork_git_sha"]["reason"], f"{name}: {by['env.fork_git_sha']['reason']}"
        assert by["env.fork_git_sha"]["remediation"], name
        monkeypatch.delenv("VERTUS_HERMES_REPO", raising=False)


# -- dialect fail paths via the stub gateway --------------------------------

def test_dialect_missing_rpc_flagged_via_stub(monkeypatch, isolated_env):
    results = vd.dialect_checks(spawner=_stub_spawner())
    assert _status(results, "dialect.gateway.ready") == "ok"
    assert _status(results, "dialect.session.create") == "ok"
    assert _status(results, "dialect.prompt.submit") == "ok"
    # The stub 404s exactly this one: the dialect drift the tool exists to catch.
    assert _status(results, "dialect.session.interrupt") == "fail"
    assert "missing" in _by_name(results)["dialect.session.interrupt"]["reason"]
    assert _by_name(results)["dialect.session.interrupt"]["remediation"]
    assert _status(results, "dialect.commands.catalog") == "ok"
    assert _status(results, "dialect.command.dispatch") == "ok"
    assert _status(results, "dialect.session.active_list") == "ok"
    # Not-called-today RPCs missing -> warn, not fail.
    assert _status(results, "dialect.config.get") == "ok"  # stub provides it
    assert _status(results, "dialect.teardown") == "ok"


def test_dialect_gateway_never_ready_fails(monkeypatch, isolated_env):
    monkeypatch.setenv("VERTUS_DOCTOR_READY_TIMEOUT_S", "1")
    results = vd.dialect_checks(spawner=_stub_spawner(never_ready=True))
    # Ready failure + teardown row; no RPC rows — nothing was probed.
    assert _status(results, "dialect.gateway.ready") == "fail"
    assert _status(results, "dialect.teardown") in ("ok", "warn")
    assert len(results) == 2


def test_dialect_fork_only_rpcs_warn_when_missing(monkeypatch, isolated_env):
    # A stub that ALSO omits config.get / approval.* — nothing the hub calls
    # today, so warn not fail.
    stub = _STUB_GATEWAY.replace("OMITTED = {'session.interrupt'}",
                                 "OMITTED = {'session.interrupt', 'config.get', "
                                 "'approval.pending', 'approval.respond'}")
    results = vd.dialect_checks(spawner=_stub_spawner_with(stub))
    assert _status(results, "dialect.config.get") == "warn"
    assert _status(results, "dialect.approval.pending") == "warn"
    assert _status(results, "dialect.approval.respond") == "warn"
    assert _status(results, "dialect.session.interrupt") == "fail"


def _stub_spawner_with(stub_code: str):
    def spawn(log):
        proc = subprocess.Popen(
            [sys.executable, "-u", "-c", stub_code], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
            start_new_session=True,
        )
        session = vd._HermesSession(proc, log)
        return session, Path(tempfile.mkdtemp()), Path(tempfile.mkdtemp())
    return spawn


def test_dialect_event_vocabulary_unverified_by_design(monkeypatch, isolated_env):
    results = vd.dialect_checks(spawner=_stub_spawner())
    for etype in ("message.delta", "message.complete", "tool.start",
                  "turn.end", "error"):
        assert _status(results, f"dialect.event.{etype}") == "unverified"


# -- store / registry fail paths --------------------------------------------

def test_corrupt_store_fails(monkeypatch, isolated_env, tmp_path):
    (tmp_path / "fleet.db").write_bytes(b"this is not a sqlite database at all")
    results = vd.store_checks()
    assert _status(results, "store.file") == "ok"
    assert _status(results, "store.quick_check") == "fail"
    assert _by_name(results)["store.quick_check"]["remediation"]


def test_missing_store_tables_fails(monkeypatch, isolated_env, tmp_path):
    _make_db(tmp_path / "fleet.db", tables=False)
    results = vd.store_checks()
    assert _status(results, "store.quick_check") == "ok"
    assert _status(results, "store.tables") == "fail"


def test_healthy_store_passes(monkeypatch, isolated_env, tmp_path):
    _make_db(tmp_path / "fleet.db", tables=True)
    results = vd.store_checks()
    assert _status(results, "store.file") == "ok"
    assert _status(results, "store.quick_check") == "ok"
    assert _status(results, "store.tables") == "ok"


def test_stale_profile_schema_fails(monkeypatch, isolated_env, tmp_path):
    _make_profile(tmp_path / "agents", "oldbot", 1)
    _make_profile(tmp_path / "agents", "newbot", 4)
    results = vd.registry_checks()
    assert _status(results, "registry.profiles") == "fail"
    assert "oldbot" in _by_name(results)["registry.profiles"]["reason"]


def test_current_profiles_pass(monkeypatch, isolated_env, tmp_path):
    from agent_registry import SCHEMA_VERSION
    _make_profile(tmp_path / "agents", "newbot", SCHEMA_VERSION)
    results = vd.registry_checks()
    assert _status(results, "registry.profiles") == "ok"


# -- memory checks (Addition B) --------------------------------------------

def _materialized_skill(agents_dir: Path, agent_id: str, shared: str) -> Path:
    """Write an agent home the way the materializer would, with the given
    shared root injected into the memory skill."""
    skill = agents_dir / agent_id / "home" / "skills" / "vertus-memory" / "SKILL.md"
    skill.parent.mkdir(parents=True, exist_ok=True)
    skill.write_text(
        "# Vertus Memory\n"
        f"- **Fleet-shared memory** — `{shared}/`: read before every turn.\n",
        encoding="utf-8")
    return skill


def test_memory_missing_canonical_warns(monkeypatch, isolated_env):
    results = vd.memory_checks()
    assert _status(results, "memory.canonical") == "warn"


def test_memory_migration_marker_ok(monkeypatch, isolated_env, tmp_path):
    shared = tmp_path / "memory" / "shared"
    shared.mkdir(parents=True)
    (tmp_path / "memory" / ".migrated_v1").touch()
    results = vd.memory_checks()
    assert _status(results, "memory.canonical") == "ok"
    assert _status(results, "memory.migration") == "ok"


def test_memory_index_stale_warns(monkeypatch, isolated_env, tmp_path):
    shared = tmp_path / "memory" / "shared"
    shared.mkdir(parents=True)
    (tmp_path / "memory" / ".migrated_v1").touch()
    (shared / "profile.md").write_text("the user is Carlton", encoding="utf-8")
    # Index exists but is stale (empty) -> warn, not fail (watcher self-heals).
    (tmp_path / "memory" / ".hub-index.json").write_text("{}", encoding="utf-8")
    results = vd.memory_checks()
    assert _status(results, "memory.index") == "warn"
    # Fresh index with the right sha -> ok.
    from fleet_memory import _sha256
    p = shared / "profile.md"
    (tmp_path / "memory" / ".hub-index.json").write_text(json.dumps({
        "shared/profile.md": {"sha": _sha256(p), "size": p.stat().st_size},
    }), encoding="utf-8")
    results = vd.memory_checks()
    assert _status(results, "memory.index") == "ok"


def test_memory_conflicts_warn(monkeypatch, isolated_env, tmp_path):
    shared = tmp_path / "memory" / "shared"
    shared.mkdir(parents=True)
    (tmp_path / "memory" / ".migrated_v1").touch()
    agent_mem = tmp_path / "agents" / "alpha" / "memory"
    agent_mem.mkdir(parents=True)
    (agent_mem / "USER.md.conflict-1725000000").write_text("both sides",
                                                           encoding="utf-8")
    results = vd.memory_checks()
    assert _status(results, "memory.conflicts") == "warn"


def test_memory_skill_path_fails_on_divergence(monkeypatch, isolated_env,
                                               tmp_path):
    """The check that would have caught the env-divergence bug: a materialized
    skill pointing at a different shared root than the hub resolves must fail
    with a re-materialization remediation."""
    shared = tmp_path / "memory" / "shared"
    shared.mkdir(parents=True)
    (tmp_path / "memory" / ".migrated_v1").touch()
    wrong = tmp_path / "elsewhere" / "shared"
    _materialized_skill(tmp_path / "agents", "alpha", str(wrong))
    results = vd.memory_checks()
    assert _status(results, "memory.skill_path") == "fail", results
    assert "alpha" in _by_name(results)["memory.skill_path"]["reason"]
    assert _by_name(results)["memory.skill_path"]["remediation"]
    # Correct the skill to the resolved root -> ok.
    _materialized_skill(tmp_path / "agents", "alpha", str(shared))
    results = vd.memory_checks()
    assert _status(results, "memory.skill_path") == "ok"


def test_memory_mirror_pending_warns(monkeypatch, isolated_env, tmp_path):
    shared = tmp_path / "memory" / "shared"
    shared.mkdir(parents=True)
    (tmp_path / "memory" / ".migrated_v1").touch()
    # A fork-side USER.md with no canonical counterpart: watcher will mirror.
    fork_mem = tmp_path / "agents" / "alpha" / "home" / "memories"
    fork_mem.mkdir(parents=True)
    (fork_mem / "USER.md").write_text("fork learned this", encoding="utf-8")
    results = vd.memory_checks()
    assert _status(results, "memory.mirror") == "warn"
    # Mirrored (canonical copy exists, same bytes) -> ok.
    canon = tmp_path / "agents" / "alpha" / "memory"
    canon.mkdir(parents=True)
    (canon / "USER.md").write_text("fork learned this", encoding="utf-8")
    results = vd.memory_checks()
    assert _status(results, "memory.mirror") == "ok"


# -- terminal (hub mode) -----------------------------------------------------

@pytest.fixture()
def live_hub(monkeypatch, tmp_path):
    """Real VertusHandler with fakes + store on a random port, env pointed at
    it so terminal_checks() talks to it exactly like the real doctor run."""
    import threading
    import urllib.request as _ur
    from http.server import ThreadingHTTPServer

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import vertus_server as vs  # noqa: E402
    from run_store import RunStore  # noqa: E402
    from test_session_manager import make_manager  # noqa: E402

    mgr, registry = make_manager(monkeypatch, tmp_path)
    store = RunStore(path=tmp_path / "fleet.db")
    vs.VertusHandler.sessions = mgr
    vs.VertusHandler.registry = registry
    vs.VertusHandler.store = store
    vs.VertusHandler.token = "test-token"
    vs.VertusHandler.routines = None
    vs.VertusHandler.messenger = None
    vs.VertusHandler.health_snapshot = {}
    vs.VertusHandler.fleet = None
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    (tmp_path / "token").write_text("test-token")
    monkeypatch.setenv("VERTUS_TOKEN_PATH", str(tmp_path / "token"))
    monkeypatch.setenv("VERTUS_PORT", str(server.server_address[1]))
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "1")
    yield {"server": server, "mgr": mgr}
    server.shutdown()
    store.stop()
    vs.VertusHandler.store = None
    vs.VertusHandler.sessions = None
    vs.VertusHandler.registry = None


def test_terminal_checks_pass_against_live_hub(live_hub):
    results = vd.terminal_checks()
    by = _by_name(results)
    assert by["terminal.hub_reachable"]["status"] == "ok"
    assert by["terminal.agent_resolvable"]["status"] == "ok"
    assert by["terminal.steer_endpoint"]["status"] == "ok"
    assert "409" in by["terminal.steer_endpoint"]["reason"]


def test_terminal_steer_not_probed_while_running(live_hub):
    import json as _json
    import urllib.request as _ur

    bridge = live_hub["mgr"].get_session("primary")
    session = bridge.sessions[0]
    session.delay = 2.0
    req = _ur.Request(
        "http://127.0.0.1:%d/api/prompt" % live_hub["server"].server_address[1],
        data=_json.dumps({"agent_id": "primary", "text": "long turn"}).encode(),
        method="POST",
        headers={"Authorization": "Bearer test-token"},
    )
    _ur.urlopen(req, timeout=10).read()
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and bridge.status()["state"] != "running":
        time.sleep(0.03)
    assert bridge.status()["state"] == "running"
    by = _by_name(vd.terminal_checks())
    assert by["terminal.steer_endpoint"]["status"] == "unverified"
    assert "RUNNING" in by["terminal.steer_endpoint"]["reason"]


def test_terminal_hub_down_warns_not_fails(monkeypatch, isolated_env):
    results = vd.terminal_checks()
    assert _status(results, "terminal.hub_reachable") == "warn"
    assert len(results) == 1, "no point checking agents against a dead hub"


def test_stray_launchd_labels_flagged(monkeypatch, isolated_env):
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "")
    monkeypatch.setattr(vd, "_stray_vertus_labels", lambda: ["com.vertus.demo.memory"])
    by = _by_name(vd.terminal_checks())
    assert by["terminal.launchd_strays"]["status"] == "warn"
    assert "com.vertus.demo.memory" in by["terminal.launchd_strays"]["reason"]


def test_no_stray_launchd_labels_passes(monkeypatch, isolated_env):
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "")
    monkeypatch.setattr(vd, "_stray_vertus_labels", lambda: [])
    by = _by_name(vd.terminal_checks())
    assert by["terminal.launchd_strays"]["status"] == "ok"


# -- app (VERTUS.app) ------------------------------------------------------

def _write_bundle(tmp_path: Path, bundle_id: str) -> Path:
    """A minimal but real VERTUS.app-shaped bundle with the given id."""
    app = tmp_path / "VERTUS.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "MacOS" / "Vertus").write_text("#! /bin/true\n")
    os.chmod(app / "Contents" / "MacOS" / "Vertus", 0o755)
    plist = {"CFBundleIdentifier": bundle_id, "CFBundleDisplayName": "VERTUS"}
    (app / "Contents" / "Info.plist").write_bytes(
        plistlib.dumps(plist))
    return app


def test_app_missing_warns(monkeypatch, isolated_env, tmp_path):
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "")
    monkeypatch.setenv("VERTUS_APP_PATH", str(tmp_path / "nope" / "VERTUS.app"))
    by = _by_name(vd.app_checks())
    assert by["app.installed"]["status"] == "warn"
    assert "VERTUS.app" in by["app.installed"]["remediation"]
    assert len(by) == 1, "no point checking a missing app further"


def test_app_bad_bundle_id_fails(monkeypatch, isolated_env, tmp_path):
    """A wrong bundle id is a FAIL (it silently breaks SMAppService)."""
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "")
    monkeypatch.setenv("VERTUS_APP_PATH", str(_write_bundle(tmp_path, "com.vertusbar.dev")))
    monkeypatch.setattr(vd, "_login_item_registered", lambda: True)
    monkeypatch.setattr(vd, "_vertus_app_processes", lambda: [])
    by = _by_name(vd.app_checks())
    assert by["app.bundle_id"]["status"] == "fail"
    assert "com.vertusbar.dev" in by["app.bundle_id"]["reason"]


def test_app_good_bundle_login_and_single_process(monkeypatch, isolated_env, tmp_path):
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "")
    monkeypatch.setenv("VERTUS_APP_PATH", str(_write_bundle(tmp_path, "com.vertus.app")))
    monkeypatch.setattr(vd, "_login_item_registered", lambda: True)
    monkeypatch.setattr(vd, "_vertus_app_processes", lambda: [100])
    by = _by_name(vd.app_checks())
    assert by["app.installed"]["status"] == "ok"
    assert by["app.bundle_id"]["status"] == "ok"
    assert by["app.login_item"]["status"] == "ok"
    assert by["app.processes"]["status"] == "ok"


def test_app_two_processes_fails(monkeypatch, isolated_env, tmp_path):
    monkeypatch.setenv("VERTUS_DOCTOR_SKIP_LAUNCHD", "")
    monkeypatch.setenv("VERTUS_APP_PATH", str(_write_bundle(tmp_path, "com.vertus.app")))
    monkeypatch.setattr(vd, "_login_item_registered", lambda: False)
    monkeypatch.setattr(vd, "_vertus_app_processes", lambda: [100, 101])
    by = _by_name(vd.app_checks())
    assert by["app.processes"]["status"] == "fail"
    assert by["app.login_item"]["status"] == "warn"


def test_app_skipped_when_launchd_skipped(monkeypatch, isolated_env):
    by = _by_name(vd.app_checks())
    assert by["app.bundle"]["status"] == "unverified"

# -- hub / exit / json ------------------------------------------------------

def test_hub_down_warns_not_fails(monkeypatch, isolated_env):
    # Nothing on :59999 and launchd checks skipped -> warn, exit stays 0
    # (the hub being absent is a warning on a dev box, not a failure).
    assert vd.hub_checks()[0]["status"] == "warn"


def test_full_run_ok_env_exits_zero(monkeypatch, isolated_env, tmp_path):
    fork = _git_dir(tmp_path)
    _fake_venv_python(fork)
    monkeypatch.setenv("VERTUS_HERMES_REPO", str(fork))
    monkeypatch.delenv("VERTUS_HERMES_PYTHON", raising=False)
    _make_db(tmp_path / "fleet.db", tables=True)
    from agent_registry import SCHEMA_VERSION
    _make_profile(tmp_path / "agents", "newbot", SCHEMA_VERSION)
    (tmp_path / "token").write_text("t")
    code = vd.run(spawner=_stub_spawner(omit_interrupt=False))
    assert code == 0


def test_full_run_broken_env_exits_nonzero(monkeypatch, isolated_env):
    monkeypatch.setenv("VERTUS_HERMES_REPO", "/nonexistent/fork")
    assert vd.run() == 1


def test_json_shape(monkeypatch, isolated_env, capsys):
    monkeypatch.setenv("VERTUS_HERMES_REPO", "/nonexistent/fork")
    code = vd.run(json_out=True)
    parsed = json.loads(capsys.readouterr().out)
    assert code == parsed["exit"] == 1
    assert isinstance(parsed["checks"], list) and parsed["checks"]
    for c in parsed["checks"]:
        assert set(c) == {"name", "status", "reason", "remediation"}
        assert c["status"] in ("ok", "warn", "fail", "unverified")
    assert parsed["runtime_s"] > 0


def test_no_state_mutation(monkeypatch, isolated_env, tmp_path):
    """Doctor must be read-only: run it over a temp fleet and prove nothing
    changed — no new files, no rewritten profiles, no touched mtimes."""
    fork = _git_dir(tmp_path)
    _fake_venv_python(fork)
    monkeypatch.setenv("VERTUS_HERMES_REPO", str(fork))
    monkeypatch.delenv("VERTUS_HERMES_PYTHON", raising=False)
    _make_db(tmp_path / "fleet.db", tables=True)
    from agent_registry import SCHEMA_VERSION
    _make_profile(tmp_path / "agents", "newbot", SCHEMA_VERSION)
    (tmp_path / "token").write_text("t")
    # Full dialect pass through the stub gateway too.
    before = _tree_snapshot(tmp_path)
    assert vd.run(spawner=_stub_spawner(omit_interrupt=False)) == 0
    after = _tree_snapshot(tmp_path)
    assert before == after, "doctor mutated the fleet tree"


def _tree_snapshot(root: Path) -> dict[str, tuple[int, str]]:
    """Content snapshot, excluding SQLite sidecar files: opening a WAL db
    even read-only may (re)create empty -wal/-shm sidecars — transient
    SQLite artifacts, not doctor writes. The db CONTENT bytes are covered."""
    import hashlib
    snap = {}
    for p in sorted(root.rglob("*")):
        name = p.name
        if p.is_file() and not (name.endswith("-wal") or name.endswith("-shm")
                                or name.endswith("-journal")):
            snap[str(p.relative_to(root))] = (
                p.stat().st_size,
                hashlib.sha256(p.read_bytes()).hexdigest()[:16],
            )
    return snap


def _one_bit_bmp(width: int, height: int, pixels: bytes) -> bytes:
    """Hand-built 1-bit BI_RGB BMP (the format sips emits).
    ``pixels`` holds one byte per row (8 pixels, MSB first); rows are padded
    to 4 bytes like real BMPs."""
    import struct
    offset = 14 + 40 + 8  # file header + BITMAPINFOHEADER + 2 palette entries
    row_bytes = max(4, (width + 7) // 8)
    row_bytes = ((row_bytes + 3) // 4) * 4
    header = (b"BM" + struct.pack("<IHHI", 0, 0, 0, offset)
              + struct.pack("<IiiHHIIiiII", 40, width, height, 1, 1, 0,
                            len(pixels) * row_bytes, 0, 0, 2, 0))
    palette = bytes((0, 0, 0, 0, 255, 255, 255, 0))  # black, white
    body = b"".join(bytes([p]) + b"\x00" * (row_bytes - 1) for p in pixels)
    return header + palette + body


def test_bmp_decoder_1bit_variance(monkeypatch, isolated_env):
    # Uniform white 8x8 -> zero variance.
    flat = _one_bit_bmp(8, 8, b"\xff" * 8)
    assert vd._bmp_luminance_variance(flat) == 0.0
    # Half black, half white -> high variance.
    striped = _one_bit_bmp(8, 8, b"\xf0" * 8)
    var = vd._bmp_luminance_variance(striped)
    assert var is not None and var > 2.0
    # Not a BMP at all -> None, never an exception.
    assert vd._bmp_luminance_variance(b"not a bitmap") is None


# -- pi bundle freshness ---------------------------------------------------

def _fake_pi_tree(tmp_path: Path, src_mtime: float, bundle_mtime: float | None):
    """A fake pi/packages tree: src files with given mtime, optional bundle."""
    src = tmp_path / "pi" / "packages" / "coding-agent" / "src"
    src.mkdir(parents=True)
    f = src / "main.ts"
    f.write_text("// x")
    os.utime(f, (src_mtime, src_mtime))
    if bundle_mtime is not None:
        b = tmp_path / "pi" / "packages" / "coding-agent" / "dist" / "bundle" / "cli.js"
        b.parent.mkdir(parents=True)
        b.write_text("// bundle")
        os.utime(b, (bundle_mtime, bundle_mtime))


def _doctor_with_pi_root(monkeypatch, tmp_path):
    """Make pi_bundle_checks resolve its repo root at tmp_path."""
    monkeypatch.setattr(vd, "__file__",
                        str(tmp_path / "vertus" / "server" / "vertus_doctor.py"))


def test_pi_bundle_missing_warns(monkeypatch, isolated_env, tmp_path):
    _fake_pi_tree(tmp_path, src_mtime=1000.0, bundle_mtime=None)
    _doctor_with_pi_root(monkeypatch, tmp_path)
    out = vd.pi_bundle_checks()
    assert out[0]["name"] == "pi.bundle"
    assert out[0]["status"] == "warn"
    assert "missing" in out[0]["reason"]


def test_pi_bundle_stale_warns(monkeypatch, isolated_env, tmp_path):
    # src newer than bundle -> warn
    _fake_pi_tree(tmp_path, src_mtime=2000.0, bundle_mtime=1000.0)
    _doctor_with_pi_root(monkeypatch, tmp_path)
    out = vd.pi_bundle_checks()
    assert out[0]["name"] == "pi.bundle"
    assert out[0]["status"] == "warn"
    assert "OLDER" in out[0]["reason"]


def test_pi_bundle_fresh_ok(monkeypatch, isolated_env, tmp_path):
    _fake_pi_tree(tmp_path, src_mtime=1000.0, bundle_mtime=2000.0)
    _doctor_with_pi_root(monkeypatch, tmp_path)
    out = vd.pi_bundle_checks()
    assert out[0]["name"] == "pi.bundle"
    assert out[0]["status"] == "ok"

def test_doctor_cli_subcommand_parses(monkeypatch, isolated_env, capsys):
    """vertus_server.py doctor must dispatch through argparse."""
    import vertus_server as vs
    monkeypatch.setattr(sys, "argv", ["vertus_server.py", "doctor", "--json"])
    monkeypatch.setenv("VERTUS_HERMES_REPO", "/nonexistent/fork")
    with pytest.raises(SystemExit) as exc:
        vs.main()
    assert exc.value.code == 1
    parsed = json.loads(capsys.readouterr().out)
    assert parsed["checks"]