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
import random

# One logging path for the whole hub: every print site AND every subsystem
# logger (fleet_routines etc.) flows into ~/.vertus/logs/vertus.log (rotated)
# plus stdout for launchd. See vertus_logging.py — the scheduler-once-died-
# silently bug is exactly what this unifies away.
from vertus_logging import hub_print  # type: ignore
print = hub_print  # noqa: A001  (accepts print kwargs; logs at INFO)
import secrets
import signal
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
    from run_store import RunStore, RUN_STATES, TERMINAL_STATES  # type: ignore
    from screen_lease import ScreenLeaseManager, SCREEN_POLICY_CAVEAT  # type: ignore
    from fleet_messaging import BotMessenger, BotMessageError  # type: ignore
    from fleet_routines import (  # type: ignore
        RoutineManager, RoutineValidationError, parse_schedule, parse_trigger,
    )
    from vertus_logging import setup_logging  # type: ignore
    from session_manager import SessionManager, DEFAULT_AGENT_ID  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from .agent_registry import AgentRegistry, EDITABLE_FIELDS, AUTONOMY_VALUES  # type: ignore
    from .run_store import RunStore, RUN_STATES, TERMINAL_STATES  # type: ignore
    from .screen_lease import ScreenLeaseManager, SCREEN_POLICY_CAVEAT  # type: ignore
    from .session_manager import SessionManager, DEFAULT_AGENT_ID  # type: ignore
    from .fleet_routines import (  # type: ignore
        RoutineManager, RoutineValidationError, parse_schedule, parse_trigger,
    )
    from .vertus_logging import setup_logging  # type: ignore

VERTUS_DIR = Path.home() / ".vertus"
TOKEN_FILE = VERTUS_DIR / "token"
DEFAULT_PORT = 8787

# HTTP/API policy limits (the registry itself stays permissive; these are
# request-body guards). One persona is typically 1–2k characters; 20k is
# generous headroom while bounding what a client can stuff into SOUL.md.
PERSONA_MAX_CHARS = 20_000

# ---------------------------------------------------------------------------
# Supervision policy (Checkpoints 1–4): stall detection, escalation ladder,
# gateway backoff/degradation, idle health checks, thrash cap.
# ---------------------------------------------------------------------------

# Gateway respawn backoff: up to 3 RESPAWNS per turn (4 spawn attempts),
# sleeping the listed delays (jittered ±20%) between attempts. The GUI demo
# showed a healthy CUA turn can legitimately take 4+ minutes of continuous
# engine chatter — this backoff is about SPAWN failures, never about turn
# duration.
RESPAWN_BACKOFF = (1.0, 4.0, 16.0)

# How long each escalation rung waits for the turn to end before escalating
# to the next. Worst-case cancel latency is 3× this (interrupt → SIGTERM →
# SIGKILL). Env-tunable for tests and for hosts where interrupt is known slow.
ESCALATION_GRACE_S = float(os.environ.get("VERTUS_ESCALATION_GRACE_S", "10"))

# Idle-gateway health check: while an agent is IDLE (no turn, no queue), the
# supervisor pings its gateway at this interval with a cheap RPC and closes
# it when the ping times out, so the next prompt spawns fresh instead of
# inheriting a hung child. 300s default: spawns are ~13s cold, so probing
# more often just wastes cycles on healthy gateways.
HEALTH_CHECK_INTERVAL_S = float(os.environ.get("VERTUS_HEALTH_CHECK_S", "300"))
HEALTH_CHECK_RPC_TIMEOUT_S = 5.0

# Thrash cap: N gateway deaths within M minutes stops auto-respawning and
# reports degraded (new prompts get 503) until the window slides. N=4 / M=10
# is justified in the checkpoint report: a single run may legitimately burn
# 3 deaths while exhausting its own 1s/4s/16s backoff, so the cap must sit
# ABOVE that or it would preempt the exhaustion path. 4+ deaths in ten
# minutes therefore means pathology ACROSS runs (this machine has a known
# stray pkill loop that kills gateways); anything looser just wastes
# model-token budget on doomed restarts.
THRASH_MAX = 4
THRASH_WINDOW_S = 600.0

