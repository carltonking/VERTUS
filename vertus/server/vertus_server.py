"""VERTUS server — long-running daemon wrapping pi's agent SDK.

Exposes the agent over HTTP for three clients (CLI one-shot, macOS quick
bar, iOS app). Binds to the Tailscale interface only; every request needs
a bearer token from ~/.vertus/token.

Run:  python vertus/server/vertus_server.py serve
      VERTUS_HOST=100.x.y.z VERTUS_PORT=8787 python vertus/server/vertus_server.py serve

Lock discipline (Step C)
------------------------
Three lock domains exist: SessionManager._lock (the agent→bridge map),
AgentRegistry._lock (profiles + the on-disk tree), and each bridge's
AgentBridge._status_lock (pure in-memory turn state). Rules:

  1. No code path ever holds two domains at once EXCEPT the documented
     SessionManager._lock → AgentRegistry._lock nesting inside
     get_or_create_session (its factory resolves cwds/identity from the
     registry). AgentRegistry never takes the manager lock and bridges never
     take either, so this nesting cannot deadlock.
  2. Never call into a bridge or engine session (prompt/close/spawn/status)
     while holding the manager or registry lock. Bridge locks guard only
     in-memory flags; engine calls happen on the worker thread or after the
     manager lock is released (SessionManager.drop).
  3. Never do filesystem work while holding the manager lock. All profile /
     home / trash mutation happens under the registry lock, inside registry
     methods, and never while another lock is held.
  4. Handlers that touch both stores (PATCH / DELETE below) acquire them
     SEQUENTIALLY — registry first, manager second — so a concurrent
     PATCH/DELETE/prompt can never deadlock and never observes a torn state.
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
from queue import Queue, Empty, Full
import threading
from threading import Thread
from urllib.parse import parse_qs, urlsplit

# Script-dir import (python3 vertus/server/vertus_server.py) keeps this plain;
# fall back to a package-relative import for `python -m vertus.server.vertus_server`.
try:
    from agent_registry import AgentRegistry, EDITABLE_FIELDS, AUTONOMY_VALUES  # type: ignore
    from run_store import RunStore, RUN_STATES  # type: ignore
    from session_manager import SessionManager, DEFAULT_AGENT_ID  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from .agent_registry import AgentRegistry, EDITABLE_FIELDS, AUTONOMY_VALUES  # type: ignore
    from .run_store import RunStore, RUN_STATES  # type: ignore
    from .session_manager import SessionManager, DEFAULT_AGENT_ID  # type: ignore

VERTUS_DIR = Path.home() / ".vertus"
TOKEN_FILE = VERTUS_DIR / "token"
DEFAULT_PORT = 8787

# HTTP/API policy limits (the registry itself stays permissive; these are
# request-body guards). One persona is typically 1–2k characters; 20k is
# generous headroom while bounding what a client can stuff into SOUL.md.
PERSONA_MAX_CHARS = 20_000

# Free-form text fields treat null as "clear to empty" on PATCH; identity
# fields (model/provider/color/emoji) treat null as "unset → inherit".
_TEXT_FIELDS = ("title", "description", "persona")


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

    def __init__(self, agent_id: str = DEFAULT_AGENT_ID, create_session_factory=None, cwd: str | None = None, session_kwargs: dict | None = None, store=None) -> None:
        self.agent_id = agent_id
        # Durable run store (Step: run history). When set, every wire event is
        # committed BEFORE it is fanned out and stamped agent_id/run_id/seq/ts.
        # When None (legacy/unit tests), events fan out un-enriched exactly as
        # before.
        self.store = store
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
        # Step A: in-flight turn introspection. _status_lock guards ONLY these
        # in-memory flags (never engine calls, never other locks — see the
        # module docstring's lock discipline).
        self._status_lock = threading.Lock()
        self._running = False
        self._turn_started_at: float | None = None
        self._stale = False      # a profile PATCH happened; respawn on next turn
        self._closed = False     # close() called; no new turns may start
        # Current-run tracking (Step: run history). Guarded by _status_lock.
        # Events emitted by the engine's reader thread while the worker is
        # inside a turn are attributed to the run the worker is processing.
        self._current_run_id: str | None = None
        self._run_buffer: list[str] | None = None   # folded at turn end
        self._run_respawns = 0
        self._run_had_error = False
        self._run_error_message = ""
        self._worker = Thread(target=self._run_worker, daemon=True)
        self._worker.start()

    def subscribe(self, maxsize: int = 1000) -> Queue:
        q: Queue = Queue(maxsize=maxsize)
        self.subscribers.append(q)
        return q

    def unsubscribe(self, q: Queue) -> None:
        if q in self.subscribers:
            self.subscribers.remove(q)

    def _fanout(self, event: dict) -> None:
        """Push one (stored) envelope to every subscriber; drop laggards.

        A subscriber whose queue fills is dropped — but the drop is now
        recoverable: the client reconnects with since=<last seq it saw> and
        replays the gap from the store. A best-effort ``lagged`` marker with
        the overflow seq is pushed first when the queue has room; when it is
        completely full the marker cannot fit either and the subscriber is
        dropped silently (it resumes from its own last-seen seq).
        """
        dead: list[Queue] = []
        for q in list(self.subscribers):
            try:
                q.put_nowait(event)
            except Full:
                try:
                    q.put_nowait({
                        "type": "lagged",
                        "last_seq": event.get("seq"),
                        "agent_id": event.get("agent_id"),
                    })
                except Full:
                    pass
                dead.append(q)
        for q in dead:
            self.unsubscribe(q)

    def _emit(self, event: dict) -> None:
        """Route one wire event: persist FIRST, then fan out the envelope.

        Durability rule: an event is written to the store BEFORE it reaches
        any subscriber. On a store write failure the run goes to error and
        nothing is fanned out — no event that isn't in the store ever reaches
        a client. Events with no active run (a store-backed hub) are dropped:
        they belong to no run and cannot be stored or replayed.

        Legacy mode (no store): the pre-history behavior, un-enriched.
        """
        with self._status_lock:
            run_id = self._current_run_id
            if event.get("type") == "text" and self._run_buffer is not None:
                text = event.get("text")
                if isinstance(text, str) and text:
                    self._run_buffer.append(text)
            if event.get("type") == "error":
                self._run_had_error = True
                msg = event.get("message") or event.get("text") or ""
                self._run_error_message = str(msg)[:200]
        if self.store is None:
            self._fanout(event)
            return
        if run_id is None:
            # Store-backed hub but no run context: not storable, not replayable.
            return
        try:
            envelope = self.store.record_event(self.agent_id, run_id, event)
        except Exception as exc:  # noqa: BLE001 — store is the durability boundary
            print(
                f"[vertus] event store write failed (run {run_id}): {exc}",
                file=sys.stderr,
            )
            self._store_failure(run_id, exc)
            return
        self._fanout(envelope)

    def _store_failure(self, run_id: str, exc: BaseException) -> None:
        """A store write failed: the run can't be trusted — mark it error."""
        try:
            self.store.finish_run(
                run_id, "error", error=f"event store failure: {exc}"[:200]
            )
        except Exception:  # noqa: BLE001 — store is down; best effort only
            pass

    def _begin_run(self, run_id: str) -> None:
        """Enter a run context (worker thread, before the turn runs)."""
        with self._status_lock:
            self._current_run_id = run_id
            self._run_buffer = []
            self._run_respawns = 0
            self._run_had_error = False
            self._run_error_message = ""
        if self.store is not None:
            try:
                self.store.mark_running(run_id, self.agent_id)
            except Exception as exc:  # noqa: BLE001
                print(f"[vertus] mark_running failed ({run_id}): {exc}", file=sys.stderr)

    def _abandon_run(self) -> None:
        """A run was dequeued but never started (bridge closed) — interrupt it."""
        with self._status_lock:
            run_id = self._current_run_id
            self._current_run_id = None
            self._run_buffer = None
        if run_id and self.store is not None:
            try:
                self.store.finish_run(run_id, "interrupted")
            except Exception:  # noqa: BLE001
                pass

    def _end_run(self) -> None:
        """Leave the run context: fold the assistant text, set the terminal
        state exactly once (worker thread, after the turn finished)."""
        with self._status_lock:
            run_id = self._current_run_id
            buffer = self._run_buffer
            had_error = self._run_had_error
            error_msg = self._run_error_message
            respawns = self._run_respawns
            self._current_run_id = None
            self._run_buffer = None
            self._run_error_message = ""
        if not run_id or self.store is None:
            return
        store = self.store
        if buffer:
            text = "".join(buffer).strip()
            if text:
                try:
                    store.add_message(run_id, self.agent_id, "assistant", text)
                except Exception as exc:  # noqa: BLE001
                    print(f"[vertus] assistant message fold failed: {exc}", file=sys.stderr)
        try:
            store.finish_run(
                run_id,
                "error" if had_error else "done",
                error=error_msg or None,
                gateway_respawns=respawns,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"[vertus] finish_run failed ({run_id}): {exc}", file=sys.stderr)

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
            # ``run_id`` is the store row created at enqueue time — the run
            # context that stamps every event of this turn.
            text, remote, run_id = item
            if run_id is not None:
                self._begin_run(run_id)
            with self._status_lock:
                closed = self._closed
                if not closed:
                    self._running = True
                    self._turn_started_at = time.monotonic()
            if closed:
                # A close raced the enqueue (DELETE refuses busy bridges, so
                # this is defensive): the run never started — mark it so.
                self._abandon_run()
                break
            try:
                if self._create_session is None:
                    self._emit({"type": "error", "message": "agent SDK not available"})
                else:
                    # Stale profile config (a PATCH happened since the last
                    # turn) is consumed BETWEEN turns: the old gateway
                    # finishes any in-flight turn undisturbed; the NEXT spawn
                    # uses the new kwargs. The running marker wraps the whole
                    # turn INCLUDING the respawn retry path — a turn being
                    # retried is still "running".
                    self._consume_stale()
                    self._run_prompt_with_respawn(text, remote=remote)
            finally:
                with self._status_lock:
                    self._running = False
                    self._turn_started_at = None
                # Fold assistant text + set the terminal state exactly once.
                self._end_run()

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
            if not self._adopt_session(result["session"]):
                return  # closed mid-spawn; the session was shut down
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
                    if not self._adopt_session(result["session"]):
                        return  # bridge was closed while spawning (DELETE)
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
                        with self._status_lock:
                            self._run_respawns += 1
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
                    with self._status_lock:
                        self._run_respawns += 1
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

    def prompt(self, text: str, remote: bool, run_id: str | None = None) -> None:
        """Queue one turn. Raises RuntimeError after close() (hub → 409).

        ``run_id`` links every event of this turn to the store row created at
        enqueue time; None keeps the legacy (un-stored) path used by tests.
        """
        with self._status_lock:
            if self._closed:
                raise RuntimeError(f"agent {self.agent_id} is closed")
        self._queue.put((text, remote, run_id))

    # ------------------------------------------------------------------
    # Step A: turn introspection + lifecycle (reconfigure / close)
    # ------------------------------------------------------------------

    def status(self) -> dict:
        """Live turn state: idle | running | queued, plus queue/gateway health.

        ``gateway_alive`` is False when no engine session exists yet (agent
        never prompted, or the last spawn failed) or the current session
        reports itself dead. Pure read — no engine call, no side effect.
        """
        with self._status_lock:
            running = self._running
            started = self._turn_started_at
            closed = self._closed
        session = self._session
        gateway_alive = (
            not closed
            and session is not None
            and not bool(getattr(session, "is_dead", False))
        )
        depth = self._queue.qsize()
        state = "running" if running else ("queued" if depth else "idle")
        return {
            "state": state,
            "queue_depth": depth,
            "turn_started_at": started,
            "gateway_alive": gateway_alive,
        }

    def reconfigure(self, session_kwargs: dict) -> None:
        """Apply new identity kwargs after a profile PATCH.

        Marks the bridge stale so the NEXT turn closes the current gateway
        and respawns with the new config; an in-flight turn keeps running on
        the old gateway to completion. Two PATCHes before the next turn
        coalesce into a single respawn (stale is a boolean).
        """
        with self._status_lock:
            if self._closed:
                return
            self._session_kwargs = dict(session_kwargs or {})
            self._stale = True

    def close(self) -> None:
        """Stop the bridge: drain queued turns, close the engine session, exit.

        Safe on an idle bridge (the hub DELETE path — a running bridge is
        refused with 409 upstream). Engine close happens outside the status
        lock; the worker exits on the None sentinel.
        """
        with self._status_lock:
            if self._closed:
                return
            self._closed = True
        # Drain anything queued so no turn runs after close (DELETE refused
        # busy bridges, but a prompt can race in between the check and here).
        while True:
            try:
                self._queue.get_nowait()
            except Empty:
                break
        session = self._session
        self._session = None
        if session is not None:
            try:
                session.close()
            except Exception:  # noqa: BLE001 — close is best-effort
                pass
        self._queue.put(None)

    def _consume_stale(self) -> None:
        """Drop the current engine session when a PATCH marked it stale."""
        with self._status_lock:
            stale = self._stale
            if stale:
                self._stale = False
        if not stale:
            return
        session = self._session
        self._session = None
        if session is not None:
            try:
                session.close()
            except Exception:  # noqa: BLE001 — close is best-effort
                pass

    def _adopt_session(self, session) -> bool:
        """Store a freshly spawned engine session unless the bridge was closed
        in the meantime (a DELETE raced the spawn) — then close it instead."""
        with self._status_lock:
            if self._closed:
                closed = True
            else:
                self._session = session
                closed = False
        if closed:
            try:
                session.close()
            except Exception:  # noqa: BLE001
                pass
            return False
        return True


