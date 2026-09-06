"""Routines: scheduled and triggered work, per agent, run by the hub itself.

The whole point of a routine is work that happens while nobody is watching,
so every policy decision here is about bounding what an unattended bot can
do — see MISSED-FIRE, DEGRADED, THRESHOLD, and NEVER-CONCURRENT below.

Schedule representation
-----------------------
``schedule`` is a JSON object ``{"interval_s": N}`` — interval seconds, NOT
cron. Justification: the Python stdlib has no cron parser (adding a parser
dependency for this is not worth it), intervals are fully deterministic and
testable, and the fleet's runs are irregular-length tasks where wall-clock
alignment (\"at 9am\") buys nothing over \"every N seconds\". One syntax, never
two. N must be a positive integer; sub-60s values exist for tests and demos
— nothing prevents them because the NEVER-CONCURRENT rule bounds the damage
of a fast interval to one in-flight turn.

Trigger vocabulary (``trigger`` JSON; keep it SMALL and enumerable — this is
deliberately not a rules engine):
    {\"type\": \"run_completed\", \"agent_id\": \"X\"}
        fire when a run of agent X reaches a terminal state
    {\"type\": \"bot_message\", \"from_agent\": \"X\", \"thread_id\": null}
        fire when a delivered bot_message arrives; from_agent/thread_id are
        optional filters (null/absent = any)
A routine may carry schedule AND trigger (either can fire it), or just one.

MISSED-FIRE (hub downtime): run once on catch-up. When the hub boots (or
wakes from sleep) and finds next_run_at in the past, it fires ONCE and
slides next_run_at to now + interval. A laptop sleeping 10 hours therefore
yields exactly one catch-up run — never 40. This is the least surprising
bound, and the next fire is a full interval away.

DEGRADED: a fire targeting an agent whose gateway is degraded is skipped
and increments failure_count (the run row would 503 anyway; queuing it
would just store a doomed run). A fire targeting a deleted agent disables
the routine outright.

THRESHOLD: failure_count >= 3 disables the routine and emits
``routine_disabled``. 3 = one flake is transient (model/gateway hiccup),
two is bad luck, three in a row is a broken routine — and disabling is
loud (event + client UI) so recovery is a deliberate human act.

NEVER-CONCURRENT: before firing, the manager checks the store for an
in-flight run (state queued|running) carrying this routine_id and skips if
found — a routine can never fire while its own previous turn is still
alive. The due time is NOT advanced on a skip, so the routine re-fires as
soon as the in-flight turn ends: cadence is \"interval measured from fire,
never overlapping\".

Threading
---------
One manager thread owns ALL fires (ticks and trigger checks alike), so two
fires can never race each other. The store's event listener runs on the
STORE WRITER thread: on_event() only pushes a check onto the manager's
queue (put_nowait, never blocking the writer) — all store writes happen on
the manager thread. This mirrors the messenger's writer/worker split.
"""

from __future__ import annotations

import json
import logging
import queue
import threading
import time
from typing import Callable, Optional

log = logging.getLogger("vertus.routines")

DEFAULT_TICK_S = 1.0
MIN_INTERVAL_S = 1
FAILURE_THRESHOLD = 3

TERMINAL_EVENT_TYPES = ("done", "error", "cancelled", "timeout")
TRIGGER_TYPES = ("run_completed", "bot_message")


class RoutineValidationError(ValueError):
    """A routine payload violates the schema (400 on the wire)."""