# After a spawn-exhaustion failure the agent is degraded for this long;
# prompts during the window get 503, then the next prompt retries a fresh
# spawn (success clears degraded).
DEGRADED_RETRY_S = 60.0

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

    def __init__(self, agent_id: str = DEFAULT_AGENT_ID, create_session_factory=None, cwd: str | None = None, session_kwargs: dict | None = None, store=None, screen_leases=None, screen_targets=None, on_run_terminal=None) -> None:
        self.agent_id = agent_id
        # Per-window computer-use ownership (Step: screen leases). ``None``
        # disables the gate (legacy / unit-test bridges). ``screen_targets``
        # is a resolver ``(agent_id) -> list[str] | None`` re-read each turn
        # so a profile PATCH takes effect on the next turn without a respawn.
        self.screen_leases = screen_leases
        self._screen_targets = screen_targets
        self._active_screen_targets: list[str] | None = None
        self._waiting_on: list[str] | None = None
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
        # ``stall_timeout_s``/``hard_timeout_s`` ride in the same kwargs dict
        # from resolve_session_kwargs but are POPPED here (and in
        # reconfigure) — they are hub-side supervision policy, never engine
        # spawn args, so they must not reach create_agent_session.
        kwargs = dict(session_kwargs or {})
        # NOTE: these must be assigned HERE, before the supervision-state
        # block below — that block must NOT re-default them, or per-agent
        # profile values would be clobbered on every bridge build.
        self._stall_timeout_s: float = float(kwargs.pop("stall_timeout_s", 180.0))
        self._hard_timeout_s: float = float(kwargs.pop("hard_timeout_s", 3600.0))
        self._session_kwargs: dict = kwargs
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
        # Supervision state (Checkpoints 1–4). Guarded by _status_lock like
        # every other in-memory flag; the MONITOR THREAD reads/writes these
        # and the escalation ladder runs on its own daemon thread — never
        # under any other lock. stall/hard timeouts were already resolved
        # from session_kwargs above — do not re-default them here.
        self._last_event_at: float | None = None   # any wire event refreshes it
        self._run_cancelled: str | None = None     # None | "cancelled" | "stall" | "hard_timeout"
        self._run_timeout_msg: str | None = None   # which timeout fired + silence duration
        self._cancelled_runs: set[str] = set()     # runs cancelled while still queued
        self._escalating = False
        self._escalation_rungs: list[str] = []
        self._degraded: str | None = None
        self._degraded_until: float | None = None
        self._respawn_times: list[float] = []      # monotonic stamps for the thrash cap
        self._last_health_check = time.monotonic()
        # Current-run tracking (Step: run history). Guarded by _status_lock.
        # Events emitted by the engine's reader thread while the worker is
        # inside a turn are attributed to the run the worker is processing.
        self._current_run_id: str | None = None
        # Bot-to-bot attribution of the current run (fleet message bus): who
        # asked for this turn (from_agent), in which thread, and with which
        # kind. ``on_run_terminal`` is the hub's BotMessenger.run_terminal —
        # fired from _end_run so a delegated run reports its result back
        # deterministically (never model-dependent).
        self._run_from_agent: str | None = None
        self._run_thread_id: str | None = None
        self._run_kind: str = "user"
        self._on_run_terminal = on_run_terminal
        self._run_buffer: list[str] | None = None   # folded at turn end
        self._run_respawns = 0
        self._run_had_error = False
        self._run_error_message = ""
        self._worker = Thread(target=self._run_worker, daemon=True)
        self._worker.start()
        # Per-bridge supervisor: stall/hard timeout detection while running,
        # idle-gateway health checks while idle. One thread per agent; it
        # exits when the bridge closes.
        threading.Thread(
            target=self._monitor_loop, daemon=True, name=f"monitor-{agent_id}"
        ).start()

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

    def _emit(self, event: dict, run_id: str | None = None) -> None:
        """Route one wire event: persist FIRST, then fan out the envelope.

        Durability rule: an event is written to the store BEFORE it reaches
        any subscriber. On a store write failure the run goes to error and
        nothing is fanned out — no event that isn't in the store ever reaches
        a client. Events with no active run (a store-backed hub) are dropped:
        they belong to no run and cannot be stored or replayed.

        ``run_id`` overrides the active-run context — used by cancel to emit
        the ``cancelled`` event for a run that never started (its item was
        still in the queue, so the worker never set the context).

        Legacy mode (no store): the pre-history behavior, un-enriched.

        Any event while a run is active refreshes the stall-silence clock:
        stall detection measures ENGINE silence, so activity pings count.
        """
        with self._status_lock:
            if run_id is None:
                run_id = self._current_run_id
            if event.get("type") == "text" and self._run_buffer is not None:
                text = event.get("text")
                if isinstance(text, str) and text:
                    self._run_buffer.append(text)
            if event.get("type") == "error":
                self._run_had_error = True
                msg = event.get("message") or event.get("text") or ""
                self._run_error_message = str(msg)[:200]
            if run_id is not None:
                self._last_event_at = time.monotonic()
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
        """Flip the store row queued→running (no-op when already terminal).

        The in-memory run context (flags, silence clock, cancel check) is
        established in the worker loop when the item is POPPED, not here — a
        cancel can arrive while the turn waits on the screen-lease gate, and
        it must see (and be seen by) the run context from that moment on.
        """
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
        """Leave the run context: fold the assistant text, emit the terminal
        event, and set the terminal state EXACTLY ONCE (worker thread).

        A cancelled/timed-out run emits its terminal event (``cancelled``, or
        ``error`` naming the timeout + silence duration) while the run
        context is still live so the event is stored under this run's
        identity; the row then goes to ``cancelled`` / ``timeout`` — both
        first-class terminal states, distinct from error.
        """
        with self._status_lock:
            cancelled = self._run_cancelled
            timeout_msg = self._run_timeout_msg
            buffer = self._run_buffer
            had_error = self._run_had_error
            error_msg = self._run_error_message
            respawns = self._run_respawns
        if cancelled == "cancelled":
            self._emit({"type": "cancelled", "text": "run cancelled"})
        elif cancelled:
            msg = timeout_msg or f"turn ended by {cancelled} escalation"
            self._emit({"type": "error", "message": msg[:500]})
        with self._status_lock:
            run_id = self._current_run_id
            from_agent = self._run_from_agent
            thread_id = self._run_thread_id
            run_kind = self._run_kind
            self._current_run_id = None
            self._run_from_agent = None
            self._run_thread_id = None
            self._run_kind = "user"
            self._run_buffer = None
            self._run_error_message = ""
            self._run_cancelled = None
            self._run_timeout_msg = None
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
        state = (
            "cancelled" if cancelled == "cancelled"
            else "timeout" if cancelled
            else "error" if had_error
            else "done"
        )
        try:
            if cancelled == "cancelled":
                store.finish_run(run_id, "cancelled", gateway_respawns=respawns)
            elif cancelled:
                store.finish_run(
                    run_id,
                    "timeout",
                    error=timeout_msg or f"turn ended by {cancelled} escalation",
                    gateway_respawns=respawns,
                )
            else:
                store.finish_run(
                    run_id,
                    "error" if had_error else "done",
                    error=error_msg or None,
                    gateway_respawns=respawns,
                )
        except Exception as exc:  # noqa: BLE001
            print(f"[vertus] finish_run failed ({run_id}): {exc}", file=sys.stderr)
        # Fleet message bus: a bot-driven run reports its result back to
        # whoever asked (kind=result message in the same thread). Fired
        # AFTER the terminal state is set, from the worker thread, outside
        # every lock; the messenger never raises here (see run_terminal).
        cb = self._on_run_terminal
        if (
            cb is not None
            and run_id
            and store is not None
            and from_agent
            and run_kind in ("message", "handoff")
        ):
            try:
                summary = "".join(buffer).strip()[:400] if buffer else ""
                cb(run_id, self.agent_id, from_agent, thread_id,
                   run_kind, state, summary)
            except Exception as exc:  # noqa: BLE001 — never break the worker
                print(
                    f"[vertus] run-terminal callback failed ({run_id}): {exc}",
                    file=sys.stderr,
                )

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

    def _screen_wait(self, run_id: str | None) -> None:
        """Block this worker until the turn owns its declared screen targets.

        Only bridges wired with a ScreenLeaseManager gate here (the hub does;
        unit tests leave it None). Targets are resolved fresh each turn via
        ``_screen_targets`` so a profile PATCH applies to the next turn even
        though the gateway itself respawns lazily. While blocked, the turn is
        still logically queued and status() reports ``blocked_on_target``
        (with the holder named), so a blocked bot never looks idle. Returns
        (without owning anything) when the bridge closed mid-wait — the
        caller's closed check abandons the run.
        """
        leases = self.screen_leases
        if leases is None:
            return
        targets: list[str] | None = None
        if self._screen_targets is not None:
            try:
                targets = self._screen_targets(self.agent_id)
            except Exception:  # noqa: BLE001 — resolver failure = no claim
                targets = None
        if not targets:
            return
        run_key = str(run_id or "")
        if leases.acquire(self.agent_id, run_key, targets):
            with self._status_lock:
                self._active_screen_targets = list(targets)
                self._waiting_on = None
            return

        def holder_pairs(ts: list[str]) -> list[dict]:
            owners = leases.owners()
            return [
                {
                    "target": t,
                    "holder_agent": owners[t][0],
                    "holder_run": owners[t][1],
                }
                for t in ts
                if t in owners and owners[t][0] != self.agent_id
            ]

        # Contended: register as a FIFO waiter and poll with a short timeout
        # so bridge close — and a cancel of this run — are noticed promptly.
        while True:
            with self._status_lock:
                if self._closed or self._run_cancelled:
                    leases.cancel_wait(self.agent_id, run_key)
                    self._waiting_on = None
                    return
                # Before the first wait_for_grant the agent is not yet a
                # registered waiter, so fall back to the owners() snapshot;
                # once registered, blocked_by() reports exactly its waits.
                blocked = leases.blocked_by(self.agent_id) or holder_pairs(targets)
                self._waiting_on = blocked
            got = leases.wait_for_grant(self.agent_id, run_key, targets)
            if got is not None:
                with self._status_lock:
                    self._active_screen_targets = list(got)
                    self._waiting_on = None
                return

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
            # context that stamps every event of this turn. Items are dicts
            # (prompt() packs them); the legacy 3-tuple shape is tolerated
            # for tests.
            if isinstance(item, dict):
                text = item.get("text", "")
                remote = bool(item.get("remote", False))
                run_id = item.get("run_id")
                from_agent = item.get("from_agent")
                thread_id = item.get("thread_id")
                run_kind = item.get("run_kind", "user")
            else:
                text, remote, run_id = item
                from_agent = thread_id = None
                run_kind = "user"
            # Run context is established HERE, at pop time (not in
            # _begin_run): a cancel can arrive while the turn waits on the
            # screen-lease gate, and from the pop onward it must address
            # this run. A run cancelled while still queued is recognized via
            # _cancelled_runs and folded into the flag the same way.
            with self._status_lock:
                self._current_run_id = run_id
                self._run_from_agent = from_agent
                self._run_thread_id = thread_id
                self._run_kind = run_kind
                self._run_buffer = []
                self._run_respawns = 0
                self._run_had_error = False
                self._run_error_message = ""
                self._run_timeout_msg = None
                self._run_cancelled = None
                self._last_event_at = time.monotonic()
                if run_id is not None and run_id in self._cancelled_runs:
                    self._cancelled_runs.discard(run_id)
                    self._run_cancelled = "cancelled"
            # Screen-lease gate (Step: per-window ownership): a run whose
            # agent declares cua_targets waits here until it owns every one
            # of them. The run row stays ``queued`` while waiting and status()
            # reports blocked_on_target, so a lease-blocked bot never looks
            # idle. The lease is held across the whole turn INCLUDING the
            # respawn-retry path and released in the finally below.
            self._screen_wait(run_id)
            if run_id is not None:
                self._begin_run(run_id)
            with self._status_lock:
                cancelled = self._run_cancelled
                closed = self._closed
                if not cancelled and not closed:
                    self._running = True
                    self._turn_started_at = time.monotonic()
            if closed:
                # A close raced the enqueue (DELETE refuses busy bridges, so
                # this is defensive): the run never started — mark it so.
                # The worker may also have waited out a screen gate before
                # noticing close; close() pushed a None sentinel that nobody
                # will consume now — drain it so status stays truthful.
                while True:
                    try:
                        self._queue.get_nowait()
                    except Empty:
                        break
                self._abandon_run()
                break
            try:
                if cancelled:
                    # A cancel raced this turn before it reached the engine:
                    # never spawn, never run — the finally finalizes it as
                    # cancelled (the screen gate above already aborted).
                    pass
                elif self._create_session is None:
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
                # Screen-lease release (Step: per-window ownership): drop the
                # turn's target claims whether it finished, errored, the
                # gateway died mid-turn, OR the turn was cancelled/timed out.
                if self.screen_leases is not None:
                    held = self._active_screen_targets
                    with self._status_lock:
                        self._active_screen_targets = None
                        self._waiting_on = None
                    if held:
                        self.screen_leases.release(
                            self.agent_id, run_id or "", held
                        )
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
        """Run one prompt, respawning a dead gateway with backoff (Checkpoint 4).

        The hermes gateway runs as a child process that can be killed
        externally (e.g. SIGTERM). Without recovery, every later prompt
        would write into the dead pipe and surface as "[Errno 32] Broken
        pipe". On gateway death we drop the session and respawn it so the
        same prompt still goes through; genuine agent errors are surfaced
        immediately.

        Respawn policy: up to 3 spawn attempts per turn, sleeping
        RESPAWN_BACKOFF (1s/4s/16s, jittered ±20%) between attempts. After
        exhaustion the agent is DEGRADED (status() shows the reason; new
        prompts get 503) until a successful spawn clears it. A gateway that
        dies THRASH_MAX times within THRASH_WINDOW_S stops auto-respawning
        outright.

        ``remote`` rides on this call instead of a process-global env var
        (Step 4). Ground truth from the fork's RPC: prompt.submit carries no
        per-turn context field, and the approval guard is a pi-engine
        extension — so remote/local is enforced at SPAWN time via
        HERMES_YOLO_MODE and cannot vary between turns within one gateway
        lifetime (see _spawn_session for the sticky-mode trade-off).

        A turn cancelled or timed out mid-flight (Checkpoints 1–3) must NOT
        be respawned: the cancelled flag is checked at every attempt boundary
        and after prompt() returns/raises, and the terminal event then comes
        from _end_run — never from this loop.
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
        for attempt in range(len(RESPAWN_BACKOFF) + 1):
            with self._status_lock:
                cancelled = self._run_cancelled
            if cancelled:
                # Escalated between attempts (cancel/timeout raced a respawn):
                # stop — the terminal event comes from _end_run.
                return
            if self._thrash_cap_tripped():
                reason = (
                    f"gateway thrashing: gateway died {THRASH_MAX} times within "
                    f"{int(THRASH_WINDOW_S // 60)} min; auto-respawn paused"
                )
                self._set_degraded(reason, None)
                self._emit({"type": "error", "message": "agent gateway thrashing; auto-respawn stopped"})
                return
            if self._session is None:
                try:
                    result = self._spawn_session(remote)
                    if not self._adopt_session(result["session"]):
                        return  # bridge was closed while spawning (DELETE)
                    self._session.subscribe(self._on_pi_event)
                    self._clear_degraded()  # a live spawn ends the degraded state
                except Exception as exc:
                    if attempt < len(RESPAWN_BACKOFF) and (
                        "gateway" in str(exc).lower()
                        or "broken pipe" in str(exc).lower()
                        or "exited" in str(exc).lower()
                    ):
                        delay = RESPAWN_BACKOFF[attempt] * random.uniform(0.8, 1.2)
                        print(
                            f"[vertus] agent gateway failed to start ({exc}); "
                            f"respawning in {delay:.1f}s (attempt {attempt + 1})",
                            file=sys.stderr,
                        )
                        self._note_respawn()
                        time.sleep(delay)
                        continue
                    self._set_degraded(
                        f"gateway failed to start after {len(RESPAWN_BACKOFF) + 1} "
                        f"attempts: {exc}",
                        DEGRADED_RETRY_S,
                    )
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
                # backstop so clients always see a terminator. An escalation
                # that killed the gateway can make prompt() RETURN (the
                # reader unblocks it) — check the flag before declaring done.
                with self._status_lock:
                    cancelled = self._run_cancelled
                if cancelled:
                    return  # escalated mid-turn; terminal event from _end_run
                self._emit({"type": "done"})
                return
            except Exception as exc:  # noqa: PERF203
                with self._status_lock:
                    cancelled = self._run_cancelled
                if cancelled:
                    return  # escalated mid-turn; terminal event from _end_run
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
                if dead and attempt < len(RESPAWN_BACKOFF):
                    delay = RESPAWN_BACKOFF[attempt] * random.uniform(0.8, 1.2)
                    print(
                        f"[vertus] agent gateway died ({exc}); respawning in "
                        f"{delay:.1f}s (attempt {attempt + 1})",
                        file=sys.stderr,
                    )
                    self._note_respawn()
                    time.sleep(delay)
                    continue
                self._emit({"type": "error", "message": str(exc)[:500]})
                return

    def _note_respawn(self) -> None:
        """Count one gateway respawn (run row + thrash-cap window)."""
        with self._status_lock:
            self._run_respawns += 1
            self._respawn_times.append(time.monotonic())
            # The system is actively recovering — refresh the stall-silence
            # clock so a backoff sleep is not misread as a silent engine.
            self._last_event_at = time.monotonic()

    def _set_degraded(self, reason: str, retry_after_s: float | None) -> None:
        with self._status_lock:
            self._degraded = reason
            self._degraded_until = (
                time.monotonic() + retry_after_s if retry_after_s else None
            )

    def _clear_degraded(self) -> None:
        with self._status_lock:
            self._degraded = None
            self._degraded_until = None

    def _thrash_cap_tripped(self) -> bool:
        """True when >= THRASH_MAX gateway deaths sit inside the window.

        Self-healing: deaths older than THRASH_WINDOW_S drop out of the
        sliding window, so a degraded agent that was merely unlucky can be
        prompted again once the window slides (status() reports degraded
        meanwhile, and prompts 503).
        """
        now = time.monotonic()
        with self._status_lock:
            self._respawn_times[:] = [
                t for t in self._respawn_times if now - t <= THRASH_WINDOW_S
            ]
            return len(self._respawn_times) >= THRASH_MAX

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

    def prompt(self, text: str, remote: bool, run_id: str | None = None,
               from_agent: str | None = None, thread_id: str | None = None,
               run_kind: str = "user") -> None:
        """Queue one turn. Raises RuntimeError after close() (hub → 409).

        ``run_id`` links every event of this turn to the store row created at
        enqueue time; None keeps the legacy (un-stored) path used by tests.
        ``from_agent``/``thread_id``/``run_kind`` carry bot-to-bot
        attribution (message bus / delegation): the worker tracks them so
        _end_run can report the result back to the delegator.
        """
        with self._status_lock:
            if self._closed:
                raise RuntimeError(f"agent {self.agent_id} is closed")
        self._queue.put({
            "text": text, "remote": remote, "run_id": run_id,
            "from_agent": from_agent, "thread_id": thread_id,
            "run_kind": run_kind,
        })

    # ------------------------------------------------------------------
    # Step A: turn introspection + lifecycle (reconfigure / close)
    # ------------------------------------------------------------------

    def status(self) -> dict:
        """Live turn state: idle | running | queued, plus queue/gateway health.

        ``gateway_alive`` is False when no engine session exists yet (agent
        never prompted, or the last spawn failed) or the current session
        reports itself dead. Pure read — no engine call, no side effect.

        Supervision visibility (Checkpoints 1–4): a slow-but-healthy turn is
        distinguishable from a stuck one — ``stall_timeout_s``/
        ``hard_timeout_s`` are the per-agent limits and ``silence_s`` is how
        long the engine has emitted nothing. ``degraded`` carries a readable
        reason when the agent's gateway is failing or thrashing.
        """
        now = time.monotonic()
        with self._status_lock:
            running = self._running
            started = self._turn_started_at
            closed = self._closed
            waiting = self._waiting_on
            last_event = self._last_event_at
            stall = self._stall_timeout_s
            hard = self._hard_timeout_s
            degraded = self._degraded
            until = self._degraded_until
            if until is not None and now >= until:
                # The degraded window expired: the next prompt may retry a
                # fresh spawn (success clears the flag for good).
                self._degraded = None
                self._degraded_until = None
                degraded = None
        session = self._session
        gateway_alive = (
            not closed
            and session is not None
            and not bool(getattr(session, "is_dead", False))
        )
        if degraded is None and self._thrash_cap_tripped():
            degraded = (
                f"gateway thrashing: gateway died {THRASH_MAX} times within "
                f"{int(THRASH_WINDOW_S // 60)} min; auto-respawn paused"
            )
        # A turn held by the screen-lease gate was already popped off the
        # queue; count it so DELETE's busy guard and UI depth stay truthful.
        depth = self._queue.qsize() + (1 if waiting else 0)
        state = "running" if running else ("queued" if (depth or waiting) else "idle")
        out: dict = {
            "state": state,
            "queue_depth": depth,
            "turn_started_at": started,
            "gateway_alive": gateway_alive,
            "stall_timeout_s": stall,
            "hard_timeout_s": hard,
            "last_event_at": last_event,
            "silence_s": round(now - last_event, 1) if (running and last_event) else 0.0,
            "degraded": degraded,
        }
        if waiting:
            # A bot blocked on a declared target must show as such (with the
            # holder named), not idle — and never as running.
            out["blocked_on_target"] = [dict(b) for b in waiting]
        return out

    @property
    def current_run_id(self) -> str | None:
        """The run id of the turn in progress (None when idle).

        The message bus uses it as the PARENT of a handoff child run, so the
        delegation graph is a tree. Pure read under the status lock.
        """
        with self._status_lock:
            return self._current_run_id

    @property
    def gateway_pgid(self) -> int | None:
        """Process-group id of the live engine gateway, if any.

        The gateway is spawned with ``start_new_session=True``, so pgid ==
        gateway pid and every child it spawned (notably the embedded
        cua-driver) shares it. Used by /api/fleet/screens to attribute
        driver processes to agents. Pure read, no side effect.
        """
        session = self._session
        if session is None or bool(getattr(session, "is_dead", False)):
            return None
        proc = getattr(session, "_proc", None)
        if proc is None or proc.poll() is not None:
            return None
        return proc.pid

    def reconfigure(self, session_kwargs: dict) -> None:
        """Apply new identity kwargs after a profile PATCH.

        Marks the bridge stale so the NEXT turn closes the current gateway
        and respawns with the new config; an in-flight turn keeps running on
        the old gateway to completion. Two PATCHes before the next turn
        coalesce into a single respawn (stale is a boolean).

        Supervision timeouts ride in the same kwargs dict and are popped the
        same way as in __init__: they are hub-side policy, never engine args.
        """
        with self._status_lock:
            if self._closed:
                return
            kwargs = dict(session_kwargs or {})
            if "stall_timeout_s" in kwargs:
                self._stall_timeout_s = float(kwargs.pop("stall_timeout_s"))
            if "hard_timeout_s" in kwargs:
                self._hard_timeout_s = float(kwargs.pop("hard_timeout_s"))
            self._session_kwargs = kwargs
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

    # ------------------------------------------------------------------
    # Checkpoint 3: cancellation (one ladder, shared with timeouts)
    # ------------------------------------------------------------------

    def active_run_id(self) -> str | None:
        """The run currently popped by the worker (running or gated/waiting)."""
        with self._status_lock:
            return self._current_run_id

    def escalation_rungs(self) -> list[str]:
        """Rungs attempted/succeeded for the most recent escalations (tests)."""
        with self._status_lock:
            return list(self._escalation_rungs)

    def cancel_run(self, run_id: str, drain_queue: bool = False) -> None:
        """Cancel one run (Checkpoint 3).

        Active run (popped by the worker): set the cancel flag — the
        worker skips the engine if it hasn't started, or the escalation
        ladder runs on a background thread if the turn is mid-prompt. This
        call returns immediately; the terminal state is set by the worker
        (exactly once, in _end_run).

        Queued run: removed from the queue, its row finalized cancelled, and
        a ``cancelled`` event stored/fanned out. ``drain_queue`` ALSO
        cancels every other run still queued for this agent (each gets its
        own cancelled row + event). A cancel never touches runs already
        popped by the worker beyond the target — a cancel kills one run, not
        the agent's queue, unless drain is requested.

        The caller (HTTP layer) is responsible for terminal-state 409s: this
        method assumes the run is not yet terminal in the store.
        """
        with self._status_lock:
            active = self._current_run_id == run_id
            if active:
                self._run_cancelled = "cancelled"
            else:
                self._cancelled_runs.add(run_id)
        # Drain BEFORE escalating: while this call runs synchronously the
        # worker is still busy with the current turn (it cannot have popped
        # a queued item yet), so the queue contents are deterministic here.
        if drain_queue:
            self._drain_queued_runs(cancel=None)
        if active:
            with self._status_lock:
                running = self._running
            if running:
                self._escalate_async("cancelled")
            return
        # Queued: drain the matching item(s) off the queue and finalize.
        self._drain_queued_runs(cancel=[run_id])

    def _drain_queued_runs(self, cancel: list[str] | None) -> None:
        """Remove queued items from the worker queue, finalizing the cancelled.

        Items whose run_id is in ``cancel`` (or every run_id item when
        ``cancel`` is None) are finalized as cancelled; everything else is
        re-queued in order. The worker may concurrently pop an item — it
        then handles the cancel itself via _cancelled_runs, so no run is
        ever double-finalized.
        """
        kept: list = []
        dropped: list[str] = []
        while True:
            try:
                item = self._queue.get_nowait()
            except Empty:
                break
            # Items are dicts (prompt()); tolerate the legacy 3-tuple.
            if isinstance(item, dict):
                rid = item.get("run_id")
            else:
                _text, _remote, rid = item
            if rid is not None and (cancel is None or rid in cancel):
                dropped.append(rid)
            else:
                kept.append(item)
        for item in kept:
            self._queue.put(item)
        for rid in dropped:
            self._finalize_cancelled(rid)

    def _finalize_cancelled(self, run_id: str) -> None:
        """Terminalize a run that never started: cancelled row + event."""
        try:
            self._emit({"type": "cancelled", "text": "run cancelled"}, run_id=run_id)
            if self.store is not None:
                self.store.finish_run(run_id, "cancelled")
        except Exception as exc:  # noqa: BLE001
            print(
                f"[vertus] finalize-cancel failed ({run_id}): {exc}", file=sys.stderr
            )

    def _escalate_async(self, reason: str) -> None:
        """Run the escalation ladder on a background thread (cancel API)."""
        threading.Thread(
            target=self._escalate,
            args=(reason,),
            daemon=True,
            name=f"escalate-{self.agent_id}",
        ).start()

    def _escalate(self, reason: str) -> None:
        """One escalation ladder (Checkpoint 2), shared by timeout and cancel.

        Rung 1 — session.interrupt RPC, then wait grace for the turn to end
        (a well-behaved engine stops at the next action boundary).
        Rung 2 — SIGTERM the gateway's process group (the embedded
        cua-driver daemon shares the group, so it dies with the gateway).
        Rung 3 — SIGKILL the group; the turn is terminal by construction.

        Each rung is logged with which one succeeded. Runs on a daemon
        thread; the worker's prompt call unblocks through the reader (EOF on
        process death, or the interrupt event), checks the cancel flag, and
        finalizes the run — so this method never touches the store itself.
        """
        with self._status_lock:
            if self._escalating or not self._running:
                return
            self._escalating = True
            # The reason IS the terminal-state request: the worker's
            # cancelled check (every attempt boundary + after prompt()) reads
            # this flag, so escalation must stamp it or the worker would
            # RESPAWN a turn that was killed on purpose. First writer wins —
            # a user cancel racing a stall keeps "cancelled".
            if self._run_cancelled is None:
                self._run_cancelled = reason

        def log(msg: str) -> None:
            print(
                f"[vertus] agent {self.agent_id} escalate[{reason}] {msg}",
                file=sys.stderr,
            )

        try:
            session = self._session
            if session is None:
                # Nothing to stop (mid-respawn or pre-spawn): the worker
                # notices the cancel flag at its next attempt boundary.
                log("no live session; waiting for the worker to notice")
                return

            def rung(n: int, label: str, attr: str, done_msg: str) -> bool:
                call = getattr(session, attr, None)
                if call is None:
                    log(f"rung{n} {label} skipped (session lacks {attr})")
                    return False
                try:
                    call()
                except Exception as exc:  # noqa: BLE001
                    log(f"rung{n} {label} failed: {exc}")
                    return False
                with self._status_lock:
                    self._escalation_rungs.append(f"rung{n}:{label}")
                log(done_msg)
                return True

            rung(1, "interrupt", "interrupt", "rung1 interrupt sent")
            if self._wait_turn_end(ESCALATION_GRACE_S):
                log("rung1 succeeded — turn ended within grace")
                return
            rung(2, "terminate", "terminate_process", "rung2 SIGTERM sent to gateway process group")
            if self._wait_turn_end(ESCALATION_GRACE_S):
                log("rung2 succeeded — turn ended after SIGTERM")
                return
            rung(3, "kill", "kill_process", "rung3 SIGKILL sent to gateway process group")
            self._wait_turn_end(ESCALATION_GRACE_S)
            log("rung3 done — turn terminal")
        finally:
            with self._status_lock:
                self._escalating = False

    def _wait_turn_end(self, timeout: float) -> bool:
        """True when the turn stops being ``running`` within ``timeout``."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._status_lock:
                running = self._running
            if not running:
                return True
            time.sleep(0.05)
        return False

    # ------------------------------------------------------------------
    # Checkpoint 1 + 4: the per-bridge supervisor thread
    # ------------------------------------------------------------------

    def _monitor_loop(self) -> None:
        """Per-bridge supervisor: stall/hard timeouts + idle gateway health.

        While a turn runs: if the engine has emitted NOTHING for longer than
        stall_timeout_s (any event type refreshes the clock — a healthy CUA
        turn pings constantly, a wedged one is silent), or the turn has run
        longer than hard_timeout_s while emitting forever without
        converging, escalate. While idle: health-check the gateway.
        """
        while True:
            time.sleep(1.0)
            with self._status_lock:
                if self._closed:
                    return
                running = self._running
                escalating = self._escalating
                started = self._turn_started_at
                last_event = self._last_event_at
                stall = self._stall_timeout_s
                hard = self._hard_timeout_s
            if not running:
                self._health_check()
                continue
            if escalating:
                continue
            now = time.monotonic()
            if stall > 0 and last_event is not None and now - last_event > stall:
                msg = (
                    f"stall timeout: no agent events for {now - last_event:.0f}s "
                    f"(stall_timeout_s={stall:g})"
                )
                with self._status_lock:
                    self._run_timeout_msg = msg
                print(f"[vertus] agent {self.agent_id}: {msg}", file=sys.stderr)
                self._escalate("stall")
            elif hard > 0 and started is not None and now - started > hard:
                msg = (
                    f"hard timeout: turn ran {now - started:.0f}s "
                    f"(hard_timeout_s={hard:g})"
                )
                with self._status_lock:
                    self._run_timeout_msg = msg
                print(f"[vertus] agent {self.agent_id}: {msg}", file=sys.stderr)
                self._escalate("hard_timeout")

    def _health_check(self) -> None:
        """Idle-gateway liveness (Checkpoint 4).

        A gateway that is alive (process up, pipes open) but does not answer
        a cheap RPC within HEALTH_CHECK_RPC_TIMEOUT_S is hung, not slow —
        close it so the next prompt spawns fresh. Only ever runs while the
        agent is idle, and only on the session captured at check time (a
        concurrent spawn replacing it is never closed by this check).
        """
        now = time.monotonic()
        with self._status_lock:
            if self._closed or self._running or self._waiting_on:
                return
            if now - self._last_health_check < HEALTH_CHECK_INTERVAL_S:
                return
            self._last_health_check = now
            session = self._session
            if session is None or bool(getattr(session, "is_dead", False)):
                return
        try:
            ping = getattr(session, "active_list", None)
            if ping is None:
                return
            ping(timeout=HEALTH_CHECK_RPC_TIMEOUT_S)
        except Exception:  # noqa: BLE001 — unresponsive = reap
            with self._status_lock:
                if self._session is session:
                    self._session = None
            try:
                session.close()
            except Exception:  # noqa: BLE001
                pass
            print(
                f"[vertus] agent {self.agent_id}: idle gateway unresponsive — "
                "closed for a fresh spawn on next prompt",
                file=sys.stderr,
            )


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
    screen_leases: ScreenLeaseManager = None  # type: ignore[assignment]
    routines: RoutineManager = None  # type: ignore[assignment]
    # Boot self-check snapshot (name -> {ok, reason}); /api/health re-probes
    # the live subsystems and merges this for anything without a live probe.
    health_snapshot: dict = {}  # type: ignore[assignment]

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
            self._handle_health()
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
        elif path == "/api/messages":
            self._handle_messages_list()
        elif path == "/api/threads":
            self._handle_threads_list()
        elif path == "/api/approvals":
            self._handle_approvals_list()
        elif path == "/api/runs":
            self._handle_runs_list()
        elif path.startswith("/api/runs/"):
            self._handle_run_get(path[len("/api/runs/"):].strip("/"))
        elif path == "/api/routines":
            self._handle_routines_list()
        elif path.startswith("/api/routines/"):
            rest = path[len("/api/routines/"):].strip("/")
            if rest.endswith("/history"):  # runs produced by one routine
                self._handle_routine_history(rest[: -len("/history")])
            else:
                self._handle_routine_get(rest)
        elif path == "/api/fleet/activity":
            self._handle_fleet_activity()
        elif path == "/api/fleet/screens":
            self._handle_fleet_screens()
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
            # never leaves an orphan queued run behind; the bridge is fetched
            # before the row too so a DEGRADED agent (gateway failing/thrash-
            # ing) is refused with 503 before anything is even queued.
            try:
                self.registry.get_agent(agent_id)
            except KeyError:
                self._json(404, {"error": f"agent not found: {agent_id}"})
                return
            try:
                bridge = self.sessions.get_or_create_session(agent_id)
            except KeyError:
                # Agent deleted between validation and enqueue (a DELETE won
                # the race).
                self._json(404, {"error": f"agent not found: {agent_id}"})
                return
            st = getattr(bridge, "status", lambda: {})()
            if st.get("degraded"):
                self._json(503, {"error": f"agent degraded: {st['degraded']}"})
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
            if self.store is not None:
                # The bridge persists every event of the run to the store
                # BEFORE fanout; bind it now (the default factory doesn't
                # take a store kwarg so test fakes stay compatible).
                bridge.store = self.store
            try:
                bridge.prompt(text, remote=remote, run_id=run_id)
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
        elif route == "/api/messages":
            self._handle_message_send(payload)
        elif route == "/api/routines":
            self._handle_routine_create(payload)
        elif route.startswith("/api/routines/") and route.endswith("/run"):
            rid = route[len("/api/routines/"):-len("/run")].strip("/")
            self._handle_routine_run_now(rid)
        elif route.startswith("/api/threads/") and route.endswith("/read"):
            self._handle_thread_read(route[len("/api/threads/"):-len("/read")].strip("/"))
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
        elif route.startswith("/api/agents/") and route.endswith("/cancel"):
            agent_id = route[len("/api/agents/"):-len("/cancel")].strip("/")
            self._handle_agent_cancel(agent_id)
        elif route.startswith("/api/runs/") and route.endswith("/cancel"):
            run_id = route[len("/api/runs/"):-len("/cancel")].strip("/")
            self._handle_run_cancel(run_id, payload)
        else:
            self._json(404, {"error": "not found"})

    def do_PATCH(self) -> None:  # noqa: N802
        """PATCH /api/agents/<id> or /api/routines/<id> — partial updates."""
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        path = urlsplit(self.path).path
        if path.startswith("/api/routines/"):
            rid = path[len("/api/routines/"):].strip("/")
            payload = self._read_body()
            if payload is None:
                return
            self._handle_routine_patch(rid, payload)
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
        """DELETE /api/agents/<id> (archive) or /api/routines/<id>."""
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        path = urlsplit(self.path).path
        if path.startswith("/api/routines/"):
            rid = path[len("/api/routines/"):].strip("/")
            self._handle_routine_delete(rid)
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
        # A deleted agent's routines must never fire again — disable them so
        # the scheduler's existence gate can't even see them.
        if self.store is not None and self.routines is not None:
            try:
                n = self.store.disable_routines_for(agent_id)
                if n:
                    print(f"[vertus] disabled {n} routine(s) of deleted agent {agent_id}")
            except Exception as exc:  # noqa: BLE001 — archive already succeeded
                print(f"[vertus] routine disable for {agent_id} failed: {exc}", file=sys.stderr)
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

    def _handle_health(self) -> None:
        """GET /api/health — REAL hub health: uptime, live subsystem probes,
        fleet census, and scheduler state.

        Keeps the historical {status, time} keys so existing clients keep
        parsing it. ``status`` is "ok" only when every probed subsystem is
        live; otherwise "degraded" with the failing subsystems named in
        ``subsystems``. The store probe runs a real writer round-trip, so a
        wedged writer thread shows here within seconds, not days.
        """
        store = self.store
        checks: dict = {}
        if store is not None:
            try:
                ms = store.ping()
                checks["store"] = {"ok": True, "reason": f"writer round-trip {ms:.1f}ms"}
            except Exception as exc:  # noqa: BLE001
                checks["store"] = {"ok": False, "reason": str(exc)[:200]}
            try:
                checks["scheduler_next_fire"] = store.next_routine_fire()
            except Exception:  # noqa: BLE001
                checks["scheduler_next_fire"] = None
            try:
                running = store.running_run_count()
            except Exception:  # noqa: BLE001
                running = 0
        else:
            running = 0
        thr = getattr(self.routines, "_thread", None) if self.routines else None
        routines_ok = thr is not None and thr.is_alive()
        checks["routines"] = {
            "ok": routines_ok,
            "reason": "scheduler thread alive" if routines_ok else "scheduler thread dead",
        }
        checks["messenger"] = {
            "ok": self.messenger is not None,
            "reason": ("message bus wired" if self.messenger is not None
                       else "message bus not wired"),
        }
        if store is not None and store.listener is not None:
            checks["fleet_listener"] = {"ok": True, "reason": "store listener registered"}
        # Merge the boot snapshot for subsystems without a live probe.
        for name, check in (self.health_snapshot or {}).items():
            checks.setdefault(name, check)
        ok_all = all(c.get("ok") for c in checks.values() if isinstance(c, dict))
        # Fleet census: agents, live degraded agents, in-flight runs.
        degraded_agents: list[dict] = []
        agent_count = 0
        try:
            agent_count = len(self.registry.list_agents())
            for aid in self.sessions.live_ids():
                st = self.sessions.status(aid)
                if st.get("degraded"):
                    degraded_agents.append({"agent_id": aid, "reason": st["degraded"]})
        except Exception:  # noqa: BLE001 — census is best-effort
            pass
        self._json(200, {
            "status": "ok" if ok_all else "degraded",
            "time": int(time.time()),
            "uptime_s": int(time.time() - _SERVE_STARTED),
            "subsystems": checks,
            "agents": agent_count,
            "running_runs": running,
            "degraded_agents": degraded_agents,
            "scheduler_next_fire": checks.get("scheduler_next_fire"),
        })

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

    def _handle_run_cancel(self, run_id: str, payload: dict) -> None:
        """POST /api/runs/<run_id>/cancel — cancel one run (Checkpoint 3).

        Queued run → dequeued, state=cancelled, never spawns. Running run →
        the escalation ladder (async; this returns 200 immediately).
        Terminal run → 409. ``drain_queue: true`` additionally cancels every
        other run still queued for that agent.
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
        if run["state"] in TERMINAL_STATES:
            self._json(409, {"error": f"run already terminal ({run['state']})"})
            return
        drain = bool(payload.get("drain_queue", False))
        agent_id = run["agent_id"]
        if not self.sessions.has_session(agent_id):
            # No live bridge (e.g. a DELETE raced the enqueue): the row is
            # stuck queued — finalize it directly so nothing can hang.
            try:
                store.finish_run(run_id, "cancelled")
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"error": f"run store unavailable: {str(exc)[:200]}"})
                return
            self._json(200, {"cancelled": run_id, "drain_queue": drain})
            return
        bridge = self.sessions.get_or_create_session(agent_id)
        bridge.cancel_run(run_id, drain_queue=drain)
        self._json(200, {"cancelled": run_id, "drain_queue": drain})

    def _handle_agent_cancel(self, agent_id: str) -> None:
        """POST /api/agents/<id>/cancel — cancel whatever the agent is doing now.

        Cancels the ACTIVE run only (the queue is left intact — use the
        run-level drain_queue for that). 409 when the agent is idle or has
        no run in progress.
        """
        if not agent_id:
            self._json(404, {"error": "not found"})
            return
        try:
            self.registry.get_agent(agent_id)  # KeyError → 404
        except KeyError:
            self._json(404, {"error": "agent not found"})
            return
        st = self.sessions.status(agent_id)
        if st["state"] == "idle":
            self._json(409, {"error": f"agent {agent_id} is idle — nothing to cancel"})
            return
        bridge = self.sessions.get_or_create_session(agent_id)
        run_id = getattr(bridge, "active_run_id", lambda: None)()
        if run_id is None:
            self._json(409, {"error": f"agent {agent_id} has no run in progress"})
            return
        bridge.cancel_run(run_id, drain_queue=False)
        self._json(200, {"cancelled": run_id})

    # ------------------------------------------------------------------
    # Routines (scheduled/triggered work — fleet_routines.py)
    # ------------------------------------------------------------------

    def _routines_store(self) -> "RunStore | None":
        """The store or None (503 already sent). Routines live in the run
        store because they are run history first and schedule state second."""
        store = self._history_store()
        if store is None:
            return None
        if self.routines is None:
            self._json(503, {"error": "routine scheduler unavailable"})
            return None
        return store

    def _handle_routine_create(self, payload: dict) -> None:
        """POST /api/routines — create one routine."""
        store = self._routines_store()
        if store is None:
            return
        agent_id = str(payload.get("agent_id") or "").strip()
        if not agent_id:
            self._json(400, {"error": "agent_id required"})
            return
        try:
            self.registry.get_agent(agent_id)
        except KeyError:
            self._json(404, {"error": f"agent not found: {agent_id}"})
            return
        name = str(payload.get("name") or "").strip()
        if not name:
            self._json(400, {"error": "name required (non-empty string)"})
            return
        prompt = payload.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            self._json(400, {"error": "prompt required (non-empty string)"})
            return
        prompt = prompt.strip()
        if len(prompt) > 8000:
            self._json(400, {"error": "prompt too long (max 8000 chars)"})
            return
        try:
            schedule = parse_schedule(payload.get("schedule"))
            trigger = parse_trigger(payload.get("trigger"))
        except RoutineValidationError as exc:
            self._json(400, {"error": str(exc)})
            return
        if schedule is None and trigger is None:
            self._json(400, {
                "error": "routine needs schedule and/or trigger (both were null)"
            })
            return
        enabled = bool(payload.get("enabled", True))
        try:
            routine = store.create_routine(
                agent_id, name, prompt, schedule, trigger, enabled=enabled
            )
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"error": str(exc)[:200]})
            return
        self.routines.arm(routine["routine_id"], schedule)
        # Re-read AFTER arming so the response carries the truth: next_run_at
        # is set by arm() (the create-time row predates it).
        self._json(201, self._routine_wire(store.get_routine(routine["routine_id"])))

    @staticmethod
    def _routine_wire(row: dict | None) -> dict | None:
        """Reparse stored schedule/trigger JSON strings into objects for the
        wire — the client should never see the storage encoding."""
        if row is None:
            return None
        row = dict(row)
        for key in ("schedule", "trigger"):
            raw = row.get(key)
            if isinstance(raw, str):
                try:
                    row[key] = json.loads(raw)
                except (ValueError, TypeError):
                    row[key] = None
        if "enabled" in row:
            row["enabled"] = bool(row["enabled"])
        return row

    def _handle_routine_get(self, routine_id: str) -> None:
        """GET /api/routines/<id> — one routine row."""
        store = self._routines_store()
        if store is None:
            return
        if not routine_id or "/" in routine_id:
            self._json(404, {"error": "not found"})
            return
        routine = store.get_routine(routine_id)
        if routine is None:
            self._json(404, {"error": f"routine not found: {routine_id}"})
            return
        self._json(200, self._routine_wire(routine))

    def _handle_routines_list(self) -> None:
        """GET /api/routines?agent_id= — routines, optionally per agent."""
        store = self._routines_store()
        if store is None:
            return
        agent = self._query_param("agent_id").strip() or None
        rows = [self._routine_wire(r) for r in store.list_routines(agent_id=agent)]
        self._json(200, {"routines": rows})

    def _handle_routine_patch(self, routine_id: str, payload: dict) -> None:
        """PATCH /api/routines/<id> — partial update (name/prompt/schedule/
        trigger/enabled). Changing the schedule re-arms next_run_at; enabling
        clears failure history."""
        store = self._routines_store()
        if store is None:
            return
        if not routine_id or "/" in routine_id:
            self._json(404, {"error": "not found"})
            return
        current = store.get_routine(routine_id)
        if current is None:
            self._json(404, {"error": f"routine not found: {routine_id}"})
            return
        allowed = {"name", "prompt", "schedule", "trigger", "enabled"}
        unknown = set(payload) - allowed
        if unknown:
            self._json(400, {"error": f"unknown routine fields: {sorted(unknown)}"})
            return
        fields: dict = {}
        if "name" in payload:
            name = str(payload["name"] or "").strip()
            if not name:
                self._json(400, {"error": "name required (non-empty string)"})
                return
            fields["name"] = name
        if "prompt" in payload:
            prompt = payload["prompt"]
            if not isinstance(prompt, str) or not prompt.strip():
                self._json(400, {"error": "prompt required (non-empty string)"})
                return
            fields["prompt"] = prompt.strip()
        if "schedule" in payload or "trigger" in payload:
            # Stored rows carry schedule/trigger as JSON strings; reparse the
            # EXISTING values before mixing with the incoming ones.
            try:
                cur_sched = json.loads(current["schedule"]) if current.get("schedule") else None
                cur_trig = json.loads(current["trigger"]) if current.get("trigger") else None
                schedule = parse_schedule(payload.get("schedule", cur_sched))
                trigger = parse_trigger(payload.get("trigger", cur_trig))
            except RoutineValidationError as exc:
                self._json(400, {"error": str(exc)})
                return
            except (ValueError, TypeError):  # stored row corrupt — refuse, don't guess
                self._json(500, {"error": "stored routine schedule/trigger is corrupt"})
                return
            if schedule is None and trigger is None:
                self._json(400, {
                    "error": "routine needs schedule and/or trigger (both null)"
                })
                return
            if "schedule" in payload:
                fields["schedule"] = schedule
            if "trigger" in payload:
                fields["trigger"] = trigger
        if "enabled" in payload:
            fields["enabled"] = bool(payload["enabled"])
        try:
            updated = store.update_routine(routine_id, **fields)
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"error": str(exc)[:200]})
            return
        if "schedule" in fields:
            self.routines.arm(routine_id, fields["schedule"])
        self._json(200, self._routine_wire(updated))

    def _handle_routine_delete(self, routine_id: str) -> None:
        """DELETE /api/routines/<id> — remove the routine; its runs stay."""
        store = self._routines_store()
        if store is None:
            return
        if not routine_id or "/" in routine_id:
            self._json(404, {"error": "not found"})
            return
        if store.get_routine(routine_id) is None:
            self._json(404, {"error": f"routine not found: {routine_id}"})
            return
        store.delete_routine(routine_id)
        self._json(200, {"deleted": routine_id})

    def _handle_routine_run_now(self, routine_id: str) -> None:
        """POST /api/routines/<id>/run — fire now, ignoring the schedule."""
        store = self._routines_store()
        if store is None:
            return
        if not routine_id or "/" in routine_id:
            self._json(404, {"error": "not found"})
            return
        if store.get_routine(routine_id) is None:
            self._json(404, {"error": f"routine not found: {routine_id}"})
            return
        result = self.routines.fire_now(routine_id)
        if result.get("fired"):
            self._json(202, {"accepted": True, **result})
        elif result.get("reason") == "not found":
            self._json(404, {"error": "routine not found"})
        elif result.get("reason") == "routine disabled":
            self._json(400, {"error": "routine is disabled"})
        elif result.get("reason", "").startswith("already running"):
            self._json(409, {"error": result["reason"]})
        elif result.get("reason", "").startswith("agent degraded"):
            self._json(503, {"error": result["reason"]})
        elif result.get("reason", "").startswith("agent "):
            self._json(404, {"error": result["reason"]})
        else:
            self._json(500, {"error": result.get("reason", "fire failed")})

    def _handle_routine_history(self, routine_id: str) -> None:
        """GET /api/routines/<id>/history — runs produced by one routine."""
        store = self._history_store()
        if store is None:
            return
        if not routine_id or "/" in routine_id:
            self._json(404, {"error": "not found"})
            return
        if store.get_routine(routine_id) is None:
            self._json(404, {"error": f"routine not found: {routine_id}"})
            return
        limit = self._limit_param("limit", 50, 200)
        self._json(200, {
            "routine_id": routine_id,
            "runs": store.list_runs(routine_id=routine_id, limit=limit),
        })

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
        terminal_types = ("done", "error", "cancelled")

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

    def _float_param(self, name: str) -> float | None:
        raw = self._query_param(name)
        if not raw:
            return None
        try:
            return float(raw)
        except ValueError:
            return None

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
        """GET /api/runs/<run_id> — one run + messages + delegation tree.

        ``parent`` is the run that delegated this one (if any) and
        ``children`` are the runs this one spawned — so a delegation chain
        is navigable end to end. Works for deleted agents too: run history
        is the record of what the bot did and is deliberately NOT removed by
        DELETE /api/agents.
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
        parent = None
        if run.get("parent_run_id"):
            parent = store.get_run(run["parent_run_id"])
        self._json(200, {
            "run": run,
            "messages": store.run_messages(run_id),
            "parent": parent,
            "children": store.children_of(run_id),
        })

    def _handle_message_send(self, payload: dict) -> None:
        """POST /api/messages — send one bot-to-bot message (or handoff).

        Delivered messages become turns on the recipient (kind=result never
        spawns a run; kind=handoff records the delegator's live run as
        parent). Depth/rate-capped messages are STORED with a dropped status
        and returned as such — never silently discarded, never raising.
        """
        messenger = self.messenger
        if messenger is None:
            self._json(503, {"error": "message bus unavailable"})
            return
        from_agent = str(payload.get("from") or "").strip()
        to_agent = str(payload.get("to") or "").strip()
        body = payload.get("body")
        thread_id = payload.get("thread_id")
        kind = str(payload.get("kind") or "message")
        try:
            result = messenger.send(
                from_agent, to_agent, str(body or ""),
                thread_id=thread_id, kind=kind,
            )
        except BotMessageError as exc:
            self._json(exc.status, {"error": str(exc)})
            return
        except Exception as exc:  # noqa: BLE001
            self._json(503, {"error": str(exc)[:200]})
            return
        self._json(202 if result["status"] == "delivered" else 200, result)

    def _handle_messages_list(self) -> None:
        """GET /api/messages?agent_id=&thread_id=&unread=&limit=&before="""
        messenger = self.messenger
        if messenger is None:
            self._json(503, {"error": "message bus unavailable"})
            return
        agent_id = self._query_param("agent_id") or None
        thread_id = self._query_param("thread_id") or None
        unread = self._query_param("unread") == "1"
        limit = self._limit_param("limit", 50, 200)
        before = self._float_param("before")
        try:
            rows = messenger.list_messages(
                agent_id=agent_id, thread_id=thread_id, unread=unread,
                limit=limit, before=before,
            )
        except Exception as exc:  # noqa: BLE001
            self._json(503, {"error": str(exc)[:200]})
            return
        self._json(200, {"messages": rows})

    def _handle_threads_list(self) -> None:
        """GET /api/threads — thread list with unread counts."""
        messenger = self.messenger
        if messenger is None:
            self._json(503, {"error": "message bus unavailable"})
            return
        limit = self._limit_param("limit", 50, 200)
        try:
            rows = messenger.list_threads(limit=limit)
        except Exception as exc:  # noqa: BLE001
            self._json(503, {"error": str(exc)[:200]})
            return
        self._json(200, {"threads": rows})

    def _handle_thread_read(self, thread_id: str) -> None:
        """POST /api/threads/<id>/read — mark a thread's messages read."""
        messenger = self.messenger
        if messenger is None:
            self._json(503, {"error": "message bus unavailable"})
            return
        if not thread_id:
            self._json(404, {"error": "not found"})
            return
        try:
            marked = messenger.mark_thread_read(thread_id)
        except Exception as exc:  # noqa: BLE001
            self._json(503, {"error": str(exc)[:200]})
            return
        self._json(200, {"marked": marked, "thread_id": thread_id})

    def _handle_approvals_list(self) -> None:
        """GET /api/approvals?state= — read-only approval ledger.

        Honest scope: the hub cannot see per-action approval requests today
        (approvals are off in the fleet config and computer_use never reaches
        the fork's gateable path in gateway mode), so this ledger is empty
        until a future phase populates it. The endpoint exists now so the
        contract — and the client UI — don't have to be invented later.
        """
        store = self._history_store()
        if store is None:
            return
        state = self._query_param("state") or None
        limit = self._limit_param("limit", 100, 500)
        self._json(200, {"approvals": store.list_approvals(state=state, limit=limit)})

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
                "from_agent": r.get("from_agent"),
                "run_kind": r.get("run_kind"),
                "parent_run_id": r.get("parent_run_id"),
            }
            for r in rows
        ]
        self._json(200, {"activity": activity})

    @staticmethod
    def _socket_of_cmd(cmd: str) -> str:
        """Extract the driver's ``--socket <path>`` (its identity), else ''."""
        try:
            return cmd.split("--socket", 1)[1].strip().split()[0]
        except (IndexError, ValueError):
            return ""

    def _driver_inventory(self) -> tuple[list[dict], list[dict]]:
        """Live ps scan of cua-driver processes: owned vs orphaned.

        ``owned``: every driver process whose pgid matches a live gateway
        (attributed to that agent). ``orphaned``: ppid-1 drivers (``--embedded``)
        left behind by a dead gateway — the same signature the boot sweep
        reaps; listed here so operators can see the accumulation live.
        The user's CuaDriver.app daemon never appears: its args carry
        ``--cua-internal-gate-engaged``, never ``--embedded``.
        """
        try:
            out = subprocess.run(
                ["ps", "-axo", "pid=,ppid=,pgid=,command="],
                capture_output=True, text=True, check=False,
            )
        except OSError:
            return [], []
        rows = []
        for line in out.stdout.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) != 4:
                continue
            pid, ppid, pgid, cmd = parts
            if "cua-driver" not in cmd:
                continue
            rows.append(
                {"pid": int(pid), "ppid": int(ppid), "pgid": int(pgid), "cmd": cmd}
            )
        owned: list[dict] = []
        sessions = self.sessions
        if sessions is not None:
            for agent_id in sessions.live_ids():
                # live_ids() only lists EXISTING bridges, so this never
                # instantiates an engine as a side effect.
                try:
                    bridge = sessions.get_or_create_session(agent_id)
                except Exception:  # noqa: BLE001 — roster is best-effort
                    continue
                pgid = getattr(bridge, "gateway_pgid", None)
                if not pgid:
                    continue
                for r in rows:
                    if r["pgid"] == pgid:
                        owned.append(
                            {
                                "agent_id": agent_id,
                                "pid": r["pid"],
                                "role": (
                                    "embedded" if "--embedded" in r["cmd"] else "mcp"
                                ),
                                "socket": self._socket_of_cmd(r["cmd"]),
                            }
                        )
        orphaned = [
            {"pid": r["pid"], "cmd": r["cmd"][:140]}
            for r in rows
            if r["ppid"] == 1 and "--embedded" in r["cmd"]
        ]
        return owned, orphaned

    def _handle_fleet_screens(self) -> None:
        """GET /api/fleet/screens — declared targets, who is running, who waits,
        and a live cua-driver process inventory.

        Roster behind the per-window computer-use policy. Every agent with
        computer_use enabled and non-null cua_targets appears; each target
        shows who declared it, which run currently owns it (if any), and
        which agents are waiting on it. The response carries the policy
        caveat verbatim: targets are declarations, not a sandbox — the hub
        cannot see what an agent actually drives mid-turn. ``drivers``
        attributes each live cua-driver process to its gateway (via process
        group) and lists anything orphaned from a previous hub life.
        """
        leases = self.screen_leases
        if leases is None:
            self._json(
                200,
                {"screens": [], "caveat": SCREEN_POLICY_CAVEAT,
                 "drivers": {"owned": [], "orphaned": []}},
            )
            return
        owners = leases.owners()
        blocked = leases.blocked()
        try:
            agents = self.registry.list_agents()
        except Exception:  # noqa: BLE001 — roster is best-effort
            agents = []
        declared: dict[str, list[str]] = {}
        for agent in agents:
            if not bool(agent.get("computer_use")):
                continue
            for target in agent.get("cua_targets") or []:
                declared.setdefault(str(target), []).append(agent["id"])
        screens: list[dict] = []
        for target in sorted(set(declared) | set(owners)):
            entry: dict = {
                "target": target,
                "declared_by": sorted(declared.get(target, [])),
            }
            holder = owners.get(target)
            entry["running"] = (
                {"agent_id": holder[0], "run_id": holder[1], "since": holder[2]}
                if holder
                else None
            )
            entry["waiting"] = sorted(
                b["agent_id"] for b in blocked if b["target"] == target
            )
            screens.append(entry)
        owned, orphaned = self._driver_inventory()
        self._json(
            200,
            {"screens": screens, "caveat": SCREEN_POLICY_CAVEAT,
             "drivers": {"owned": owned, "orphaned": orphaned}},
        )

    def log_message(self, fmt: str, *args) -> None:
        pass


