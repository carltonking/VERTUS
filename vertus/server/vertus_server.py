"""VERTUS server — long-running daemon wrapping pi's agent SDK.

Exposes the agent over HTTP for three clients (CLI one-shot, macOS quick
bar, iOS app). Binds to the Tailscale interface only; every request needs
a bearer token from ~/.vertus/token.

Run:  python vertus/server/vertus_server.py serve
      VERTUS_HOST=100.x.y.z VERTUS_PORT=8787 python vertus/server/vertus_server.py serve
"""

from __future__ import annotations

import argparse
import json
import os

# Line-buffered stdout so launchd log files show progress promptly.
import functools
print = functools.partial(print, flush=True)  # noqa: A001
import secrets
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Queue, Empty
import threading
from threading import Thread
from urllib.parse import parse_qs, urlsplit

# Script-dir import (python3 vertus/server/vertus_server.py) keeps this plain;
# fall back to a package-relative import for `python -m vertus.server.vertus_server`.
try:
    from agent_registry import AgentRegistry  # type: ignore
    from session_manager import SessionManager, DEFAULT_AGENT_ID  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from .agent_registry import AgentRegistry  # type: ignore
    from .session_manager import SessionManager, DEFAULT_AGENT_ID  # type: ignore

VERTUS_DIR = Path.home() / ".vertus"
TOKEN_FILE = VERTUS_DIR / "token"
DEFAULT_PORT = 8787


def ensure_token() -> str:
    """Load or create the bearer token."""
    VERTUS_DIR.mkdir(parents=True, exist_ok=True)
    if TOKEN_FILE.exists():
        token = TOKEN_FILE.read_text().strip()
        if token:
            return token
    token = secrets.token_urlsafe(32)
    TOKEN_FILE.write_text(token + "\n")
    if os.name != "nt":
        TOKEN_FILE.chmod(0o600)
    return token


def tailnet_ip() -> str | None:
    """Find the local Tailscale IPv4 (100.x.y.z) if present."""
    for candidate in (_tailnet_ip_socket, _tailnet_ip_cli):
        try:
            ip = candidate()
            if ip and ip.startswith("100."):
                return ip
        except Exception:
            continue
    return None


def _tailnet_ip_socket() -> str | None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("100.100.100.100", 0))
        return s.getsockname()[0]


def _tailnet_ip_cli() -> str | None:
    """Fall back to the tailscale CLI (speaks to the daemon directly)."""
    for cli in ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "tailscale"):
        try:
            out = subprocess.run(
                [cli, "ip", "-4"], capture_output=True, text=True, timeout=5
            ).stdout.strip().split()
            return next((ip for ip in out if ip.startswith("100.")), None)
        except Exception:
            continue
    return None


