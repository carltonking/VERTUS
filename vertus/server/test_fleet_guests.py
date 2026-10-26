"""Disposable-guest tests: lifecycle, provisioning, frames, HTTP surface.

No real QEMU, no real VM, no network: a fake ``qemu-system-aarch64`` (a
python script that speaks just enough RFB 3.8 to serve a solid-color
framebuffer on the requested VNC port) and a fake ``qemu-img`` stand in for
the host prerequisites, and the base image is provisioned from a tiny
``file://`` URL. Everything is pointed at a temp fleet root via explicit
constructor args, so no test touches ~/.vertus.

The end-to-end shape matters here: boot() runs the REAL manager code paths
(port allocation, seed ISO, state files, process spawning) and the frame
tests talk to the REAL RFB client against the fake server — the same bytes
a real qemu display would produce.
"""

from __future__ import annotations

import http.client
import json
import socket
import struct
import textwrap
import threading
import time
import zlib
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

import vertus_server as vs
from agent_registry import AgentRegistry  # noqa: E402

# ---------------------------------------------------------------------------
# Fake host prerequisites (qemu-system-aarch64, qemu-img) + fake VNC display
# ---------------------------------------------------------------------------

_FAKE_QEMU = textwrap.dedent("""\
    #!/usr/bin/env python3
    import signal, socket, struct, sys, threading, time

    W, H = 96, 64

    def handle(conn):
        conn.sendall(b"RFB 003.008\\n")
        conn.recv(12)
        conn.sendall(bytes([1, 1]))
        conn.recv(1)
        conn.sendall(struct.pack(">I", 0))
        conn.recv(1)
        name = b"fake-guest"
        conn.sendall(struct.pack(">HH", W, H) + bytes(16)
                     + struct.pack(">I", len(name)) + name)
        while True:
            head = conn.recv(1)
            if not head:
                return
            t = head[0]
            if t == 0:
                conn.recv(19)
            elif t == 2:
                hdr = conn.recv(3)
                count = struct.unpack(">H", hdr[1:3])[0]
                conn.recv(count * 4)
            elif t == 3:
                conn.recv(9)
                frame = bytearray(W * H * 4)
                for y in range(H):
                    for x in range(W):
                        i = (y * W + x) * 4
                        frame[i] = 0x80
                        frame[i + 1] = y & 0xFF
                        frame[i + 2] = x & 0xFF
                        frame[i + 3] = 0xFF
                conn.sendall(b"\\x00\\x00" + struct.pack(">H", 1)
                             + struct.pack(">HHHH", 0, 0, W, H)
                             + struct.pack(">i", 0) + bytes(frame))
            elif t == 4:
                conn.recv(5)
            elif t == 5:
                conn.recv(7)
            else:
                return

    def server(port):
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", port))
            s.listen(4)
            while True:
                try:
                    c, _ = s.accept()
                except OSError:
                    return
                threading.Thread(target=handle, args=(c,), daemon=True).start()

    def main():
        args = sys.argv[1:]
        vnc_display = None
        overlay = None
        i = 0
        while i < len(args):
            a = args[i]
            if a == "-vnc":
                vnc_display = int(args[i + 1].rsplit(":", 1)[1])
                i += 2
            elif a == "-drive":
                drive = args[i + 1]
                for part in drive.split(","):
                    if part.startswith("file=") and "cdrom" not in drive:
                        overlay = part[5:]
                i += 2
            elif a == "-serial":
                serial = args[i + 1]
                if serial.startswith("file:"):
                    open(serial[5:], "ab").close()
                i += 2
            else:
                i += 1
        if overlay:
            Path = __import__("pathlib").Path
            Path(overlay + ".fake-marker").write_text("started")
        signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
        if vnc_display is not None:
            threading.Thread(target=server, args=(5900 + vnc_display,),
                             daemon=True).start()
        while True:
            time.sleep(1)

    main()
""")

_FAKE_QEMU_IMG = textwrap.dedent("""\
    #!/usr/bin/env python3
    import shutil, sys
    args = sys.argv[1:]
    cmd = args[0]
    if cmd == "create":
        open(args[-1], "wb").close()
    elif cmd == "convert":
        src = args[args.index("-O") + 2]
        shutil.copyfile(src, args[-1])
    elif cmd == "resize":
        pass
""")


