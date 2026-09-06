"""``vertus doctor`` — diagnostics for the VERTUS fleet.

Why this exists (recommendation accepted): nothing in the repo verifies that
the forked hermes gateway still speaks the JSON-RPC dialect the bridge
depends on. Every spawn-path assumption (session.create params, prompt.submit,
the event vocabulary) is reverse-engineered from an external codebase that
can change under us. This tool probes a THROWAWAY gateway against the real
fork and asserts the exact RPC/event surface ``hermes_bridge.py`` uses, so a
fork update that renames a method or drops an event type is caught in
seconds, not when a turn dies at 3am.

Invocation:

    python3 vertus/server/vertus_server.py doctor [--json]

(There is no repo-owned ``vertus`` CLI — the terminal client is pi's, outside
this repo — so the entry is the server module's ``doctor`` subcommand. A
future repo-owned CLI can wire ``vertus doctor`` with one line.)

Rules baked into every check:

  - read-only: never writes to ~/.vertus, never mutates the real DB or agent
    homes, never kills the user's CuaDriver.app daemon (identified by
    ``--cua-internal-gate-engaged``, not by process name);
  - safe against a live hub (only GET /api/health) and with no hub running;
  - no real model turns: if a check can only be proven by one, it is
    ``unverified`` with the reason — never a hang;
  - a ``fail`` always carries a remediation, never just a complaint;
  - under 30s end to end (the gateway cold start is ~12s and dominates).
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

# Dual import like vertus_server.py: plain for script-dir invocation, package-relative for -m.
try:
    import vertus_paths  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore

from hermes_bridge import (
    FORK_REPO,
    VENV_PYTHON,
    _HermesSession,
    build_gateway_env,
)

# -- configuration (all diagnostic-only knobs) ------------------------------
# Read from env at CALL time, not import time, so tests can point the whole
# tool at a temp fleet without reloading the module.

def _cfg() -> dict:
    return {
        "ready_timeout_s": float(os.environ.get("VERTUS_DOCTOR_READY_TIMEOUT_S", "20")),
        "rpc_timeout_s": float(os.environ.get("VERTUS_DOCTOR_RPC_TIMEOUT_S", "10")),
        "skip_launchd": os.environ.get("VERTUS_DOCTOR_SKIP_LAUNCHD") == "1",
        "hub_port": int(os.environ.get("VERTUS_PORT", "8787")),
        "agents_dir": vertus_paths.agents_dir(),
        "db_path": vertus_paths.fleet_db_path(),
        "token_file": vertus_paths.token_path(),
    }

# The event types the bridge's _handle_event actually parses. All but
# gateway.ready are only observable during a live turn.
_BRIDGE_EVENT_TYPES = (
    "gateway.ready",
    "message.delta",
    "message.complete",
    "tool.start",
    "turn.end",
    "error",
)
# RPCs the bridge calls on every turn/session path.
_BRIDGE_RPCS = (
    "session.create",
    "prompt.submit",
    "session.interrupt",
    "commands.catalog",
    "command.dispatch",
    "session.active_list",
)
# RPCs nothing in the hub calls today but the fleet's approval/config paths
# assume exist in the fork's surface. Missing here is a warn (drift signal),
# not a fail — nothing in the runtime path breaks.
_FORK_ONLY_RPCS = (
    "config.get",
    "approval.pending",
    "approval.respond",
)

_STATUS = ("ok", "warn", "fail", "unverified")


def _check(name: str, status: str, reason: str, remediation: str = "") -> dict:
    assert status in _STATUS, status
    return {"name": name, "status": status, "reason": reason,
            "remediation": remediation}


# -- environment ------------------------------------------------------------

def _git(args: list[str], cwd: Path) -> str | None:
    try:
        out = subprocess.run(
            ["git", *args], cwd=str(cwd), capture_output=True, text=True,
            timeout=10, check=False,
        )
        return out.stdout.strip() or None
    except Exception:
        return None


def _venv_site_packages(venv_py: Path) -> Path | None:
    """venv/bin/python -> venv/lib/python3.X/site-packages (newest py)."""
    base = venv_py.parent.parent
    lib = base / "lib"
    if not lib.is_dir():
        return None
    pys = sorted(lib.glob("python3.*"))
    if not pys:
        return None
    sp = pys[-1] / "site-packages"
    return sp if sp.is_dir() else None


def _editable_install_target(fork: Path, venv_py: Path) -> tuple[Path | None, str | None]:
    """When `fork` is a venv-only dir (no .git), find the real checkout the
    venv runs via an editable install. Returns (target, None) or
    (None, reason) with a DISTINCT reason per failure mode."""
    sp = _venv_site_packages(venv_py)
    if sp is None:
        return None, "venv has no site-packages to inspect"
    infos = list(sp.glob("*.dist-info"))
    if not infos:
        return None, "venv site-packages has no dist-info (nothing installed?)"
    seen_non_editable = False
    for info in infos:
        direct = info / "direct_url.json"
        if not direct.is_file():
            continue
        try:
            data = json.loads(direct.read_text())
        except Exception:
            continue
        if data.get("dir_info", {}).get("editable") is not True:
            seen_non_editable = True
            continue
        url = data.get("url", "")
        if not url.startswith("file://"):
            continue
        target = Path(urllib.parse.unquote(url[len("file://"):]))
        if not target.is_dir():
            return None, f"editable install target missing: {target}"
        return target, None
    if seen_non_editable:
        return None, "dist-info present but no editable direct_url.json " \
                     "(packages are regular copies, not editable installs)"
    return None, "no direct_url.json in any dist-info (non-pip install?)"


def _fork_git_target(fork: Path, venv_py: Path) -> tuple[Path | None, str | None]:
    """The git repo the fork ACTUALLY runs from: the checkout itself when it
    has .git, otherwise the editable-install target from the venv."""
    if (fork / ".git").exists():
        return fork, None
    return _editable_install_target(fork, venv_py)


def _entry_imports(venv_python: Path, fork: Path) -> bool:
    """Can the gateway's entry module be imported under the venv from the
    fork cwd? The real precondition of every spawn (import is inert — it
    does not run the gateway). This is the check that matters: the checkout
    may be an editable-install venv with no source tree of its own."""
    try:
        r = subprocess.run(
            [str(venv_python), "-c",
             "import importlib; importlib.import_module('tui_gateway.entry')"],
            cwd=str(fork), capture_output=True, text=True, timeout=15,
            check=False,
        )
        return r.returncode == 0
    except Exception:
        return False


def env_checks() -> list[dict]:
    out: list[dict] = []
    fork = vertus_paths.fork_repo()
    venv_py = vertus_paths.venv_python()

    # fork checkout — functionally: spawn cwd exists AND the gateway entry
    # imports under the venv. (.git is NOT required: this machine's checkout
    # is a venv with an editable install pointing at the real fork.)
    if fork.is_dir() and venv_py.is_file() and _entry_imports(venv_py, fork):
        out.append(_check("env.fork_checkout", "ok",
                          f"fork resolvable at {fork}: tui_gateway.entry imports "
                          "under the venv"))
    else:
        missing = []
        if not fork.is_dir():
            missing.append("checkout dir")
        if not venv_py.is_file():
            missing.append("venv python")
        if missing:
            out.append(_check("env.fork_checkout", "fail",
                              f"{', '.join(missing)} not found at {fork}",
                              "set VERTUS_HERMES_REPO / VERTUS_HERMES_PYTHON to the "
                              "fork checkout and its venv python — the bridge spawns "
                              "from these defaults"))
        else:
            out.append(_check("env.fork_checkout", "fail",
                              f"{fork} exists but tui_gateway.entry does not import "
                              "under its venv python",
                              "the fork moved its entry point or the venv is stale — "
                              "recreate the venv or point VERTUS_HERMES_REPO at the "
                              "real checkout"))

    # fork git SHA + local drift — against the checkout the venv ACTUALLY
    # runs (a venv-only dir with an editable install used to report
    # "unverified" while the live hub ran a dirty clone the doctor could not
    # see: a drift check that cannot see drift is worse than no check).
    target, resolve_err = _fork_git_target(fork, venv_py) if fork.is_dir() else (None, "checkout dir missing")
    if target is None:
        out.append(_check("env.fork_git_sha", "unverified",
                          f"cannot resolve a git checkout for {fork}: {resolve_err}",
                          "set VERTUS_HERMES_REPO to a checkout that has .git, or "
                          "reinstall the fork editable from a git clone"))
    else:
        sha = _git(["rev-parse", "HEAD"], target)
        if sha is None:
            out.append(_check("env.fork_git_sha", "unverified",
                              f"{target} is not a git repo (no HEAD) — SHA drift is "
                              "invisible run over run",
                              "the fork's real checkout has no .git; commit or clone "
                              "properly if you want drift visible"))
        else:
            branch = _git(["rev-parse", "--abbrev-ref", "HEAD"], target) or "detached"
            dirty = _git(["status", "--porcelain"], target)
            where = f" (editable install → {target})" if target != fork else ""
            reason = f"fork SHA {sha[:12]} on {branch}{where}"
            if dirty:
                out.append(_check("env.fork_git_sha", "warn",
                                  reason + f" + {len(dirty.splitlines())} uncommitted change(s)",
                                  "commit or stash fork changes; the dialect you test may "
                                  "not be the dialect that runs"))
            else:
                out.append(_check("env.fork_git_sha", "ok", reason))

    # venv python present and runnable
    if venv_py.is_file():
        try:
            v = subprocess.run(
                [str(venv_py), "-V"], capture_output=True, text=True,
                timeout=10, check=False,
            )
            if v.returncode == 0:
                out.append(_check("env.venv_python", "ok",
                                  f"{venv_py} runs ({v.stdout.strip() or v.stderr.strip()})"))
            else:
                out.append(_check("env.venv_python", "fail",
                                  f"{venv_py} exists but exits {v.returncode}: "
                                  f"{(v.stderr or v.stdout).strip()[:200]}",
                                  "repair or recreate the fork's venv, or set "
                                  "VERTUS_HERMES_PYTHON"))
        except Exception as exc:
            out.append(_check("env.venv_python", "fail",
                              f"{venv_py} did not answer -V: {exc}",
                              "check the interpreter is executable"))
    else:
        out.append(_check("env.venv_python", "fail",
                          f"venv python missing at {venv_py}",
                          "create the fork's venv, or set VERTUS_HERMES_PYTHON"))

    # interpreter + stdlib assumptions: the hub's code is 3.10+ syntax; the
    # real proof is that the server modules import under this interpreter.
    py = sys.version_info
    if py >= (3, 10):
        out.append(_check("env.python_interp", "ok",
                          f"Python {py.major}.{py.minor}.{py.micro} (>= 3.10)"))
    else:
        out.append(_check("env.python_interp", "fail",
                          f"Python {py.major}.{py.minor} — hub code uses 3.10+ syntax",
                          "run doctor (and the hub) with Python >= 3.10"))
    try:
        subprocess.run(
            [sys.executable, "-c",
             "import vertus_server, run_store, agent_registry, hermes_bridge"],
            cwd=str(Path(__file__).parent), capture_output=True, text=True,
            timeout=20, check=True,
        )
        out.append(_check("env.server_modules_import", "ok",
                          "vertus_server, run_store, agent_registry, hermes_bridge import"))
    except subprocess.CalledProcessError as exc:
        out.append(_check("env.server_modules_import", "fail",
                          f"a server module fails to import: {exc.stderr.strip()[:200]}",
                          "fix the import error — the hub cannot boot either"))

    # cua-driver
    driver_cmd = os.environ.get("HERMES_CUA_DRIVER_CMD", "").strip()
    candidates: list[Path] = []
    if driver_cmd:
        candidates.append(Path(driver_cmd))
    candidates += [
        Path("/Applications/CuaDriver.app/Contents/MacOS/cua-driver"),
        Path("/usr/local/bin/cua-driver"),
    ]
    driver = next((c for c in candidates if c.is_file()), None)
    if driver is None:
        out.append(_check("env.cua_driver", "warn",
                          "no cua-driver binary found (checked HERMES_CUA_DRIVER_CMD, "
                          "/Applications/CuaDriver.app, /usr/local/bin)",
                          "computer use is disabled until a driver is installed; "
                          "not a failure for text-only fleets"))
    else:
        ver = ""
        try:
            v = subprocess.run([str(driver), "--version"], capture_output=True,
                               text=True, timeout=5, check=False)
            ver = (v.stdout or v.stderr).strip()
        except Exception:
            pass
        out.append(_check("env.cua_driver", "ok",
                          f"{driver}" + (f" ({ver[:60]})" if ver else "")))

    # TCC — empirical probes, not TCC.db. Caveat on both: the grant measured
    # is the INVOKING process chain's; the launchd hub's attribution can
    # differ, so these are indicative, not the hub's own grant.
    try:
        ax = subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to count processes'],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if ax.returncode == 0:
            out.append(_check("env.tcc.accessibility", "ok",
                              "System Events probe succeeded (this process chain has "
                              "Accessibility)"))
        else:
            out.append(_check("env.tcc.accessibility", "warn",
                              f"System Events refused: {ax.stderr.strip()[:120]}",
                              "grant Accessibility to the app running doctor in "
                              "System Settings → Privacy & Security → Accessibility"))
    except Exception as exc:
        out.append(_check("env.tcc.accessibility", "unverified",
                          f"probe could not run: {exc}"))
    out.append(_check("env.tcc.screen_recording", *_screen_recording()))

    return out


def _screen_recording() -> tuple[str, str, str]:
    """Empirical screen-recording probe: capture, then prove content.

    ``screencapture`` without Screen Recording permission still exits 0 but
    yields a wallpaper-only image; we convert to BMP (trivially decodable)
    and measure luminance variance. Near-zero variance = blank capture =
    likely no grant. Measured for the invoking chain, not the launchd hub.
    """
    tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
    tmp.close()
    try:
        cap = subprocess.run(
            ["screencapture", "-x", tmp.name], capture_output=True, text=True,
            timeout=10, check=False,
        )
        if cap.returncode != 0 or not Path(tmp.name).exists() or Path(tmp.name).stat().st_size == 0:
            return ("warn", "screencapture failed to produce an image",
                    "grant Screen Recording to this app in System Settings → "
                    "Privacy & Security → Screen Recording")
        bmp = tmp.name + ".bmp"
        conv = subprocess.run(
            ["sips", "-s", "format", "bmp", tmp.name, "--out", bmp],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if conv.returncode != 0 or not Path(bmp).exists():
            return ("unverified", "capture succeeded but sips conversion failed",
                    "")
        variance = _bmp_luminance_variance(Path(bmp).read_bytes())
        if variance is None:
            return ("unverified", "capture produced but BMP decode failed",
                    "")
        if variance < 2.0:
            return ("warn",
                    f"capture is essentially blank (luminance var {variance:.1f}) — "
                    "no Screen Recording for THIS process chain (the fleet's GUI "
                    "path is CuaDriver.app, which has its own grant)",
                    "grant Screen Recording to the app running doctor and re-run, "
                    "or confirm CuaDriver.app's grant in System Settings → Privacy "
                    "& Security → Screen Recording")
        return ("ok",
                f"capture has real content (luminance var {variance:.1f})",
                "")
    finally:
        for p in (tmp.name, tmp.name + ".bmp"):
            try:
                Path(p).unlink()
            except OSError:
                pass


def _bmp_luminance_variance(data: bytes) -> float | None:
    """Sampled luminance variance of an uncompressed BMP (BI_RGB).

    sips emits 1-bit palette BMPs by default, so indexed formats (1/4/8) are
    handled via the palette; 24/32-bit are read directly."""
    try:
        import struct
        if data[:2] != b"BM":
            return None
        offset = struct.unpack_from("<I", data, 10)[0]
        dib = struct.unpack_from("<I", data, 14)[0]
        width, height, bitcount = struct.unpack_from("<iih", data, 18)
        if bitcount not in (1, 4, 8, 24, 32):
            return None
        # Indexed formats carry an RGB palette right after the DIB header.
        palette: list[tuple[int, int, int]] = []
        if bitcount <= 8:
            palette_start = 14 + dib
            entries = 1 << bitcount
            for i in range(entries):
                pos = palette_start + i * 4
                b, g, r = data[pos], data[pos + 1], data[pos + 2]
                palette.append((r, g, b))
        bpp = bitcount // 8
        row_size = ((width * (bitcount // 8) + 3) // 4) * 4
        lum: list[float] = []
        step = max(1, width // 40)
        ystep = max(1, abs(height) // 40)
        for y in range(0, abs(height), ystep):
            row = offset + y * row_size
            for x in range(0, width, step):
                if bitcount == 24 or bitcount == 32:
                    b, g, r = data[row + x * bpp: row + x * bpp + 3]
                else:
                    byte = data[row + (x * bitcount) // 8]
                    if bitcount == 8:
                        idx = byte
                    elif bitcount == 4:
                        idx = byte >> 4 if x % 2 == 0 else byte & 0x0F
                    else:
                        bit = 7 - (x % 8)
                        idx = (byte >> bit) & 1
                    if idx >= len(palette):
                        continue
                    r, g, b = palette[idx]
                lum.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        if not lum:
            return None
        mean = sum(lum) / len(lum)
        return sum((v - mean) ** 2 for v in lum) / len(lum)
    except Exception:
        return None


# -- dialect ----------------------------------------------------------------

def _spawn_throwaway_gateway(log) -> tuple[_HermesSession, Path, Path]:
    """One throwaway gateway on a temp HERMES_HOME — the real fork, the real
    spawn machinery, nothing shared with the fleet. Returns (session, home,
    cwd); caller MUST close() the session."""
    fork_repo = vertus_paths.fork_repo()
    home = Path(tempfile.mkdtemp(prefix="vertus-doctor-home-"))
    cwd = Path(tempfile.mkdtemp(prefix="vertus-doctor-cwd-"))
    # Mirror the fleet materializer's config.yaml shape: model/provider
    # override section, read from the fleet config (read-only).
    model, provider = _fleet_model_defaults()
    cfg: dict = {}
    if model or provider:
        model_section: dict = {}
        if model:
            model_section["default"] = model
        if provider:
            model_section["provider"] = provider
        cfg["model"] = model_section
    (home / "config.yaml").write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    (home / "SOUL.md").write_text(
        "You are a VERTUS doctor diagnostics session.\n", encoding="utf-8")
    (home / "memories").mkdir(parents=True, exist_ok=True)
    # Seed auth.json / .env from the fleet home like the materializer does —
    # read-only source, temp destination.
    fleet_home = _fleet_home()
    for name in ("auth.json", ".env"):
        src = fleet_home / name
        if src.is_file():
            try:
                (home / name).write_bytes(src.read_bytes())
            except OSError:
                pass
    venv_py = vertus_paths.venv_python()
    if not venv_py.is_file():
        raise FileNotFoundError(f"venv python missing: {venv_py}")
    env = build_gateway_env(agent_home=home)
    env.setdefault("HOME", str(home))
    env.setdefault("PATH", os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"))
    proc = subprocess.Popen(
        [str(venv_py), "-u", "-c",
         "import runpy, sys; sys.argv=[\"vertus-hermes-gateway\"]; "
         "runpy.run_module(\"tui_\" + \"gateway.entry\", run_name=\"__main__\")"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, cwd=str(fork_repo), env=env,
        start_new_session=True,
    )
    session = _HermesSession(proc, log)
    return session, home, cwd


def _fleet_home() -> Path:
    return vertus_paths.fleet_hermes_home()


def _fleet_model_defaults() -> tuple[str | None, str | None]:
    """Read model.default/provider from the fleet config.yaml (read-only).
    Reuses agent_registry's loader; falls back to a tiny regex if yaml is
    unavailable in this interpreter."""
    cfg_path = _fleet_home() / "config.yaml"
    if not cfg_path.is_file():
        return None, None
    try:
        from agent_registry import _yaml_load
        cfg = _yaml_load(cfg_path.read_text(encoding="utf-8"))
        if not isinstance(cfg, dict):
            return None, None
        model_section = cfg.get("model") or {}
        if not isinstance(model_section, dict):
            return None, None
        return (
            str(model_section["default"]) if model_section.get("default") else None,
            str(model_section["provider"]) if model_section.get("provider") else None,
        )
    except Exception:
        return None, None


def _rpccall(session: _HermesSession, method: str, params: dict,
             timeout: float | None = None) -> dict:
    """Call through the BRIDGE's own plumbing so we test the exact code path
    the hub runs, not a parallel implementation."""
    return session._rpccall(method, params,
                            timeout=timeout if timeout is not None
                            else _cfg()["rpc_timeout_s"])


def dialect_checks(spawner=None, log=print) -> list[dict]:
    """Probe the fork's gateway surface. ``spawner`` is injectable for tests
    (signature: (log) -> (session, home, cwd)); default spawns the real fork
    on a throwaway HERMES_HOME."""
    out: list[dict] = []
    spawner = spawner or _spawn_throwaway_gateway
    try:
        session, home, cwd = spawner(log)
    except Exception as exc:
        out.append(_check("dialect.gateway.ready", "fail",
                          f"gateway spawn failed: {exc}",
                          "check env.fork_checkout / env.venv_python above; if the "
                          "fork moved its entry point, the bridge cannot boot either"))
        return out
    try:
        ready_timeout = _cfg()["ready_timeout_s"]
        if not session._ready.wait(ready_timeout):
            out.append(_check("dialect.gateway.ready", "fail",
                              "gateway did not emit gateway.ready "
                              f"within {ready_timeout:.0f}s",
                              "the fork's gateway.ready event has moved or the "
                              "gateway hangs at boot — the bridge waits on this "
                              "event for every spawn"))
            return out
        out.append(_check("dialect.gateway.ready", "ok",
                          "gateway.ready observed on a throwaway spawn"))
        sid = None
        model, provider = _fleet_model_defaults()
        # Same conditional construction as the bridge's _create_session: only
        # include model/provider when the fleet config defines them.
        create_params: dict = {"cwd": str(cwd)}
        sent_overrides = []
        if model:
            create_params["model"] = model
            sent_overrides.append("model")
        if provider:
            create_params["provider"] = provider
            sent_overrides.append("provider")
        try:
            resp = _rpccall(session, "session.create", create_params)
            sid = resp.get("session_id") or resp.get("sid")
            if not sid:
                raise RuntimeError(f"no session id in {resp}")
            out.append(_check("dialect.session.create", "ok",
                              "accepted cwd" +
                              (f" + {'/'.join(sent_overrides)} overrides" if sent_overrides
                               else " (no model/provider in fleet config to send)") +
                              ", returned a session id"))
        except Exception as exc:
            msg = str(exc)
            if "Method not found" in msg or "-32601" in msg:
                out.append(_check("dialect.session.create", "fail",
                                  f"session.create missing: {msg}",
                                  "the fork renamed/removed session.create — the "
                                  "bridge cannot create any session"))
            else:
                out.append(_check("dialect.session.create", "fail",
                                  f"session.create failed: {msg[:200]}",
                                  "see the error; if it names the model/provider, the "
                                  "fork changed its create schema"))
        if sid:
            session._session_id = sid
            for method, params, critical in _rpc_matrix(sid):
                try:
                    _rpccall(session, method, params)
                    out.append(_check(f"dialect.{method}", "ok",
                                      "answered without -32601"))
                except Exception as exc:
                    msg = str(exc)
                    if "Method not found" in msg or "-32601" in msg:
                        if critical:
                            out.append(_check(f"dialect.{method}", "fail",
                                              f"{method} missing: {msg}",
                                              "the fork renamed/removed this RPC — "
                                              "the bridge calls it on every turn"))
                        else:
                            out.append(_check(f"dialect.{method}", "warn",
                                              f"{method} missing: {msg} — nothing in "
                                              "the hub calls it today, but the "
                                              "approval/config paths assume it exists"))
                    else:
                        out.append(_check(f"dialect.{method}", "ok",
                                          f"answered: {msg[:120]}"))
            # Event vocabulary. gateway.ready was observed at spawn; the rest
            # only arrive during a live turn.
            for etype in _BRIDGE_EVENT_TYPES[1:]:
                out.append(_check(f"dialect.event.{etype}", "unverified",
                                  "only observable during a live model turn; doctor "
                                  "never runs one (offline-safe by design)"))
    finally:
        teardown_ok = _teardown(session)
        out.append(_check(
            "dialect.teardown", "ok" if teardown_ok else "warn",
            "gateway reaped through close() (SIGTERM → grace → SIGKILL); "
            "process group gone" if teardown_ok else
            "gateway group may not be fully gone",
            "stale gateway processes block nothing but waste memory; check "
            "ps for vertus-hermes-gateway" if not teardown_ok else ""))
    return out


def _rpc_matrix(sid: str) -> list[tuple[str, dict, bool]]:
    """(method, params, critical) — critical = the bridge depends on it."""
    return [
        ("prompt.submit", {"session_id": sid, "text": ""}, True),
        ("session.interrupt", {"session_id": sid}, True),
        ("commands.catalog", {}, True),
        ("command.dispatch",
         {"name": "__doctor_nonexistent__", "arg": "", "session_id": sid}, True),
        ("session.active_list", {"current_session_id": sid}, True),
        ("config.get", {}, False),
        ("approval.pending", {"session_id": sid}, False),
        ("approval.respond", {"session_id": sid, "decision": "deny"}, False),
    ]


def _teardown(session: _HermesSession) -> bool:
    """Ladder teardown + verify the process group is gone (no orphaned
    driver can outlive it — the driver shares the group)."""
    try:
        session.interrupt()
    except Exception:
        pass
    session.close()  # _reap_group: SIGTERM, grace, SIGKILL
    try:
        os.killpg(session._proc.pid, 0)
        return False  # group still exists
    except ProcessLookupError:
        return True
    except Exception:
        return False


# -- hub / store / registry / launchd ---------------------------------------

def _hub_health() -> dict | None:
    cfg = _cfg()
    token_file = cfg["token_file"]
    token = token_file.read_text().strip() if token_file.is_file() else ""
    url = f"http://127.0.0.1:{cfg['hub_port']}/api/health"
    try:
        req = urllib.request.Request(url)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def _launchd_status(label: str) -> tuple[bool, int | None]:
    try:
        out = subprocess.run(["launchctl", "list"], capture_output=True,
                             text=True, timeout=10, check=False)
    except Exception:
        return False, None
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[2] == label:
            try:
                return True, int(parts[0]) if parts[0].isdigit() else None
            except ValueError:
                return True, None
    return False, None


def _plist_program(plist_path: Path) -> list[str] | None:
    try:
        out = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", str(plist_path)],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if out.returncode != 0:
            return None
        data = json.loads(out.stdout)
        return data.get("ProgramArguments") or ([data["Program"]] if data.get("Program") else None)
    except Exception:
        return None


def hub_checks() -> list[dict]:
    out: list[dict] = []
    cfg = _cfg()
    if cfg["skip_launchd"]:
        loaded, pid = False, None
    else:
        loaded, pid = _launchd_status("com.vertus.server")
    if not loaded and not cfg["skip_launchd"]:
        out.append(_check("hub.process", "warn",
                          f"no hub running on :{cfg['hub_port']} and no launchd agent "
                          "com.vertus.server",
                          "bootstrap disabled-launchagents/com.vertus.server.plist "
                          "(see docs/FIRST_RUN.md)"))
        return out
    health = _hub_health()
    if health is None:
        if loaded:
            out.append(_check("hub.process", "fail",
                              f"launchd agent com.vertus.server is loaded but "
                              f":{cfg['hub_port']} does not answer /api/health",
                              "check the hub log at ~/.vertus/logs/vertus.log — a "
                              "loaded-but-silent agent under KeepAlive means a "
                              "boot crash loop"))
        else:
            out.append(_check("hub.process", "warn",
                              "no hub running (launchd checks skipped)", ""))
        return out
    out.append(_check("hub.process", "ok",
                      f"hub answering on 127.0.0.1:{cfg['hub_port']}"
                      + (f" (pid {pid})" if pid else "")))
    subs = health.get("subsystems") or {}
    bad = {name: spec for name, spec in subs.items()
           if isinstance(spec, dict) and spec.get("ok") is False}
    if bad:
        for name, spec in bad.items():
            out.append(_check(f"hub.subsystem.{name}", "fail",
                              f"{spec.get('reason', 'unhealthy')}",
                              "restart the hub; if it recurs the subsystem is broken, "
                              "not wedged"))
    else:
        live = ", ".join(sorted(k for k, v in subs.items()
                                if isinstance(v, dict) and v.get("ok")))
        out.append(_check("hub.subsystem", "ok",
                          f"all subsystems live: {live}"))
    out.append(_check("hub.uptime", "ok",
                      f"up {health.get('uptime_s', '?')}s"))

    # Code currency: approximate without a hub feature — hub start time vs
    # the last commit touching vertus/server/. Honest about being an
    # approximation; exactness would need the hub to report its own SHA.
    try:
        start = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid or 0)], capture_output=True,
            text=True, timeout=5, check=False,
        ).stdout.strip()
        last = subprocess.run(
            ["git", "log", "-1", "--format=%cI", "--", "vertus/server/"],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout.strip()
        if start and last:
            import datetime
            hub_start = datetime.datetime.strptime(start, "%a %b %e %H:%M:%S %Y").timestamp()
            last_change = datetime.datetime.fromisoformat(last).timestamp()
            if hub_start >= last_change:
                out.append(_check("hub.code_current", "ok",
                                  f"hub started {start[4:16]} after the last server "
                                  f"change ({last[:16]})"))
            else:
                out.append(_check("hub.code_current", "warn",
                                  f"hub started {start[4:16]} BEFORE the last server "
                                  f"change ({last[:16]})",
                                  "reload the hub: launchctl kickstart -k "
                                  "gui/$(id -u)/com.vertus.server"))
    except Exception:
        pass
    return out


_EXPECTED_TABLES = {
    "runs": ("run_id", "agent_id", "state"),
    "events": ("seq", "run_id", "agent_id"),
    "messages": ("run_id", "agent_id", "role"),
    "bot_messages": ("from_agent", "to_agent"),
    "threads": ("thread_id",),
    "approvals": ("approval_id", "run_id"),
    "routines": ("routine_id", "agent_id"),
}


def _sqlite(sql: str, db_path: Path) -> subprocess.CompletedProcess:
    """One read-only-by-contract sqlite3 CLI call.

    NOT ``-readonly``: SQLite cannot open a WAL-mode database read-only
    (it needs to touch the -shm sidecar), and the fleet db is WAL — the
    -readonly flag fails with SQLITE_CANTOPEN(14) against it. Instead the
    connection is opened normally with ``query_only=ON`` (every statement
    below is a read; the db content is provably untouched — the no-mutation
    test asserts it) and a busy_timeout so a live hub mid-write does not
    false-fail quick_check."""
    return subprocess.run(
        ["/usr/bin/sqlite3", str(db_path),
         "PRAGMA busy_timeout=3000; PRAGMA query_only=ON; " + sql],
        capture_output=True, text=True, timeout=10, check=False,
    )


def store_checks() -> list[dict]:
    out: list[dict] = []
    db_path = _cfg()["db_path"]
    if not db_path.is_file():
        out.append(_check("store.file", "warn",
                          f"no database at {db_path}",
                          "the hub creates it at first boot"))
        return out
    out.append(_check("store.file", "ok", f"{db_path} present"))
    if not Path("/usr/bin/sqlite3").is_file():
        out.append(_check("store.quick_check", "unverified",
                          "sqlite3 CLI unavailable", ""))
        return out
    qc = _sqlite("PRAGMA quick_check;", db_path)
    if qc.returncode != 0 or "ok" not in qc.stdout.strip().lower():
        out.append(_check("store.quick_check", "fail",
                          f"quick_check: {qc.stdout.strip()[:120] or qc.stderr.strip()[:120]}",
                          "the fleet database is corrupt; restore from backup or let "
                          "the hub rebuild (events are prunable, runs/messages are the "
                          "record)"))
    else:
        out.append(_check("store.quick_check", "ok", "database integrity ok"))
    tables = _sqlite("SELECT name FROM sqlite_master WHERE type='table';", db_path)
    present = set(tables.stdout.split())
    missing = [t for t in _EXPECTED_TABLES if t not in present]
    if missing:
        out.append(_check("store.tables", "fail",
                          f"missing tables: {', '.join(missing)}",
                          "start the hub once — it migrates/create-missing tables on "
                          "boot"))
    else:
        # column spot-check
        bad = []
        for table, cols in _EXPECTED_TABLES.items():
            ci = _sqlite(f"PRAGMA table_info({table});", db_path)
            have = {r.split("|")[1] for r in ci.stdout.splitlines() if "|" in r}
            bad += [f"{table}.{c}" for c in cols if c not in have]
        if bad:
            out.append(_check("store.tables", "fail",
                              f"missing columns: {', '.join(bad)}",
                              "start the hub once — the idempotent column migration "
                              "runs on boot"))
        else:
            out.append(_check("store.tables", "ok", "all tables and columns present"))
    mode = _sqlite("PRAGMA journal_mode;", db_path).stdout.strip()
    if "wal" in mode.lower():
        out.append(_check("store.wal", "ok", "WAL mode active"))
    else:
        out.append(_check("store.wal", "warn",
                          f"journal_mode is {mode or 'unknown'}",
                          "WAL is required for the writer-thread design; the hub sets "
                          "it at boot"))
    return out


def registry_checks() -> list[dict]:
    out: list[dict] = []
    agents_dir = _cfg()["agents_dir"]
    if not agents_dir.is_dir():
        out.append(_check("registry.profiles", "warn",
                          f"no agents directory at {agents_dir}",
                          "the hub creates it at first boot"))
        return out
    from agent_registry import SCHEMA_VERSION
    profiles = sorted(agents_dir.glob("*/profile.json"))
    if not profiles:
        out.append(_check("registry.profiles", "warn",
                          f"no agent profiles under {agents_dir}", ""))
        return out
    stale = []
    for p in profiles:
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
            version = data.get("schema_version")
            if version != SCHEMA_VERSION:
                stale.append((p.parent.name, version))
        except Exception as exc:
            stale.append((p.parent.name, f"unreadable: {exc}"))
    if stale:
        names = ", ".join(f"{a} (v{v})" for a, v in stale)
        out.append(_check("registry.profiles", "fail",
                          f"schema drift: {names}",
                          "start the hub once — profile migration is lossless and "
                          "runs on load"))
    else:
        out.append(_check("registry.profiles", "ok",
                          f"all {len(profiles)} profiles at schema v{SCHEMA_VERSION}"))
    return out


def launchd_checks() -> list[dict]:
    out: list[dict] = []
    if _cfg()["skip_launchd"]:
        out.append(_check("launchd.agents", "unverified", "skipped (tests)", ""))
        return out
    for label, installed, repo_plist in (
        ("com.vertus.server", Path.home() / "Library" / "LaunchAgents" / "com.vertus.server.plist",
         Path(__file__).parent.parent.parent / "disabled-launchagents" / "com.vertus.server.plist"),
    ):
        loaded, pid = _launchd_status(label)
        if not loaded:
            out.append(_check(f"launchd.{label}", "warn",
                              "agent not loaded",
                              f"launchctl bootstrap gui/$(id -u) {installed or repo_plist}"))
            continue
        plist = installed if installed.is_file() else repo_plist
        program = _plist_program(plist) if plist.is_file() else None
        if not program:
            out.append(_check(f"launchd.{label}", "warn",
                              f"loaded (pid {pid}) but its plist is unreadable at {plist}",
                              "reinstall the plist from disabled-launchagents/"))
            continue
        missing = [a for a in program if a.startswith("/") and not Path(a).exists()]
        if missing:
            out.append(_check(f"launchd.{label}", "fail",
                              f"loaded (pid {pid}) but points at missing path(s): "
                              f"{', '.join(missing)}",
                              "rebuild the bundles and fix the plist path"))
        else:
            out.append(_check(f"launchd.{label}", "ok",
                              f"loaded (pid {pid}), program {program[0]} exists"))
    return out


def _login_item_registered() -> bool:
    """SMAppService registers into the Background Task Management database.
    (sfltool dumpbtm needs no privileges and is read-only.) Also accept the
    launchd fallback plist the app writes when SMAppService is refused."""
    try:
        out = subprocess.run(["sfltool", "dumpbtm"], capture_output=True,
                             text=True, timeout=20).stdout
        for line in out.splitlines():
            if "com.vertus.app" in line and "Identifier:" in line:
                return True
    except Exception:
        pass
    return (Path.home() / "Library" / "LaunchAgents" / "com.vertus.app.plist").is_file()


def _vertus_app_processes() -> list[int]:
    """PIDs running the bundle's binary. The merge's whole point was ONE
    process (one fleet-stream connection, one store); two of these means
    duplicate streams and double notifications."""
    try:
        out = subprocess.run(["pgrep", "-f", "/Applications/VERTUS.app/Contents/MacOS/Vertus"],
                             capture_output=True, text=True, timeout=5).stdout
        return [int(p) for p in out.split() if p.strip()]
    except Exception:
        return []


def app_checks() -> list[dict]:
    """The macOS client is ONE bundled app: installed, correct bundle id,
    registered to launch at login, and at most one running process.
    Honors VERTUS_DOCTOR_SKIP_LAUNCHD like launchd_checks (client state is
    not a failure on a headless test box; a wrong bundle id IS a failure
    because it silently breaks SMAppService registration)."""
    out: list[dict] = []
    if _cfg()["skip_launchd"]:
        out.append(_check("app.bundle", "unverified", "skipped (tests)", ""))
        return out

    app = Path(os.environ.get("VERTUS_APP_PATH", "/Applications/VERTUS.app"))
    if not app.is_dir():
        out.append(_check("app.installed", "warn",
                          "/Applications/VERTUS.app missing",
                          "cd vertus/apps && bash scripts/build-app.sh && "
                          "cp -R dist/VERTUS.app /Applications/"))
        return out  # nothing further is meaningful
    out.append(_check("app.installed", "ok", "/Applications/VERTUS.app present", ""))

    info = app / "Contents" / "Info.plist"
    try:
        import plistlib
        with open(info, "rb") as f:
            bundle_id = plistlib.load(f).get("CFBundleIdentifier", "")
        if bundle_id == "com.vertus.app":
            out.append(_check("app.bundle_id", "ok", "bundle id com.vertus.app", ""))
        else:
            out.append(_check("app.bundle_id", "fail",
                              f"bundle id is {bundle_id!r}, expected com.vertus.app",
                              "fix CFBundleIdentifier in scripts/build-app.sh and reinstall"))
    except Exception as exc:  # pragma: no cover - plist corruption is exotic
        out.append(_check("app.bundle_id", "fail", f"Info.plist unreadable: {exc}",
                          "rebuild the bundle"))

    if _login_item_registered():
        out.append(_check("app.login_item", "ok", "registered to launch at login", ""))
    else:
        out.append(_check("app.login_item", "warn",
                          "not registered to launch at login",
                          "launch VERTUS once (it self-registers via SMAppService), "
                          "or install ~/Library/LaunchAgents/com.vertus.app.plist"))

    procs = _vertus_app_processes()
    if not procs:
        out.append(_check("app.processes", "ok", "not running (launch-at-login starts it)", ""))
    elif len(procs) == 1:
        out.append(_check("app.processes", "ok", "one process running", ""))
    else:
        out.append(_check("app.processes", "fail",
                          f"{len(procs)} processes running: {procs} — two means two "
                          "fleet-stream connections and double notifications",
                          "quit the extras (they were started before the merge or manually)"))
    return out


# launchd labels that legitimately live on a production machine. Anything
# else under com.vertus.* is a demo that outlived its demo (two occurrences
# this session: com.vertus.demo.memory and an earlier one).
# The bar's launchd label (com.vertusbar.dev) was removed in the merge —
# the app now registers launch-at-login itself via SMAppService (which does
# not appear in launchctl list unless the launchd fallback plist was used).
_KNOWN_LAUNCHD_LABELS = {"com.vertus.server"}


def _stray_vertus_labels() -> list[str]:
    try:
        out = subprocess.run(["launchctl", "list"], capture_output=True,
                             text=True, timeout=10, check=False)
    except Exception:
        return []
    stray: list[str] = []
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[2].startswith("com.vertus."):
            if parts[2] not in _KNOWN_LAUNCHD_LABELS:
                stray.append(parts[2])
    return sorted(stray)


def terminal_checks() -> list[dict]:
    """The terminal as a fleet client (VERTUS_ENGINE=hub, hub-session.ts):
    hub reachable, the configured agent resolvable, and the steer endpoint
    live. The steer probe is side-effect-free: POSTing to an IDLE agent
    returns 409 and touches nothing; a RUNNING agent is never probed (that
    would inject a steer into a live turn) — reported unverified instead.
    """
    out: list[dict] = []
    cfg = _cfg()
    token = cfg["token_file"].read_text().strip() if cfg["token_file"].is_file() else ""
    agent_id = (os.environ.get("VERTUS_AGENT", "primary").strip() or "primary")
    base = f"http://127.0.0.1:{cfg['hub_port']}"
    quote = urllib.request.quote

    def request(path: str, method: str = "GET", payload: dict | None = None):
        data = json.dumps(payload).encode() if payload is not None else None
        try:
            req = urllib.request.Request(base + path, data=data, method=method)
            if token:
                req.add_header("Authorization", f"Bearer {token}")
            with urllib.request.urlopen(req, timeout=5) as resp:
                raw = resp.read()
                try:
                    return resp.status, json.loads(raw or b"{}")
                except Exception:
                    return resp.status, {}
        except urllib.error.HTTPError as exc:
            try:
                return exc.code, json.loads(exc.read() or b"{}")
            except Exception:
                return exc.code, {}
        except Exception:
            return 0, {}

    # The launchd sweep is independent of hub state — a demo job must be
    # flagged even (especially) when nothing else is healthy.
    if not cfg["skip_launchd"]:
        stray = _stray_vertus_labels()
        if stray:
            out.append(_check("terminal.launchd_strays", "warn",
                              f"unexpected com.vertus.* labels loaded: {', '.join(stray)}",
                              "launchctl bootout gui/$(id -u)/<label> — a demo agent "
                              "must not outlive its demo"))
        else:
            out.append(_check("terminal.launchd_strays", "ok",
                              "only com.vertus.server loaded"))

    health = _hub_health()
    if health is None:
        # Warn, not fail — same contract as hub.process: a dev box without a
        # hub is not a broken installation, but hub mode cannot attach.
        out.append(_check(
            "terminal.hub_reachable", "warn",
            f"hub not answering on :{cfg['hub_port']} — VERTUS_ENGINE=hub has nothing to attach to",
            "start the hub: launchctl bootstrap gui/$(id -u) "
            "~/Library/LaunchAgents/com.vertus.server.plist"))
        return out
    out.append(_check("terminal.hub_reachable", "ok", "hub answering /api/health"))

    status, _ = request(f"/api/agents/{quote(agent_id)}")
    if status == 200:
        out.append(_check("terminal.agent_resolvable", "ok",
                          f"agent {agent_id!r} resolves (VERTUS_AGENT)"))
    else:
        out.append(_check("terminal.agent_resolvable", "fail",
                          f"agent {agent_id!r} not found (HTTP {status})",
                          "create it in the Fleet app (bot editor) or POST /api/agents"))

    status, body = request(f"/api/agents/{quote(agent_id)}/status")
    running = isinstance(body, dict) and body.get("state") == "running"
    if status != 200:
        out.append(_check("terminal.steer_endpoint", "unverified",
                          f"status endpoint unreachable (HTTP {status})", ""))
    elif running:
        out.append(_check("terminal.steer_endpoint", "unverified",
                          f"agent {agent_id!r} is RUNNING — steer endpoint not probed "
                          "(a probe would inject a steer into a live turn)", ""))
    else:
        status, body = request(f"/api/steer", "POST",
                               {"agent_id": agent_id, "text": "doctor probe"})
        if status == 409:
            out.append(_check("terminal.steer_endpoint", "ok",
                              "POST /api/steer answers 409 on an idle agent (endpoint live)"))
        else:
            out.append(_check("terminal.steer_endpoint", "fail",
                              f"POST /api/steer answered {status} instead of 409 — "
                              "mid-turn corrections from the terminal would fail",
                              "check the hub log; the steer route must be present "
                              "(hub on current code)"))

    return out


def memory_checks() -> list[dict]:
    """Hub-owned memory (fleet_memory.py): canonical dirs, migration marker,
    index health, fork-mirror consistency, pending conflicts, and — the one
    that matters — that each materialized skill points at the SAME shared
    root the hub resolves. The last one is the exact check that would have
    caught the env-divergence bug that sent a temp hub's agents at the REAL
    ~/.vertus/memory."""
    out: list[dict] = []
    from fleet_memory import (_MIGRATION_MARKER, _FORK_MEMORY_FILES, _sha256)

    root = vertus_paths.memory_root()
    shared = vertus_paths.shared_memory_dir()
    agents = vertus_paths.agents_dir()
    if not shared.is_dir():
        out.append(_check("memory.canonical", "warn",
                          f"shared memory dir missing at {shared}",
                          "the hub creates it at first boot; start the hub once"))
        return out
    out.append(_check("memory.canonical", "ok", f"{shared} present"))

    marker = root / _MIGRATION_MARKER
    if marker.is_file():
        out.append(_check("memory.migration", "ok",
                          f"legacy migration marker at {marker.name} (idempotent)"))
    else:
        out.append(_check("memory.migration", "warn",
                          "no migration marker — legacy memory never folded in",
                          "start the hub once; it backs up + migrates + marks"))

    # Index health + freshness: every canonical file should have an index
    # entry whose sha matches (the watcher catches up on its next poll, so
    # staleness is a warn, not a fail).
    index_file = root / ".hub-index.json"
    index: dict = {}
    if not index_file.is_file():
        out.append(_check("memory.index", "warn",
                          "no hub index yet (created on first write)",
                          "the watcher creates it; nothing to fix"))
    else:
        try:
            parsed = json.loads(index_file.read_text(encoding="utf-8"))
            index = parsed if isinstance(parsed, dict) else {}
        except Exception as exc:
            out.append(_check("memory.index", "fail",
                              f"index unreadable: {exc}",
                              "delete it and let the hub rebuild (it is derived state)"))
            index = {}
        if not index:
            out.append(_check("memory.index", "warn",
                              "index exists but is empty — nothing indexed yet",
                              "the watcher populates it; nothing to fix"))
        else:
            stale = []
            for p in sorted(shared.rglob("*")):
                if not p.is_file() or p.name.startswith("."):
                    continue
                key = f"shared/{p.relative_to(shared)}"
                meta = index.get(key)
                if not meta or meta.get("sha") != _sha256(p):
                    stale.append(str(p.relative_to(shared)))
            if stale:
                out.append(_check("memory.index", "warn",
                                  f"index stale for {len(stale)} shared file(s): "
                                  f"{', '.join(stale[:3])}",
                                  "the hub watcher catches up on its next poll (2s)"))
            else:
                out.append(_check("memory.index", "ok",
                                  f"index current ({len(index)} entries)"))

    # Pending conflicts: staged <name>.conflict-<ts> files, never destroyed.
    conflicts = sorted(agents.glob("*/memory/*.conflict-*")) if agents.is_dir() else []
    if conflicts:
        names = ", ".join(str(c.relative_to(agents)) for c in conflicts[:3])
        out.append(_check("memory.conflicts", "warn",
                          f"{len(conflicts)} staged conflict(s): {names}",
                          "both sides were preserved; merge by hand and delete the "
                          ".conflict-* file"))
    else:
        out.append(_check("memory.conflicts", "ok", "no pending conflicts"))

    # Fork mirror consistency: a fork-side file with no canonical counterpart
    # (or a different sha) has not propagated yet. Self-healing via the
    # watcher, so warn only.
    pending = []
    if agents.is_dir():
        for home_mem in sorted(agents.glob("*/home/memories/*")):
            if not home_mem.is_file():
                continue
            agent = home_mem.parent.parent.parent.name
            if home_mem.name not in _FORK_MEMORY_FILES:
                continue
            dst = agents / agent / "memory" / home_mem.name
            if not dst.is_file() or _sha256(dst) != _sha256(home_mem):
                pending.append(f"{agent}/{home_mem.name}")
    if pending:
        out.append(_check("memory.mirror", "warn",
                          f"{len(pending)} fork write(s) not yet mirrored: "
                          f"{', '.join(pending)}",
                          "the hub watcher propagates fork writes into canonical "
                          "(one-way, never destroyed) on its next poll"))
    else:
        out.append(_check("memory.mirror", "ok", "fork mirrors consistent"))

    # THE check: materialized skills must point at the hub's resolved root.
    expected = str(shared)
    bad: list[str] = []
    if agents.is_dir():
        for skill in sorted(agents.glob("*/home/skills/vertus-memory/SKILL.md")):
            agent = skill.parent.parent.parent.parent.name
            try:
                text = skill.read_text(encoding="utf-8")
            except OSError:
                continue
            if expected not in text:
                bad.append(agent)
    if bad:
        out.append(_check("memory.skill_path", "fail",
                          f"{len(bad)} agent(s) have materialized skills pointing "
                          f"at a DIFFERENT shared root than the hub resolves "
                          f"({expected}): {', '.join(bad)}",
                          "re-materialize: restart the hub, or PATCH each agent "
                          "(the skill path is derived state, rewritten on every "
                          "profile write)"))
    else:
        out.append(_check("memory.skill_path", "ok",
                          "all materialized skills point at the resolved shared root"))
    return out


# -- pi bundle freshness ----------------------------------------------------

def pi_bundle_checks() -> list[dict]:
    """Is the built terminal bundle newer than its sources?

    The terminal (and the local REPL) run the BUNDLED cli
    (pi/packages/coding-agent/dist/bundle/cli.js), not the sources. Editing
    src/ and forgetting to rebuild has bitten twice: the suite kept testing
    stale code and the running binary silently diverged. This check makes
    that visible: bundle missing → warn (nothing built); bundle older than
    any of its sources → warn with the exact rebuild command.
    """
    out: list[dict] = []
    root = Path(__file__).resolve().parents[2]
    src_dirs = [
        root / "pi" / "packages" / "coding-agent" / "src",
        root / "pi" / "packages" / "ai" / "src",
    ]
    bundle = root / "pi" / "packages" / "coding-agent" / "dist" / "bundle" / "cli.js"

    if not bundle.is_file():
        out.append(_check("pi.bundle", "warn",
                          f"terminal bundle missing: {bundle}",
                          "cd pi/packages/coding-agent && npm run build — the "
                          "local REPL and one-shot CLI run this bundle, not src/"))
        return out

    newest_src = max(
        (p.stat().st_mtime for d in src_dirs if d.is_dir()
         for p in d.rglob("*.*") if p.is_file()),
        default=0.0,
    )
    bundle_mtime = bundle.stat().st_mtime
    if newest_src > bundle_mtime:
        stale_s = int(newest_src - bundle_mtime)
        out.append(_check("pi.bundle", "warn",
                          f"bundle is {stale_s}s OLDER than its newest source "
                          f"(bundle {bundle.name} vs src/)",
                          "cd pi/packages/coding-agent && npm run build — a stale "
                          "bundle means the REPL runs code the suite no longer tests"))
    else:
        out.append(_check("pi.bundle", "ok",
                          "terminal bundle is newer than its sources"))
    return out


# -- runner -----------------------------------------------------------------

def run(json_out: bool = False, spawner=None) -> int:
    started = time.monotonic()
    all_checks: list[dict] = []
    all_checks += env_checks()
    all_checks += dialect_checks(spawner=spawner)
    all_checks += hub_checks()
    all_checks += store_checks()
    all_checks += registry_checks()
    all_checks += memory_checks()
    all_checks += launchd_checks()
    all_checks += app_checks()
    all_checks += terminal_checks()
    all_checks += pi_bundle_checks()
    runtime_s = time.monotonic() - started
    exit_code = 1 if any(c["status"] == "fail" for c in all_checks) else 0
    if json_out:
        print(json.dumps(
            {"checks": all_checks, "exit": exit_code,
             "runtime_s": round(runtime_s, 2)},
            indent=2,
        ))
    else:
        for c in all_checks:
            pad = f"[{c['status']}]".ljust(11)
            line = f"{c['name'].ljust(32)} {pad} {c['reason']}"
            print(line)
            if c["remediation"]:
                print(f"{'':34}  → {c['remediation']}")
        print(f"\n{len(all_checks)} checks, {exit_code and 'FAILURES PRESENT' or 'all clear'}, "
              f"{runtime_s:.1f}s")
    return exit_code


if __name__ == "__main__":
    sys.exit(run(json_out="--json" in sys.argv))