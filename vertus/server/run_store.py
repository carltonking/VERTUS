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

DEFAULT_DB_PATH = Path.home() / ".vertus" / "fleet.db"

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
"""


class RunStore:
    """Thread-safe durable run store. One writer thread; readers per-call."""

    def __init__(self, path: str | Path | None = None) -> None:
        env = os.environ.get("VERTUS_DB_PATH", "").strip()
        self.path = Path(path or env or DEFAULT_DB_PATH).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.path), isolation_level=None)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.execute("PRAGMA busy_timeout=5000")
            conn.execute("PRAGMA wal_autocheckpoint=1000")
            conn.executescript(_SCHEMA)
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
                  limit: int | None = None, before: float | None = None) -> list[dict]:
        """Newest-first run rows; ``before`` = exclusive created_at cursor."""
        sql = "SELECT * FROM runs WHERE 1=1"
        params: list = []
        if agent_id is not None:
            sql += " AND agent_id = ?"
            params.append(agent_id)
        if state is not None:
            sql += " AND state = ?"
            params.append(state)
        if before is not None:
            sql += " AND created_at < ?"
            params.append(float(before))
        sql += " ORDER BY created_at DESC, run_id DESC"
        if limit is not None:
            sql += " LIMIT ?"
            params.append(int(limit))
        rows = self._read(lambda c: c.execute(sql, params).fetchall())
        return [dict(r) for r in rows]

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

    def list_approvals(self, state: str | None = None,
                       limit: int = 100) -> list[dict]:
        """Newest-first approval rows; ``state=pending`` = undecided rows.

        READ-ONLY RECORD: nothing in the hub writes this table today. The
        gateway's approvals fire only when a per-agent config.yaml carries
        ``approvals.mode: manual`` (the fleet default is off) AND the request
        reaches tools/approval.py's generic gate — which computer_use never
        does in gateway mode. Flipping the mode would make shell/file
        approvals reachable (see the checkpoint report); until then this
        endpoint honestly returns an empty ledger.
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
                   source: str = "") -> str:
        """Insert the run row in state=queued; returns the run_id."""
        run_id = uuid.uuid4().hex
        now = time.time()
        out: dict = {}

        def op(conn: sqlite3.Connection) -> None:
            conn.execute(
                "INSERT INTO runs(run_id, agent_id, prompt, remote, source, state, "
                "created_at) VALUES (?, ?, ?, ?, ?, 'queued', ?)",
                (run_id, agent_id, prompt, 1 if remote else 0, source, now),
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