class RoutineManager:
    """One fleet-wide routine scheduler. Not thread-safe externally beyond
    on_event()/fire_now()/stop(), which hand work to the manager thread."""

    def __init__(self, store, registry, sessions_provider: Callable,
                 tick_s: float = DEFAULT_TICK_S,
                 now_fn: Optional[Callable[[], float]] = None,
                 autostart: bool = True) -> None:
        self._store = store
        self.registry = registry
        # sessions_provider() -> SessionManager; fires fetch the bridge and
        # enqueue through it exactly like BotMessenger does (same pattern,
        # same degraded/closed semantics).
        self._sessions = sessions_provider
        self._tick_s = tick_s
        self._now = now_fn or time.time
        self._queue: queue.Queue = queue.Queue()
        self._stop_event = threading.Event()
        if autostart:
            self._thread = threading.Thread(
                target=self._loop, daemon=True, name="fleet-routines"
            )
            self._thread.start()
        else:
            self._thread = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def _loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                item = self._queue.get(timeout=self._tick_s)
            except queue.Empty:
                item = None
            if item is None:
                self._tick()
            elif item is self._STOP:
                break
            else:
                self._handle_item(item)

    _STOP = object()

    def stop(self) -> None:
        self._stop_event.set()
        try:
            self._queue.put_nowait(self._STOP)
        except queue.Full:
            pass
        if self._thread is not None:
            self._thread.join(timeout=5)

    def catch_up(self) -> None:
        """One immediate scheduler pass at hub boot: routines whose next_run_at
        is in the past (hub was down / laptop slept) fire exactly ONCE here —
        the missed-fire policy. Harmless when nothing is due."""
        self._tick()

    # ------------------------------------------------------------------
    # Public API (thread-safe entry points)
    # ------------------------------------------------------------------

    def arm(self, routine_id: str, schedule: dict | None) -> None:
        """Arm a schedule: next fire time = now + interval. Called on create
        and on schedule change (PATCH); the routine is not due until armed."""
        store = self._store()
        if store is None or not schedule:
            return
        try:
            store.set_routine_next(routine_id, self._now() + int(schedule["interval_s"]))
        except Exception:  # noqa: BLE001
            log.exception("arm routine %s failed", routine_id)

    def fire_now(self, routine_id: str) -> dict:
        """POST /api/routines/<id>/run — fire immediately, ignoring schedule.

        Serialized through the manager queue so a manual run can never race
        a tick. Returns {fired, reason, run_id, routine} — the HTTP layer
        maps the outcome to a status code.
        """
        out: dict = {}
        done = threading.Event()
        self._queue.put((self._fire_now, routine_id, out, done))
        done.wait(timeout=30)
        return out

    def on_event(self, envelope: dict) -> None:
        """Called by the store's event listener (WRITER thread). Never
        blocks, never writes: just hands a trigger scan to the manager."""
        etype = envelope.get("type")
        if etype in TERMINAL_EVENT_TYPES:
            payload = {"type": "run_completed", "agent_id": envelope.get("agent_id")}
        elif etype == "bot_message":
            payload = {
                "type": "bot_message",
                "from_agent": envelope.get("from_agent"),
                "thread_id": envelope.get("thread_id"),
                "status": envelope.get("status"),
            }
        else:
            return
        try:
            self._queue.put_nowait((self._scan_triggers, payload))
        except queue.Full:
            log.warning("routine trigger queue full; dropped event %s", envelope.get("seq"))

    # ------------------------------------------------------------------
    # Manager-thread work
    # ------------------------------------------------------------------

    def _handle_item(self, item) -> None:
        fn, *args = item
        try:
            fn(*args)
        except Exception:  # noqa: BLE001 — one bad routine must not kill the loop
            log.exception("routine manager work item failed")

    def _tick(self) -> None:
        """Scheduler pass: catch-up + due schedule routines."""
        store = self._store()
        if store is None:
            return
        try:
            due = store.routines_due(self._now())
        except Exception:  # noqa: BLE001
            log.exception("routines_due query failed")
            return
        for routine in due:
            try:
                self._fire(routine)
            except Exception:  # noqa: BLE001
                log.exception("routine %s fire failed", routine["routine_id"])

    def _scan_triggers(self, payload: dict) -> None:
        """One store event arrived: fire every enabled routine whose trigger
        matches, subject to the same active-run/degraded gates as a tick."""
        store = self._store()
        if store is None:
            return
        try:
            routines = store.list_routines()
        except Exception:  # noqa: BLE001
            log.exception("list_routines failed in trigger scan")
            return
        for routine in routines:
            if not routine.get("enabled"):
                continue
            trigger = _parse_trigger(routine.get("trigger"))
            if trigger is None:
                continue
            if _trigger_matches(trigger, payload):
                try:
                    self._fire(routine)
                except Exception:  # noqa: BLE001
                    log.exception("routine %s trigger fire failed", routine["routine_id"])

    def _fire_now(self, routine_id: str, out: dict, done: threading.Event) -> None:
        try:
            store = self._store()
            if store is None:
                out.update({"fired": False, "reason": "run store unavailable"})
                return
            routine = store.get_routine(routine_id)
            if routine is None:
                out.update({"fired": False, "reason": "not found"})
                return
            if not routine.get("enabled"):
                out.update({"fired": False, "reason": "routine disabled"})
                return
            result = self._fire(routine, manual=True)
            out.update(result)
        finally:
            done.set()

    def _fire(self, routine: dict, manual: bool = False) -> dict:
        """Fire one routine NOW. Runs on the manager thread only. Returns
        {fired, reason, run_id}. ``manual`` skips the due check (fire now
        ignores schedule) but never the safety gates."""
        store = self._store()
        if store is None:
            return {"fired": False, "reason": "run store unavailable"}
        rid = routine["routine_id"]
        aid = routine["agent_id"]

        # NEVER-CONCURRENT: an in-flight run of this routine blocks a new fire.
        in_flight = store.active_routine_run(rid)
        if in_flight:
            # Deliberately NOT advancing next_run_at: when the in-flight turn
            # ends, the routine is still due and fires (cadence = from fire).
            return {"fired": False, "reason": f"already running ({in_flight[:8]})"}

        # Agent existence: a deleted agent's routines are disabled by the
        # DELETE handler, but a race (delete between check and fire) must not
        # leave a queued run for a ghost. Disabling beats erroring.
        try:
            self.registry.get_agent(aid)
        except KeyError:
            self._disable(rid, f"agent {aid} no longer exists")
            return {"fired": False, "reason": f"agent {aid} not found"}

        # DEGRADED: skip + failure_count (the run would 503 anyway).
        try:
            bridge = self._sessions().get_or_create_session(aid)
            st = getattr(bridge, "status", lambda: {})()
        except KeyError:
            self._disable(rid, f"agent {aid} no longer exists")
            return {"fired": False, "reason": f"agent {aid} not found"}
        if st.get("degraded"):
            self._record_failure(routine, f"agent degraded: {st['degraded']}")
            return {"fired": False, "reason": "agent degraded"}

        prompt = routine["prompt"]
        try:
            run_id = store.create_run(
                aid, prompt, remote=False,
                source=f"routine:{rid}", run_kind="routine", routine_id=rid,
            )
            store.add_message(run_id, aid, "user", prompt)
            bridge.store = store
            bridge.prompt(prompt, remote=False, run_id=run_id, run_kind="routine")
        except RuntimeError as exc:  # bridge closed mid-DELETE
            try:
                store.finish_run(run_id, "abandoned", error=str(exc)[:200])
            except Exception:  # noqa: BLE001
                pass
            self._record_failure(routine, f"delivery failed: {str(exc)[:120]}")
            return {"fired": False, "reason": f"delivery failed: {str(exc)[:120]}"}
        except Exception as exc:  # noqa: BLE001
            self._record_failure(routine, f"fire failed: {str(exc)[:120]}")
            return {"fired": False, "reason": f"fire failed: {str(exc)[:120]}"}

        # Success: advance the schedule (catch-up = one fire; the next fire
        # is a full interval away) and clear failure history.
        if routine.get("schedule"):
            try:
                interval = int(json.loads(routine["schedule"]).get("interval_s", 0))
            except (ValueError, TypeError, json.JSONDecodeError):
                interval = 0
            if interval > 0:
                store.mark_routine_fired(rid, run_id, self._now() + interval)
            else:
                store.mark_routine_fired(rid, run_id, self._now() + 3600)
        else:
            store.mark_routine_fired(rid, run_id, self._now() + 3600)  # no-op arm
        self._emit({
            "type": "routine_fired",
            "routine_id": rid,
            "agent_id": aid,
            "run_id": run_id,
            "manual": manual,
        })
        return {"fired": True, "run_id": run_id}

    def _record_failure(self, routine: dict, reason: str) -> None:
        """Increment consecutive failures; disable at the threshold."""
        store = self._store()
        if store is None:
            return
        rid = routine["routine_id"]
        try:
            count = store.bump_routine_failure(rid)
        except Exception:  # noqa: BLE001
            log.exception("bump_routine_failure failed")
            return
        self._emit({
            "type": "routine_skipped",
            "routine_id": rid,
            "agent_id": routine["agent_id"],
            "failure_count": count,
            "reason": reason[:300],
        })
        if count >= FAILURE_THRESHOLD:
            self._disable(rid, f"{count} consecutive failures: {reason[:120]}")

    def _disable(self, routine_id: str, reason: str) -> None:
        store = self._store()
        if store is None:
            return
        try:
            routine = store.get_routine(routine_id)
            if routine is None or not routine.get("enabled"):
                return  # idempotent: already disabled/removed
            store.set_routine_enabled(routine_id, False)
        except Exception:  # noqa: BLE001
            log.exception("disable routine %s failed", routine_id)
            return
        self._emit({
            "type": "routine_disabled",
            "routine_id": routine_id,
            "agent_id": routine["agent_id"],
            "reason": reason[:300],
        })

    def _emit(self, event: dict) -> None:
        store = self._store()
        if store is None:
            return
        try:
            store.record_event(event.get("agent_id", ""), event.get("run_id") or "", event)
        except Exception:  # noqa: BLE001 — never fatal; the routine row is the truth
            log.warning("routine event write failed: %s", event.get("type"))


