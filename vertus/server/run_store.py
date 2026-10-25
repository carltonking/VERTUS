"""Durable run history for the VERTUS fleet — SQLite, single-writer, replayable.

Why this exists: a turn's output currently lives only in live SSE subscriber
queues (per-bridge, in memory) and vanishes on disconnect. This module makes
every run event durable *before* it is fanned out, so a client can reconnect
with ``since=<seq>`` and replay exactly what it missed — no gap, no duplicate.

Storage
-------
Single SQLite database at ``~/.vertus/fleet.db`` (override with
``VERTUS_DB_PATH``). WAL mode so readers never block the writer. One
dedicated writer thread owns a single connection and processes a FIFO queue
of write operations; every public write submits an op and *waits for its
commit* before returning, so callers can uphold the durability rule:

    an event is committed to ``events`` BEFORE it is fanned out to clients.
    If the commit fails, the caller surfaces a run error and no event that
    isn't in the store ever reaches a subscriber.

Readers open their own short-lived connections (SQLite is fine with that
under WAL) — they never touch the writer's connection.

Schema
------
    runs(run_id TEXT PK, agent_id, prompt, remote INT, source, state,
         started_at REAL, ended_at REAL, error, gateway_respawns INT,
         created_at REAL)
         state in: queued|running|done|error|interrupted|abandoned|
                    cancelled|timeout
    events(seq INTEGER PK AUTOINCREMENT, run_id, agent_id, ts REAL,
           type TEXT, payload TEXT)   -- type: text|activity|done|error|cancelled
    messages(id INTEGER PK AUTOINCREMENT, run_id, agent_id, role TEXT,
             text TEXT, created_at REAL)     -- role: user|assistant
    bot_messages(msg_id TEXT PK, from_agent, to_agent, thread_id, body,
                 kind, depth INT, status, run_id, created_at, read_at)
                 kind in: message | handoff | result
                 status in: delivered | dropped_depth | dropped_rate
    threads(thread_id TEXT PK, subject, participants JSON, created_at,
            last_message_at)

runs additionally carry bot-to-bot attribution (added by _migrate):
    from_agent, thread_id, run_kind (user|message|handoff|result),
    parent_run_id, routine_id (runs produced by a routine).
    routines(routine_id TEXT PK, agent_id, name, prompt,
             schedule JSON|null, trigger JSON|null, enabled, created_at,
             last_run_at, last_run_id, next_run_at, failure_count)
    -- schedule/trigger policy lives in fleet_routines.py; the store only
       persists state.

``events.seq`` is the fleet-wide monotonic cursor: ONE sequence across all
agents, so ``since=`` replay on the fleet stream is a single ordered cursor.
``payload`` holds the wire event minus the envelope columns (type, agent_id,
run_id, seq, ts are columns); replay rehydrates the exact envelope.

Text deltas are stored one row per delta (the durable transcript), and the
assembled assistant text is additionally folded into one ``messages`` row at
turn end so history reads are one row per message instead of thousands.

Durability / sync choice: ``synchronous=NORMAL`` under WAL — committed
transactions survive a process crash (what recovery cares about); the last
fraction of a second can be lost on OS power failure. WAL checkpoints are
left to SQLite; ``prune_events`` runs a PASSIVE checkpoint after deleting.

VACUUM policy: none automatic. Events older than the TTL are deleted by
``prune_events``; WAL reuses freed pages, so the file only grows when the
checkpoint lags, and a ``VACUUM`` (file-shrinking, locking) is deliberately
not scheduled — runs/messages are never pruned and dominate long-term size.
"""

from __future__ import annotations

import json
import os
import queue
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Callable, Optional

# Dual import like vertus_server.py: plain for script-dir invocation, package-relative for -m.
try:
    import vertus_paths  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore

# DB path resolution lives in vertus_paths.fleet_db_path (VERTUS_DB_PATH →
# VERTUS_ROOT → ~/.vertus/fleet.db); the constructor default is call-time so
# env changes are honored without module reloads. No other module resolves
# the DB path on its own (env-divergence sweep).

RUN_STATES = (
    "queued",
    "running",
    "done",
    "error",
    "interrupted",
    "abandoned",
    "cancelled",
    "timeout",
)
TERMINAL_STATES = (
    "done",
    "error",
    "interrupted",
    "abandoned",
    "cancelled",
    "timeout",
)
WIRE_EVENT_TYPES = ("text", "activity", "done", "error", "cancelled")

