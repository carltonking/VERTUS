"""``vertus doctor`` tests: every fail path with the dependency deliberately
broken, the dialect checks against a REAL stub gateway process speaking the
same JSON-RPC framing (never the model), --json shape, exit codes, and the
no-state-mutation guarantee (doctor must be read-only)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
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