class FleetFan:
    """Fan committed envelopes (ALL agents) to fleet-stream subscribers.

    The hub registers this as the RunStore's ``listener``, so the writer
    thread pushes every committed event here after commit. Fleet SSE clients
    subscribe here instead of to one agent's bridge — they see every agent,
    including agents that start mid-connection. Drop policy mirrors
    AgentBridge._fanout: a full subscriber is dropped (recoverable via
    since=), with a best-effort ``lagged`` marker.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.subscribers: list[Queue] = []

    def subscribe(self) -> Queue:
        q: Queue = Queue(maxsize=1000)
        with self._lock:
            self.subscribers.append(q)
        return q

    def unsubscribe(self, q: Queue) -> None:
        with self._lock:
            if q in self.subscribers:
                self.subscribers.remove(q)

    def publish(self, envelope: dict) -> None:
        dead: list[Queue] = []
        with self._lock:
            targets = list(self.subscribers)
        for q in targets:
            try:
                q.put_nowait(envelope)
            except Full:
                try:
                    q.put_nowait({
                        "type": "lagged",
                        "last_seq": envelope.get("seq"),
                        "agent_id": envelope.get("agent_id"),
                    })
                except Full:
                    pass
                dead.append(q)
        if dead:
            self.unsubscribe_all(dead)

    def unsubscribe_all(self, dead: list[Queue]) -> None:
        with self._lock:
            for q in dead:
                if q in self.subscribers:
                    self.subscribers.remove(q)


class VertusHandler(BaseHTTPRequestHandler):
    server_version = "VertusServer/1.1"
    sessions: SessionManager = None  # type: ignore[assignment]
    token: str = ""
    registry: AgentRegistry = None  # type: ignore[assignment]
    store: RunStore = None  # type: ignore[assignment]
    fleet: FleetFan = None  # type: ignore[assignment]

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
            rest = path[len("/api/agents/"):].strip("/")
            if not rest:
                self._json(404, {"error": "not found"})
            elif rest.endswith("/messages"):
                self._handle_agent_messages(rest[: -len("/messages")])
            elif rest.endswith("/status"):
                self._handle_agent_status(rest[: -len("/status")])
            else:
                self._handle_agent_get(rest)
        elif path == "/api/events":
            self._sse(
                self._query_param("agent_id"),
                since=self._query_param("since"),
                run_id=self._query_param("run_id"),
            )
        elif path == "/api/runs":
            self._handle_runs_list()
        elif path.startswith("/api/runs/"):
            self._handle_run_get(path[len("/api/runs/"):].strip("/"))
        elif path == "/api/fleet/activity":
            self._handle_fleet_activity()
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        payload = self._read_body()
        if payload is None:
            return
        route = urlsplit(self.path).path
        if route == "/api/prompt":
            text = str(payload.get("text", payload.get("prompt", ""))).strip()
            if not text:
                self._json(400, {"error": "text required"})
                return
            source = str(self.headers.get("X-Vertus-Client", "local") or "local")
            remote = source.lower() != "local"
            agent_id = str(payload.get("agent_id") or DEFAULT_AGENT_ID)
            # Validate the agent BEFORE creating the run row so an unknown id
            # never leaves an orphan queued run behind.
            try:
                self.registry.get_agent(agent_id)
            except KeyError:
                self._json(404, {"error": f"agent not found: {agent_id}"})
                return
            run_id = None
            if self.store is not None:
                try:
                    # The run row exists at enqueue time (state=queued); the
                    # worker flips it to running and sets the terminal state.
                    run_id = self.store.create_run(agent_id, text, remote, source=source)
                    self.store.add_message(run_id, agent_id, "user", text)
                except Exception as exc:  # noqa: BLE001
                    self._json(503, {"error": f"run store unavailable: {str(exc)[:200]}"})
                    return
            try:
                bridge = self.sessions.get_or_create_session(agent_id)
                if self.store is not None:
                    # The bridge persists every event of the run to the store
                    # BEFORE fanout; bind it now (the default factory doesn't
                    # take a store kwarg so test fakes stay compatible).
                    bridge.store = self.store
                bridge.prompt(text, remote=remote, run_id=run_id)
            except KeyError:
                # Agent deleted between validation and enqueue (a DELETE won
                # the race). The queued run must not linger: abandon it.
                if run_id:
                    try:
                        self.store.finish_run(run_id, "abandoned", error="agent deleted")
                    except Exception:  # noqa: BLE001
                        pass
                self._json(404, {"error": f"agent not found: {agent_id}"})
                return
            except RuntimeError as exc:  # bridge closed mid-DELETE
                if run_id:
                    try:
                        self.store.finish_run(run_id, "abandoned", error=str(exc)[:200])
                    except Exception:  # noqa: BLE001
                        pass
                self._json(409, {"error": str(exc)[:200]})
                return
            sandbox_path = ""
            try:
                sandbox_path = resolve_sandbox_cwd(self.registry, agent_id)
            except Exception:  # noqa: BLE001  # report path best-effort only
                pass
            self._json(202, {
                "accepted": True,
                "agent_id": agent_id,
                "run_id": run_id,
                "sandbox_path": sandbox_path,
            })
        elif route == "/api/agents":
            raw_name = payload.get("name")
            if not isinstance(raw_name, str) or not raw_name.strip():
                self._json(400, {"error": "name required (non-empty string)"})
                return
            try:
                fields = _validate_profile_payload(payload, allow_name=True)
            except ValueError as exc:
                self._json(400, {"error": str(exc)})
                return
            try:
                self._json(201, self.registry.create_agent(raw_name.strip(), **fields))
            except (TypeError, ValueError) as exc:  # registry backstop
                self._json(400, {"error": str(exc)[:200]})
        else:
            self._json(404, {"error": "not found"})

    def do_PATCH(self) -> None:  # noqa: N802
        """PATCH /api/agents/<id> — partial profile update (v2 editable fields)."""
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        agent_id = self._agent_route_id()
        if agent_id is None:
            self._json(404, {"error": "not found"})
            return
        payload = self._read_body()
        if payload is None:
            return
        if "name" in payload:
            self._json(
                400,
                {"error": f"name is not editable via PATCH; allowed: {', '.join(EDITABLE_FIELDS)}"},
            )
            return
        try:
            fields = _validate_profile_payload(payload, allow_name=False)
        except ValueError as exc:
            self._json(400, {"error": str(exc)})
            return
        if not fields:
            # PATCH {} — a no-op read of current state; nothing is respawned.
            try:
                updated = self.registry.get_agent(agent_id)
            except KeyError:
                self._json(404, {"error": f"agent not found: {agent_id}"})
                return
            self._json(200, {**updated, "respawn_pending": False})
            return
        try:
            updated = self.registry.update_agent(agent_id, **fields)
        except KeyError:
            self._json(404, {"error": f"agent not found: {agent_id}"})
            return
        except (TypeError, ValueError) as exc:  # registry backstop
            self._json(400, {"error": str(exc)[:200]})
            return
        # A live bridge must respawn with the new config on its NEXT turn; an
        # in-flight turn keeps running on the old gateway to completion. The
        # update is deferred, never blocked — reconfigure() only flags state.
        respawn_pending = False
        if self.sessions.has_session(agent_id):
            try:
                bridge = self.sessions.get_or_create_session(agent_id)  # exists: no creation
                bridge.reconfigure(resolve_session_kwargs(self.registry, agent_id))
                respawn_pending = True
            except KeyError:
                respawn_pending = False  # agent deleted concurrently — nothing to respawn
        self._json(200, {**updated, "respawn_pending": respawn_pending})

    def do_DELETE(self) -> None:  # noqa: N802
        """DELETE /api/agents/<id> — archive + tear down, or 409 when busy."""
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        agent_id = self._agent_route_id()
        if agent_id is None:
            self._json(404, {"error": "not found"})
            return
        try:
            agent = self.registry.get_agent(agent_id)
        except KeyError:
            self._json(404, {"error": f"agent not found: {agent_id}"})
            return
        if agent.get("is_primary"):
            self._json(409, {"error": "cannot delete the primary agent"})
            return
        st = self.sessions.status(agent_id)
        if st["state"] == "running" or st["queue_depth"] > 0:
            self._json(
                409,
                {"error": f"agent {agent_id} is busy (state={st['state']}, "
                          f"queue_depth={st['queue_depth']})"},
            )
            return
        try:
            archived = self.registry.delete_agent(agent_id, archive=True)
        except ValueError as exc:  # last remaining agent (shouldn't happen: primary guard)
            self._json(409, {"error": str(exc)[:200]})
            return
        # Drop AFTER the registry delete so no racing prompt can resurrect a
        # bridge for a registry entry that no longer exists (see
        # SessionManager.get_or_create_session's re-validation).
        self.sessions.drop(agent_id)
        self._json(200, {"deleted": agent_id, "archived_to": archived})

    def _agent_route_id(self) -> str | None:
        """The <id> from /api/agents/<id>; None when the path isn't exactly that."""
        prefix = "/api/agents/"
        path = urlsplit(self.path).path
        if not path.startswith(prefix):
            return None
        agent_id = path[len(prefix):].strip("/")
        if not agent_id or "/" in agent_id:  # sub-resources (e.g. .../status) excluded
            return None
        return agent_id

    def _read_body(self) -> dict | None:
        """Parse the request body as a JSON object; 400 + None on failure."""
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return None
        if not isinstance(payload, dict):
            self._json(400, {"error": "body must be a JSON object"})
            return None
        return payload

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

    def _handle_agent_status(self, agent_id: str) -> None:
        """GET /api/agents/<id>/status — live turn state.

        Deliberately no bridge side effect: existence is gated through the
        registry and turn state comes from SessionManager.status(), which
        reports the idle payload for agents that have never run.
        """
        if not agent_id:
            self._json(404, {"error": "not found"})
            return
        try:
            self.registry.get_agent(agent_id)  # KeyError → 404
        except KeyError:
            self._json(404, {"error": "agent not found"})
            return
        self._json(200, self.sessions.status(agent_id))

    def _sse(self, agent_id: str = DEFAULT_AGENT_ID, since: str = "",
             run_id: str = "") -> None:
        """GET /api/events — agent stream, fleet stream, or a single run.

        Stream shape:
          agent_id=<id>   this agent's events (live; replay with since=)
          (omitted)       FLEET STREAM: every agent's events
          since=<seq>     replay stored events with seq > since, then tail
                          live with no gap and no duplicate
          run_id=<id>     only that run; closes after its terminal event

        Replay handoff (the point of this step): subscribe to the live source
        FIRST, snapshot the store's latest committed seq S0, then drain store
        rows with seq in (since, S0]. Live events with seq <= S0 are
        duplicates of the drain and are skipped; every event with seq > S0
        was emitted after the snapshot (hence after the subscribe) and arrives
        exactly once via the live queue. An event emitted mid-drain therefore
        lands in the live queue, not the drain.

        A hub without a store (unit-test fixtures) keeps the legacy behavior:
        pure live, un-enriched events, no replay.
        """
        store = self.store
        agent = (agent_id or "").strip()
        run_filter = (run_id or "").strip()
        since_seq = 0
        if since.strip():
            try:
                since_seq = max(0, int(float(since)))
            except ValueError:
                since_seq = 0

        bridge = None
        live_queue = None
        agent_drain_filter = None
        is_run_stream = False
        do_drain = False
        terminal_types = ("done", "error")

        if store is not None and run_filter:
            row = store.get_run(run_filter)
            if row is None:
                self._json(404, {"error": f"run not found: {run_filter}"})
                return
            is_run_stream = True
            do_drain = True  # replay the run's history from the store, then tail
            try:
                bridge = self.sessions.get_or_create_session(row["agent_id"])
            except KeyError:
                bridge = None  # agent deleted; the run is terminal in the store
            if bridge is not None:
                live_queue = bridge.subscribe()
        elif agent:
            try:
                bridge = self.sessions.get_or_create_session(agent)
            except KeyError:
                self._json(404, {"error": f"agent not found: {agent}"})
                return
            live_queue = bridge.subscribe()
            agent_drain_filter = agent
            do_drain = store is not None and since != ""
        else:
            # Fleet stream: no per-agent bridge (never instantiate N gateways
            # for one reader). Live events come from the store's listener fan.
            if self.fleet is None:
                self._json(404, {"error": "fleet stream unavailable"})
                return
            live_queue = self.fleet.subscribe()
            do_drain = store is not None and since != ""

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        terminal_seen = False
        try:
            # --- replay drain (store rows up to the S0 snapshot) ---
            s0 = None
            if do_drain and store is not None:
                s0 = store.latest_seq()
                cursor = since_seq
                while True:
                    rows = store.events_after(
                        cursor,
                        agent_id=agent_drain_filter,
                        run_id=run_filter or None,
                        limit=500,
                    )
                    if not rows:
                        break
                    rows = [e for e in rows if e["seq"] <= s0]
                    if not rows:
                        break
                    closed = False
                    for env in rows:
                        self._write_sse(env)
                        if is_run_stream and env.get("type") in terminal_types:
                            terminal_seen = True
                            closed = True
                    cursor = rows[-1]["seq"]
                    if closed:
                        break  # run already terminal in the store
            if live_queue is not None and not (is_run_stream and terminal_seen):
                # --- live tail with duplicate suppression ---
                # (a run stream whose terminal was already drained is done;
                # closing happens in the finally below)
                while True:
                    try:
                        event = live_queue.get(timeout=15)
                    except Empty:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                        continue
                    if not isinstance(event, dict):
                        continue
                    if is_run_stream and event.get("run_id") != run_filter:
                        continue  # another run on the same agent's bridge
                    if agent_drain_filter is not None and event.get("agent_id"):
                        if event["agent_id"] != agent_drain_filter:
                            continue
                    seq = event.get("seq")
                    if s0 is not None and isinstance(seq, int) and seq <= s0:
                        continue  # already drained: exactly-once handoff
                    self._write_sse(event)
                    if is_run_stream and event.get("type") in terminal_types:
                        terminal_seen = True
                        break
        except (ConnectionAbortedError, BrokenPipeError, OSError):
            pass
        finally:
            if live_queue is not None:
                if bridge is not None:
                    bridge.unsubscribe(live_queue)
                elif self.fleet is not None:
                    self.fleet.unsubscribe(live_queue)
            if is_run_stream and terminal_seen:
                # A run stream is done: close the HTTP connection so the
                # client sees EOF instead of an idle keep-alive socket.
                self.close_connection = True

    def _write_sse(self, event: dict) -> None:
        """Write one SSE data frame (dict → JSON)."""
        data = json.dumps(event, ensure_ascii=False)
        self.wfile.write(f"data: {data}\n\n".encode())
        self.wfile.flush()

    # ------------------------------------------------------------------
    # History endpoints (all read-only; never instantiate a bridge)
    # ------------------------------------------------------------------

    def _history_store(self) -> RunStore | None:
        """Return the store or send 503 + None (hub without run store)."""
        if self.store is None:
            self._json(503, {"error": "run store not enabled"})
        return self.store

    def _limit_param(self, name: str, default: int, cap: int) -> int:
        raw = self._query_param(name)
        try:
            value = int(raw)
        except ValueError:
            return default
        return max(1, min(value, cap))

    def _handle_agent_messages(self, agent_id: str) -> None:
        """GET /api/agents/<id>/messages — paginated folded messages."""
        if not agent_id:
            self._json(404, {"error": "not found"})
            return
        store = self._history_store()
        if store is None:
            return
        try:
            self.registry.get_agent(agent_id)  # history is scoped to live agents
        except KeyError:
            self._json(404, {"error": "agent not found"})
            return
        before_raw = self._query_param("before")
        before = None
        try:
            before = int(before_raw) if before_raw.strip() else None
        except ValueError:
            before = None
        limit = self._limit_param("limit", 50, 200)
        rows = store.agent_messages(agent_id, limit=limit, before=before)
        self._json(200, {"agent_id": agent_id, "messages": rows})

    def _handle_runs_list(self) -> None:
        """GET /api/runs — run list, newest first."""
        store = self._history_store()
        if store is None:
            return
        agent = self._query_param("agent_id").strip() or None
        state = self._query_param("state").strip() or None
        if state is not None and state not in RUN_STATES:
            self._json(400, {"error": f"state must be one of {list(RUN_STATES)}"})
            return
        before_raw = self._query_param("before")
        before = None
        try:
            before = float(before_raw) if before_raw.strip() else None
        except ValueError:
            before = None
        limit = self._limit_param("limit", 50, 200)
        rows = store.list_runs(agent_id=agent, state=state, limit=limit, before=before)
        self._json(200, {"runs": rows})

    def _handle_run_get(self, run_id: str) -> None:
        """GET /api/runs/<run_id> — one run + its folded messages.

        Works for deleted agents too: run history is the record of what the
        bot did and is deliberately NOT removed by DELETE /api/agents.
        """
        store = self._history_store()
        if store is None:
            return
        if not run_id or "/" in run_id:
            self._json(404, {"error": "not found"})
            return
        run = store.get_run(run_id)
        if run is None:
            self._json(404, {"error": f"run not found: {run_id}"})
            return
        self._json(200, {"run": run, "messages": store.run_messages(run_id)})

    def _handle_fleet_activity(self) -> None:
        """GET /api/fleet/activity — newest runs across ALL agents (roster UI)."""
        store = self._history_store()
        if store is None:
            return
        limit = self._limit_param("limit", 20, 100)
        rows = store.list_runs(limit=limit)
        activity = [
            {
                "run_id": r["run_id"],
                "agent_id": r["agent_id"],
                "prompt": r["prompt"][:160],
                "state": r["state"],
                "remote": bool(r["remote"]),
                "source": r["source"],
                "created_at": r["created_at"],
                "started_at": r["started_at"],
                "ended_at": r["ended_at"],
                "gateway_respawns": r["gateway_respawns"],
            }
            for r in rows
        ]
        self._json(200, {"activity": activity})

    def log_message(self, fmt: str, *args) -> None:
        pass


