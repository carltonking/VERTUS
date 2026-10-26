"""VERTUS journal — one record of every conversation, whatever the surface.

The island (hub agent) and iMessage (Photon gateway agent) are separate
engine processes with separate session databases, so neither could recall
what was said on the other. After every turn this appends the exchange to a
dated file in the fleet's SHARED memory, which every agent reads and the hub
indexes for search. Scheduled routine turns are not journaled (they are the
agent talking to itself), and neither are empty or failed turns.
"""

from __future__ import annotations

import fcntl
import os
import time
from pathlib import Path

_MAX = 600
_SURFACES = {"photon": "iMessage", "tui": "island", "acp": "island"}


def journal_dir() -> Path:
    env = os.environ.get("VERTUS_SHARED_MEMORY_DIR", "").strip()
    base = Path(env).expanduser() if env else Path.home() / ".vertus" / "memory" / "shared"
    return base / "journal"


def _clip(text: str) -> str:
    one = " ".join(str(text or "").split())
    return one if len(one) <= _MAX else one[: _MAX - 1] + "…"


def entry(user_message, assistant_response, platform, now: float | None = None) -> str | None:
    """The journal line for one turn, or None when it should not be kept."""
    said, replied = _clip(user_message), _clip(assistant_response)
    if not said or not replied or said.startswith("[vertus-proactive:"):
        return None
    surface = _SURFACES.get(str(platform or "").lower(), str(platform or "chat"))
    stamp = time.strftime("%H:%M", time.localtime(now))
    return f"- {stamp} ({surface}) Carlton: {said}\n  VERTUS: {replied}\n"


def append(line: str, now: float | None = None, directory: Path | None = None) -> Path:
    folder = directory or journal_dir()
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / (time.strftime("%Y-%m-%d", time.localtime(now)) + ".md")
    with open(path, "a", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        if handle.tell() == 0:
            handle.write(f"# Conversations {path.stem}\n\n")
        handle.write(line)
        fcntl.flock(handle, fcntl.LOCK_UN)
    return path


def _on_turn(user_message=None, assistant_response=None, platform=None, **_):
    try:
        line = entry(user_message, assistant_response, platform)
        if line:
            append(line)
    except Exception:  # noqa: BLE001 — a journal must never break a turn
        pass


def register(ctx) -> None:
    ctx.register_hook("post_llm_call", _on_turn)
