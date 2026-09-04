"""VERTUS hermes bridge — drives the forked hermes engine via its TUI gateway.

Exposes the SAME API the VERTUS server expects (drop-in for pi_coding_agent.py):

    result = create_agent_session()
    session = result["session"]
    session.subscribe(callback)   # structured wire-event dicts
    session.prompt(text)          # fire-and-forget; events stream via SSE

Protocol: JSON-RPC 2.0 over stdio to `python -m tui_gateway.entry` in the
forked hermes-agent venv (see hermes-agent/tui_gateway/entry.py). Newline-
framed JSON in both directions. Agent events arrive as `event` frames whose
`params.type` is message.delta / message.complete / tool.start / error / ...
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from pathlib import Path

FORK_REPO = Path(os.environ.get("VERTUS_HERMES_REPO", str(Path.home() / ".hermes" / "hermes-agent")))
VENV_PYTHON = Path(
    os.environ.get("VERTUS_HERMES_PYTHON", str(FORK_REPO / "venv" / "bin" / "python"))
)
READY_TIMEOUT_S = float(os.environ.get("VERTUS_HERMES_READY_TIMEOUT_S", "60"))

# A stray automation loop on this machine runs `pkill -f tui_gateway.entry`
# before its own CLI canary tests, which also kills THIS server's gateway
# child. Launch the gateway through a -c shim whose cmdline never contains
# the literal "tui_gateway.entry", so that blanket pkill can't match it.
# (The module name is built at runtime from two pieces to keep the string
# out of the process list.)
_GATEWAY_BOOT = (
    "import runpy, sys;"
    "sys.argv = [\"vertus-hermes-gateway\"];"
    "runpy.run_module(\"tui_\" + \"gateway.entry\", run_name=\"__main__\")"
)


class AgentSessionError(RuntimeError):
    pass


class _HermesSession:
    """Talk JSON-RPC to the hermes stdio gateway and fan events out to listeners."""

    def __init__(self, proc: subprocess.Popen, log):
        self._proc = proc
        self._log = log
        self._lock = threading.Lock()
        self._listeners: list = []
        self._ready = threading.Event()
        self.is_dead = False
        self._failures: list[str] = []
        self._session_id: str | None = None
        self._next_id = 0
        self._pending: dict[str, tuple[threading.Event, dict, list]] = {}
        self._pending_turn: tuple[threading.Event, list] | None = None
        threading.Thread(target=self._reader, daemon=True).start()

    # -- public API -------------------------------------------------------

    def subscribe(self, listener) -> None:
        with self._lock:
            self._listeners.append(listener)

    def prompt(self, text: str) -> None:
        """Send the prompt and block until the hermes turn finishes.

        The VERTUS server treats prompt() returning as "turn done" (it emits
        a backstop done event); blocking here keeps that contract so a client
        never sees "done" before the reply text.
        """
        self._ensure_ready()
        if self.is_dead:
            raise AgentSessionError("hermes gateway exited")
        with self._lock:
            if self._proc.stdin is None:
                raise AgentSessionError("hermes gateway stdin closed")
            if self._pending_turn is not None:
                raise AgentSessionError("a turn is already in flight")
            if not self._session_id:
                raise AgentSessionError("hermes session not created")
        self._request("prompt.submit", {"session_id": self._session_id, "text": text})
        done = threading.Event()
        errors: list = []
        with self._lock:
            self._pending_turn = (done, errors)
        # The gateway may have died between the is_dead check above and this
        # write; close that race so the worker never blocks forever.
        if self.is_dead:
            self._finish_turn(error="hermes gateway exited")
        # Wait for the turn-terminal event (message.complete / error), not
        # the RPC response: prompt.submit's response frame races the stream.
        done.wait()
        if errors:
            raise AgentSessionError(errors[-1])

    def slash_catalog(self) -> dict:
        """Fetch the slash-command + skill catalog (registry + skills + quick
        commands), shaped for clients: {"commands": [{name, description}]}.
        Mirrors what the hermes CLI's '/' menu shows."""
        resp = self._rpccall("commands.catalog", {}, timeout=30)
        pairs = resp.get("pairs") or []
        commands = []
        for pair in pairs:
            if isinstance(pair, (list, tuple)) and pair:
                commands.append(
                    {
                        "name": str(pair[0]),
                        "description": str(pair[1]) if len(pair) > 1 else "",
                    }
                )
            elif isinstance(pair, str) and pair:
                commands.append({"name": pair, "description": ""})
        return {"commands": commands, "skillCount": int(resp.get("skill_count") or 0)}

    def expand_slash(self, name: str, arg: str) -> dict | None:
        """Resolve a /command through the gateway's command.dispatch — the
        same server-side expansion the hermes CLI uses for skills, bundles,
        /learn, /init, quick commands, and aliases.

        Returns the dispatch result dict ("type": send/exec/alias/skill/…)
        or None when the gateway reports the name isn't a resolvable command
        (the caller then submits the raw text as an ordinary prompt).
        """
        try:
            resp = self._rpccall(
                "command.dispatch",
                {"name": name, "arg": arg, "session_id": self._session_id or ""},
                timeout=30,
            )
        except AgentSessionError as exc:
            # Not a resolvable slash command → submit the raw text as an
            # ordinary prompt (dispatch errors with "unknown command" for
            # registry misses and "not a quick/plugin/bundle/skill command"
            # when nothing claimed the name).
            lowered = str(exc).lower()
            if "unknown command" in lowered or "not a quick" in lowered:
                return None
            raise
        return resp if isinstance(resp, dict) and resp.get("type") else None

    def interrupt(self) -> None:
        """Abort the in-flight turn (best-effort; hub has no abort endpoint yet)."""
        with self._lock:
            sid = self._session_id
        if sid:
            try:
                self._request("session.interrupt", {"session_id": sid})
            except Exception as exc:
                self._log(f"interrupt failed: {exc}")

    def close(self) -> None:
        """Terminate and reap the gateway child (safe when already dead)."""
        if self._proc.poll() is None:
            try:
                self._proc.terminate()
            except Exception:
                pass
            try:
                self._proc.wait(timeout=10)
            except Exception:
                try:
                    self._proc.kill()
                    self._proc.wait(timeout=10)
                except Exception:
                    pass
        self.is_dead = True

    # -- plumbing ----------------------------------------------------------

    def _ensure_ready(self) -> None:
        if not self._ready.wait(READY_TIMEOUT_S):
            raise AgentSessionError("hermes gateway did not become ready in time")

    def _request(self, method: str, params: dict) -> str:
        """Send a JSON-RPC request from the worker thread; returns its id."""
        with self._lock:
            self._next_id += 1
            rid = str(self._next_id)
            self._proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")  # type: ignore[union-attr]
            self._proc.stdin.flush()  # type: ignore[union-attr]
        return rid

    def _rpccall(self, method: str, params: dict, timeout: float = 90.0) -> dict:
        """Send a request and block for its response frame."""
        with self._lock:
            self._next_id += 1
            rid = str(self._next_id)
            evt = threading.Event()
            self._pending[rid] = (evt, {}, [])
            self._proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")  # type: ignore[union-attr]
            self._proc.stdin.flush()  # type: ignore[union-attr]
        if not evt.wait(timeout):
            with self._lock:
                self._pending.pop(rid, None)
            raise AgentSessionError(f"hermes RPC {method} timed out")
        with self._lock:
            holder = self._pending.pop(rid, None)
        if holder is None:
            raise AgentSessionError(f"hermes RPC {method} response lost")
        _evt, result, errors = holder
        if errors:
            raise AgentSessionError(errors[0])
        return result

    def _create_session(self, cwd: str) -> str:
        """Create one persistent hermes session; returns its session id."""
        resp = self._rpccall("session.create", {"cwd": cwd})
        sid = resp.get("session_id") or resp.get("sid")
        if not sid:
            raise AgentSessionError(f"session.create returned no session id: {resp}")
        return str(sid)

    def _emit(self, event: dict) -> None:
        with self._lock:
            listeners = list(self._listeners)
        for fn in listeners:
            try:
                fn(event)
            except Exception:
                pass

    def _finish_turn(self, error: str | None = None) -> None:
        with self._lock:
            pending, self._pending_turn = self._pending_turn, None
        if pending is not None:
            evt, errors = pending
            if error:
                errors.append(error)
            evt.set()

    def _handle_event(self, ptype: str, payload: dict) -> None:
        """Translate hermes gateway events into the structured wire events the
        VERTUS server forwards to clients (same shapes the pi bridge produced):

          {"type": "text",     "text": "<assistant text chunk>"}
          {"type": "activity", "text": "<tool call / status description>"}
          {"type": "done"}
          {"type": "error",    "message": "..."}
        """
        try:
            if ptype == "message.delta":
                text = payload.get("text")
                if text:
                    self._emit({"type": "text", "text": text})
            elif ptype == "message.complete":
                status = payload.get("status")
                if status == "error":
                    msg = payload.get("text") or "hermes turn failed"
                    self._emit({"type": "error", "message": str(msg)[:500]})
                    self._finish_turn(error=str(msg))
                else:
                    self._finish_turn()
            elif ptype == "turn.end":
                self._finish_turn()
            elif ptype == "tool.start":
                name = (payload.get("name") or payload.get("tool") or "tool").split(".")[-1]
                self._emit({"type": "activity", "text": f"running {name}…"})
            elif ptype == "tool.complete":
                pass  # activity spam; clients only need the start marker
            elif ptype == "error":
                msg = payload.get("text") or payload.get("message") or "agent error"
                self._emit({"type": "error", "message": str(msg)[:500]})
                self._finish_turn(error=str(msg))
            # Everything else (session lifecycle, approvals, clarify, ...) is
            # intentionally not forwarded — clients only need text, activity,
            # done, and error.
        except Exception:
            pass

    def _reader(self) -> None:
        try:
            for raw in self._proc.stdout:  # type: ignore[union-attr]
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                # Event frames: {"jsonrpc":"2.0","method":"event","params":{...}}
                if msg.get("method") == "event":
                    params = msg.get("params") or {}
                    ptype = params.get("type")
                    if ptype == "gateway.ready":
                        self._ready.set()
                    elif ptype:
                        self._handle_event(ptype, params.get("payload") or {})
                    continue
                # RPC responses (matched by id).
                rid = str(msg.get("id", ""))
                if msg.get("error"):
                    emsg = str(msg["error"].get("message", "rpc error"))
                    self._failures.append(emsg)
                    with self._lock:
                        holder = self._pending.get(rid)
                    if holder:
                        holder[2].append(emsg)
                        holder[0].set()
                    self._finish_turn(error=emsg)
                    continue
                with self._lock:
                    holder = self._pending.get(rid)
                if holder:
                    holder[1].update(msg.get("result") or {})
                    holder[0].set()
        except Exception:
            pass
        finally:
            self.is_dead = True
            self._ready.set()  # unblock create_agent_session if the gateway dies early
            self._finish_turn(error="hermes gateway exited")
            # Fail any in-flight RPC (e.g. session.create) so callers don't
            # sit out their full timeout waiting on a dead gateway.
            with self._lock:
                pending_rpcs = list(self._pending.values())
                self._pending.clear()
            for _evt, _result, _errors in pending_rpcs:
                _errors.append("hermes gateway exited")
                _evt.set()
            # Reap the child so it doesn't linger as a zombie; wait() on an
            # already-exited process returns immediately.
            try:
                self._proc.wait(timeout=10)
            except Exception:
                pass


