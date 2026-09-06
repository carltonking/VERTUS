"""Fleet message bus + delegation (Checkpoints 2–3 of the fleet work).

Bots message each other through the hub. A delivered message becomes a turn
on the recipient (created as a run row with bot attribution, queued behind
that agent's current work exactly like a user prompt). The hub auto-sends a
``kind=result`` message back to the delegator when a message/handoff-driven
run reaches a terminal state — the return path is hub-deterministic, so
delegation never depends on the model remembering to report back.

Loop protection (the hard part — two bots can ping-pong forever and burn
tokens): every message carries a DEPTH. The hub computes it — bots cannot
spoof it — as ``(latest message from the sender in this thread).depth + 1``;
auto-generated result replies REUSE the depth of the message that triggered
them, so results never inflate a chain. A message whose computed depth would
exceed ``DEPTH_MAX`` (5) is stored with ``status=dropped_depth`` and never
delivered. A per-recipient RATE CAP (10 inbound bot messages / 60s rolling)
stores ``status=dropped_rate`` for the same reason. Dropped messages are
stored — they are the record of the attempt — and a ``bot_message_rejected``
event goes on the fleet stream so the UI shows why nothing happened.

Justification for the caps:

  DEPTH_MAX = 5 — a legitimate chain (user → coordinator → worker → tool,
  then results back) is 1–2 hops; even coordinator → worker → sub-worker is
  2. 5 gives that real headroom while bounding a runaway loop: the worst
  case burns 5 engine turns per thread before the hub refuses, and the rate
  cap bounds the burn RATE on top of that.

  RATE_MAX = 10 / 60s per recipient — a real delegation burst is a handful
  of messages; 10/min is generous headroom, and 60s is long enough that a
  ping-pong pair cannot hide by being "slow but endless". A rejected
  message still consumes a slot (the limiter records the attempt), so a
  retrying bot cannot beat the cap by hammering.

Delegation (Checkpoint 3): the fork is OFF LIMITS, so there is no hub-side
``delegate`` tool the engine can call. The convention instead: a bot sends
``kind=handoff`` via POST /api/messages (the model reaches the API with
curl; FLEET.md materialized into its home spells out the exact request). The
hub creates the child run on the target with ``parent_run_id`` = the
delegator's CURRENT run (so the run graph shows the tree), attributes it,
and returns ``run_id`` in the POST response — the handle. The child's
terminal event fires the auto-result above; the delegator (running or idle)
receives a ``kind=result`` message and is woken by a turn of its own, or
picks it up by polling if it is already mid-turn.

Isolation honesty: the message bus is a CONVENTION the persona describes,
not a sandbox. A bot can do anything its shell allows; nothing here
restricts that. Depth/rate caps bound runaway token burn only.
"""

from __future__ import annotations

import json
import threading
import time
import uuid

BOT_MSG_KINDS = ("message", "handoff", "result")
DEPTH_MAX = 5
RATE_MAX = 10
RATE_WINDOW_S = 60.0


