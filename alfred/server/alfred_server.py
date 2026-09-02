"""ALFRED server — long-running daemon wrapping pi's agent SDK.

Exposes the agent over HTTP for three clients (CLI one-shot, macOS quick
bar, iOS app). Binds to the Tailscale interface only; every request needs
a bearer token from ~/.alfred/token.

Run:  python alfred/server/alfred_server.py serve
      ALFRED_HOST=100.x.y.z ALFRED_PORT=8787 python alfred/server/alfred_server.py serve
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

ALFRED_DIR = Path.home() / ".alfred"
TOKEN_FILE = ALFRED_DIR / "token"
DEFAULT_PORT = 8787


def ensure_token() -> str:
    """Load or create the bearer token."""
    ALFRED_DIR.mkdir(parents=True, exist_ok=True)
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
    """Owns the pi agent session and serializes prompts through a queue."""

    def __init__(self) -> None:
        self.subscribers: list[Queue] = []
        self._queue: Queue = Queue()
        self._create_session = None
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

        ALFRED_BRIDGE=pi forces the old pi SDK path (rollback).
        """
        server_dir = Path(__file__).resolve().parent
        if os.environ.get("ALFRED_BRIDGE") != "pi":
            try:
                sys.path.insert(0, str(server_dir))
                from hermes_bridge import create_agent_session  # type: ignore

                return create_agent_session
            except Exception as exc:
                print(f"[alfred] hermes bridge unavailable: {exc}", file=sys.stderr)
                print("[alfred] falling back to pi SDK", file=sys.stderr)
        repo = Path(__file__).resolve().parents[2] / "pi" / "packages" / "coding-agent"
        try:
            sys.path.insert(0, str(repo / "src"))
            from pi_coding_agent import create_agent_session  # type: ignore

            return create_agent_session
        except Exception as exc:
            print(f"[alfred] pi SDK unavailable: {exc}", file=sys.stderr)
            return None

    def _run_worker(self) -> None:
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
            text, remote = item
            os.environ["ALFRED_REMOTE"] = "1" if remote else "0"
            if self._create_session is None:
                self._emit({"type": "error", "message": "agent SDK not available"})
                continue
            self._run_prompt_with_respawn(text)

    def _prewarm(self) -> None:
        """Create the agent session at startup; never raises."""
        if self._create_session is None:
            return
        try:
            result = self._create_session()
            self._session = result["session"]
            self._session.subscribe(self._on_pi_event)
            print("[alfred] agent session prewarmed", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            print(f"[alfred] prewarm failed (will retry on first prompt): {exc}", file=sys.stderr)

    def _run_prompt_with_respawn(self, text: str) -> None:
        """Run one prompt, restarting a dead agent gateway once in-line.

        The hermes gateway runs as a child process that can be killed
        externally (e.g. SIGTERM). Without recovery, every later prompt
        would write into the dead pipe and surface as "[Errno 32] Broken
        pipe". On gateway death we drop the session and respawn it so the
        same prompt still goes through; genuine agent errors are surfaced
        immediately.
        """
        for _attempt in range(2):
            if self._session is None:
                try:
                    result = self._create_session()
                    self._session = result["session"]
                    self._session.subscribe(self._on_pi_event)
                except Exception as exc:
                    if _attempt == 0 and (
                        "gateway" in str(exc).lower()
                        or "broken pipe" in str(exc).lower()
                    ):
                        print(
                            f"[alfred] agent gateway died at startup ({exc}); respawning",
                            file=sys.stderr,
                        )
                        continue
                    self._emit({"type": "error", "message": f"agent start failed: {exc}"})
                    return
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
                    print(f"[alfred] agent gateway died ({exc}); respawning", file=sys.stderr)
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

    def prompt(self, text: str, remote: bool) -> None:
        self._queue.put((text, remote))


class AlfredHandler(BaseHTTPRequestHandler):
    server_version = "AlfredServer/1.0"
    bridge: AgentBridge = None  # type: ignore[assignment]
    token: str = ""

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
        if self.path == "/api/health":
            self._json(200, {"status": "ok", "time": int(time.time())})
        elif self.path == "/api/events":
            self._sse()
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
        if self.path == "/api/prompt":
            text = str(payload.get("text", "")).strip()
            if not text:
                self._json(400, {"error": "text required"})
                return
            remote = self.headers.get("X-Alfred-Client", "local").lower() != "local"
            self.bridge.prompt(text, remote=remote)
            self._json(202, {"accepted": True})
        else:
            self._json(404, {"error": "not found"})

    def _sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        q = self.bridge.subscribe()
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
            self.bridge.unsubscribe(q)

    def log_message(self, fmt: str, *args) -> None:
        pass


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
    bridge = AgentBridge()
    AlfredHandler.bridge = bridge
    AlfredHandler.token = token
    servers: list[ThreadingHTTPServer] = []
    for h in bind_hosts:
        try:
            server = ThreadingHTTPServer((h, port), AlfredHandler)
        except OSError as exc:
            print(f"[alfred] could not bind {h}:{port} ({exc})", file=sys.stderr)
            continue
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"[alfred] serving on http://{h}:{port}")
    print(f"[alfred] token file: {TOKEN_FILE}")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        for server in servers:
            server.shutdown()


def main() -> None:
    parser = argparse.ArgumentParser(description="ALFRED server")
    sub = parser.add_subparsers(dest="command", required=True)
    p_serve = sub.add_parser("serve", help="run the ALFRED daemon")
    p_serve.add_argument("--host", default=os.environ.get("ALFRED_HOST"))
    p_serve.add_argument("--port", type=int, default=int(os.environ.get("ALFRED_PORT", "8787")))
    sub.add_parser("token", help="print the bearer token")
    args = parser.parse_args()
    if args.command == "serve":
        serve(args.host, args.port)
    elif args.command == "token":
        print(ensure_token())


if __name__ == "__main__":
    main()