def _validate_profile_payload(payload: dict, *, allow_name: bool) -> dict:
    """Validate a POST/PATCH agent body against the v4 editable schema.

    Returns the registry field dict (``name`` is handled by the caller).
    Raises ValueError with a client-facing message for any 400 condition:
    unknown keys, wrong-typed values, bad autonomy, persona over the
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
        if key == "computer_use":
            if not isinstance(value, bool):
                raise ValueError("computer_use must be a boolean")
            fields[key] = value
            continue
        if key == "cua_targets":
            if value is None:
                fields[key] = None
            elif not isinstance(value, list) or not all(
                isinstance(t, str) and t.strip() for t in value
            ):
                raise ValueError("cua_targets must be a list of non-empty strings or null")
            else:
                fields[key] = [t.strip() for t in value]
            continue
        if key in ("stall_timeout_s", "hard_timeout_s"):
            # Supervision limits: positive seconds, or null → hub default.
            if value is None:
                fields[key] = None
            elif isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
                raise ValueError(f"{key} must be a positive number or null")
            else:
                fields[key] = float(value)
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
                    session.create model param (belt and suspenders); plus
                    HERMES_COMPUTER_USE_BACKEND=noop for agents whose
                    profile has computer_use OFF — the fork's documented
                    per-process CUA kill switch (the tool stays registered
                    but its backend is a no-op stub: captures return blank
                    frames and input actions touch nothing on the desktop).
    """
    agent = registry.get_agent(agent_id)
    kwargs: dict = {}
    # Supervision policy (v4): stall/hard timeouts ride the same kwargs dict
    # and are POPPED by AgentBridge (hub-side policy, never engine spawn
    # args). None/null means "hub default".
    kwargs["stall_timeout_s"] = float(agent.get("stall_timeout_s") or 180)
    kwargs["hard_timeout_s"] = float(agent.get("hard_timeout_s") or 3600)
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
    if not bool(agent.get("computer_use")):
        # computer_use OFF (the v3 default): cut capability at spawn. The
        # fork resolves the backend name from process env on first use
        # (tools/computer_use/tool.py) — noop never spawns cua-driver.
        extra["HERMES_COMPUTER_USE_BACKEND"] = "noop"
    if extra:
        kwargs["extra_env"] = extra
    return kwargs