class BotMessageError(RuntimeError):
    """Carries the HTTP status the hub should reply with (404/503/409)."""

    def __init__(self, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.status = status


class _RateLimiter:
    """Rolling-window limiter per key; allow() consumes a slot on rejection."""

    def __init__(self, max_hits: int, window_s: float) -> None:
        self._max = max_hits
        self._window = window_s
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.time()
        with self._lock:
            hits = self._hits.setdefault(key, [])
            while hits and now - hits[0] > self._window:
                hits.pop(0)
            if len(hits) >= self._max:
                hits.append(now)  # count the attempt; retries can't beat the cap
                return False
            hits.append(now)
            return True


class BotMessenger:
    """Store-backed bot-to-bot messaging; one instance per hub."""

    def __init__(self, store_provider, sessions_provider, registry,
                 rate_max: int = RATE_MAX,
                 rate_window_s: float = RATE_WINDOW_S) -> None:
        # Providers (callables) not instances: the hub constructs the
        # messenger before the store/session-manager exist (serve() wiring
        # order), and tests want fakes anyway.
        self._store = store_provider
        self._sessions = sessions_provider
        self.registry = registry
        self._limiter = _RateLimiter(rate_max, rate_window_s)

    # ------------------------------------------------------------------
    # Send path
    # ------------------------------------------------------------------

    def send(self, from_agent: str, to_agent: str, body: str,
             thread_id: str | None = None, kind: str = "message",
             depth: int | None = None, auto: bool = False) -> dict:
        """Send one bot message; returns {msg_id, thread_id, status, ...}.

        Raises BotMessageError for agent-level failures (unknown agent →
        404, degraded recipient → 503). Depth/rate caps never raise: the
        message is STORED with a dropped status and returned as such.

        ``depth`` is normally hub-computed (see module docstring); the hub
        passes it explicitly only for auto-generated result replies, which
        reuse the triggering message's depth.
        """
        store = self._store()
        if store is None:
            raise BotMessageError("run store unavailable", 503)
        if kind not in BOT_MSG_KINDS:
            raise BotMessageError(
                f"kind must be one of {', '.join(BOT_MSG_KINDS)}", 400
            )
        body = str(body).strip()
        if not body:
            raise BotMessageError("body required (non-empty string)", 400)
        if len(body) > 4000:
            raise BotMessageError("body too long (max 4000 chars)", 400)
        for aid in (from_agent, to_agent):
            try:
                self.registry.get_agent(aid)
            except KeyError as exc:
                raise BotMessageError(f"agent not found: {aid}", 404) from exc
        thread_id = str(thread_id or "").strip() or uuid.uuid4().hex

        # Depth: hub-computed (bots cannot spoof it). A reply increments the
        # sender's own chain; a result reuses the triggering depth.
        if depth is None:
            depth = store.bot_message_depth(from_agent, thread_id) + 1

        status = "delivered"
        reason = None
        if depth > DEPTH_MAX:
            status, reason = "dropped_depth", (
                f"depth {depth} exceeds fleet cap {DEPTH_MAX}; "
                "the chain would not terminate"
            )
        elif not self._limiter.allow(to_agent):
            status, reason = "dropped_rate", (
                f"recipient {to_agent} exceeded {RATE_MAX} bot messages / "
                f"{int(RATE_WINDOW_S)}s"
            )
        elif not auto and kind in ("message", "handoff"):
            # A degraded recipient must fail READABLY (503) rather than
            # queue a turn that will 503 anyway. Auto results are
            # informational and must never wedge the worker.
            try:
                bridge = self._sessions().get_or_create_session(to_agent)
                st = getattr(bridge, "status", lambda: {})()
                if st.get("degraded"):
                    raise BotMessageError(
                        f"agent degraded: {st['degraded']}", 503
                    )
            except KeyError as exc:
                raise BotMessageError(f"agent not found: {to_agent}", 404) from exc

        run_id: str | None = None
        if status == "delivered":
            # UNIFORM delivery: a delivered message becomes a turn on the
            # recipient — kind=result included — queued behind its current
            # work like any prompt. That is how an IDLE delegator wakes up
            # when its worker reports back (it gets a turn whose prompt is
            # the result body); a RUNNING delegator finds it queued. A
            # result-driven run never auto-sends another result (see
            # run_terminal), so result chains always terminate. A handoff
            # additionally records the delegator's CURRENT run as parent so
            # the delegation graph is a navigable tree.
            parent = None
            if kind == "handoff":
                parent = self._current_run_id(from_agent)
            try:
                run_id = store.create_run(
                    to_agent, body, remote=False,
                    source=f"bot:{from_agent}",
                    from_agent=from_agent, thread_id=thread_id,
                    run_kind=kind, parent_run_id=parent,
                )
                store.add_message(run_id, to_agent, "user", body)
                bridge = self._sessions().get_or_create_session(to_agent)
                if bridge is not None:
                    bridge.store = store  # same binding the prompt handler uses
                    bridge.prompt(
                        body, remote=False, run_id=run_id,
                        from_agent=from_agent, thread_id=thread_id,
                        run_kind=kind,
                    )
            except KeyError as exc:
                raise BotMessageError(f"agent not found: {to_agent}", 404) from exc
            except RuntimeError as exc:
                # Bridge closed mid-DELETE: the row exists; abandon it.
                try:
                    store.finish_run(run_id, "abandoned", error=str(exc)[:200])
                except Exception:  # noqa: BLE001
                    pass
                raise BotMessageError(str(exc)[:200], 409) from exc

        msg = store.store_bot_message(
            from_agent, to_agent, body, thread_id, kind, depth,
            status=status, run_id=run_id,
        )
        if run_id and status == "delivered":
            try:
                store.set_bot_message_run(msg["msg_id"], run_id)
            except Exception:  # noqa: BLE001
                pass
        self._emit_bot_message(msg)
        out = {
            "msg_id": msg["msg_id"], "thread_id": thread_id,
            "status": status, "kind": kind, "depth": depth,
        }
        if run_id:
            out["run_id"] = run_id
        if reason:
            out["reason"] = reason
        return out

    def _current_run_id(self, agent_id: str) -> str | None:
        """The delegator's live run (the parent of a handoff child), if any."""
        try:
            bridge = self._sessions().get_or_create_session(agent_id)
            return getattr(bridge, "current_run_id", None)
        except Exception:  # noqa: BLE001 — parent link is best-effort
            return None

    def _emit_bot_message(self, msg: dict) -> None:
        """Durable fleet-stream event for one stored bot message."""
        store = self._store()
        if store is None:
            return
        try:
            store.record_event(
                msg["to_agent"],
                msg["run_id"] or "",
                {
                    "type": "bot_message",
                    "msg_id": msg["msg_id"],
                    "from_agent": msg["from_agent"],
                    "to_agent": msg["to_agent"],
                    "thread_id": msg["thread_id"],
                    "body": msg["body"][:500],
                    "kind": msg["kind"],
                    "depth": msg["depth"],
                    "status": msg["status"],
                },
            )
        except Exception:  # noqa: BLE001 — the message row is already durable
            pass

    # ------------------------------------------------------------------
    # Auto-result (hub-deterministic return path of delegation)
    # ------------------------------------------------------------------

    def run_terminal(self, run_id: str, agent_id: str, from_agent: str | None,
                     thread_id: str | None, run_kind: str, state: str,
                     summary: str) -> None:
        """A bot-driven run reached a terminal state: report back to whoever
        asked, as a kind=result message in the same thread.

        Fires ONLY for message/handoff runs — a run created FROM a result
        never sends another result, so result chains always terminate. The
        result keeps the triggering message's depth. Never raises: the
        worker must not die because a reply was dropped.
        """
        if not from_agent or run_kind not in ("message", "handoff"):
            return
        store = self._store()
        if store is None:
            return
        depth = store.message_run_depth(run_id) or 1
        body = f"[{state}] {summary}"[:500] if summary else f"[{state}]"
        try:
            self.send(
                agent_id, from_agent, body, thread_id=thread_id,
                kind="result", depth=depth, auto=True,
            )
        except BotMessageError as exc:
            print(
                f"[vertus] auto-result from {agent_id} to {from_agent} "
                f"failed: {exc}",
                file=__import__("sys").stderr,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"[vertus] auto-result failed: {exc}",
                  file=__import__("sys").stderr)

    # ------------------------------------------------------------------
    # Reads (thin store wrappers for the HTTP layer)
    # ------------------------------------------------------------------

    def list_messages(self, agent_id: str | None = None,
                      thread_id: str | None = None, unread: bool = False,
                      limit: int = 100, before: float | None = None) -> list[dict]:
        return self._store().list_bot_messages(
            agent_id=agent_id, thread_id=thread_id, unread=unread,
            limit=limit, before=before,
        )

    def list_threads(self, limit: int = 100) -> list[dict]:
        return self._store().list_threads(limit=limit)

    def mark_thread_read(self, thread_id: str) -> int:
        return self._store().mark_thread_read(thread_id)