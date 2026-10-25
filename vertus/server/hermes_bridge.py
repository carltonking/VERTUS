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
import signal
import subprocess
import threading
from pathlib import Path

# Dual import like vertus_server.py: plain for script-dir invocation, package-relative for -m.
try:
    import vertus_paths  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore

# Fork/venv resolution lives in vertus_paths (VERTUS_HERMES_REPO /
# VERTUS_HERMES_PYTHON → ~/.hermes/hermes-agent). Frozen at import like
# before — the doctor resolves at call time from the same single resolver.
FORK_REPO = vertus_paths.fork_repo()
VENV_PYTHON = vertus_paths.venv_python()
READY_TIMEOUT_S = float(os.environ.get("VERTUS_HERMES_READY_TIMEOUT_S", "60"))

# A stray automation loop on this machine runs `pkill -f tui_gateway.entry`
# before its own CLI canary tests, which also kills THIS server's gateway
# child. Launch the gateway through a -c shim whose cmdline never contains
# the literal "tui_gateway.entry", so that blanket pkill can't match it.
# (The module name is built at runtime from two pieces to keep the string
# out of the process list.)
#
# sys.argv stays ["-c"]: Hermes (Oct 2026) re-execs itself under a per-data-
# root runtime for an agent home other than ~/.hermes, and only a "-c" argv
# makes it replay this shim; any other argv[0] is run as a file path, which
# killed every agent gateway at spawn.
_GATEWAY_BOOT = (
    "import runpy;"
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
        # Approval requests the gateway is waiting on: approval_id -> (the
        # gateway's own request id, which the answer frame must carry; the
        # choices it offered).
        self._approvals: dict[str, tuple[str, tuple[str, ...]]] = {}
        # How recently settled approvals ended (answer or withdrawal), so a
        # losing second answer is told what actually happened. Bounded.
        self._settled: dict[str, str] = {}
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

    APPROVAL_CHOICES = ("once", "session", "always", "deny")

    def settled_approval(self, approval_id: str) -> str | None:
        """How an approval this session saw was settled, or None."""
        with self._lock:
            return self._settled.get(approval_id)

    def _remember_settled(self, approval_id: str, decision: str) -> None:
        # Caller holds _lock.
        self._settled[approval_id] = decision
        while len(self._settled) > 256:
            self._settled.pop(next(iter(self._settled)))

    def respond_approval(self, approval_id: str, choice: str) -> bool:
        """Answer a pending approval request. False when it is unknown or
        already settled (answered elsewhere, withdrawn, timed out). A choice
        the engine did not offer (e.g. "always" for a command it will not let
        be allowed for good) is refused with ValueError."""
        if choice not in self.APPROVAL_CHOICES:
            raise ValueError(f"choice must be one of {self.APPROVAL_CHOICES}")
        with self._lock:
            pending = self._approvals.get(approval_id)
            if pending is None or self._proc.stdin is None:
                return False
            gateway_id, offered = pending
            if choice not in offered:
                raise ValueError(f"choice {choice!r} was not offered for this approval ({', '.join(offered)})")
            del self._approvals[approval_id]
            self._remember_settled(approval_id, choice)
            frame = {"jsonrpc": "2.0", "id": gateway_id, "result": {"choice": choice}}
            try:
                self._proc.stdin.write(json.dumps(frame) + "\n")
                self._proc.stdin.flush()
            except (BrokenPipeError, OSError, ValueError):
                return False
        self._emit({"type": "approval_resolved", "approval_id": approval_id, "decision": choice})
        return True

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
        """Rung 1 of the hub's escalation ladder: RPC-abort the in-flight turn.

        Best-effort: the gateway decides what interrupt means (typically it
        cancels the agent loop at the next action boundary — an in-flight
        CUA type/click completes because the driver call is synchronous).
        """
        with self._lock:
            sid = self._session_id
        if sid:
            try:
                self._request("session.interrupt", {"session_id": sid})
            except Exception as exc:
                self._log(f"interrupt failed: {exc}")

    def steer(self, text: str) -> None:
        """Inject a user note into the live turn (fork's ``session.steer``).

        Safe to call while a turn is running: the fork appends the text to
        the last tool result of the NEXT tool batch (no interrupt, no new
        user turn, no role-alternation violation — see methods_session.py
        session.steer in the fork). Raises AgentSessionError when the
        gateway refuses (no session, agent without steer support).
        """
        with self._lock:
            sid = self._session_id
        if not sid:
            raise AgentSessionError("no gateway session to steer")
        self._rpccall("session.steer", {"session_id": sid, "text": text},
                      timeout=15)

    def active_list(self, timeout: float = 5.0) -> dict:
        """Cheap liveness RPC for the hub's idle-gateway health check.

        ``session.active_list`` in the fork is an in-memory snapshot of the
        gateway's live sessions — no disk, no agent build — so a healthy
        idle gateway answers in milliseconds and a hung one times out.
        """
        return self._rpccall(
            "session.active_list",
            {"current_session_id": self._session_id or ""},
            timeout=timeout,
        )

    def terminate_process(self) -> None:
        """Rung 2 of the hub's escalation ladder: SIGTERM the process group.

        The gateway is spawned with ``start_new_session=True``, so its whole
        process tree — including the embedded cua-driver daemon the fork
        spawns for computer use — shares one process group. Group-signalling
        means the driver dies WITH the gateway instead of being orphaned to
        launchd when the gateway is killed mid-CUA-action. If the engine has
        already exited the group is gone; that's not an error here.
        """
        try:
            os.killpg(self._proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except Exception as exc:  # noqa: BLE001
            self._log(f"terminate_process failed: {exc}")

    def kill_process(self) -> None:
        """Rung 3 of the hub's escalation ladder: SIGKILL the process group.

        Same group semantics as terminate_process; SIGKILL cannot be ignored,
        so after this rung the gateway and its driver are gone by
        construction and the worker's reader thread observes EOF.
        """
        try:
            os.killpg(self._proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except Exception as exc:  # noqa: BLE001
            self._log(f"kill_process failed: {exc}")

    def _reap_group(self, grace: float = 1.0) -> None:
        """Reap every survivor of the gateway's process group.

        The gateway is spawned with ``start_new_session=True``, so the
        embedded cua-driver daemon it spawns for computer use shares its
        process group. A plain ``proc.terminate()/wait()`` kills only the
        GROUP LEADER: the driver keeps the pgid and is reparented to
        launchd — an orphan that accumulates across a long-lived hub
        (observed live: ppid-1 ``cua-driver serve --embedded`` after a
        natural gateway exit). This signals the WHOLE group — SIGTERM,
        grace, then SIGKILL — so the driver dies with its gateway on every
        teardown path: natural exit (reader EOF), stale respawn, close(),
        agent DELETE. Idempotent: ProcessLookupError means the group is
        already empty. The escalation ladder's terminate/kill rungs use the
        same group semantics, so this is the one shared mechanism.

        pgid-reuse race: if the group empties and the OS hands the pgid to
        an unrelated new group before the SIGKILL lands, killpg would signal
        strangers. In practice the grace is a fraction of a second and the
        pgid is the gateway's own pid — just-freed pids are not recycled
        that fast; we accept the residual risk rather than track children
        by pid (which would race the driver's own exit anyway).
        """
        try:
            os.killpg(self._proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return  # group already empty (leader gone, no children)
        except Exception as exc:  # noqa: BLE001
            self._log(f"reap SIGTERM failed: {exc}")
            return
        try:
            self._proc.wait(timeout=grace)
        except Exception:
            pass
        try:
            os.killpg(self._proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except Exception as exc:  # noqa: BLE001
            self._log(f"reap SIGKILL failed: {exc}")
        try:
            self._proc.wait(timeout=2)
        except Exception:
            pass

    def close(self) -> None:
        """Terminate and reap the gateway child (safe when already dead).

        Group-signals (see _reap_group) so a driver child dies with the
        gateway instead of being orphaned to launchd.
        """
        self._reap_group(grace=10)
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

    def _create_session(self, cwd: str, model: str | None = None, provider: str | None = None) -> str:
        """Create one persistent hermes session; returns its session id.

        ``model``/``provider`` are the fork's documented PER-SESSION overrides
        (tui_gateway/methods_session.py: the desktop composer ships them on
        every session.create; they never mutate the profile config).
        """
        params: dict = {"cwd": cwd}
        if model:
            params["model"] = model
        if provider:
            params["provider"] = provider
        resp = self._rpccall("session.create", params)
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
            elif ptype == "request.cancel":
                # The gateway withdrew a request (approval timed out,
                # answered on another surface, turn interrupted).
                if payload.get("method") == "approval":
                    gateway_id = str(payload.get("id", ""))
                    with self._lock:
                        approval_id = next((a for a, (g, _) in self._approvals.items() if g == gateway_id), None)
                        if approval_id is not None:
                            del self._approvals[approval_id]
                            self._remember_settled(approval_id, "withdrawn")
                    if approval_id is not None:
                        self._emit({"type": "approval_resolved", "approval_id": approval_id,
                                    "decision": "withdrawn",
                                    "reason": str(payload.get("reason") or "")[:200]})
            elif ptype == "error":
                msg = payload.get("text") or payload.get("message") or "agent error"
                self._emit({"type": "error", "message": str(msg)[:500]})
                self._finish_turn(error=str(msg))
            # Everything else (session lifecycle, approvals, clarify, ...) is
            # intentionally not forwarded — clients only need text, activity,
            # done, and error.
        except Exception:
            pass

    def _handle_server_request(self, msg: dict) -> None:
        """An approval becomes a hub event any client can answer (the island,
        today); the gateway keeps its own deadline and fails closed on it.

        Any other request (clarify, secrets, …) has no hub surface yet, so it
        is answered "method not found" at once: the gateway then withdraws it
        instead of parking the agent until its timeout."""
        gateway_id = str(msg.get("id"))
        params = msg.get("params") or {}
        if msg.get("method") == "approval":
            approval_id = str(params.get("request_id") or f"gw-{gateway_id}")
            choices = [c for c in (params.get("choices") or []) if c in self.APPROVAL_CHOICES]
            with self._lock:
                self._approvals[approval_id] = (gateway_id, tuple(choices or ["once", "deny"]))
            self._emit({
                "type": "approval_request",
                "approval_id": approval_id,
                "command": str(params.get("command") or "")[:2000],
                "description": str(params.get("description") or "")[:500],
                "choices": choices or ["once", "deny"],
            })
            return
        with self._lock:
            if self._proc.stdin is None:
                return
            try:
                self._proc.stdin.write(json.dumps({
                    "jsonrpc": "2.0", "id": msg.get("id"),
                    "error": {"code": -32601, "message": "the VERTUS hub cannot answer this yet"},
                }) + "\n")
                self._proc.stdin.flush()
            except (BrokenPipeError, OSError, ValueError):
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
                # Server -> client requests (the gateway asking the client
                # something and waiting): a method AND an id.
                if msg.get("method") and msg.get("id") is not None:
                    self._handle_server_request(msg)
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
            # The LEADER is gone but the embedded cua-driver daemon (same
            # process group) may still be alive — a natural gateway exit
            # orphans it to launchd (ppid 1). Reap the whole group so no
            # driver outlives its gateway on ANY exit path.
            try:
                self._reap_group(grace=1.0)
            except Exception:  # noqa: BLE001 — cleanup is best-effort
                pass


# Environment variables the hermes engine actually reads (Step 0(e) of the
# multi-agent audit, grep of os.environ/os.getenv across agent/, tools/,
# hermes_cli/, tui_gateway/ in the fork). Everything else is deliberately
# DROPPED so one bot's context can never leak into another bot's engine.
_ENGINE_ENV_ALLOWLIST = (
    "HERMES_HOME",           # per-agent engine config root (identity isolation)
    "HERMES_PROFILE",        # fork profile selector (profile.* RPC params)
    "HERMES_MODEL",          # model override (server.py _resolve_model)
    "HERMES_INFERENCE_MODEL",
    "HERMES_INFERENCE_PROVIDER",  # provider override (runtime_provider.py)
    "HERMES_YOLO_MODE",      # approval-prompt bypass (fleet-wide policy)
    "HERMES_TIMEZONE",
    "HERMES_QUIET",
    "HERMES_IGNORE_RULES",
    "HERMES_CUA_DRIVER_CMD",  # computer-use driver (fleet default)
    "HERMES_COMPUTER_USE_BACKEND",  # per-agent CUA kill switch ("noop")
    "VERTUS_HUB_URL",          # fleet hub base URL (FLEET.md convention)

    "PATH",
    "HOME",
    "USER",
    "SHELL",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "TERM",
    "TERMINFO",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "REQUESTS_CA_BUNDLE",
    "http_proxy",
    "https_proxy",
    "no_proxy",
)

# Fleet-wide provider API keys, passed through EXPLICITLY (never via wholesale
# env inheritance). The engine prefers its per-agent ``HERMES_HOME/.env`` for
# bot-specific credentials; these cover the case where keys live only in the
# hub's launchd environment. Mirrors the providers documented in the fork's
# cli-config.yaml.example.
PROVIDER_KEY_VARS = (
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "OPENROUTER_API_KEY",
    "NOUS_API_KEY",
    "GITHUB_TOKEN",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "GLM_API_KEY",
    "KIMI_API_KEY",
    "MINIMAX_API_KEY",
    "MINIMAX_CN_API_KEY",
    "HF_TOKEN",
    "NVIDIA_API_KEY",
    "XIAOMI_API_KEY",
    "ARCEEAI_API_KEY",
    "OLLAMA_API_KEY",
    "DEEPINFRA_API_KEY",
    "KILOCODE_API_KEY",
    "AI_GATEWAY_API_KEY",
)


def build_gateway_env(agent_home: str | Path | None = None) -> dict:
    """Construct the gateway child env explicitly — never ``{**os.environ}``.

    Why (Step 3 of the multi-agent audit): the old spawn inherited the hub's
    whole environment, so any agent-scoped variable written into the hub
    process (or set differently between bots) leaked into every gateway and
    from there into every tool the model runs. The allowlist keeps only
    engine-relevant vars; provider API keys are read by the engine from the
    per-agent ``HERMES_HOME/.env`` file, not from this env (the fork resolves
    ``get_env_path()`` under ``get_hermes_home()`` — hermes_cli/config.py).

    ``agent_home`` is injected as ``HERMES_HOME`` (the fork's documented
    per-process config-root override — hermes_constants.get_hermes_home),
    which re-roots config.yaml, SOUL.md, memories/, auth.json, and .env for
    this gateway process alone.

    Provider API keys that must come via env (only when no per-agent .env
    exists) can be attached by the hub through ``extra_env``; the bridge
    itself never forwards the hub's env wholesale.
    """
    env: dict[str, str] = {}
    for key in _ENGINE_ENV_ALLOWLIST:
        value = os.environ.get(key)
        if value is not None:
            env[key] = value
    for key in PROVIDER_KEY_VARS:
        value = os.environ.get(key)
        if value is not None:
            env[key] = value
    if agent_home is not None:
        env["HERMES_HOME"] = str(agent_home)
    return env


def create_agent_session(
    log=print,
    cwd: str | None = None,
    agent_home: str | Path | None = None,
    extra_env: dict | None = None,
    model: str | None = None,
    provider: str | None = None,
):
    """Start the hermes stdio gateway and wait until a session is ready.

    ``cwd`` sets the session workspace the hermes agent runs its tools in
    (shell cwd, file tools, git probe). It is sent as the explicit ``cwd``
    param of the gateway's ``session.create`` RPC — the gateway validates it
    and persists it as the session's workspace. When omitted, the gateway
    falls back to config ``terminal.cwd`` → ``TERMINAL_CWD`` → process cwd.

    ``agent_home`` gives this gateway its own engine config root, passed to
    the child as ``HERMES_HOME`` (the fork resolves its entire config tree
    — config.yaml, SOUL.md, memories/, auth.json, .env — under that var; see
    hermes_constants.get_hermes_home in the fork). When omitted the child
    falls back to the hub's own ``HERMES_HOME``/``~/.hermes`` — the legacy
    single-identity behavior.

    VERTUS hub invariant: each agent's session is created with that agent's
    sandbox directory as cwd, never ``$HOME`` or the repo root, and (when
    the hub passes ``agent_home``) with that agent's identity tree as the
    engine config root.
    """
    if not VENV_PYTHON.exists():
        raise AgentSessionError(f"hermes venv python not found: {VENV_PYTHON}")
    if cwd:
        c = Path(cwd).expanduser()
        c.mkdir(parents=True, exist_ok=True)
        cwd = str(c.resolve())
    child_env = build_gateway_env(agent_home=agent_home)
    if extra_env:
        child_env.update({str(k): str(v) for k, v in extra_env.items()})
    proc = subprocess.Popen(
        [str(VENV_PYTHON), "-u", "-c", _GATEWAY_BOOT],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        cwd=str(FORK_REPO),
        env=child_env,
        # Own session/process group per gateway: the escalation ladder kills
        # the WHOLE group (terminate_process/kill_process use killpg), so the
        # gateway and any child it spawned — notably the embedded cua-driver
        # daemon for computer use — die together. No cross-agent interference
        # (each gateway is its own group) and no orphaned driver processes.
        start_new_session=True,
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
        session._session_id = session._create_session(cwd, model=model, provider=provider)
    except Exception as exc:
        proc.kill()
        raise AgentSessionError(f"hermes session.create failed: {exc}") from exc
    if session._failures:
        raise AgentSessionError(session._failures[0])
    return {"session": session}