def build_session_manager(registry: AgentRegistry, factory=None,
                          screen_leases: ScreenLeaseManager | None = None,
                          on_run_terminal=None) -> SessionManager:
    """One SessionManager for the hub: primary prewarmed, others lazy.

    Each bridge is created with its agent's sandbox dir as the session cwd
    plus its identity kwargs (per-agent HERMES_HOME + model override; see
    resolve_session_kwargs). ``factory`` defaults to building real
    AgentBridges (hermes engine); tests inject fakes so no engine subprocess
    is ever spawned — fakes that accept ``cwd=`` keep working because
    identity kwargs are only added when the profile actually carries them.

    ``screen_leases`` (the hub's shared ScreenLeaseManager) is attached to
    every real bridge together with a live resolver of the agent's declared
    cua_targets, so per-window computer-use ownership gates at turn start.
    """
    if factory is None:
        # The default factory closes over the shared ScreenLeaseManager. The
        # lease kwargs are passed ONLY when a manager is actually wired so
        # test harnesses that monkeypatch ``AgentBridge`` with fakes (which
        # accept the historical 3-kwarg signature) keep working unchanged.
        # ``on_run_terminal`` is added to the AgentBridge call ONLY when a
        # messenger is actually wired (serve() passes one; test harnesses
        # monkeypatch AgentBridge with fakes that accept the historical
        # 3-kwarg signature — same rule as the lease kwargs above).
        terminal_kwargs = {} if on_run_terminal is None else {
            "on_run_terminal": on_run_terminal,
        }
        if screen_leases is None:
            def factory(agent_id: str):
                return AgentBridge(
                    agent_id=agent_id,
                    cwd=resolve_sandbox_cwd(registry, agent_id),
                    session_kwargs=resolve_session_kwargs(registry, agent_id),
                    **terminal_kwargs,
                )
        else:
            def factory(agent_id: str):
                def targets_resolver(aid: str):
                    try:
                        agent = registry.get_agent(aid)
                    except KeyError:
                        return None
                    if not bool(agent.get("computer_use")):
                        return None
                    return agent.get("cua_targets") or None

                return AgentBridge(
                    agent_id=agent_id,
                    cwd=resolve_sandbox_cwd(registry, agent_id),
                    session_kwargs=resolve_session_kwargs(registry, agent_id),
                    screen_leases=screen_leases,
                    screen_targets=targets_resolver,
                    **terminal_kwargs,
                )
    return SessionManager(
        registry,
        factory=factory,
        seed_agent_id=DEFAULT_AGENT_ID,
    )