class AgentBridge:
    """Owns the pi agent session and serializes prompts through a queue.

    Each agent gets its own bridge (own queue + worker thread + engine
    session); the SessionManager builds one per agent id, so two agents can
    be mid-prompt at the same time. The class itself is unchanged in spirit:
    prompts are serialized per-agent, and events fan out to that agent's
    subscribers only.
    """

    def __init__(self, agent_id: str = DEFAULT_AGENT_ID, create_session_factory=None, cwd: str | None = None, session_kwargs: dict | None = None) -> None:
        self.agent_id = agent_id
        # Session workspace: the agent's sandbox dir (never $HOME / repo root).
        self.cwd = cwd
        # Identity kwargs forwarded to every engine session this bridge creates
        # (per-agent HERMES_HOME / model / provider). Captured at bridge build
        # time and refreshed by reconfigure() on a profile PATCH — a live
        # gateway keeps its identity until the next turn respawns it.
        self._session_kwargs: dict = dict(session_kwargs or {})
        # Step 4: remote/local is enforced at SPAWN time (HERMES_YOLO_MODE=0),
        # because prompt.submit has no per-turn context field. Sticky: once a
        # remote prompt is seen, this agent's gateways keep approvals on.
        self._remote_seen = False
        self.subscribers: list[Queue] = []
        self._queue: Queue = Queue()
        self._create_session = create_session_factory
        self._session = None
        self._worker = Thread(target=self._run_worker, daemon=True)
        self._worker.start()

    def subscribe(self) -> Queue:
        q: Queue = Queue(maxsize=1000)
        self.subscribers.append(q)
        return q

    def unsubscribe(self, q: Queue) -> None:
        if q in self.subscribers:
            self.subscribers.remove(q)

    def _emit(self, event: dict) -> None:
        for q in list(self.subscribers):
            try:
                q.put_nowait(event)
            except Exception:
                self.unsubscribe(q)

    def _load_pi(self):
        """Load the agent bridge: forked hermes engine by default, pi fallback.

        VERTUS_BRIDGE=pi forces the old pi SDK path (rollback).
        """
        server_dir = Path(__file__).resolve().parent
        if os.environ.get("VERTUS_BRIDGE") != "pi":
            try:
                sys.path.insert(0, str(server_dir))
                from hermes_bridge import create_agent_session  # type: ignore

                return create_agent_session
            except Exception as exc:
                print(f"[vertus] hermes bridge unavailable: {exc}", file=sys.stderr)
                print("[vertus] falling back to pi SDK", file=sys.stderr)
        repo = Path(__file__).resolve().parents[2] / "pi" / "packages" / "coding-agent"
        try:
            sys.path.insert(0, str(repo / "src"))
            from pi_coding_agent import create_agent_session  # type: ignore

            return create_agent_session
        except Exception as exc:
            print(f"[vertus] pi SDK unavailable: {exc}", file=sys.stderr)
            return None

    def _run_worker(self) -> None:
        if self._create_session is None:
            self._create_session = self._load_pi()
        # Prewarm: spawn the engine gateway and create the session NOW, at
        # server start, so the first real prompt doesn't pay the ~50s cold-
        # start (venv python import + hermes session init). Failure here is
        # non-fatal — the lazy path in _run_prompt_with_respawn retries.
        self._prewarm()
        while True:
            item = self._queue.get()
            if item is None:
                break
            # ``remote`` is carried explicitly on the item (Step 4: the old
            # os.environ["VERTUS_REMOTE"] write was process-global — two
            # agents running concurrently overwrote each other's flag).
            text, remote = item
            if self._create_session is None:
                self._emit({"type": "error", "message": "agent SDK not available"})
                continue
            self._run_prompt_with_respawn(text, remote=remote)

    def _spawn_session(self, remote: bool):
        """Create one engine session with this agent's identity + spawn-mode env.

        Single funnel for prewarm and the lazy prompt path so both always
        bind the same cwd, identity kwargs, and remote-mode env. No
        process-global state is touched (Step 4).
        """
        if remote:
            self._remote_seen = True
        kwargs = dict(self._session_kwargs)
        extra = dict(kwargs.pop("extra_env", None) or {})
        if self._remote_seen:
            # Sticky safety: once any remote prompt has been seen for this
            # agent, every future gateway for it keeps the engine's approval
            # prompts ON (HERMES_YOLO_MODE=0), even if the fleet default
            # would bypass them. prompt.submit has no per-turn field
            # (Step 0(d)), so mode is fixed per gateway lifetime.
            extra["HERMES_YOLO_MODE"] = "0"
            # pi fallback: its approval guard extension reads VERTUS_REMOTE in
            # the bridge child; spawn-time injection replaces the old
            # process-global hub write (inert for the hermes engine).
            extra["VERTUS_REMOTE"] = "1"
        if extra:
            kwargs["extra_env"] = extra
        return self._create_session(cwd=self.cwd, **kwargs)

    def _prewarm(self) -> None:
        """Create the agent session at startup; never raises."""
        if self._create_session is None:
            return
        try:
            # Prewarm with the agent's sandbox cwd + identity kwargs — same
            # binding the lazy path uses, so the prewarmed session never
            # starts in $HOME or the repo root and no re-creation happens on
            # first prompt. Prewarm is always local-mode (approvals default).
            result = self._spawn_session(remote=False)
            self._session = result["session"]
            self._session.subscribe(self._on_pi_event)
            print(
                f"[vertus] agent {self.agent_id} session prewarmed (cwd: {self.cwd})",
                file=sys.stderr,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"[vertus] prewarm failed (will retry on first prompt): {exc}", file=sys.stderr)

    def _expand_slash_text(self, text: str) -> str | None:
        """Expand a leading /command before it reaches the agent.

        Skills, bundles, /learn, /init, quick commands, and aliases are
        resolved through the gateway's command.dispatch — the same server-side
        expansion the hermes CLI's '/' menu uses. Clients send plain text, so
        every surface (bar, phone, CLI one-shot) gets identical slash behavior.

        Returns the text to submit, or None when the command already produced
        its own output (an exec-style command); the caller then stops.
        """
        stripped = text.strip()
        if not stripped.startswith("/"):
            return text
        expand = getattr(self._session, "expand_slash", None)
        if expand is None:  # pi fallback bridge has no slash dispatch
            return text
        head, _, arg = stripped.partition(" ")
        try:
            result = expand(head.lstrip("/"), arg.strip())
        except Exception as exc:  # noqa: BLE001
            self._emit({"type": "activity", "text": f"slash dispatch failed: {exc}"})
            return text
        if result is None:
            # Not a resolvable /command — submit as an ordinary prompt.
            return text
        rtype = result.get("type")
        if rtype in ("send", "skill"):
            msg = result.get("message")
            if isinstance(msg, str) and msg:
                return msg
            return text
        if rtype == "alias":
            target = str(result.get("target") or "").lstrip("/")
            if target and target != head.lstrip("/"):
                return self._expand_slash_text(f"/{target} {arg}".strip())
            return text
        # exec / plugin / anything else: output was produced server-side.
        out = str(result.get("output") or result.get("notice") or result.get("display") or "")
        if out:
            self._emit({"type": "text", "text": out})
        else:
            self._emit({"type": "activity", "text": f"ran {head}"})
        self._emit({"type": "done"})
        return None

    def _run_prompt_with_respawn(self, text: str, remote: bool = False) -> None:
        """Run one prompt, restarting a dead agent gateway once in-line.

        The hermes gateway runs as a child process that can be killed
        externally (e.g. SIGTERM). Without recovery, every later prompt
        would write into the dead pipe and surface as "[Errno 32] Broken
        pipe". On gateway death we drop the session and respawn it so the
        same prompt still goes through; genuine agent errors are surfaced
        immediately.

        ``remote`` rides on this call instead of a process-global env var
        (Step 4). Ground truth from the fork's RPC: prompt.submit carries no
        per-turn context field, and the approval guard is a pi-engine
        extension — so remote/local is enforced at SPAWN time via
        HERMES_YOLO_MODE and cannot vary between turns within one gateway
        lifetime (see _spawn_session for the sticky-mode trade-off).
        """
        if remote and not self._remote_seen and self._session is not None:
            # First remote prompt on a locally-spawned gateway: the running
            # gateway may have approvals bypassed (fleet HERMES_YOLO_MODE=1).
            # Drop it so this turn — and every later one — runs on a gateway
            # spawned with approvals enforced. One-time cold-start cost.
            try:
                close = getattr(self._session, "close", None)
                if close:
                    close()
            except Exception:
                pass
            self._session = None
        for _attempt in range(2):
            if self._session is None:
                try:
                    result = self._spawn_session(remote)
                    self._session = result["session"]
                    self._session.subscribe(self._on_pi_event)
                except Exception as exc:
                    if _attempt == 0 and (
                        "gateway" in str(exc).lower()
                        or "broken pipe" in str(exc).lower()
                    ):
                        print(
                            f"[vertus] agent gateway died at startup ({exc}); respawning",
                            file=sys.stderr,
                        )
                        continue
                    self._emit({"type": "error", "message": f"agent start failed: {exc}"})
                    return
            expanded = self._expand_slash_text(text)
            if expanded is None:
                return
            text = expanded
            try:
                self._session.prompt(text)
                # prompt() returning means the agent turn finished; the
                # bridge may already emit done, but emit it here as a
                # backstop so clients always see a terminator.
                self._emit({"type": "done"})
                return
            except Exception as exc:  # noqa: PERF203
                dead = (
                    bool(getattr(self._session, "is_dead", False))
                    or isinstance(exc, BrokenPipeError)
                    or "broken pipe" in str(exc).lower()
                    or "gateway exited" in str(exc).lower()
                )
                try:
                    close = getattr(self._session, "close", None)
                    if close:
                        close()
                except Exception:
                    pass
                self._session = None
                if dead and _attempt == 0:
                    print(f"[vertus] agent gateway died ({exc}); respawning", file=sys.stderr)
                    continue
                self._emit({"type": "error", "message": str(exc)[:500]})
                return

    def _on_pi_event(self, event) -> None:
        """Translate raw agent session events into structured wire events.

        Wire format (what every client expects):
          {"type": "text",     "text": "<assistant text chunk>"}
          {"type": "activity", "text": "<tool call / status description>"}
          {"type": "done"}
          {"type": "error",    "message": "..."}

        The hermes bridge already emits wire-shaped events; pass those
        through untouched. The pi path below translates its raw events.
        """
        try:
            etype = getattr(event, "type", None) or (event.get("type") if isinstance(event, dict) else None)
            if etype in ("text", "activity", "done"):
                self._emit(event)
                return
            # Streaming assistant text: message_update wraps an
            # assistantMessageEvent with type text_delta.
            if etype == "message_update":
                ame = getattr(event, "assistantMessageEvent", None)
                if ame is None and isinstance(event, dict):
                    ame = event.get("assistantMessageEvent")
                ame_type = getattr(ame, "type", None) or (ame.get("type") if isinstance(ame, dict) else None)
                if ame_type == "text_delta":
                    delta = getattr(ame, "delta", None)
                    if delta is None and isinstance(ame, dict):
                        delta = ame.get("delta")
                    if delta:
                        self._emit({"type": "text", "text": delta})
                elif ame_type == "thinking_delta":
                    # Surface reasoning as activity, not transcript text.
                    delta = getattr(ame, "delta", None)
                    if delta is None and isinstance(ame, dict):
                        delta = ame.get("delta")
                    if delta:
                        self._emit({"type": "activity", "text": "thinking…"})
                elif ame_type == "toolcall_start":
                    self._emit({"type": "activity", "text": "running tools…"})

            elif etype == "tool_execution_start":
                tool = getattr(event, "toolName", None) or (event.get("toolName") if isinstance(event, dict) else "tool")
                self._emit({"type": "activity", "text": f"running {tool}…"})

            elif etype == "agent_end":
                self._emit({"type": "done"})

            elif etype == "error":
                msg = getattr(event, "errorMessage", None) or getattr(event, "message", None) or "agent error"
                self._emit({"type": "error", "message": str(msg)[:500]})

            # Other events (message_start/end, turn_start, compaction, retries)
            # are intentionally not forwarded — clients only need text,
            # activity, done, and error.
        except Exception:
            pass

    def slash_catalog(self) -> dict:
        """Slash-command + skill catalog for client autocomplete menus."""
        catalog = getattr(self._session, "slash_catalog", None)
        if catalog is None:  # pi fallback bridge
            return {"commands": [], "skillCount": 0}
        try:
            return catalog()
        except Exception as exc:  # noqa: BLE001
            return {"commands": [], "skillCount": 0, "error": str(exc)[:200]}

    def prompt(self, text: str, remote: bool) -> None:
        self._queue.put((text, remote))


