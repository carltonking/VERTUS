"""Routines: scheduled and triggered work, per agent, run by the hub itself.

The whole point of a routine is work that happens while nobody is watching,
so every policy decision here is about bounding what an unattended bot can
do — see MISSED-FIRE, DEGRADED, THRESHOLD, and NEVER-CONCURRENT below.

Schedule representation
-----------------------
``schedule`` is a JSON object in exactly one of three shapes (parsing and
next-fire math live in the pure module routine_schedule.py):

    {"interval_s": N}                          every N seconds from the last fire
    {"cron": "M H DOM MON DOW", "tz": "IANA"}  wall-clock recurring (5-field cron)
    {"at": "<ISO 8601>", "tz": "IANA"}         one-shot; disabled after it fires

This reverses an earlier "intervals only, one syntax never two" decision.
That decision held while routines were fleet plumbing ("poll every N
minutes"); it stopped holding when the user asked for VERTUS to be
proactive on THEIR clock — a morning brief at 08:00, check-ins during the
day, memory consolidation at 03:00, "remind me tomorrow at 9". None of
those is expressible as an interval: an interval drifts with every
restart and fire, and a laptop that slept through 08:00 has no idea when
"08:00" was. So wall-clock schedules are user-requested, not speculative.
The cost is contained: the cron dialect is small (no names, no macros, no
seconds — see routine_schedule), it is stdlib-only (zoneinfo), and DST is
handled in one tested place. Intervals stay fully supported and behave
exactly as before. ``tz`` is optional; absent = the Mac's current local
zone, resolved at compute time.

interval_s must be an integer >= 30s at the API (MIN_INTERVAL_S); tests use
the internal store path to go faster — NEVER-CONCURRENT bounds the damage
of a fast interval to one in-flight turn, but 30s keeps a mis-set routine
from becoming a token-burn footgun. A cron cannot fire more than once a
minute by construction, so it has no extra floor.

ONE-SHOT completion: when an ``at`` routine fires successfully there is no
next time, so next_run_at is cleared (NULL) and the routine is disabled
through the normal disable path, emitting ``routine_disabled`` with
``"completed": true`` and reason "one-shot completed". The row and its run
history stay (a reminder that fired is a fact, not garbage); re-enabling it
alone does nothing until a new schedule is PATCHed, because nothing is due.
A failed/skipped fire does NOT complete it — it is retried on the RETRY
BACKOFF below and the normal THRESHOLD policy applies.

RE-ENABLE: turning a disabled routine back on (PATCH enabled false -> true)
re-arms it from NOW — the next future occurrence (interval: now + N; cron:
the next matching wall time; at: its instant if still ahead, else nothing,
so a past one-shot stays completed until a new ``at`` is PATCHed). The
next_run_at it carried while disabled is stale by however long it was off,
and honoring it would fire the moment the user flips the switch.

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
slides next_run_at to the next occurrence strictly after NOW (interval:
now + interval; cron: the next matching wall time; at: none -> completed).
A laptop sleeping 10 hours therefore yields exactly one catch-up run —
never 40, and never a backlog of every missed 08:00. This is the least
surprising bound, and the next fire is a full period away.

STALENESS (wall-clock kinds only): a cron or one-shot catch-up runs only if
the most recent missed occurrence is within CATCH_UP_STALE_S (2 hours) of
now. Older than that, the fire is dropped — a cron is armed for its next
occurrence, a one-shot is disabled with reason "missed" (not "completed":
it never ran). A wall-clock schedule is a promise about WHEN: a "good
morning" brief delivered at 21:00 after a day asleep is wrong, not late.
"Most recent" matters: an hourly cron after 10 hours down still runs once,
because its 17:00 occurrence is 45 minutes old even if its 08:00 one is
not. 2 hours covers a lid closed through a commute or a lunch break and
excludes "the whole morning". Intervals keep the plain run-once catch-up:
they promise a cadence, not a time of day. The check runs on every tick,
not only at boot, so it covers waking from sleep with the hub still alive
(and a run blocked for more than the window by its own in-flight turn —
see NEVER-CONCURRENT — likewise yields to the next occurrence).

DEGRADED: a fire targeting an agent whose gateway is degraded is skipped
and increments failure_count (the run row would 503 anyway; queuing it
would just store a doomed run). A fire targeting a deleted agent disables
the routine outright.

RETRY BACKOFF: a failed scheduled fire (degraded gateway, delivery or
create failure) is retried at now + RETRY_BASE_S * 2**(failures-1), capped
at RETRY_MAX_S — 60s, 120s, 240s ... 15 min — and never later than the
schedule's next regular occurrence (cron/interval; a one-shot has none).
Without it next_run_at stays in the past, the 1s tick refires every
second, and THRESHOLD disables a routine within ~3 seconds of a gateway
blip — long before a restarting gateway is back. With it, the three
strikes are minutes apart, which is what "three in a row is a broken
routine" meant. Only a routine that was actually DUE is pushed back: a
failed manual run or trigger fire of a routine not yet due leaves its
schedule alone (pulling it earlier would add a fire).

THRESHOLD: failure_count >= 3 disables the routine and emits
``routine_disabled``. 3 = one flake is transient (model/gateway hiccup),
two is bad luck, three in a row is a broken routine — and disabling is
loud (event + client UI) so recovery is a deliberate human act.

NEVER-CONCURRENT: before firing, the manager checks the store for an
in-flight run (state queued|running) carrying this routine_id and skips if
found — a routine can never fire while its own previous turn is still
alive. The due time is NOT advanced on a skip, so the routine re-fires as
soon as the in-flight turn ends: cadence is \"interval measured from fire,
never overlapping\". A skip is not a failure: it writes nothing, emits
nothing and leaves failure_count alone, so a long turn costs one indexed
read per tick and never trips THRESHOLD or the retry backoff.

Threading
---------
One manager thread owns ALL fires (ticks, the boot catch-up, and trigger
checks alike), so two fires can never race each other. ``catch_up()`` hands
its pass to that thread when it is running; hub boot constructs the manager
with autostart=False and calls ``start()`` only after seeding and catch-up,
so nothing ticks against a half-booted hub (store listener unset, previous
life's runs not yet marked interrupted). The store's event listener runs on the
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

try:
    import routine_schedule  # type: ignore
    from routine_schedule import RoutineValidationError  # type: ignore  # re-exported
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import routine_schedule  # type: ignore
    from .routine_schedule import RoutineValidationError  # type: ignore

log = logging.getLogger("vertus.routines")

DEFAULT_TICK_S = 1.0
# External callers (the HTTP API) cannot schedule faster than every 30s —
# sub-30s intervals are token-burn footguns and exist only for tests, which
# bypass the parser entirely by creating routine rows directly on the store
# (the internal path: store.create_routine + RoutineManager.arm).
MIN_INTERVAL_S = routine_schedule.MIN_INTERVAL_S
FAILURE_THRESHOLD = 3
# RETRY BACKOFF: first retry 60s after a failed scheduled fire, doubling,
# never more than 15 min apart (and never past the next regular occurrence).
RETRY_BASE_S = 60.0
RETRY_MAX_S = 15 * 60.0
# STALENESS: a missed cron/at occurrence older than this is dropped, not
# caught up (see MISSED-FIRE). Intervals have no staleness window.
CATCH_UP_STALE_S = 2 * 60 * 60.0

TERMINAL_EVENT_TYPES = ("done", "error", "cancelled", "timeout")
TRIGGER_TYPES = ("run_completed", "bot_message")


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
        self._thread: Optional[threading.Thread] = None
        if autostart:
            self.start()

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

    def start(self) -> None:
        """Start the manager thread (idempotent). Hub boot calls this after
        seeding and catch_up(), so the first tick sees a fully booted hub."""
        if self._thread is not None:
            return
        self._thread = threading.Thread(
            target=self._loop, daemon=True, name="fleet-routines"
        )
        self._thread.start()

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
        the missed-fire policy. Harmless when nothing is due.

        When the manager thread is running the pass is queued onto it and
        waited for, never run here: a boot-thread pass concurrent with a
        thread tick could both read the routine as due and both fire it."""
        thread = self._thread
        if thread is None or not thread.is_alive():
            self._tick()
            return
        done = threading.Event()
        self._queue.put((self._catch_up_on_thread, done))
        done.wait(timeout=30)

    def _catch_up_on_thread(self, done: threading.Event) -> None:
        try:
            self._tick()
        finally:
            done.set()

    # ------------------------------------------------------------------
    # Public API (thread-safe entry points)
    # ------------------------------------------------------------------

    def arm(self, routine_id: str, schedule: dict | None) -> None:
        """Arm a schedule: next fire time = the first occurrence strictly
        after now (interval: now + N; cron: next matching wall time; at: the
        instant itself). Called on create and on schedule change (PATCH);
        the routine is not due until armed."""
        store = self._store()
        if store is None or not schedule:
            return
        try:
            store.set_routine_next(
                routine_id, routine_schedule.next_fire(schedule, self._now())
            )
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
                if self._drop_if_stale(routine):
                    continue
                self._fire(routine)
            except Exception:  # noqa: BLE001
                log.exception("routine %s fire failed", routine["routine_id"])

    def _drop_if_stale(self, routine: dict) -> bool:
        """STALENESS (see MISSED-FIRE): True when a due cron/at routine's most
        recent missed occurrence is older than CATCH_UP_STALE_S — the fire is
        dropped and the routine armed for its next occurrence (cron) or
        disabled as missed (one-shot). Intervals are never stale."""
        schedule = _load_schedule(routine.get("schedule"))
        kind = routine_schedule.kind_of(schedule)
        if kind not in ("cron", "at"):
            return False
        now = self._now()
        try:
            # Any occurrence inside (now - window, now] is a recent miss.
            recent = routine_schedule.next_fire(schedule, now - CATCH_UP_STALE_S)
        except (RoutineValidationError, ValueError, TypeError):
            return False  # corrupt row: let _fire's own handling decide
        if recent is not None and recent <= now:
            return False
        store = self._store()
        rid = routine["routine_id"]
        if kind == "cron":
            try:
                nxt = routine_schedule.next_fire(schedule, now)
            except (RoutineValidationError, ValueError, TypeError):
                nxt = None
            store.set_routine_next(rid, nxt)
            log.info("routine %s: missed occurrence older than %ds dropped; "
                     "next fire %s", rid, int(CATCH_UP_STALE_S), nxt)
            return True
        store.set_routine_next(rid, None)
        self._disable(rid, "one-shot missed: hub was not running at its time "
                           f"(more than {int(CATCH_UP_STALE_S // 3600)}h ago)")
        return True

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
            # Use unattended session for routines - they are scheduled work
            # that should not block on user input.
            bridge = self._sessions().get_or_create_unattended_session(aid)
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
            # Routines run unattended by default: they are scheduled work that
            # should not block on user input. The bridge's session kwargs are
            # resolved with unattended=True so the gateway suppresses approval
            # prompts for this turn's session.
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

        # Success: advance the schedule to the next occurrence strictly after
        # NOW (MISSED-FIRE: a catch-up fire never leaves a backlog behind it)
        # and clear failure history.
        completed = False
        if routine.get("schedule"):
            try:
                schedule = json.loads(routine["schedule"])
            except (ValueError, TypeError):
                schedule = None
            kind = routine_schedule.kind_of(schedule if isinstance(schedule, dict) else None)
            try:
                nxt = routine_schedule.next_fire(schedule, self._now()) if kind else None
            except (RoutineValidationError, ValueError, TypeError):
                nxt = None
            if kind == "at" and nxt is None:
                # One-shot fired: nothing is ever due again (see ONE-SHOT).
                store.mark_routine_fired(rid, run_id, None)
                completed = True
            elif nxt is not None:
                store.mark_routine_fired(rid, run_id, nxt)
            else:
                store.mark_routine_fired(rid, run_id, self._now() + 3600)  # corrupt row
        else:
            store.mark_routine_fired(rid, run_id, self._now() + 3600)  # no-op arm
        self._emit({
            "type": "routine_fired",
            "routine_id": rid,
            "agent_id": aid,
            "run_id": run_id,
            "manual": manual,
        })
        if completed:
            self._disable(rid, "one-shot completed", completed=True)
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
            return
        self._back_off(routine, count)

    def _back_off(self, routine: dict, count: int) -> None:
        """RETRY BACKOFF: push a DUE routine's next attempt out after a
        failure. A routine not yet due (manual run, trigger fire) keeps its
        schedule — moving it would only ever add a fire."""
        now = self._now()
        due_at = routine.get("next_run_at")
        if due_at is None or due_at > now:
            return
        delay = min(RETRY_BASE_S * (2 ** max(count - 1, 0)), RETRY_MAX_S)
        retry = now + delay
        schedule = _load_schedule(routine.get("schedule"))
        if routine_schedule.kind_of(schedule) in ("cron", "interval"):
            try:
                regular = routine_schedule.next_fire(schedule, now)
            except (RoutineValidationError, ValueError, TypeError):
                regular = None
            if regular is not None:
                retry = min(retry, regular)
        try:
            self._store().set_routine_next(routine["routine_id"], retry)
        except Exception:  # noqa: BLE001
            log.exception("routine %s retry arm failed", routine["routine_id"])

    def _disable(self, routine_id: str, reason: str,
                 completed: bool = False) -> None:
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
        event = {
            "type": "routine_disabled",
            "routine_id": routine_id,
            "agent_id": routine["agent_id"],
            "reason": reason[:300],
        }
        if completed:
            # Distinguishes "done, as intended" from "broken, needs a human".
            event["completed"] = True
        self._emit(event)

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

def parse_schedule(raw, now: float | None = None) -> dict | None:
    """Validate a schedule payload; None = trigger-only routine. Accepts
    {"interval_s": N} | {"cron": ..., "tz"?} | {"at": ..., "tz"?} — see
    routine_schedule.parse. Raises RoutineValidationError."""
    return routine_schedule.parse(raw, now=now)


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


def _load_schedule(raw) -> dict | None:
    """A stored (JSON-string) schedule as a dict; None if absent/corrupt."""
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except (ValueError, TypeError):
        return None
    return value if isinstance(value, dict) else None


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