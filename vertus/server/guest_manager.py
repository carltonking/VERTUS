"""Fleet-wide disposable guests: one Linux VM per agent (the Grok-Bot model).

What this is: one per-agent QEMU Linux VM — its own disk (copy-on-write
overlay on the shared base image), its own cloud-init-provisioned identity
(hostname, ssh password, **and a per-agent ed25519 ssh key**), and its
own VNC-exported screen streamed as PNG frames over the hub.

Identity model: each agent gets a **stable ed25519 keypair** written once
to `~/.vertus/agents/<id>/guest/ssh/` (id_ed25519 + id.pub + authorized_keys).
The public key is injected into the guest's authorized_keys via cloud-init's
ssh_authorized_keys, so the canonical credential is the key — not the
cloud-init password (which becomes a deprecated fallback only). A
per-agent key survives **reset only if the overlay disk survives** (which
is unlikely because reset deletes the overlay); the cheap, correct behavior
is to generate a fresh key on each boot iff the old one is gone. The key
is surfaced in `GET /api/fleet/guests/<id>` (`ssh_public_key`) and in
`state.json` so CLI/app/agent-tools can ssh in without parsing anything.

$0 path: ssh-keygen is part of macOS (and of any Linux that runs the hub).
No pip package, no external key provisioning service.

State layout:
    <agents_root>/<id>/guest/
        overlay.qcow2     # per-agent disk (copy-on-write on the base image)
        seed.iso          # cloud-init NoCloud seed (cidata label)
        ssh/              # per-agent ed25519 key (id_ed25519, id.pub,
                           authorized_keys) — survives reset iff the disk does
        state.json        # pid, ports, ssh_public_key, booted_at
        qemu.log          # qemu stderr (boot diagnostics)
    <guests_root>/base/<arch>/noble-server-cloudimg-<arch>.qcow2  # shared base
    <guests_root>/ports.json                                      # port registry
"""

from __future__ import annotations

import json
import os
import platform
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

# Dual import like vertus_server.py: plain for script-dir invocation, package-relative for -m.
try:
    import vertus_paths  # type: ignore
    from seed_iso import write_seed_iso  # type: ignore
    from vnc_rfb import VncFramebuffer, RfbError, encode_png_rgb  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore
    from .seed_iso import write_seed_iso  # type: ignore
    from .vnc_rfb import VncFramebuffer, RfbError, encode_png_rgb  # type: ignore

# The free cloud image this path provisions. URL is per-arch; override with
# VERTUS_GUEST_IMAGE_URL (tests point it at a tiny local file).
_UBUNTU_NOBLE = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-{arch}.img"
DISTRO_NAME = "ubuntu-24.04"

_VNC_BASE = 5900  # qemu -vnc <display> listens on 5900+display
_SSH_OFFSET = -3700  # ssh port = vnc port - 3700 (5911 -> 2211)


class GuestError(Exception):
    """Operational failure with a remediation-oriented message."""


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "").strip() or default)
    except ValueError:
        return default


def _port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.2)
        return s.connect_ex(("127.0.0.1", port)) != 0


def _tail(path: Path, n_lines: int = 8) -> str:
    try:
        lines = path.read_text(errors="replace").splitlines()
        return "\n".join(lines[-n_lines:])
    except OSError:
        return ""