def reap_orphaned_drivers(log=print) -> int:
    """Boot sweep: kill cua-driver processes orphaned by gateways that died
    in a PREVIOUS hub life, and return how many were reaped.

    Signature: ppid 1 (reparented to launchd after the gateway died) AND
    ``--embedded`` in the command line — the flag the fork's backend passes
    when a gateway spawns its own driver
    (``cua-driver serve --embedded --socket <tmp>/hc-*.sock``).

    The user's pre-existing driver daemon
    (``CuaDriver.app/.../cua-driver serve --cua-internal-gate-engaged``)
    NEVER matches: it is a launchd daemon (ppid 1) but its args never
    contain ``--embedded``. If a future driver revision blurs that line,
    this sweep must be re-audited before it can be trusted to run at boot.

    Idempotent: a second pass finds nothing to kill. Best-effort: a busy
    driver gets SIGTERM then a 1s grace then SIGKILL.
    """
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,command="],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        log(f"[vertus] driver sweep failed (no ps?): {exc}")
        return 0
    victims: list[int] = []
    for line in out.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        pid, ppid, cmd = parts
        if ppid == "1" and "cua-driver" in cmd and "--embedded" in cmd:
            victims.append(int(pid))
    for pid in victims:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if victims:
        time.sleep(1.0)
        for pid in victims:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if victims:
        log(
            f"[vertus] reaped {len(victims)} orphaned cua-driver process(es) "
            "left by a previous hub life"
        )
    return len(victims)