def _validate_profile_payload(payload: dict, *, allow_name: bool) -> dict:
    """Validate a POST/PATCH agent body against the v2 editable schema.

    Returns the registry field dict (``name`` is handled by the caller).
    Raises ValueError with a client-facing message for any 400 condition:
    unknown keys, non-string values, bad autonomy, persona over the
    PERSONA_MAX_CHARS cap. The registry itself stays permissive — this is
    the HTTP guard, the only path clients can reach.
    """
    allowed = set(EDITABLE_FIELDS) | ({"name"} if allow_name else set())
    unknown = set(payload) - allowed
    if unknown:
        raise ValueError(f"unknown field(s): {', '.join(sorted(unknown))}")
    fields: dict = {}
    for key in EDITABLE_FIELDS:
        if key not in payload:
            continue
        value = payload[key]
        if key == "autonomy":
            if value not in AUTONOMY_VALUES:
                raise ValueError(f"autonomy must be one of {AUTONOMY_VALUES}")
            fields[key] = value
            continue
        if isinstance(value, bool) or (value is not None and not isinstance(value, str)):
            raise ValueError(f"{key} must be a string or null")
        if value is None:
            # null clears: text fields → "", identity fields → None (inherit)
            fields[key] = "" if key in _TEXT_FIELDS else None
        elif key in ("model", "provider") and value == "":
            fields[key] = None  # empty string means "no override", like null
        else:
            fields[key] = value
    persona = fields.get("persona")
    if isinstance(persona, str) and len(persona) > PERSONA_MAX_CHARS:
        raise ValueError(f"persona exceeds {PERSONA_MAX_CHARS} characters")
    return fields


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
    # Durable run store: boot recovery + retention. A run left queued/running
    # when the hub died is marked interrupted; events older than the TTL
    # (default 30d, VERTUS_EVENT_TTL_DAYS) are pruned on boot and daily.
    # runs/messages are NEVER pruned — they are the record of what the bots
    # did. The store's listener fans committed events to fleet subscribers.
    store = RunStore()
    fleet = FleetFan()
    VertusHandler.store = store
    VertusHandler.fleet = fleet
    store.listener = fleet.publish
    try:
        recovered = store.recover_interrupted()
        if recovered:
            print(f"[vertus] crash recovery: {recovered} run(s) marked interrupted")
        pruned = store.prune_events()
        if pruned:
            print(f"[vertus] retention: pruned {pruned} old event row(s)")
    except Exception as exc:  # noqa: BLE001
        print(f"[vertus] run-store boot maintenance failed: {exc}", file=sys.stderr)

    def _daily_prune() -> None:
        """Daily retention pass (daemon; events older than the TTL)."""
        while True:
            time.sleep(86400)
            try:
                n = store.prune_events()
                if n:
                    print(f"[vertus] retention: pruned {n} old event row(s)")
            except Exception as exc:  # noqa: BLE001
                print(f"[vertus] daily event prune failed: {exc}", file=sys.stderr)

    threading.Thread(target=_daily_prune, daemon=True).start()
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