# SQL fragment shared by finish_run / recover: a run is terminal exactly
# when its state is in TERMINAL_STATES — keep the two in lockstep.
_TERMINAL_SQL = ",".join(f"'{s}'" for s in TERMINAL_STATES)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS runs(
  run_id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  prompt TEXT NOT NULL,
  remote INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL,
  started_at REAL,
  ended_at REAL,
  error TEXT,
  gateway_respawns INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS events(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  ts REAL NOT NULL,
  type TEXT NOT NULL,
  payload TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  role TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_agent_seq ON events(agent_id, seq);
CREATE INDEX IF NOT EXISTS idx_events_run_seq  ON events(run_id, seq);
CREATE INDEX IF NOT EXISTS idx_messages_agent_created ON messages(agent_id, created_at);
CREATE INDEX IF NOT EXISTS idx_runs_created ON runs(created_at);
CREATE INDEX IF NOT EXISTS idx_runs_agent_state ON runs(agent_id, state);
CREATE TABLE IF NOT EXISTS bot_messages(
  msg_id TEXT PRIMARY KEY,
  from_agent TEXT NOT NULL,
  to_agent TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  body TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'message',
  depth INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'delivered',
  run_id TEXT,
  created_at REAL NOT NULL,
  read_at REAL
);
CREATE TABLE IF NOT EXISTS threads(
  thread_id TEXT PRIMARY KEY,
  subject TEXT NOT NULL DEFAULT '',
  participants TEXT NOT NULL DEFAULT '[]',
  created_at REAL NOT NULL,
  last_message_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bot_messages_thread ON bot_messages(thread_id, created_at);
CREATE INDEX IF NOT EXISTS idx_bot_messages_to ON bot_messages(to_agent, created_at);
CREATE INDEX IF NOT EXISTS idx_bot_messages_thread_read ON bot_messages(thread_id, read_at);
CREATE INDEX IF NOT EXISTS idx_threads_last ON threads(last_message_at);
CREATE INDEX IF NOT EXISTS idx_bot_messages_run ON bot_messages(run_id);
CREATE TABLE IF NOT EXISTS approvals(
  approval_id TEXT PRIMARY KEY,
  run_id TEXT,
  agent_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target TEXT NOT NULL DEFAULT '',
  requested_at REAL NOT NULL,
  decided_at REAL,
  decision TEXT,
  decided_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_approvals_requested ON approvals(requested_at);
CREATE TABLE IF NOT EXISTS routines(
  routine_id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL,
  schedule TEXT,          -- NULL (trigger-only) or JSON {"interval_s": N}
  trigger TEXT,           -- NULL (schedule-only) or JSON {"type": ..., ...}
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL,
  last_run_at REAL,
  last_run_id TEXT,
  next_run_at REAL,
  failure_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_routines_agent ON routines(agent_id);
CREATE INDEX IF NOT EXISTS idx_routines_due ON routines(enabled, next_run_at);
"""


class RunStore:
    """Thread-safe durable run store. One writer thread; readers per-call."""

    def __init__(self, path: str | Path | None = None) -> None:
        self.path = Path(path or vertus_paths.fleet_db_path()).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.path), isolation_level=None)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.execute("PRAGMA busy_timeout=5000")
            conn.execute("PRAGMA wal_autocheckpoint=1000")
            conn.executescript(_SCHEMA)
            self._migrate(conn)
        finally:
            conn.close()
        self._queue: queue.Queue = queue.Queue()
        self._thread = threading.Thread(
            target=self._writer_loop, daemon=True, name="fleet-store-writer"
        )
        self._thread.start()
        self._stopped = False
        # Optional callback invoked BY THE WRITER THREAD after each event is
        # committed (never under the caller's lock). The hub uses it to push
        # committed envelopes to fleet-stream subscriber queues.
        self.listener: Optional[Callable[[dict], None]] = None

    @staticmethod
    def _migrate(conn: sqlite3.Connection) -> None:
        """Idempotent column/index migrations for PRE-EXISTING databases.

        ``_SCHEMA`` uses CREATE TABLE IF NOT EXISTS, which never adds
        columns to an existing runs table, so the bot-to-bot attribution
        columns must be ALTERed in here (SQLite has no IF NOT EXISTS for
        columns; PRAGMA table_info guards each one). Fresh databases are
        created by _SCHEMA without these columns and pick them up here too
        — the two paths must stay in lockstep with create_run().
        """
        cols = {row[1] for row in conn.execute("PRAGMA table_info(runs)")}
        if "from_agent" not in cols:
            conn.execute("ALTER TABLE runs ADD COLUMN from_agent TEXT")
        if "thread_id" not in cols:
            conn.execute("ALTER TABLE runs ADD COLUMN thread_id TEXT")
        if "run_kind" not in cols:
            conn.execute(
                "ALTER TABLE runs ADD COLUMN run_kind TEXT NOT NULL DEFAULT 'user'"
            )
        if "parent_run_id" not in cols:
            conn.execute("ALTER TABLE runs ADD COLUMN parent_run_id TEXT")
        if "routine_id" not in cols:
            conn.execute("ALTER TABLE runs ADD COLUMN routine_id TEXT")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_runs_parent ON runs(parent_run_id)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_runs_routine ON runs(routine_id)"
        )

    # ------------------------------------------------------------------
    # Writer plumbing
    # ------------------------------------------------------------------

    def _submit(self, fn: Callable[[sqlite3.Connection], None], out: dict) -> dict:
        """Run ``fn(conn)`` on the writer thread; wait for its commit.

        Raises the writer's exception on failure (after rollback) so callers
        can uphold store-before-fanout. ``out`` is a caller-owned dict the op
        fills with results; if it gains an ``_event`` key, the committed
        envelope is dispatched to ``listener`` right after commit.

        After ``stop()`` the writer thread is gone: submitting must FAIL FAST
        (RuntimeError) rather than enqueue onto a dead queue and hang the
        caller forever — a hung HTTP handler is worse than a 503.
        """
        if self._stopped:
            raise RuntimeError("run store is stopped")
        done = threading.Event()
        error: list[BaseException] = []
        self._queue.put((fn, out, done, error))
        done.wait()
        if error:
            raise error[0]
        return out

    def _writer_loop(self) -> None:
        conn = sqlite3.connect(str(self.path))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA busy_timeout=5000")
        try:
            while True:
                item = self._queue.get()
                if item is None:
                    break
                fn, out, done, error = item
                try:
                    fn(conn)
                    conn.commit()
                except BaseException as exc:  # noqa: BLE001
                    try:
                        conn.rollback()
                    except Exception:  # noqa: BLE001
                        pass
                    error.append(exc)
                finally:
                    done.set()
                # Listener dispatch happens on the WRITER thread after the
                # commit and after the waiting caller is released: the fleet
                # fan never delays a bridge's own store-before-fanout.
                event = out.get("_event")
                if not error and event is not None and self.listener is not None:
                    try:
                        self.listener(event)
                    except Exception:  # noqa: BLE001 — fanout must not kill the writer
                        pass
        finally:
            conn.close()

    def stop(self) -> None:
        """Flush and stop the writer thread (idempotent).

        After this, every _submit fails fast with RuntimeError so a stale
        reference to a stopped store can never hang a caller.
        """
        self._stopped = True
        if self._thread is None or not self._thread.is_alive():
            return
        self._queue.put(None)
        self._thread.join(timeout=10)
        self._thread = None  # type: ignore[assignment]

    # ------------------------------------------------------------------
    # Reads (own connection per call)
    # ------------------------------------------------------------------

    def _read(self, fn: Callable[[sqlite3.Connection], object]):
        conn = sqlite3.connect(str(self.path))
        conn.row_factory = sqlite3.Row
        try:
            return fn(conn)
        finally:
            conn.close()

    def latest_seq(self) -> int:
        """Highest committed event seq (0 when the store is empty)."""
        row = self._read(
            lambda c: c.execute("SELECT COALESCE(MAX(seq), 0) AS s FROM events").fetchone()
        )
        return int(row["s"])

    def events_after(self, since: int, agent_id: str | None = None,
                     run_id: str | None = None, limit: int | None = None) -> list[dict]:
        """Committed envelopes with seq > since, ascending, optional filters.

        seq is the fleet-wide cursor, so a ``since`` snapshot is valid across
        all agents: reconnecting a fleet stream with since=N never skips an
        event from an agent that started mid-drain.
        """
        sql = "SELECT seq, run_id, agent_id, ts, type, payload FROM events WHERE seq > ?"
        params: list = [int(since)]
        if agent_id is not None:
            sql += " AND agent_id = ?"
            params.append(agent_id)
        if run_id is not None:
            sql += " AND run_id = ?"
            params.append(run_id)
        sql += " ORDER BY seq ASC"
        if limit is not None:
            sql += " LIMIT ?"
            params.append(int(limit))
        rows = self._read(lambda c: c.execute(sql, params).fetchall())
        return [self._envelope(r) for r in rows]

    def last_event_of_run(self, run_id: str) -> dict | None:
        """The highest-seq committed event of a run (for terminal checks)."""
        rows = self._read(
            lambda c: c.execute(
                "SELECT seq, run_id, agent_id, ts, type, payload FROM events "
                "WHERE run_id = ? ORDER BY seq DESC LIMIT 1", (run_id,)
            ).fetchall()
        )
        return self._envelope(rows[0]) if rows else None

    def get_run(self, run_id: str) -> dict | None:
        rows = self._read(lambda c: c.execute(
            "SELECT * FROM runs WHERE run_id = ?", (run_id,)
        ).fetchall())
        return dict(rows[0]) if rows else None

    def list_runs(self, agent_id: str | None = None, state: str | None = None,
                  limit: int | None = None, before: float | None = None,
                  routine_id: str | None = None) -> list[dict]:
        """Newest-first run rows; ``before`` = exclusive created_at cursor."""
        sql = "SELECT * FROM runs WHERE 1=1"
        params: list = []
        if agent_id is not None:
            sql += " AND agent_id = ?"
            params.append(agent_id)
        if state is not None:
            sql += " AND state = ?"
            params.append(state)
        if routine_id is not None:
            sql += " AND routine_id = ?"
            params.append(routine_id)
        if before is not None:
            sql += " AND created_at < ?"
            params.append(float(before))
        sql += " ORDER BY created_at DESC, run_id DESC"
        if limit is not None:
            sql += " LIMIT ?"
            params.append(int(limit))
        rows = self._read(lambda c: c.execute(sql, params).fetchall())
        return [dict(r) for r in rows]

    # ------------------------------------------------------------------
    # Routines (scheduled/triggered work — see fleet_routines.py)
    # ------------------------------------------------------------------

    def create_routine(self, agent_id: str, name: str, prompt: str,
                       schedule: dict | None, trigger: dict | None,
                       enabled: bool = True) -> dict:
        """Insert one routine; returns the row. next_run_at is armed by the
        RoutineManager (it owns due/catch-up policy), not here."""
        routine_id = uuid.uuid4().hex
        now = time.time()
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "INSERT INTO routines(routine_id, agent_id, name, prompt, "
                "schedule, trigger, enabled, created_at, failure_count) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)",
                (routine_id, agent_id, name, prompt,
                 json.dumps(schedule) if schedule else None,
                 json.dumps(trigger) if trigger else None,
                 1 if enabled else 0, now),
            )

        self._submit(op, out)
        return self.get_routine(routine_id)

    def get_routine(self, routine_id: str) -> dict | None:
        rows = self._read(lambda c: c.execute(
            "SELECT * FROM routines WHERE routine_id = ?", (routine_id,)
        ).fetchall())
        return dict(rows[0]) if rows else None

    def list_routines(self, agent_id: str | None = None) -> list[dict]:
        sql = "SELECT * FROM routines WHERE 1=1"
        params: list = []
        if agent_id is not None:
            sql += " AND agent_id = ?"
            params.append(agent_id)
        sql += " ORDER BY created_at ASC, routine_id ASC"
        rows = self._read(lambda c: c.execute(sql, params).fetchall())
        return [dict(r) for r in rows]

    def update_routine(self, routine_id: str, **fields) -> dict | None:
        """Partial update; allowed keys are validated by the caller."""
        allowed = ("name", "prompt", "schedule", "trigger", "enabled")
        changes = {k: v for k, v in fields.items() if k in allowed}
        if not changes:
            return self.get_routine(routine_id)
        sets: list[str] = []
        params: list = []
        for key, value in changes.items():
            if key == "enabled":
                sets.append("enabled = ?")
                params.append(1 if value else 0)
            elif key in ("schedule", "trigger"):
                sets.append(f"{key} = ?")
                params.append(json.dumps(value) if value else None)
            else:
                sets.append(f"{key} = ?")
                params.append(value)
        sets.append("failure_count = 0")  # a manual edit resets failure history
        params.append(routine_id)

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                f"UPDATE routines SET {', '.join(sets)} WHERE routine_id = ?",
                params,
            )

        self._submit(op, {})
        return self.get_routine(routine_id)

    def delete_routine(self, routine_id: str) -> None:
        def op(conn: sqlite3.Connection) -> None:
            conn.execute("DELETE FROM routines WHERE routine_id = ?", (routine_id,))

        self._submit(op, {})

    def disable_routines_for(self, agent_id: str) -> int:
        """Disable every routine of an agent (agent DELETE). Returns count."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            cur = conn.execute(
                "UPDATE routines SET enabled = 0 WHERE agent_id = ?",
                (agent_id,),
            )
            out["n"] = cur.rowcount

        self._submit(op, out)
        return out.get("n", 0)

    def routines_due(self, now: float) -> list[dict]:
        """Enabled schedule routines whose next fire time has passed."""
        rows = self._read(lambda c: c.execute(
            "SELECT * FROM routines WHERE enabled = 1 AND schedule IS NOT NULL "
            "AND next_run_at IS NOT NULL AND next_run_at <= ?", (now,)
        ).fetchall())
        return [dict(r) for r in rows]

    def active_routine_run(self, routine_id: str) -> str | None:
        """The run_id of this routine's in-flight turn, if any.

        'In flight' = queued or running. Guarantees a routine never fires
        concurrently with itself; also the boot-recovery handshake (a run
        left queued/running is marked interrupted at hub boot, so a stale
        row here can never wedge a routine)."""
        active = ",".join(f"'{s}'" for s in ("queued", "running"))
        rows = self._read(lambda c: c.execute(
            "SELECT run_id FROM runs WHERE routine_id = ? AND state IN "
            f"({active}) ORDER BY created_at DESC LIMIT 1", (routine_id,)
        ).fetchall())
        return rows[0][0] if rows else None

    def runs_for_routine(self, routine_id: str, limit: int = 50) -> list[dict]:
        """Newest-first runs produced by one routine (routine history)."""
        rows = self._read(lambda c: c.execute(
            "SELECT * FROM runs WHERE routine_id = ? "
            "ORDER BY created_at DESC, run_id DESC LIMIT ?",
            (routine_id, int(limit)),
        ).fetchall())
        return [dict(r) for r in rows]

    def mark_routine_fired(self, routine_id: str, run_id: str,
                           next_run_at: float) -> None:
        """Record a successful fire: last run id/at, next due time, and a
        failure_count reset (success clears consecutive-failure history)."""

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "UPDATE routines SET last_run_at = ?, last_run_id = ?, "
                "next_run_at = ?, failure_count = 0 WHERE routine_id = ?",
                (time.time(), run_id, next_run_at, routine_id),
            )

        self._submit(op, {})

    def bump_routine_failure(self, routine_id: str) -> int:
        """Increment consecutive-failure count; returns the new count."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "UPDATE routines SET failure_count = failure_count + 1 "
                "WHERE routine_id = ?",
                (routine_id,),
            )
            rows = conn.execute(
                "SELECT failure_count FROM routines WHERE routine_id = ?",
                (routine_id,),
            ).fetchone()
            out["n"] = rows[0] if rows else 0

        self._submit(op, out)
        return out.get("n", 0)

    def set_routine_enabled(self, routine_id: str, enabled: bool) -> None:
        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "UPDATE routines SET enabled = ? WHERE routine_id = ?",
                (1 if enabled else 0, routine_id),
            )

        self._submit(op, {})

    def set_routine_next(self, routine_id: str, next_run_at: float) -> None:
        """Arm the schedule: next fire time = now + interval."""
        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "UPDATE routines SET next_run_at = ? WHERE routine_id = ?",
                (next_run_at, routine_id),
            )

        self._submit(op, {})

    def agent_messages(self, agent_id: str, limit: int | None = None,
                       before: int | None = None) -> list[dict]:
        """Newest-first folded messages for an agent; before = message id cursor."""
        sql = "SELECT * FROM messages WHERE agent_id = ?"
        params: list = [agent_id]
        if before is not None:
            sql += " AND id < ?"
            params.append(int(before))
        sql += " ORDER BY id DESC"
        if limit is not None:
            sql += " LIMIT ?"
            params.append(int(limit))
        rows = self._read(lambda c: c.execute(sql, params).fetchall())
        return [dict(r) for r in rows]

    def run_messages(self, run_id: str) -> list[dict]:
        """Chronological folded messages of one run."""
        rows = self._read(lambda c: c.execute(
            "SELECT * FROM messages WHERE run_id = ? ORDER BY id ASC", (run_id,)
        ).fetchall())
        return [dict(r) for r in rows]

    def ping(self) -> float:
        """Write-health probe: one trivial op through the writer queue.

        Returns the round-trip in milliseconds. Raises RuntimeError when the
        writer thread is gone (a stopped store) — callers surface that as an
        unhealthy subsystem instead of hanging.
        """
        start = time.perf_counter()
        self._submit(lambda conn: None, {})
        return (time.perf_counter() - start) * 1000.0

    def next_routine_fire(self) -> float | None:
        """Earliest next fire across enabled schedule routines (health view)."""
        rows = self._read(lambda c: c.execute(
            "SELECT MIN(next_run_at) FROM routines "
            "WHERE enabled = 1 AND next_run_at IS NOT NULL"
        ).fetchall())
        return rows[0][0] if rows and rows[0][0] is not None else None

    def running_run_count(self) -> int:
        rows = self._read(lambda c: c.execute(
            "SELECT COUNT(*) FROM runs WHERE state = 'running'"
        ).fetchall())
        return rows[0][0] if rows else 0

    def record_approval_request(self, approval_id: str, run_id: str | None, agent_id: str,
                                action: str, target: str = "") -> None:
        """One pending approval (idempotent: a replayed request keeps its row)."""
        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "INSERT OR IGNORE INTO approvals(approval_id, run_id, agent_id, action, target, requested_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (approval_id, run_id or None, agent_id, action[:500], target[:2000], time.time()),
            )

        self._submit(op, {})

    def decide_approval(self, approval_id: str, decision: str, decided_by: str = "") -> bool:
        """Settle a pending approval EXACTLY ONCE; True when this call settled it."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            cur = conn.execute(
                "UPDATE approvals SET decision = ?, decided_at = ?, decided_by = ? "
                "WHERE approval_id = ? AND decision IS NULL",
                (decision, time.time(), decided_by or None, approval_id),
            )
            out["rowcount"] = cur.rowcount

        self._submit(op, out)
        return bool(out.get("rowcount"))

    def withdraw_pending_approvals(self, approval_ids: list[str] | None = None,
                                   decided_by: str = "hub") -> int:
        """Settle undecided rows as withdrawn: the given ids, or all of them
        (hub boot — no engine survives a restart to answer them). Returns
        how many were settled."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            now = time.time()
            if approval_ids is None:
                cur = conn.execute(
                    "UPDATE approvals SET decision = 'withdrawn', decided_at = ?, decided_by = ? "
                    "WHERE decision IS NULL", (now, decided_by))
            else:
                if not approval_ids:
                    out["rowcount"] = 0
                    return
                marks = ",".join("?" for _ in approval_ids)
                cur = conn.execute(
                    "UPDATE approvals SET decision = 'withdrawn', decided_at = ?, decided_by = ? "
                    f"WHERE decision IS NULL AND approval_id IN ({marks})",
                    (now, decided_by, *approval_ids))
            out["rowcount"] = cur.rowcount

        self._submit(op, out)
        return int(out.get("rowcount") or 0)

    def get_approval(self, approval_id: str) -> dict | None:
        rows = [r for r in self.list_approvals(limit=500) if r.get("approval_id") == approval_id]
        return rows[0] if rows else None

    def list_approvals(self, state: str | None = None,
                       limit: int = 100) -> list[dict]:
        """Newest-first approval rows; ``state=pending`` = undecided rows.

        Written by the hub since approvals went live (Oct 2026): every
        materialized agent carries ``approvals.mode: manual`` and the
        vertus-guard plugin, so the gateway's approval requests are recorded
        here as they arrive (``record_approval_request``) and settled when a
        client answers or the gateway withdraws them (``decide_approval``).
        computer_use still never reaches the generic gate in gateway mode.
        """
        sql = "SELECT * FROM approvals WHERE 1=1"
        params: list = []
        if state == "pending":
            sql += " AND decision IS NULL"
        elif state:
            sql += " AND decision = ?"
            params.append(state)
        sql += " ORDER BY requested_at DESC, approval_id DESC LIMIT ?"
        params.append(int(limit))
        rows = self._read(lambda c: c.execute(sql, params).fetchall())
        return [dict(r) for r in rows]

    # ------------------------------------------------------------------
    # Writes (all enqueue onto the writer thread)
    # ------------------------------------------------------------------

    def create_run(self, agent_id: str, prompt: str, remote: bool,
                   source: str = "", from_agent: str | None = None,
                   thread_id: str | None = None, run_kind: str = "user",
                   parent_run_id: str | None = None,
                   routine_id: str | None = None) -> str:
        """Insert the run row in state=queued; returns the run_id.

        ``from_agent``/``thread_id``/``run_kind``/``parent_run_id`` carry
        bot-to-bot attribution (message-driven runs, delegation chains);
        ``routine_id`` attributes the run to a routine (run_kind=routine).
        """
        run_id = uuid.uuid4().hex
        now = time.time()
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "INSERT INTO runs(run_id, agent_id, prompt, remote, source, state, "
                "created_at, from_agent, thread_id, run_kind, parent_run_id, "
                "routine_id) "
                "VALUES (?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?)",
                (run_id, agent_id, prompt, 1 if remote else 0, source, now,
                 from_agent, thread_id, run_kind or "user", parent_run_id,
                 routine_id),
            )

        self._submit(op, out)
        return run_id

    def mark_running(self, run_id: str, agent_id: str) -> None:
        """Flip queued → running, stamping started_at (no-op when not queued)."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "UPDATE runs SET state = 'running', started_at = ? "
                "WHERE run_id = ? AND state = 'queued'",
                (time.time(), run_id),
            )

        self._submit(op, out)

    def record_event(self, agent_id: str, run_id: str, event: dict) -> dict:
        """Persist one wire event; returns the enriched envelope with seq/ts.

        Raises on write failure — the caller must NOT fan the event out then.
        The envelope is exactly what subscribers receive, so the client
        stream is always a subset of the store.
        """
        event_type = str(event.get("type") or "")
        payload = {k: v for k, v in event.items() if k != "type"}
        ts = time.time()
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            cur = conn.execute(
                "INSERT INTO events(run_id, agent_id, ts, type, payload) "
                "VALUES (?, ?, ?, ?, ?)",
                (run_id, agent_id, ts, event_type, json.dumps(payload)),
            )
            # Set _event INSIDE the writer op: the writer dispatches it to the
            # listener right after commit, so it must exist before commit.
            out["_event"] = self._envelope({
                "seq": int(cur.lastrowid), "run_id": run_id,
                "agent_id": agent_id, "ts": ts, "type": event_type,
                "payload": json.dumps(payload),
            })

        self._submit(op, out)
        return out["_event"]

    def add_message(self, run_id: str, agent_id: str, role: str, text: str,
                    created_at: float | None = None) -> None:
        """One folded message row (user at enqueue, assistant at turn end)."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "INSERT INTO messages(run_id, agent_id, role, text, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (run_id, agent_id, role, text,
                 created_at if created_at is not None else time.time()),
            )

        self._submit(op, out)

    # ------------------------------------------------------------------
    # Bot-to-bot messaging (fleet message bus)
    # ------------------------------------------------------------------

    def store_bot_message(self, from_agent: str, to_agent: str, body: str,
                          thread_id: str, kind: str, depth: int,
                          status: str = "delivered",
                          run_id: str | None = None) -> dict:
        """Insert one bot message + upsert its thread; returns the row dict.

        The thread upsert runs in the SAME writer op as the message insert,
        so participants/ordering can never diverge. ``status`` is decided by
        the hub BEFORE this call (delivered | dropped_depth | dropped_rate);
        a dropped message is still stored — it is the record of the attempt.
        """
        msg_id = uuid.uuid4().hex
        now = time.time()
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "INSERT INTO bot_messages(msg_id, from_agent, to_agent, "
                "thread_id, body, kind, depth, status, run_id, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (msg_id, from_agent, to_agent, thread_id, body, kind, depth,
                 status, run_id, now),
            )
            # Upsert the thread: subject is set on FIRST sight only;
            # participants and last_message_at update on every message.
            row = conn.execute(
                "SELECT participants FROM threads WHERE thread_id = ?",
                (thread_id,),
            ).fetchone()
            if row is None:
                participants = sorted(set([from_agent, to_agent]))
                conn.execute(
                    "INSERT INTO threads(thread_id, subject, participants, "
                    "created_at, last_message_at) VALUES (?, ?, ?, ?, ?)",
                    (thread_id, body[:80], json.dumps(participants), now, now),
                )
            else:
                participants = sorted(set(json.loads(row[0]) + [from_agent, to_agent]))
                conn.execute(
                    "UPDATE threads SET participants = ?, last_message_at = ? "
                    "WHERE thread_id = ?",
                    (json.dumps(participants), now, thread_id),
                )
            out["row"] = {
                "msg_id": msg_id, "from_agent": from_agent, "to_agent": to_agent,
                "thread_id": thread_id, "body": body, "kind": kind,
                "depth": depth, "status": status, "run_id": run_id,
                "created_at": now, "read_at": None,
            }

        self._submit(op, out)
        return dict(out["row"])

    def set_bot_message_run(self, msg_id: str, run_id: str) -> None:
        """Link a delivered message to the run it created (delegation handle)."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "UPDATE bot_messages SET run_id = ? WHERE msg_id = ?",
                (run_id, msg_id),
            )

        self._submit(op, out)

    def bot_message_depth(self, from_agent: str, thread_id: str) -> int:
        """Depth of the latest message FROM ``from_agent`` in the thread.

        The hub computes a bot's next depth as this + 1; result replies
        reuse the depth of the message that triggered them instead (the hub
        passes it explicitly), so results never inflate a chain.
        """
        rows = self._read(lambda c: c.execute(
            "SELECT depth FROM bot_messages WHERE from_agent = ? AND thread_id = ? "
            "ORDER BY created_at DESC, msg_id DESC LIMIT 1",
            (from_agent, thread_id),
        ).fetchall())
        return int(rows[0]["depth"]) if rows else 0

    def message_run_depth(self, run_id: str) -> int:
        """Depth of the bot message that created ``run_id`` (0 when none).

        Used for auto-generated kind=result replies: the result keeps the
        depth of the handoff/message that triggered it so chains count hops
        exactly once.
        """
        rows = self._read(lambda c: c.execute(
            "SELECT depth FROM bot_messages WHERE run_id = ? LIMIT 1", (run_id,)
        ).fetchall())
        return int(rows[0]["depth"]) if rows else 0

    def list_bot_messages(self, agent_id: str | None = None,
                          thread_id: str | None = None, unread: bool = False,
                          limit: int = 100, before: float | None = None) -> list[dict]:
        """Newest-first bot messages, optional involvement/thread/unread filters.

        ``agent_id`` filters to messages the agent sent OR received;
        ``unread`` filters to read_at IS NULL. ``before`` is an exclusive
        created_at cursor for pagination.
        """
        sql = "SELECT * FROM bot_messages WHERE 1=1"
        params: list = []
        if agent_id is not None:
            sql += " AND (from_agent = ? OR to_agent = ?)"
            params += [agent_id, agent_id]
        if thread_id is not None:
            sql += " AND thread_id = ?"
            params.append(thread_id)
        if unread:
            sql += " AND read_at IS NULL"
        if before is not None:
            sql += " AND created_at < ?"
            params.append(float(before))
        sql += " ORDER BY created_at DESC, msg_id DESC"
        if limit is not None:
            sql += " LIMIT ?"
            params.append(int(limit))
        rows = self._read(lambda c: c.execute(sql, params).fetchall())
        return [dict(r) for r in rows]

    def list_threads(self, limit: int = 100) -> list[dict]:
        """Newest-first threads with unread counts (read_at IS NULL)."""
        rows = self._read(lambda c: c.execute(
            "SELECT t.*, (SELECT COUNT(*) FROM bot_messages m "
            "WHERE m.thread_id = t.thread_id AND m.read_at IS NULL) AS unread "
            "FROM threads t ORDER BY t.last_message_at DESC LIMIT ?", (int(limit),)
        ).fetchall())
        out = []
        for r in rows:
            d = dict(r)
            try:
                d["participants"] = json.loads(d["participants"])
            except (TypeError, ValueError):
                d["participants"] = []
            out.append(d)
        return out

    def mark_thread_read(self, thread_id: str) -> int:
        """Mark every message in the thread read; returns how many."""
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            cur = conn.execute(
                "UPDATE bot_messages SET read_at = ? "
                "WHERE thread_id = ? AND read_at IS NULL",
                (time.time(), thread_id),
            )
            out["count"] = cur.rowcount

        self._submit(op, out)
        return int(out.get("count", 0))

    def children_of(self, run_id: str) -> list[dict]:
        """Runs whose parent is ``run_id`` (delegation children), newest first."""
        rows = self._read(lambda c: c.execute(
            "SELECT * FROM runs WHERE parent_run_id = ? "
            "ORDER BY created_at DESC, run_id DESC", (run_id,)
        ).fetchall())
        return [dict(r) for r in rows]

    def finish_run(self, run_id: str, state: str, error: str | None = None,
                   gateway_respawns: int | None = None) -> bool:
        """Set the terminal state EXACTLY ONCE.

        Only transitions from queued/running; a second call (or a racing
        recovery pass, or a cancel racing a natural completion) is a no-op.
        Returns True when the row was updated.
        """
        assert state in TERMINAL_STATES, state
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            cur = conn.execute(
                f"UPDATE runs SET state = ?, ended_at = ?, "
                f"error = COALESCE(?, error), "
                f"gateway_respawns = CASE WHEN ? IS NOT NULL THEN ? "
                f"                          ELSE gateway_respawns END "
                f"WHERE run_id = ? AND state NOT IN ({_TERMINAL_SQL})",
                (state, time.time(), error,
                 gateway_respawns, gateway_respawns, run_id),
            )
            out["rowcount"] = cur.rowcount

        self._submit(op, out)
        return bool(out.get("rowcount"))

    # ------------------------------------------------------------------
    # Boot recovery + retention
    # ------------------------------------------------------------------

    def recover_interrupted(self) -> int:
        """Mark queued/running runs interrupted (hub boot). Returns the count."""
        out: dict = {}
        now = time.time()

        def op(conn: sqlite3.Connection) -> None:
            cur = conn.execute(
                "UPDATE runs SET state = 'interrupted', ended_at = ? "
                "WHERE state IN ('queued','running')", (now,)
            )
            out["count"] = cur.rowcount

        self._submit(op, out)
        return int(out.get("count", 0))

    def prune_events(self, ttl_days: int | None = None) -> int:
        """Delete events older than the TTL; runs/messages are never pruned.

        A PASSIVE WAL checkpoint follows the delete COMMIT (never inside the
        writer's open transaction, which would busy-fail); busy checkpoints
        with active readers are non-fatal.
        """
        ttl_days = int(
            ttl_days if ttl_days is not None
            else os.environ.get("VERTUS_EVENT_TTL_DAYS", "30")
        )
        cutoff = time.time() - ttl_days * 86400
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            cur = conn.execute("DELETE FROM events WHERE ts < ?", (cutoff,))
            out["count"] = cur.rowcount

        self._submit(op, out)
        checkpoint: dict = {}

        def ckpt(conn: sqlite3.Connection) -> None:
            try:
                conn.execute("PRAGMA wal_checkpoint(PASSIVE)")
            except sqlite3.OperationalError:
                pass  # busy with active readers — SQLite checkpoints again later

        self._submit(ckpt, checkpoint)
        return int(out.get("count", 0))

    @staticmethod
    def _envelope(row) -> dict:
        """Rehydrate the exact client envelope from a stored row."""
        if not isinstance(row, dict):
            row = dict(row)
        env = json.loads(row["payload"])
        env["type"] = row["type"]
        env["agent_id"] = row["agent_id"]
        env["run_id"] = row["run_id"]
        env["seq"] = int(row["seq"])
        env["ts"] = row["ts"]
        return env