@pytest.fixture()
def fake_bins(tmp_path: Path):
    """Write + chmod the fake qemu binaries; return their paths.

    Also plants a fake UEFI firmware next to the qemu install (bin/../share/
    qemu/edk2-aarch64-code.fd), mirroring a Homebrew layout, so arm64 boot
    commands resolve firmware exactly like the real manager does.
    """
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir()
    qemu = bin_dir / "qemu-system-aarch64"
    qemu.write_text(_FAKE_QEMU)
    qemu.chmod(0o755)
    img = bin_dir / "qemu-img"
    img.write_text(_FAKE_QEMU_IMG)
    img.chmod(0o755)
    fw_dir = tmp_path / "share" / "qemu"
    fw_dir.mkdir(parents=True)
    (fw_dir / "edk2-aarch64-code.fd").write_bytes(b"\x00" * 64)
    return {"qemu": str(qemu), "qemu_img": str(img)}


@pytest.fixture()
def fleet(tmp_path: Path, fake_bins: dict):
    """A GuestManager on a hermetic fleet root with fake prerequisites."""
    from guest_manager import GuestManager
    agents_root = tmp_path / "agents"
    guests_root = tmp_path / "guests"
    image = tmp_path / "base.img"
    image.write_bytes(b"\x00" * (2 << 20))  # tiny fake cloud image
    manager = GuestManager(
        agents_root=agents_root, guests_root=guests_root,
        qemu_bin=fake_bins["qemu"], qemu_img_bin=fake_bins["qemu_img"],
        image_url=image.as_uri(),
    )
    yield manager
    # Stop every guest this manager spawned so no fake-qemu process (and no
    # Popen ResourceWarning) outlives the test.
    for agent_id in list(manager._procs):
        try:
            manager.stop(agent_id)
        except Exception:  # noqa: BLE001 — teardown is best-effort
            pass


# ---------------------------------------------------------------------------
# Seed ISO builder
# ---------------------------------------------------------------------------

def _walk_iso(iso: bytes):
    """Yield (name, extent, size, record) from the root directory of a seed."""
    pvd = iso[16 * 2048:17 * 2048]
    assert pvd[1:6] == b"CD001"
    volume = pvd[40:72].rstrip()
    # The PVD's root record: len(1) ext(1) extent(8) size(8) … id-len(1) id.
    root_extent = struct.unpack("<I", pvd[158:162])[0]
    root_size = struct.unpack("<I", pvd[166:170])[0]
    root = iso[root_extent * 2048:root_extent * 2048 + root_size]
    out = []
    pos = 0
    while pos < len(root):
        length = root[pos]
        if length == 0:
            break
        rec = root[pos:pos + length]
        extent = struct.unpack("<I", rec[2:6])[0]
        size = struct.unpack("<I", rec[10:14])[0]
        name_len = rec[32]  # after len/ext/size/date/flags/unit/gap/vol-seq
        name = rec[33:33 + name_len]
        out.append((name, extent, size, rec))
        pos += length
    return root_extent, volume, out


def _root_records(iso: bytes) -> dict[bytes, bytes]:
    """Map filename -> raw directory record from the built seed."""
    _root_extent, _volume, entries = _walk_iso(iso)
    return {n: rec for n, _e, _s, rec in entries}



def test_seed_iso_structure(tmp_path: Path):
    """The seed ISO is a parseable cidata volume with both-case file names."""
    from seed_iso import build_seed_iso
    payloads = {
        "user-data": b"#cloud-config\nhostname: alice\n",
        "meta-data": b"instance-id: alice-1\nlocal-hostname: alice\n",
    }
    iso = build_seed_iso(payloads)
    root_extent, volume, entries = _walk_iso(iso)
    assert volume == b"CIDATA"
    names = [n for n, _e, _s, _r in entries]
    # "." and ".." plus every payload name in BOTH cases (belt + suspenders).
    for required in (b"\x00", b"\x01", b"user-data", b"USER-DATA",
                     b"meta-data", b"META-DATA"):
        assert required in names, f"missing {required!r} in {names!r}"
    by_name = {n: (e, s) for n, e, s, _r in entries}
    for name in (b"user-data", b"USER-DATA"):
        extent, size = by_name[name]
        assert iso[extent * 2048:extent * 2048 + size] == payloads["user-data"]
    # The PVD root record must point at the same directory we walked.
    assert root_extent == 20
    # Strictness regressions caught by pycdlib (the reader cloud-init uses):
    # the directory-record volume-sequence number is BOTH-endian (4 bytes),
    # and the root path-table record is exactly 8 bytes (empty id).
    records = _root_records(iso)
    for name in (b"user-data", b"USER-DATA", b"meta-data", b"META-DATA"):
        rec = records[name]
        assert rec[28:30] == b"\x01\x00" and rec[30:32] == b"\x00\x01"  # seq 1 LE/BE
    path_table = iso[18 * 2048:18 * 2048 + 8]
    assert struct.unpack("<I", path_table[2:6])[0] == root_extent
    assert len(path_table) == 8


# ---------------------------------------------------------------------------
# Lifecycle (real manager code, fake processes)
# ---------------------------------------------------------------------------

