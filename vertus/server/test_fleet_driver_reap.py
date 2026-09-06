"""Driver-reaping tests (Checkpoint 1): every gateway teardown path reaps the
embedded cua-driver child, the boot sweep kills only OUR orphans (ppid 1 +
--embedded), never the user's CuaDriver.app daemon, and /api/fleet/screens'
inventory attributes drivers to gateways via process group.

These tests use REAL processes (a fake gateway group leader + a fake driver
child) because the reaping is group-signal based — a fake session object
would not exercise killpg. Each test cleans up its own processes.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

import pytest

from hermes_bridge import _HermesSession
from vertus_server import VertusHandler, reap_orphaned_drivers

# Fake gateway leader: spawns one "driver" child (a long sleep with a
# cua-driver-looking argv) then sleeps itself.
_LEADER_BOOT = (
    "import subprocess, sys, time;"
    "subprocess.Popen([sys.executable, '-u', '-c', "
    "'import time; time.sleep(60)', "
    "'cua-driver', 'serve', '--embedded', '--socket', '/tmp/hc-fake.sock']);"
    "time.sleep(60)"
)


def _spawn_gateway_group():
    """Leader with a driver child, own process group (like the real spawn)."""
    leader = subprocess.Popen(
        [sys.executable, "-u", "-c", _LEADER_BOOT],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return leader


def _ps_rows() -> list[tuple[int, int, int, str]]:
    out = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,command="],
        capture_output=True, text=True, check=False,
    )
    rows = []
    for line in out.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3]))
    return rows


def _group_members(pgid: int) -> list[int]:
    return [pid for pid, _ppid, gid, _cmd in _ps_rows() if gid == pgid]


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def _wait_gone(pids: list[int], timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(_alive(p) for p in pids):
            return True
        time.sleep(0.05)
    return False


def _killpg(pgid: int) -> None:
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass


@pytest.fixture
def gateway_group():
    leader = _spawn_gateway_group()
    # The driver child must exist before we assert on it.
    deadline = time.time() + 5
    while time.time() < deadline and len(_group_members(leader.pid)) < 2:
        time.sleep(0.05)
    yield leader
    _killpg(leader.pid)


def _raw_session(proc) -> _HermesSession:
    """A session object wired to a real proc, without the reader thread."""
    session = _HermesSession.__new__(_HermesSession)
    session._proc = proc
    session.is_dead = False
    return session


# ----------------------------------------------------------------------
# Teardown paths
# ----------------------------------------------------------------------

def test_close_reaps_driver_child(gateway_group):
    """close() must kill the whole group, not just the leader."""
    leader = gateway_group
    members = _group_members(leader.pid)
    assert len(members) == 2, members
    session = _raw_session(leader)
    session.close()
    assert _wait_gone(members), f"survivors: {[p for p in members if _alive(p)]}"
    assert session.is_dead


def test_natural_exit_reaps_driver_child(gateway_group):
    """Leader exits on its own (natural death); the driver in its group must
    not be left behind as an orphan."""
    leader = gateway_group
    members = _group_members(leader.pid)
    assert len(members) == 2, members
    os.kill(leader.pid, signal.SIGKILL)
    leader.wait(timeout=5)
    # Leader gone; the driver survives in the group (the old leak).
    assert _alive(members[1] if members[1] != leader.pid else members[0])
    session = _raw_session(leader)
    session._reap_group(grace=0.2)
    assert _wait_gone([leader.pid]), "driver still alive after reap"


def test_reap_group_idempotent_when_empty():
    """Reaping an already-empty group is a no-op (ProcessLookupError path)."""
    leader = _spawn_gateway_group()
    try:
        _killpg(leader.pid)
        leader.wait(timeout=5)
        session = _raw_session(leader)
        session._reap_group(grace=0.2)  # must not raise
        session._reap_group(grace=0.2)
    finally:
        _killpg(leader.pid)


# ----------------------------------------------------------------------
# Boot sweep
# ----------------------------------------------------------------------

def _spawn_orphan(argv_tail: list[str]) -> int:
    """Double-fork a process whose parent exits immediately (ppid -> 1)."""
    code = (
        "import os, sys, time;"
        "pid = os.fork();"
        "os._exit(0) if pid > 0 else time.sleep(60)"
    )
    parent = subprocess.Popen(
        [sys.executable, "-u", "-c", code] + argv_tail,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    parent.wait(timeout=5)
    marker = argv_tail[-1]
    deadline = time.time() + 5
    while time.time() < deadline:
        for pid, ppid, _gid, cmd in _ps_rows():
            if ppid == 1 and marker in cmd:
                return pid
        time.sleep(0.05)
    raise AssertionError(f"orphan with {marker!r} never appeared")


def test_sweep_kills_orphaned_embedded():
    """ppid-1 --embedded driver from a dead gateway is reaped at boot."""
    pid = _spawn_orphan(
        ["cua-driver", "serve", "--embedded", "--socket", "/tmp/hc-sweep.sock"]
    )
    try:
        assert _alive(pid)
        n = reap_orphaned_drivers(log=lambda *a: None)
        assert n == 1
        assert not _alive(pid)
    finally:
        if _alive(pid):
            os.kill(pid, signal.SIGKILL)


def test_sweep_never_touches_daemon_signature():
    """The user's CuaDriver.app daemon (--cua-internal-gate-engaged, no
    --embedded) must never be targeted even though it is ppid 1."""
    pid = _spawn_orphan(
        ["cua-driver", "serve", "--cua-internal-gate-engaged", "--no-overlay"]
    )
    try:
        n = reap_orphaned_drivers(log=lambda *a: None)
        assert n == 0
        assert _alive(pid), "sweep killed the daemon-signature process"
    finally:
        if _alive(pid):
            os.kill(pid, signal.SIGKILL)


def test_sweep_idempotent():
    """Second pass finds nothing (first pass already reaped)."""
    pid = _spawn_orphan(
        ["cua-driver", "serve", "--embedded", "--socket", "/tmp/hc-sweep2.sock"]
    )
    try:
        assert reap_orphaned_drivers(log=lambda *a: None) == 1
        assert reap_orphaned_drivers(log=lambda *a: None) == 0
    finally:
        if _alive(pid):
            os.kill(pid, signal.SIGKILL)


# ----------------------------------------------------------------------
# Screens inventory
# ----------------------------------------------------------------------

class _FakeSessions:
    def __init__(self, bridge):
        self._bridge = bridge

    def live_ids(self):
        return ["typist"]

    def get_or_create_session(self, agent_id):
        return self._bridge


class _FakeBridge:
    def __init__(self, pgid):
        self.gateway_pgid = pgid


def test_driver_inventory_attributes_to_gateway(gateway_group):
    """Owned drivers map to their agent; the daemon-signature process never
    appears (it is not --embedded and not in the gateway's group)."""
    leader = gateway_group
    members = _group_members(leader.pid)
    assert len(members) == 2, members
    handler = VertusHandler.__new__(VertusHandler)
    handler.sessions = _FakeSessions(_FakeBridge(leader.pid))
    handler.registry = None
    owned, orphaned = handler._driver_inventory()
    driver = next(
        (o for o in owned if o["pid"] != leader.pid), None
    )
    assert driver is not None, f"driver not attributed: {owned}"
    assert driver["agent_id"] == "typist"
    assert driver["role"] == "embedded"
    assert driver["socket"] == "/tmp/hc-fake.sock"
    # The live gateway is not orphaned.
    assert all(o["pid"] != leader.pid for o in orphaned)


def test_driver_inventory_orphaned_list(gateway_group):
    """A ppid-1 --embedded driver shows in the orphaned list."""
    orphan_pid = _spawn_orphan(
        ["cua-driver", "serve", "--embedded", "--socket", "/tmp/hc-orph.sock"]
    )
    try:
        handler = VertusHandler.__new__(VertusHandler)
        handler.sessions = _FakeSessions(_FakeBridge(gateway_group.pid))
        handler.registry = None
        _owned, orphaned = handler._driver_inventory()
        assert any(o["pid"] == orphan_pid for o in orphaned)
    finally:
        if _alive(orphan_pid):
            os.kill(orphan_pid, signal.SIGKILL)