def subsystem_checks(store, routines, messenger, sessions, registry) -> dict:
    """Probe every subsystem and return name -> {ok, reason}.

    Used by the boot self-check (one loud log line per subsystem) and by
    GET /api/health (re-probed live). Every check is side-effect free: no
    bridge creation, no engine spawn.
    """
    checks: dict = {}
    if store is not None:
        try:
            ms = store.ping()
            checks["store"] = {"ok": True, "reason": f"writer round-trip {ms:.1f}ms"}
        except Exception as exc:  # noqa: BLE001
            checks["store"] = {"ok": False, "reason": str(exc)[:200]}
    else:
        checks["store"] = {"ok": False, "reason": "run store not wired"}
    thr = getattr(routines, "_thread", None)
    if routines is not None:
        alive = thr is not None and thr.is_alive()
        checks["routines"] = {
            "ok": alive,
            "reason": "scheduler thread alive" if alive else "scheduler thread dead",
        }
    else:
        checks["routines"] = {"ok": False, "reason": "routine scheduler not wired"}
    checks["messenger"] = {
        "ok": messenger is not None,
        "reason": "message bus wired" if messenger is not None else "message bus not wired",
    }
    checks["fleet_listener"] = {
        "ok": store is not None and store.listener is not None,
        "reason": ("store listener (fanout+routines) registered"
                   if store is not None and store.listener is not None
                   else "store listener not registered"),
    }
    if sessions is not None:
        try:
            sessions.get_or_create_session(DEFAULT_AGENT_ID)  # prewarmed: no creation
            checks["sessions"] = {"ok": True, "reason": "session manager live (primary prewarmed)"}
        except Exception as exc:  # noqa: BLE001
            checks["sessions"] = {"ok": False, "reason": str(exc)[:200]}
    else:
        checks["sessions"] = {"ok": False, "reason": "session manager not wired"}
    if registry is not None:
        try:
            registry.ensure_primary()
            checks["registry"] = {"ok": True, "reason": "agent registry live"}
        except Exception as exc:  # noqa: BLE001
            checks["registry"] = {"ok": False, "reason": str(exc)[:200]}
    return checks