class VertusHandler(BaseHTTPRequestHandler):
    server_version = "VertusServer/1.1"
    sessions: SessionManager = None  # type: ignore[assignment]
    token: str = ""
    registry: AgentRegistry = None  # type: ignore[assignment]

    def _authed(self) -> bool:
        header = self.headers.get("Authorization", "")
        return secrets.compare_digest(header, f"Bearer {self.token}")

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        # Route on the path only; agent_id etc. arrive as query params.
        path = urlsplit(self.path).path
        if path == "/api/health":
            self._json(200, {"status": "ok", "time": int(time.time())})
        elif path == "/api/skills":
            agent_id = self._query_param("agent_id")
            self._json(200, self.sessions.get_or_create_session(agent_id).slash_catalog())
        elif path == "/api/agents":
            self._handle_agents_list()
        elif path.startswith("/api/agents/"):
            self._handle_agent_get(path[len("/api/agents/"):].strip("/"))
        elif path == "/api/events":
            self._sse(self._query_param("agent_id"))
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return
        route = urlsplit(self.path).path
        if route == "/api/prompt":
            text = str(payload.get("text", payload.get("prompt", ""))).strip()
            if not text:
                self._json(400, {"error": "text required"})
                return
            remote = self.headers.get("X-Vertus-Client", "local").lower() != "local"
            agent_id = str(payload.get("agent_id") or DEFAULT_AGENT_ID)
            try:
                self.sessions.get_or_create_session(agent_id).prompt(text, remote=remote)
            except KeyError:
                self._json(404, {"error": f"agent not found: {agent_id}"})
                return
            sandbox_path = ""
            try:
                sandbox_path = resolve_sandbox_cwd(self.registry, agent_id)
            except Exception:  # noqa: BLE001  # report path best-effort only
                pass
            self._json(202, {"accepted": True, "agent_id": agent_id, "sandbox_path": sandbox_path})
        elif route == "/api/agents":
            name = str(payload.get("name", "")).strip()
            if not name:
                self._json(400, {"error": "name required"})
                return
            try:
                self._json(201, self.registry.create_agent(name))
            except Exception as exc:  # noqa: BLE001
                self._json(500, {"error": str(exc)[:200]})
        else:
            self._json(404, {"error": "not found"})

    def _query_param(self, name: str) -> str:
        return (parse_qs(urlsplit(self.path).query).get(name) or [""])[0]

    def _handle_agents_list(self) -> None:
        """GET /api/agents — self-heals the registry (primary) then lists."""
        try:
            self.registry.ensure_primary()
            self._json(200, {"agents": self.registry.list_agents()})
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"error": str(exc)[:200]})

    def _handle_agent_get(self, agent_id: str) -> None:
        """GET /api/agents/<id> — one agent, 404 when unknown."""
        if not agent_id:
            self._json(404, {"error": "not found"})
            return
        try:
            self._json(200, self.registry.get_agent(agent_id))
        except KeyError:
            self._json(404, {"error": "agent not found"})
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"error": str(exc)[:200]})

    def _sse(self, agent_id: str = DEFAULT_AGENT_ID) -> None:
        try:
            bridge = self.sessions.get_or_create_session(agent_id or DEFAULT_AGENT_ID)
        except KeyError:
            self._json(404, {"error": f"agent not found: {agent_id}"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        q = bridge.subscribe()
        try:
            while True:
                try:
                    event = q.get(timeout=15)
                except Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                data = json.dumps(event, ensure_ascii=False)
                self.wfile.write(f"data: {data}\n\n".encode())
                self.wfile.flush()
        except (ConnectionAbortedError, BrokenPipeError, OSError):
            pass
        finally:
            bridge.unsubscribe(q)

    def log_message(self, fmt: str, *args) -> None:
        pass


def resolve_sandbox_cwd(registry: AgentRegistry, agent_id: str) -> str:
    """Validate the agent and return its sandbox dir, re-ensured on disk.

    Every per-agent session is cwd-bound here — this is the hub's sandbox
    isolation point. The registry's get_agent() is also the unknown-agent
    gate (KeyError → 404). Falls back to <registry.root>/<id>/sandbox if the
    profile predates the sandbox_path field; the directory is (re-)created
    if it vanished.
    """
    agent = registry.get_agent(agent_id)  # KeyError for unknown agents
    sandbox = agent.get("sandbox_path") or str(registry.root / agent_id / "sandbox")
    Path(sandbox).expanduser().mkdir(parents=True, exist_ok=True)
    return str(Path(sandbox).expanduser().resolve())


def resolve_session_kwargs(registry: AgentRegistry, agent_id: str) -> dict:
    """Per-agent identity kwargs for engine session creation (Step 3).

    Returns {} when the agent carries no per-agent identity (legacy profiles
    or the pi fallback bridge), and otherwise forwards exactly what the
    hermes bridge's create_agent_session() accepts:

      agent_home  — the agent's derived engine config root, injected into
                    the gateway as HERMES_HOME so config.yaml, SOUL.md,
                    memories/, auth.json, and .env all resolve per-bot.
      model/provider — forwarded as the per-session model override param.
      extra_env   — HERMES_MODEL / HERMES_INFERENCE_PROVIDER fallbacks so
                    the override holds even for engines that ignore the
                    session.create model param (belt and suspenders).
    """
    agent = registry.get_agent(agent_id)
    kwargs: dict = {}
    home = agent.get("home_path") or str(registry.agent_home(agent_id))
    if home and Path(home).is_dir():
        kwargs["agent_home"] = home
    model = agent.get("model")
    provider = agent.get("provider")
    if model:
        kwargs["model"] = str(model)
    if provider:
        kwargs["provider"] = str(provider)
    extra: dict = {}
    if model:
        extra["HERMES_MODEL"] = str(model)
    if provider:
        extra["HERMES_INFERENCE_PROVIDER"] = str(provider)
    if extra:
        kwargs["extra_env"] = extra
    return kwargs


def build_session_manager(registry: AgentRegistry, factory=None) -> SessionManager:
    """One SessionManager for the hub: primary prewarmed, others lazy.

    Each bridge is created with its agent's sandbox dir as the session cwd
    plus its identity kwargs (per-agent HERMES_HOME + model override; see
    resolve_session_kwargs). ``factory`` defaults to building real
    AgentBridges (hermes engine); tests inject fakes so no engine subprocess
    is ever spawned — fakes that accept ``cwd=`` keep working because
    identity kwargs are only added when the profile actually carries them.
    """
    if factory is None:
        def factory(agent_id: str):
            return AgentBridge(
                agent_id=agent_id,
                cwd=resolve_sandbox_cwd(registry, agent_id),
                session_kwargs=resolve_session_kwargs(registry, agent_id),
            )
    return SessionManager(
        registry,
        factory=factory,
        seed_agent_id=DEFAULT_AGENT_ID,
    )


def serve(host: str | None, port: int) -> None:
    token = ensure_token()
    # The quick bar runs on this Mac and dials 127.0.0.1; the phone dials the
    # tailnet address. Bind both so every client reaches the same hub.
    bind_hosts = ["127.0.0.1"]
    if host and host not in bind_hosts:
        bind_hosts.append(host)
    elif host is None:
        ip = tailnet_ip()
        if ip and ip not in bind_hosts:
            bind_hosts.append(ip)
    registry = AgentRegistry()
    VertusHandler.registry = registry
    VertusHandler.token = token
    # ensure_primary() MUST run before the session manager seeds the primary
    # bridge: on a fresh store the seed factory resolves the sandbox via
    # get_agent("primary"), which raises KeyError until the agent exists.
    try:
        primary = registry.ensure_primary()
        print(f"[vertus] agents root: {registry.root} (primary: {primary['id']})")
        sessions = build_session_manager(registry)
        VertusHandler.sessions = sessions
        print("[vertus] agent session prewarm starting (primary)…", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001
        # A hub with no usable registry cannot serve any agent; fail loudly
        # rather than come up half-broken.
        print(f"[vertus] agent registry/session init failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    servers: list[ThreadingHTTPServer] = []
    for h in bind_hosts:
        try:
            server = ThreadingHTTPServer((h, port), VertusHandler)
        except OSError as exc:
            print(f"[vertus] could not bind {h}:{port} ({exc})", file=sys.stderr)
            continue
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"[vertus] serving on http://{h}:{port}")
    print(f"[vertus] token file: {TOKEN_FILE}")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        for server in servers:
            server.shutdown()


def main() -> None:
    parser = argparse.ArgumentParser(description="VERTUS server")
    sub = parser.add_subparsers(dest="command", required=True)
    p_serve = sub.add_parser("serve", help="run the VERTUS daemon")
    p_serve.add_argument("--host", default=os.environ.get("VERTUS_HOST"))
    p_serve.add_argument("--port", type=int, default=int(os.environ.get("VERTUS_PORT", "8787")))
    sub.add_parser("token", help="print the bearer token")
    args = parser.parse_args()
    if args.command == "serve":
        serve(args.host, args.port)
    elif args.command == "token":
        print(ensure_token())


if __name__ == "__main__":
    main()