def test_boot_provisions_and_runs(fleet):
    st = fleet.boot("alice")
    assert st["state"] == "running"
    assert st["ssh_port"] and st["vnc_port"] and st["password"]
    guest_dir = fleet._guest_dir("alice")
    assert (guest_dir / "overlay.qcow2").exists()
    # The fake qemu writes its marker asynchronously after launch.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and \
            not (guest_dir / "overlay.qcow2.fake-marker").exists():
        time.sleep(0.05)
    assert (guest_dir / "overlay.qcow2.fake-marker").exists()  # qemu launched
    assert (guest_dir / "seed.iso").exists()
    state = json.loads((guest_dir / "state.json").read_text())
    assert state["pid"] == st["pid"] and state["pid"]
    # Base image provisioning ran exactly once and marked ready.
    assert fleet.base_status()["state"] == "ready"
    # Boot is idempotent: same process, no second spawn.
    again = fleet.boot("alice")
    assert again["pid"] == st["pid"]


def test_arm64_boot_carries_uefi_firmware(fleet):
    """arm64 guests boot with the edk2 pflash drive (UEFI-only images)."""
    from pathlib import Path as _P
    cmd = fleet._qemu_cmd(
        fleet.qemu_bin(), "alice", _P("/tmp/overlay.qcow2"),
        _P("/tmp/seed.iso"), vnc_display=1, ssh_port=2201, pidfile="/tmp/q.pid")
    pflash = [a for a in cmd if a.startswith("if=pflash,")]
    assert len(pflash) == 1
    assert "edk2-aarch64-code.fd" in pflash[0]


def test_boot_without_qemu_is_a_remediation_error(tmp_path: Path, fleet):
    from guest_manager import GuestManager, GuestError
    broken = GuestManager(
        agents_root=fleet.agents_root, guests_root=fleet.guests_root,
        qemu_bin="/nonexistent/qemu-system-aarch64",
        qemu_img_bin=fleet.qemu_img_bin(),
        image_url=str(tmp_path / "x"),
    )
    with pytest.raises(GuestError, match="brew install qemu"):
        broken.boot("alice")


def test_stop_terminates(fleet):
    st = fleet.boot("alice")
    stopped = fleet.stop("alice")
    assert stopped["state"] == "stopped"
    assert stopped["pid"] is None
    with pytest.raises(ProcessLookupError):
        os_kill_probe(st["pid"])


def os_kill_probe(pid: int) -> None:
    import os
    os.kill(pid, 0)


def test_reset_destroys_and_reboots_fresh(fleet):
    first = fleet.boot("alice")
    time.sleep(0.1)  # let the fake qemu marker land
    guest_dir = fleet._guest_dir("alice")
    overlay_inode = (guest_dir / "overlay.qcow2").stat().st_ino
    second = fleet.reset("alice")
    assert second["state"] == "running"
    assert second["password"] != first["password"]  # fresh identity
    assert (guest_dir / "overlay.qcow2").stat().st_ino != overlay_inode
    with pytest.raises(ProcessLookupError):
        os_kill_probe(first["pid"])


def test_reap_orphans_kills_previous_hub_life(fleet):
    """A new manager (hub restart) reaps a VM its predecessor left running."""
    fleet.boot("alice")
    pid = fleet._read_state("alice")["pid"]
    from guest_manager import GuestManager
    successor = GuestManager(
        agents_root=fleet.agents_root, guests_root=fleet.guests_root,
        qemu_bin=fleet.qemu_bin(), qemu_img_bin=fleet.qemu_img_bin(),
    )
    reaped = successor.reap_orphans()
    assert reaped == ["alice"]
    # Reap the zombie (the old manager still holds the Popen) so the pid is
    # genuinely gone, then probe it.
    old_proc = fleet._procs.pop("alice", None)
    if old_proc is not None:
        old_proc.wait(timeout=5)
    with pytest.raises(ProcessLookupError):
        os_kill_probe(pid)
    assert successor.status("alice")["state"] == "stopped"


# ---------------------------------------------------------------------------
# Frames (real RFB client against the fake VNC display)
# ---------------------------------------------------------------------------

def _decode_png(png: bytes) -> tuple[int, int, bytes]:
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack(">II", png[16:24])
    pos = 8
    idat = b""
    while pos < len(png):
        length = struct.unpack(">I", png[pos:pos + 4])[0]
        tag = png[pos + 4:pos + 8]
        if tag == b"IDAT":
            idat += png[pos + 8:pos + 8 + length]
        pos += 12 + length
    raw = zlib.decompress(idat)
    return width, height, raw