_SERVE_STARTED = time.time()


def serve(host: str | None, port: int) -> None:
    setup_logging()
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
    # Per-window computer-use ownership (Step: screen leases): one fleet-wide
    # manager shared by every bridge. In-memory by design — a hub restart
    # clears leases along with the gateways that held them.
    screen_leases = ScreenLeaseManager()
    VertusHandler.screen_leases = screen_leases
    # ensure_primary() MUST run before the session manager seeds the primary
    # bridge: on a fresh store the seed factory resolves the sandbox via
    # get_agent("primary"), which raises KeyError until the agent exists.
    try:
        primary = registry.ensure_primary()
        print(f"[vertus] agents root: {registry.root} (primary: {primary['id']})")
        # Fleet message bus: store-backed bot-to-bot messaging + delegation.
        # Built BEFORE the session manager so every bridge's on_run_terminal
        # callback is the messenger's; its store/session providers are
        # lambdas over locals assigned in later serve() steps (resolved at
        # call time, so construction order stays irrelevant).
        messenger = BotMessenger(
            lambda: store, lambda: sessions, registry
        )
        VertusHandler.messenger = messenger
        sessions = build_session_manager(
            registry, screen_leases=screen_leases,
            on_run_terminal=messenger.run_terminal,
        )
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
    # Routine scheduler: one thread owns all fires (ticks + trigger scans), so
    # a routine can never fire concurrently with itself and two routines can
    # never race each other. The store's event listener composes fleet fanout
    # with the trigger scan — the listener runs on the STORE WRITER thread, so
    # on_event() only queues work (never blocks, never writes).
    # Provider callables, not instances: the manager resolves the store and
    # session manager lazily (mirrors BotMessenger's construction pattern).
    routines = RoutineManager(lambda: store, registry, lambda: sessions)
    VertusHandler.routines = routines

    def _composed_listener(envelope: dict) -> None:
        fleet.publish(envelope)
        routines.on_event(envelope)

    store.listener = _composed_listener
    try:
        recovered = store.recover_interrupted()
        if recovered:
            print(f"[vertus] crash recovery: {recovered} run(s) marked interrupted")
        pruned = store.prune_events()
        if pruned:
            print(f"[vertus] retention: pruned {pruned} old event row(s)")
        reaped = reap_orphaned_drivers()
        if reaped:
            print(f"[vertus] driver sweep: reaped {reaped} orphaned cua-driver(s)")
        # Missed-fire catch-up: routines due while the hub was down fire
        # exactly once here (see fleet_routines.MISSED-FIRE).
        routines.catch_up()
    except Exception as exc:  # noqa: BLE001
        print(f"[vertus] run-store boot maintenance failed: {exc}", file=sys.stderr)

    # Boot self-check: one explicit line per subsystem. A subsystem that
    # failed to start must be LOUD here and visible in GET /api/health, not
    # just buried in a log nobody reads.
    health_snapshot = subsystem_checks(
        store, routines, messenger, sessions, registry
    )
    VertusHandler.health_snapshot = health_snapshot
    for name, check in health_snapshot.items():
        if check.get("ok"):
            print(f"[vertus] self-check {name}: ok ({check['reason']})")
        else:
            print(f"[vertus] SELF-CHECK FAILED {name}: {check['reason']}")
    if not all(c.get("ok") for c in health_snapshot.values()):
        failed = [n for n, c in health_snapshot.items() if not c.get("ok")]
        print(f"[vertus] HUB DEGRADED at boot: {', '.join(failed)} (see /api/health)")

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
        routines.stop()


def main() -> None:
    parser = argparse.ArgumentParser(description="VERTUS server")
    sub = parser.add_subparsers(dest="command", required=True)
    p_serve = sub.add_parser("serve", help="run the VERTUS daemon")
    p_serve.add_argument("--host", default=os.environ.get("VERTUS_HOST"))
    p_serve.add_argument("--port", type=int, default=int(os.environ.get("VERTUS_PORT", "8787")))
    sub.add_parser("token", help="print the bearer token")
    p_doc = sub.add_parser(
        "doctor", help="diagnose the fleet (env, gateway dialect, hub, store, registry, launchd)"
    )
    p_doc.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()
    if args.command == "serve":
        serve(args.host, args.port)
    elif args.command == "token":
        print(ensure_token())
    elif args.command == "doctor":
        # Lazy import: doctor pulls hermes_bridge/agent_registry and must not
        # slow the serving path. Exit code is 1 when any check failed.
        from vertus_doctor import run
        sys.exit(run(json_out=args.json))


if __name__ == "__main__":
    main()