# ----------------------------------------------------------------------
# Validation helpers (shared by the HTTP layer and tests)
# ----------------------------------------------------------------------

def parse_schedule(raw) -> dict | None:
    """Validate a schedule payload; None = trigger-only routine."""
    if raw is None:
        return None
    if not isinstance(raw, dict) or set(raw) != {"interval_s"}:
        raise RoutineValidationError("schedule must be {\"interval_s\": N}")
    interval = raw["interval_s"]
    if not isinstance(interval, int) or isinstance(interval, bool) or interval < MIN_INTERVAL_S:
        raise RoutineValidationError(
            f"schedule interval_s must be an integer >= {MIN_INTERVAL_S}"
        )
    return {"interval_s": interval}


def parse_trigger(raw) -> dict | None:
    """Validate a trigger payload; None = schedule-only routine."""
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise RoutineValidationError("trigger must be a JSON object or null")
    ttype = raw.get("type")
    if ttype not in TRIGGER_TYPES:
        raise RoutineValidationError(f"trigger type must be one of {TRIGGER_TYPES}")
    allowed = set(TRIGGER_TYPES)
    extra = set(raw) - allowed - {"type", "agent_id", "from_agent", "thread_id"}
    if extra:
        raise RoutineValidationError(f"unknown trigger keys: {sorted(extra)}")
    if ttype == "run_completed":
        agent_id = raw.get("agent_id")
        if not isinstance(agent_id, str) or not agent_id:
            raise RoutineValidationError("run_completed trigger requires agent_id")
        return {"type": "run_completed", "agent_id": agent_id}
    from_agent = raw.get("from_agent")
    thread_id = raw.get("thread_id")
    if from_agent is not None and not isinstance(from_agent, str):
        raise RoutineValidationError("bot_message from_agent must be a string or null")
    if thread_id is not None and not isinstance(thread_id, str):
        raise RoutineValidationError("bot_message thread_id must be a string or null")
    return {
        "type": "bot_message",
        "from_agent": from_agent,
        "thread_id": thread_id,
    }


def _parse_trigger(raw) -> dict | None:
    """Parse a stored (JSON-string) trigger defensively; None = no trigger."""
    if not raw:
        return None
    try:
        return parse_trigger(json.loads(raw))
    except (RoutineValidationError, ValueError, TypeError):
        return None


def _trigger_matches(trigger: dict, event: dict) -> bool:
    """Does a stored trigger match one wire event? Both are plain dicts."""
    if trigger["type"] == "run_completed":
        return bool(event.get("agent_id")) and event["agent_id"] == trigger["agent_id"]
    # bot_message
    if event.get("status") not in (None, "delivered"):
        return False  # dropped messages must not wake a bot
    if trigger.get("from_agent") and event.get("from_agent") != trigger["from_agent"]:
        return False
    if trigger.get("thread_id") and event.get("thread_id") != trigger["thread_id"]:
        return False
    return True