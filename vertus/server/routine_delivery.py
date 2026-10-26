"""Deliver what VERTUS says unasked to the user's phone, as an iMessage.

Instinct-style reach-out off the Mac: when a routine run (morning brief,
check-in) finishes with something to say, the hub itself sends that reply to
the one number the user configured. The hub sends it — not the agent — so the
approvals guard, which stops the agent's own `imsg send`, does not park every
brief on a yes: the destination is fixed by the user, never chosen by a model.

Off unless ``~/.vertus/notify.json`` (VERTUS_NOTIFY_PATH) holds
``{"imessage_to": "+15555550123"}``. Never sends a check-in's
NOTHING_TO_REPORT, a failed run, or a housekeeping routine's report.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable, Optional

try:
    import vertus_paths  # type: ignore
    from proactive_routines import is_nothing_to_report  # type: ignore
except ImportError:  # pragma: no cover - package-relative import
    from . import vertus_paths  # type: ignore
    from .proactive_routines import is_nothing_to_report  # type: ignore

log = logging.getLogger("vertus.delivery")

# Routines whose reply is a report to keep, not news to send.
QUIET_ROUTINES = frozenset({"memory-consolidation"})
MAX_CHARS = 1800
# The reply is folded into the store as the run ends; give it a moment.
SETTLE_S = 2.0


def notify_path() -> Path:
    env = os.environ.get("VERTUS_NOTIFY_PATH", "").strip()
    return Path(env).expanduser() if env else vertus_paths.vertus_root() / "notify.json"


def destination(path: Optional[Path] = None) -> str | None:
    try:
        cfg = json.loads((path or notify_path()).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    to = str(cfg.get("imessage_to") or "").strip() if isinstance(cfg, dict) else ""
    return to or None


def message_for(run: dict | None, routine: dict | None, messages: list[dict]) -> str | None:
    """The text to send for a finished run, or None when nothing should go."""
    if not run or run.get("run_kind") != "routine" or run.get("state") not in (None, "done"):
        return None
    if routine and str(routine.get("name") or "").strip().lower() in QUIET_ROUTINES:
        return None
    replies = [m.get("text") or "" for m in messages if m.get("role") == "assistant"]
    reply = (replies[-1] if replies else "").strip()
    if not reply or is_nothing_to_report(reply):
        return None
    return reply if len(reply) <= MAX_CHARS else reply[: MAX_CHARS - 1] + "…"


def _imsg_send(to: str, text: str) -> None:
    subprocess.run(["imsg", "send", "--to", to, "--text", text],
                   check=True, timeout=30, capture_output=True)


class PhoneDelivery:
    def __init__(self, store_provider: Callable, send: Callable[[str, str], None] = _imsg_send,
                 settle_s: float = SETTLE_S, path: Optional[Path] = None) -> None:
        self._store = store_provider
        self._send = send
        self._settle_s = settle_s
        self._path = path

    def on_run_done(self, run_id: str, agent_id: str, from_agent, thread_id,
                    run_kind: str, state: str) -> None:
        """Hub hook for every terminal run; cheap unless a routine finished."""
        if state != "done" or run_kind != "routine":
            return
        to = destination(self._path)
        if not to:
            return
        threading.Thread(target=self._deliver, args=(run_id, to), daemon=True).start()

    def _deliver(self, run_id: str, to: str) -> None:
        if self._settle_s:
            time.sleep(self._settle_s)
        store = self._store()
        if store is None:
            return
        try:
            run = store.get_run(run_id)
            routine = store.get_routine(run["routine_id"]) if run and run.get("routine_id") else None
            text = message_for(run, routine, store.run_messages(run_id))
            if text:
                self._send(to, text)
        except Exception as exc:  # noqa: BLE001 — a failed text must never hurt the hub
            log.warning("routine reply not delivered to phone (%s): %s", run_id, exc)
