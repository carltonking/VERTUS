"""Python facade over the pi SDK via the bun bridge (pi_bridge.mjs).

Exposes the same API the VERTUS server expects:
    result = create_agent_session()
    session = result["session"]
    session.subscribe(callback)   # pi-shaped event dicts
    session.prompt(text)          # fire-and-forget; events stream via SSE
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
VERTUS_ROOT = SERVER_DIR.parents[1]
BRIDGE = VERTUS_ROOT / "vertus" / "server" / "pi_bridge.mjs"
BUN = os.environ.get("VERTUS_BUN", "bun")

BRIDGE_READY_TIMEOUT_S = 60


class AgentSessionError(RuntimeError):
    pass


class _AgentSession:
    """Talk JSON-lines to the bridge over stdio and fan events out to listeners."""

    def __init__(self, proc: subprocess.Popen, log):
        self._proc = proc
        self._log = log
        self._lock = threading.Lock()
        self._listeners: list = []
        self._ready = threading.Event()
        self._failures: list[str] = []
        self._pending_turn: tuple[threading.Event, list] | None = None
        threading.Thread(target=self._reader, daemon=True).start()

    # -- public API -------------------------------------------------------

    def subscribe(self, listener) -> None:
        with self._lock:
            self._listeners.append(listener)

    def prompt(self, text: str) -> None:
        """Send the prompt and block until the bridge finishes the turn.

        The VERTUS server treats prompt() returning as "turn done" (it emits
        a backstop done event); blocking here keeps that contract so a client
        never sees "done" before the reply text.
        """
        done = threading.Event()
        errors: list = []
        with self._lock:
            if self._proc.stdin is None:
                raise AgentSessionError("bridge stdin closed")
            if self._pending_turn is not None:
                raise AgentSessionError("a turn is already in flight")
            self._pending_turn = (done, errors)
            self._proc.stdin.write(json.dumps({"cmd": "prompt", "text": text}) + "\n")
            self._proc.stdin.flush()
        done.wait()
        if errors:
            raise AgentSessionError(errors[-1])

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

    # -- plumbing ----------------------------------------------------------

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
                kind = msg.get("type")
                if kind == "ready":
                    self._ready.set()
                elif kind == "event":
                    self._emit(msg.get("event") or {})
                elif kind == "error":
                    msg_text = str(msg.get("message", "bridge error"))
                    self._failures.append(msg_text)
                    self._emit({"type": "error", "message": msg_text[:500]})
                    self._finish_turn(error=msg_text)
                elif kind == "done":
                    self._finish_turn()
                elif kind == "log":
                    self._log(msg.get("message", ""))
        except Exception:
            pass
        finally:
            self._ready.set()  # unblock create_agent_session if bridge dies early


def create_agent_session(log=print):
    """Start the bun bridge and wait until its pi session is ready."""
    proc = subprocess.Popen(
        [BUN, str(BRIDGE)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
        env={**os.environ},
    )
    session = _AgentSession(proc, log)
    if not session._ready.wait(BRIDGE_READY_TIMEOUT_S):
        proc.kill()
        raise AgentSessionError("pi bridge did not become ready in time")
    if session._failures:
        raise AgentSessionError(session._failures[0])
    return {"session": session}