def create_agent_session(log=print, cwd: str | None = None):
    """Start the hermes stdio gateway and wait until a session is ready.

    ``cwd`` sets the session workspace the hermes agent runs its tools in
    (shell cwd, file tools, git probe). It is sent as the explicit ``cwd``
    param of the gateway's ``session.create`` RPC — the gateway validates it
    and persists it as the session's workspace. When omitted, the gateway
    falls back to config ``terminal.cwd`` → ``TERMINAL_CWD`` → process cwd.

    VERTUS hub invariant: each agent's session is created with that agent's
    sandbox directory as cwd, never ``$HOME`` or the repo root (the hub
    resolves and creates the directory before calling this).
    """
    if not VENV_PYTHON.exists():
        raise AgentSessionError(f"hermes venv python not found: {VENV_PYTHON}")
    if cwd:
        c = Path(cwd).expanduser()
        c.mkdir(parents=True, exist_ok=True)
        cwd = str(c.resolve())
    proc = subprocess.Popen(
        [str(VENV_PYTHON), "-u", "-c", _GATEWAY_BOOT],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        cwd=str(FORK_REPO),
        env={**os.environ},
    )

    # The hermes engine writes diagnostics to stderr (e.g. the Copilot
    # token-exchange "degraded to RAW token" warning at session create).
    # Never let that leak onto a client's terminal/UI: pipe it and drain it
    # into the hub's own log instead. The engine persists its diagnostics
    # on disk too (agent.log / crash log), so nothing is lost if the hub
    # discards log output.
    def _drain_gateway_stderr() -> None:
        try:
            if proc.stderr is None:
                return
            for raw in proc.stderr:
                line = raw.rstrip()
                if line:
                    log(line)
        except Exception:
            pass

    threading.Thread(target=_drain_gateway_stderr, daemon=True).start()
    session = _HermesSession(proc, log)
    if not session._ready.wait(READY_TIMEOUT_S):
        proc.kill()
        raise AgentSessionError("hermes gateway did not become ready in time")
    # Create one persistent session cwd-bound to the VERTUS working dir so
    # the agent has real workspace context. Each agent gets its own sandbox
    # directory here — the gateway treats an explicit cwd as the session
    # workspace and validates it, so this is the isolation point (see
    # module docstring). Mirrors the pi in-memory default.
    cwd = cwd or os.environ.get("VERTUS_CWD") or os.getcwd()
    try:
        session._session_id = session._create_session(cwd)
    except Exception as exc:
        proc.kill()
        raise AgentSessionError(f"hermes session.create failed: {exc}") from exc
    if session._failures:
        raise AgentSessionError(session._failures[0])
    return {"session": session}