def test_frame_returns_a_png_of_the_guest_screen(fleet):
    fleet.boot("alice")
    png = fleet.frame("alice")
    width, height, raw = _decode_png(png)
    assert (width, height) == (96, 64)
    # Each PNG scanline starts with a filter byte, so pixel (x,y) lives at
    # raw[(1 + 96 * 3) * y + x * 3]. Pixel (0,0): fake sends B=0x80, G=0,
    # R=0 in BGRX; PNG is RGB.
    assert raw[1] == 0 and raw[2] == 0 and raw[3] == 0x80
    # Pixel (1,0): R=1.
    assert raw[4] == 1 and raw[5] == 0 and raw[6] == 0x80


def test_frame_before_boot_is_a_clean_error(fleet):
    from guest_manager import GuestError
    with pytest.raises(GuestError, match="boot it before grabbing"):
        fleet.frame("bob")


def test_stream_yields_until_stopped(fleet):
    fleet.boot("alice")
    frames = fleet.stream("alice", interval_s=0.05)
    first = next(frames)
    assert first[:8] == b"\x89PNG\r\n\x1a\n"
    fleet.stop("alice")
    with pytest.raises(StopIteration):
        next(frames)


# ---------------------------------------------------------------------------
# HTTP surface (real VertusHandler on a live server)
# ---------------------------------------------------------------------------

@pytest.fixture()
def http_server(fleet, tmp_path: Path):
    registry = AgentRegistry(root=fleet.agents_root)
    registry.create_agent("alice")
    vs.VertusHandler.registry = registry
    vs.VertusHandler.token = "test-token"
    vs.VertusHandler.guests = fleet
    vs.VertusHandler.health_snapshot = {}
    server = ThreadingHTTPServer(("127.0.0.1", 0), vs.VertusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    yield port
    server.shutdown()
    vs.VertusHandler.guests = None


def _client(port: int) -> http.client.HTTPConnection:
    return http.client.HTTPConnection("127.0.0.1", port, timeout=10)


def test_http_guests_list_and_boot_reset(http_server):
    port = http_server
    conn = _client(port)
    headers = {"Authorization": "Bearer test-token"}

    conn.request("GET", "/api/fleet/guests", headers=headers)
    resp = conn.getresponse()
    body = json.loads(resp.read())
    assert resp.status == 200
    assert body["guests"]["alice"]["state"] == "none"
    assert body["runtime"]["qemu"] == "found"
    assert body["runtime"]["base"]["state"] == "missing"

    conn.request("POST", "/api/fleet/guests/alice/boot", body=b"{}",
                 headers={**headers, "Content-Type": "application/json"})
    resp = conn.getresponse()
    body = json.loads(resp.read())
    assert resp.status == 200 and body["state"] == "running"
    first_password = body["password"]

    conn.request("POST", "/api/fleet/guests/alice/reset", body=b"{}",
                 headers={**headers, "Content-Type": "application/json"})
    resp = conn.getresponse()
    body = json.loads(resp.read())
    assert resp.status == 200 and body["state"] == "running"
    assert body["password"] != first_password

    conn.request("GET", "/api/fleet/guests", headers=headers)
    resp = conn.getresponse()
    body = json.loads(resp.read())
    assert body["guests"]["alice"]["state"] == "running"
    assert body["runtime"]["base"]["state"] == "ready"

    conn.request("POST", "/api/fleet/guests/nobody/boot", body=b"{}",
                 headers={**headers, "Content-Type": "application/json"})
    resp = conn.getresponse()
    assert resp.status == 404
    conn.close()


def test_http_frame_and_stream(http_server):
    port = http_server
    conn = _client(port)
    headers = {"Authorization": "Bearer test-token"}
    conn.request("POST", "/api/fleet/guests/alice/boot", body=b"{}",
                 headers={**headers, "Content-Type": "application/json"})
    conn.getresponse().read()

    conn.request("GET", "/api/fleet/guests/alice/frame", headers=headers)
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.getheader("Content-Type") == "image/png"
    png = resp.read()
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    conn.close()

    conn = _client(port)
    conn.request("GET", "/api/fleet/guests/alice/stream", headers=headers)
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.getheader("Content-Type", "").startswith("multipart/x-mixed-replace")
    assert resp.readline().strip() == b"--vertusframe"
    resp.readline()  # Content-Type
    length = int(resp.readline().split(b":")[1].strip())
    resp.readline()  # blank line
    part = resp.read(length)
    assert part[:8] == b"\x89PNG\r\n\x1a\n"
    conn.close()


def test_http_frame_requires_a_running_guest(http_server):
    conn = _client(http_server)
    conn.request("GET", "/api/fleet/guests/alice/frame",
                 headers={"Authorization": "Bearer test-token"})
    resp = conn.getresponse()
    assert resp.status == 409
    conn.close()