class GuestManager:
    """Owns the fleet's disposable guests. Thread-safe for lifecycle ops.

    ``agents_root``/``guests_root`` default to the vertus_paths resolvers
    (which honor VERTUS_ROOT), read at INIT time — tests construct the
    manager with explicit temp roots.
    """

    def __init__(
        self,
        agents_root: Path | None = None,
        guests_root: Path | None = None,
        qemu_bin: str | None = None,
        qemu_img_bin: str | None = None,
        image_url: str | None = None,
        arch: str | None = None,
    ) -> None:
        self.agents_root = agents_root or vertus_paths.agents_dir()
        self.guests_root = guests_root or vertus_paths.guests_dir()
        self.arch = arch or platform.machine()
        self._qemu_bin = qemu_bin
        self._qemu_img_bin = qemu_img_bin
        self._image_url = image_url or os.environ.get(
            "VERTUS_GUEST_IMAGE_URL", ""
        ) or _UBUNTU_NOBLE.format(arch=self.arch)
        self.mem_mb = _env_int("VERTUS_GUEST_MEM_MB", 2048)
        self.smp = _env_int("VERTUS_GUEST_SMP", 2)
        self.disk_gb = _env_int("VERTUS_GUEST_DISK_GB", 12)
        self._provision_timeout_s = _env_int("VERTUS_GUEST_PROVISION_TIMEOUT_S", 1800)
        self._lock = threading.Lock()
        self._procs: dict[str, subprocess.Popen] = {}
        # Base-image provisioning: one event per manager life; a second
        # provision request waits on the first.
        self._provision_lock = threading.Lock()
        self._provision_event: threading.Event | None = None
        self._provision_error: str | None = None

    # ------------------------------------------------------------------
    # Binaries + base image (the only host prerequisites)
    # ------------------------------------------------------------------

    def qemu_bin(self) -> str | None:
        """Path to qemu-system-<arch>, or None with the install hint."""
        if self._qemu_bin:
            if not Path(self._qemu_bin).exists():
                raise GuestError(
                    f"qemu binary {self._qemu_bin} not found — install it "
                    "free with: brew install qemu")
            return self._qemu_bin
        name = "qemu-system-aarch64" if self.arch in ("arm64", "aarch64") \
            else "qemu-system-x86_64"
        found = shutil.which(name)
        if not found:
            raise GuestError(
                f"{name} not found in PATH — install it free with: brew install qemu"
            )
        self._qemu_bin = found
        return found

    def qemu_img_bin(self) -> str:
        if self._qemu_img_bin:
            return self._qemu_img_bin
        found = shutil.which("qemu-img")
        if not found:
            raise GuestError(
                "qemu-img not found in PATH — install it free with: brew install qemu"
            )
        self._qemu_img_bin = found
        return found

    def base_image_path(self) -> Path:
        return self.guests_root / "base" / self.arch / f"noble-server-cloudimg-{self.arch}.qcow2"

    def base_status(self) -> dict:
        """{state: ready|provisioning|error|missing, downloaded, total, error}.

        Deliberately LOCK-FREE: it is called from inside the lifecycle lock
        (boot -> _await_base) and only reads attributes the provisioning
        thread replaces wholesale — a plain read is safe here, and taking
        the lock would deadlock the re-entrant call.
        """
        base = self.base_image_path()
        ready = (base / ".." / ".ready").resolve()
        if self._provision_error:
            return {"state": "error", "error": self._provision_error}
        if self._provision_event is not None and not self._provision_event.is_set():
            return self._read_progress()
        if ready.exists() and base.exists():
            size_mb = base.stat().st_size // (1024 * 1024)
            return {"state": "ready", "image": DISTRO_NAME,
                    "arch": self.arch, "size_mb": size_mb,
                    "path": str(base)}
        if base.exists():
            return {"state": "provisioning", "image": DISTRO_NAME,
                    "arch": self.arch, "error": "convert/resize incomplete"}
        return {"state": "missing", "image": DISTRO_NAME,
                "arch": self.arch,
                "error": f"no base image yet (downloads {self._image_url})"}

    def _progress_path(self) -> Path:
        return self.guests_root / "base" / self.arch / "progress.json"

    def _read_progress(self) -> dict:
        try:
            data = json.loads(self._progress_path().read_text())
        except (OSError, json.JSONDecodeError):
            data = {"stage": "starting"}
        return {"state": "provisioning", "image": DISTRO_NAME, "arch": self.arch,
                **data}

    def ensure_base_image(self) -> None:
        """Start (or join) background provisioning of the shared base image.

        Non-blocking: returns immediately; ``boot`` blocks on the same
        event, so a boot during provisioning simply waits. Failures are
        recorded in ``_provision_error`` and surfaced in base_status().
        """
        if self.base_status()["state"] == "ready":
            return
        with self._provision_lock:
            if self._provision_event is not None:
                return
            self._provision_event = threading.Event()
        threading.Thread(target=self._provision, daemon=True,
                         name="guest-base-provision").start()

    def _provision(self) -> None:
        try:
            self._do_provision()
        except Exception as exc:  # noqa: BLE001 — recorded for base_status()
            self._provision_error = str(exc)[:300]
            self._write_progress({"stage": "error", "error": self._provision_error})
        finally:
            event = self._provision_event
            if event is not None:
                event.set()

    def _write_progress(self, data: dict) -> None:
        try:
            self._progress_path().parent.mkdir(parents=True, exist_ok=True)
            self._progress_path().write_text(json.dumps(data))
        except OSError:
            pass

    def _do_provision(self) -> None:
        base_dir = self.guests_root / "base" / self.arch
        base_dir.mkdir(parents=True, exist_ok=True)
        base = self.base_image_path()
        qemu_img = self.qemu_img_bin()
        download = base_dir / "download.img"
        # 1. Download the free cloud image (streamed, with progress).
        if not base.exists():
            if not download.exists():
                self._write_progress({"stage": "downloading",
                                      "url": self._image_url})
                req = urllib.request.Request(self._image_url, headers={
                    "User-Agent": "vertus-guest-manager/1.0"})
                with urllib.request.urlopen(req, timeout=60) as resp:
                    total = int(resp.headers.get("Content-Length") or 0)
                    got = 0
                    with open(download, "wb") as fh:
                        while True:
                            chunk = resp.read(1 << 16)
                            if not chunk:
                                break
                            fh.write(chunk)
                            got += len(chunk)
                            if total:
                                self._write_progress(
                                    {"stage": "downloading", "url": self._image_url,
                                     "downloaded": got, "total": total})
            # 2. Convert to qcow2 (copy-on-write base for per-agent overlays).
            self._write_progress({"stage": "converting"})
            subprocess.run(
                [qemu_img, "convert", "-O", "qcow2", str(download), str(base)],
                check=True, capture_output=True)
            # 3. Grow to the fleet-wide disk size (sparse — cheap).
            self._write_progress({"stage": "resizing", "disk_gb": self.disk_gb})
            subprocess.run(
                [qemu_img, "resize", str(base), f"+{self.disk_gb}G"],
                check=True, capture_output=True)
            download.unlink(missing_ok=True)
        (base_dir / ".ready").write_text(
            json.dumps({"image": DISTRO_NAME, "arch": self.arch,
                        "ready_at": int(time.time())}))
        self._write_progress({"stage": "ready"})

    def _await_base(self) -> None:
        """Block until the base image is ready (or provisioning failed)."""
        if self.base_status()["state"] == "ready":
            return
        self.ensure_base_image()
        deadline = time.monotonic() + self._provision_timeout_s
        event = self._provision_event
        while event is not None and time.monotonic() < deadline:
            if event.wait(2.0):
                break
        status = self.base_status()
        if status["state"] != "ready":
            raise GuestError(
                f"base image not ready: {status.get('state')} "
                f"({status.get('error') or 'provisioning timed out'})")

    # ------------------------------------------------------------------
    # Port registry
    # ------------------------------------------------------------------

    def _ports(self) -> dict:
        path = self.guests_root / "ports.json"
        try:
            return json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            return {}

    def _save_ports(self, ports: dict) -> None:
        self.guests_root.mkdir(parents=True, exist_ok=True)
        (self.guests_root / "ports.json").write_text(json.dumps(ports, indent=2))

    def _alloc_ports(self, agent_id: str) -> tuple[int, int]:
        """Stable per-agent ports, scanning upward past anything in use."""
        ports = self._ports()
        existing = ports.get(agent_id)
        if existing and _port_free(existing["vnc"]):
            return existing["vnc"], existing["ssh"]
        display = 1
        for other in ports.values():
            display = max(display, (other["vnc"] - _VNC_BASE) + 1)
        while True:
            vnc = _VNC_BASE + display
            ssh = vnc + _SSH_OFFSET
            if _port_free(vnc) and _port_free(ssh):
                ports[agent_id] = {"vnc": vnc, "ssh": ssh}
                self._save_ports(ports)
                return vnc, ssh
            display += 1

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def _guest_dir(self, agent_id: str) -> Path:
        return self.agents_root / agent_id / "guest"

    def _state_path(self, agent_id: str) -> Path:
        return self._guest_dir(agent_id) / "state.json"

    def _read_state(self, agent_id: str) -> dict | None:
        try:
            return json.loads(self._state_path(agent_id).read_text())
        except (OSError, json.JSONDecodeError):
            return None

    def _write_state(self, agent_id: str, state: dict) -> None:
        self._guest_dir(agent_id).mkdir(parents=True, exist_ok=True)
        (self._state_path(agent_id)).write_text(json.dumps(state, indent=2))

    def _key_rotation(self) -> dict:
        """Per-agent key inventory for the fleet status: which agents have a
        key, which need rotation (none yet — rotation is opt-in via reset
        with FRIENDLY_KEY_ROTATE=1)."""
        # Purely a dashboard signal; nothing forces rotation.
        inventory: dict[str, dict] = {}
        if not self.agents_root.exists():
            return inventory
        for guest_dir in self.agents_root.glob("*/guest"):
            agent_id = guest_dir.parent.name
            pub = guest_dir / "ssh" / "id.pub"
            if pub.exists():
                inventory[agent_id] = {
                    "has_key": True,
                    "public_key": pub.read_text().strip(),
                }
        return inventory

    def boot(self, agent_id: str) -> dict:
        """Provision + start the agent's guest. Returns its status dict."""
        with self._lock:
            return self._boot_locked(agent_id)

    def _boot_locked(self, agent_id: str) -> dict:
        state = self._read_state(agent_id)
        if state and self._pid_alive(state):
            return self.status(agent_id)
        # Fail fast on a missing qemu BEFORE a multi-hundred-MB base image
        # download, and before any other guest work.
        qemu = self.qemu_bin()
        self._await_base()
        guest_dir = self._guest_dir(agent_id)
        guest_dir.mkdir(parents=True, exist_ok=True)
        overlay = guest_dir / "overlay.qcow2"
        seed = guest_dir / "seed.iso"
        if not overlay.exists():
            subprocess.run(
                [self.qemu_img_bin(), "create", "-f", "qcow2", "-F", "qcow2",
                 "-b", str(self.base_image_path()), str(overlay)],
                check=True, capture_output=True)
        password = secrets.token_urlsafe(9)
        pub_key = self._write_seed(agent_id, seed, password)
        vnc_port, ssh_port = self._alloc_ports(agent_id)
        vnc_display = vnc_port - _VNC_BASE
        pidfile = guest_dir / "qemu.pid"
        cmd = self._qemu_cmd(qemu, agent_id, overlay, seed, vnc_display, ssh_port,
                             str(pidfile))
        log_path = guest_dir / "qemu.log"
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.DEVNULL, stderr=open(log_path, "ab"))
        except OSError as exc:
            raise GuestError(f"failed to launch qemu: {exc}") from exc
        self._procs[agent_id] = proc
        self._write_state(agent_id, {
            "agent_id": agent_id, "pid": proc.pid,
            "vnc_display": vnc_display, "vnc_port": vnc_port,
            "ssh_port": ssh_port, "password": password,
            "ssh_public_key": pub_key,
            "booted_at": int(time.time()), "arch": self.arch,
            "image": DISTRO_NAME, "error": None,
        })
        return self.status(agent_id)

    def _edk2_firmware(self, qemu: str) -> str:
        """The UEFI firmware path for arm64 guests (Ubuntu cloud images are
        UEFI-only and will not boot without it). Resolved next to the qemu
        install (bin/../share/qemu), with the common Homebrew locations as
        fallback. Raises GuestError with a remediation when missing."""
        candidates = [
            Path(qemu).resolve().parent.parent / "share" / "qemu",
            Path("/opt/homebrew/share/qemu"),
            Path("/usr/local/share/qemu"),
            Path("/usr/share/qemu"),
        ]
        for base in candidates:
            fw = base / "edk2-aarch64-code.fd"
            if fw.exists():
                return str(fw)
        raise GuestError(
            "edk2-aarch64-code.fd not found (arm64 guests are UEFI-only) — "
            "reinstall qemu: brew reinstall qemu")

    def _qemu_cmd(self, qemu: str, agent_id: str, overlay: Path, seed: Path,
                  vnc_display: int, ssh_port: int, pidfile: str) -> list[str]:
        if self.arch in ("arm64", "aarch64"):
            machine = ["-machine", "virt"]
        else:
            machine = ["-machine", "pc"]
        cmd = [
            qemu, *machine, "-accel", "hvf", "-cpu", "host",
            "-smp", str(self.smp), "-m", f"{self.mem_mb}M",
        ]
        if self.arch in ("arm64", "aarch64"):
            # UEFI firmware (read-only code flash); without it the cloud
            # image's EFI system partition has nothing to boot.
            cmd += ["-drive",
                    f"if=pflash,format=raw,readonly=on,file={self._edk2_firmware(qemu)}"]
        cmd += [
            "-drive", f"file={overlay},if=virtio,format=qcow2",
            "-drive", f"file={seed},media=cdrom,readonly=on,format=raw",
            "-nic", f"user,model=virtio-net-pci,hostfwd=tcp::{ssh_port}-:22",
            "-vnc", f"127.0.0.1:{vnc_display}",
            "-display", "none",
            # The guest console (Ubuntu's ttyAMA0) IS the serial port; put it
            # on the VNC display so the streamed screen shows the guest, and
            # disable qemu's own monitor so it never claims the display.
            # ('vc' = the virtual console exposed through -vnc; '-serial vnc'
            # is NOT a valid char driver.)
            "-monitor", "none",
            "-serial", "vc",
            "-pidfile", pidfile,
        ]
        return cmd

    def _write_seed(self, agent_id: str, seed: Path, password: str) -> str:
        """Build the cloud-init seed for this agent's guest.

        Provisions a **per-agent ed25519 keypair** in
        ``~/.vertus/agents/<id>/guest/ssh/`` (id_ed25519 + id.pub +
        authorized_keys) iff one does not already exist. The public key is
        injected into the guest's ``authorized_keys`` via cloud-init's
        ``ssh_authorized_keys``, so the canonical credential is the key —
        the cloud-init password becomes a deprecated fallback only.

        Returns the public key (the agent's ssh identity).
        """
        guest_dir = self._guest_dir(agent_id)
        key_dir = guest_dir / "ssh"
        key_dir.mkdir(parents=True, exist_ok=True)
        priv_path = key_dir / "id_ed25519"
        pub_path = key_dir / "id.pub"
        existing_pub = pub_path.read_text().strip() if pub_path.exists() else ""
        if not existing_pub:
            import subprocess as _sp
            _sp.run(["ssh-keygen", "-t", "ed25519", "-f", str(priv_path),
                     "-N", "", "-C", f"vertus:{agent_id}"],
                     check=True, capture_output=True, timeout=10)
            gen_pub = key_dir / "id_ed25519.pub"
            existing_pub = gen_pub.read_text().strip() if gen_pub.exists() else ""
            if existing_pub:
                pub_path.write_text(existing_pub + "\n")
            else:
                # ssh-keygen writes id_ed25519.pub, not id.pub — read it back.
                import subprocess as _sp
                out = _sp.run(["ssh-keygen", "-y", "-f", str(priv_path)],
                              capture_output=True, check=True, timeout=10)
                existing_pub = out.stdout.decode().strip()
                (key_dir / "id.pub").write_text(existing_pub + "\n")
            # authorized_keys on the host: the same pub key so the agent's
            # key is self-consistent (used by human operators/agent-tools).
            (key_dir / "authorized_keys").write_text(existing_pub + "\n")
        # The public key IS the identity; password remains only as a
        # deprecated fallback for hosts without ssh keys.
        authorized_keys = (key_dir / "authorized_keys").read_text().strip()
        if not authorized_keys or existing_pub not in authorized_keys.splitlines():
            (key_dir / "authorized_keys").write_text(existing_pub + "\n")
        # authorized_keys as a file written into the user-data write_files
        # (cloud-init writes one into /home/ubuntu/.ssh/authorized_keys).
        user_data = (
            "#cloud-config\n"
            f"hostname: {agent_id}\n"
            "preserve_hostname: true\n"
            "users:\n"
            "  - default\n"
            "chpasswd:\n"
            "  expire: false\n"
            "  users:\n"
            "    - name: ubuntu\n"
            f"      password: {password}\n"
            "      type: text\n"
            "ssh_pwauth: true\n"
            "disable_root: false\n"
            "ssh_authorized_keys:\n"
            "  - " + existing_pub + "\n"
        ).encode()
        meta_data = (
            f"instance-id: {agent_id}-{int(time.time())}\n"
            f"local-hostname: {agent_id}\n"
        ).encode()
        # Per-agent ssh identity: a stable ed25519 keypair so clients (CLI,
        # app, agent tools) can reach the guest without parsing state.json or
        # sending the cloud-init password. The public key is injected into
        # authorized_keys; the private key is stored (chmod 600) in the
        # agent's guest dir so the same identity survives reset iff the disk
        # survives (on reset we generate a fresh key iff the old one is gone).
        key_dir = guest_dir / "ssh"
        key_dir.mkdir(parents=True, exist_ok=True)
        priv_path = key_dir / "id_ed25519"
        pub_path = key_dir / "id.pub"
        existing_pub = pub_path.read_text().strip() if pub_path.exists() else ""
        if not existing_pub:
            import subprocess as _sp
            _sp.run(["ssh-keygen", "-t", "ed25519", "-f", str(priv_path),
                     "-N", "", "-C", f"vertus:{agent_id}"],
                     check=True, capture_output=True, timeout=10)
            # ssh-keygen writes id_ed25519.pub, not id.pub — read it back.
            (key_dir / "id.pub").write_text((key_dir / "id_ed25519.pub").read_text())
            existing_pub = pub_path.read_text().strip()
        # authorized_keys on the host: the same pub key so the agent's
        # key is self-consistent (used by human operators/agent-tools).
        (key_dir / "authorized_keys").write_text(existing_pub + "\n")
        # The public key IS the identity; password remains only as a
        # deprecated fallback for hosts without ssh keys.
        authorized_keys = (key_dir / "authorized_keys").read_text().strip()
        if not authorized_keys or existing_pub not in authorized_keys.splitlines():
            (key_dir / "authorized_keys").write_text(existing_pub + "\n")
        # authorized_keys as a file written into the user-data write_files
        # (cloud-init writes one into /home/ubuntu/.ssh/authorized_keys).
        user_data = (
            "#cloud-config\n"
            f"hostname: {agent_id}\n"
            "preserve_hostname: true\n"
            "users:\n"
            "  - default\n"
            "chpasswd:\n"
            "  expire: false\n"
            "  users:\n"
            "    - name: ubuntu\n"
            f"      password: {password}\n"
            "      type: text\n"
            "ssh_pwauth: true\n"
            "disable_root: false\n"
            "ssh_authorized_keys:\n"
            "  - " + existing_pub + "\n"
        ).encode()
        write_seed_iso(seed, {"user-data": user_data, "meta-data": meta_data})
        return existing_pub

    def stop(self, agent_id: str, grace_s: float = 3.0) -> dict:
        """Terminate the guest's qemu process (SIGTERM, then SIGKILL)."""
        with self._lock:
            state = self._read_state(agent_id)
            if state and self._pid_alive(state):
                self._kill(state["pid"], grace_s)
            self._procs.pop(agent_id, None)
            self._write_state(agent_id, {
                **({k: v for k, v in state.items() if k != "pid"}
                   if state else {"agent_id": agent_id}),
                "state": "stopped", "pid": None,
            })
            return self.status(agent_id)

    def reset(self, agent_id: str) -> dict:
        """Destroy the guest's disk + seed and boot a fresh one."""
        with self._lock:
            state = self._read_state(agent_id)
            if state and self._pid_alive(state):
                self._kill(state["pid"], grace_s=3.0)
            self._procs.pop(agent_id, None)
            guest_dir = self._guest_dir(agent_id)
            shutil.rmtree(guest_dir, ignore_errors=True)
            return self._boot_locked(agent_id)

    @staticmethod
    def _kill(pid: int, grace_s: float) -> None:
        try:
            os.kill(pid, 15)  # SIGTERM — qemu exits cleanly
        except ProcessLookupError:
            return
        deadline = time.monotonic() + grace_s
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        try:
            os.kill(pid, 9)  # SIGKILL — disposable; never leave it running
        except ProcessLookupError:
            pass

    # ------------------------------------------------------------------
    # Status + orphan reaping
    # ------------------------------------------------------------------

    def _pid_alive(self, state: dict) -> bool:
        pid = state.get("pid")
        if not pid:
            return False
        proc = self._procs.get(state.get("agent_id"))
        if proc is not None:
            return proc.poll() is None
        try:
            os.kill(pid, 0)
            return True
        except (ProcessLookupError, PermissionError, ValueError):
            return False

    def status(self, agent_id: str) -> dict:
        state = self._read_state(agent_id)
        out: dict = {
            "agent_id": agent_id, "state": "none", "image": DISTRO_NAME,
            "vnc_port": None, "ssh_port": None, "password": None,
            "ssh_public_key": None,
            "booted_at": None, "pid": None, "error": None,
        }
        if not state:
            return out
        out.update({k: state.get(k) for k in (
            "vnc_port", "ssh_port", "password", "ssh_public_key",
            "booted_at", "pid", "error")})
        if self._pid_alive(state):
            out["state"] = "running"
        else:
            out["state"] = "stopped"
            if state.get("pid"):
                out["error"] = _tail(self._guest_dir(agent_id) / "qemu.log") or \
                    "qemu exited"
        return out

    def fleet_status(self, agent_ids: list[str]) -> dict:
        """Status for every listed agent, plus the shared runtime facts."""
        guests = {aid: self.status(aid) for aid in agent_ids}
        try:
            qemu_ok = self.qemu_bin() is not None
            qemu = "found" if qemu_ok else "missing"
        except GuestError:
            qemu = "missing"
        return {
            "guests": guests,
            "runtime": {
                "qemu": qemu,
                "qemu_install_hint": "brew install qemu" if qemu == "missing" else "",
                "base": self.base_status(),
            "key_rotation": self._key_rotation(),
        },
        }

    def reap_orphans(self) -> list[str]:
        """Kill any guest VM left running from a previous hub life.

        A hub restart owns the guests again at boot; anything still running
        belongs to a dead hub and is disposable by definition. Only pids
        whose process command line references THIS agent's guest dir are
        killed — a reused pid pointing at an unrelated process is left
        alone (and its state marked stopped).
        """
        reaped: list[str] = []
        if not self.agents_root.exists():
            return reaped
        for guest_dir in self.agents_root.glob("*/guest"):
            if not guest_dir.is_dir():
                continue
            agent_id = guest_dir.parent.name
            state_path = guest_dir / "state.json"
            try:
                state = json.loads(state_path.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            pid = state.get("pid")
            if not pid:
                continue
            try:
                alive = os.kill(pid, 0) is None
            except ProcessLookupError:
                alive = False
            except PermissionError:
                alive = True
            if alive and self._cmdline_mentions(pid, str(guest_dir)):
                self._kill(pid, grace_s=2.0)
                reaped.append(agent_id)
            if not alive:
                state["pid"] = None
                state["state"] = "stopped"
                try:
                    state_path.write_text(json.dumps(state, indent=2))
                except OSError:
                    pass
        return reaped

    @staticmethod
    def _cmdline_mentions(pid: int, needle: str) -> bool:
        try:
            out = subprocess.run(
                ["ps", "-p", str(pid), "-o", "command="],
                capture_output=True, text=True, timeout=5)
            return needle in (out.stdout or "")
        except (OSError, subprocess.SubprocessError):
            return False

    # ------------------------------------------------------------------
    # Screen frames
    # ------------------------------------------------------------------

    def frame(self, agent_id: str, boot_grace_s: float = 15.0) -> bytes:
        """One PNG of the guest's current screen. GuestError when not running.

        Retries for ``boot_grace_s`` when the VNC display is not listening
        yet (qemu accepts the process but takes seconds to open the display),
        so a client can call this immediately after ``boot``.
        """
        st = self.status(agent_id)
        if st["state"] != "running" or not st["vnc_port"]:
            raise GuestError(
                f"guest {agent_id} is {st['state']} — boot it before grabbing frames")
        deadline = time.monotonic() + boot_grace_s
        last: Exception | None = None
        while time.monotonic() < deadline:
            try:
                with VncFramebuffer("127.0.0.1", st["vnc_port"], timeout=5) as fb:
                    w, h, rgb = fb.grab()
                return encode_png_rgb(w, h, rgb)
            except (RfbError, OSError) as exc:
                last = exc
                time.sleep(0.5)
        raise GuestError(f"screen grab failed: {last}")

    def stream(self, agent_id: str, interval_s: float = 0.5):
        """Yield PNG frames until the guest stops or the client goes away.

        One VNC connection per stream; a full framebuffer update per frame
        (the console screen compresses well, so this is cheap at ~2 fps).
        Reconnects briefly when the grab races the VM's boot.
        """
        while True:
            st = self.status(agent_id)
            if st["state"] != "running":
                return
            try:
                yield self.frame(agent_id)
            except GuestError:
                time.sleep(interval_s)
                continue
            time.sleep(interval_s)


# ---------------------------------------------------------------------------
# CLI (python3 -m vertus.server.guest_manager boot <agent> …)
# ---------------------------------------------------------------------------

def _cli(argv: list[str] | None = None) -> None:
    import argparse
    import urllib.parse as _up

    def hub_get(verb: str, path: str, body: dict | None = None) -> dict:
        import urllib.request as u
        token = vertus_paths.token_path()
        try:
            tok = token.read_text().strip()
        except OSError:
            tok = ""
        url = vertus_paths.hub_url() + path
        data = json.dumps(body).encode() if body is not None else None
        req = u.Request(url, data=data, method=verb, headers={
            "Authorization": f"Bearer {tok}",
            "Content-Type": "application/json",
        })
        with u.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())

    p = argparse.ArgumentParser(prog="guest", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, help_text in (("status", "guest status for all agents (or one)"),
                            ("boot", "boot an agent's guest"),
                            ("stop", "stop an agent's guest"),
                            ("reset", "destroy + reboot an agent's guest")):
        sp = sub.add_parser(name, help=help_text)
        sp.add_argument("agent", nargs="?")
    sp = sub.add_parser("url", help="print the browser stream URL for an agent")
    sp.add_argument("agent")
    args = p.parse_args(argv)

    if args.cmd == "url":
        agent = _up.quote(args.agent, safe="")
        print(f"{vertus_paths.hub_url()}/api/fleet/guests/{agent}/stream")
        return
    if args.cmd == "status":
        result = hub_get("GET", "/api/fleet/guests")
        wanted = args.agent
        for aid, st in sorted(result.get("guests", {}).items()):
            if wanted and aid != wanted:
                continue
            print(f"{aid:12s} {st['state']:10s} vnc={st.get('vnc_port')} "
                  f"ssh={st.get('ssh_port')} "
                  f"pw={st.get('password') or '-'} "
                  f"key={'yes' if st.get('ssh_public_key') else '-'}")
        if not wanted:
            print(f"runtime: qemu={result['runtime']['qemu']} "
                  f"base={result['runtime']['base']['state']} "
                  f"keys={result['runtime'].get('key_rotation', {})}")
    else:
        path = f"/api/fleet/guests/{_up.quote(args.agent, safe='')}/{args.cmd}"
        st = hub_get("POST", path)
        print(f"{args.cmd}: {st['state']} "
              f"(vnc={st.get('vnc_port')} ssh={st.get('ssh_port')} "
              f"pw={st.get('password') or '-'} "
              f"key={'yes' if st.get('ssh_public_key') else '-'})")


if __name__ == "__main__":
    _cli()