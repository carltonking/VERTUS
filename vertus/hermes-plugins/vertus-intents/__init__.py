"""VERTUS intents — requests answered by the hub, not improvised by the model.

A small local model asked to "connect my Google account" invented connector
menus and desktop apps instead of using its skill. For that request the hub
knows the exact answer, so this rewrites the incoming text into an
instruction carrying the real one-time link, before the model sees it.
"""

from __future__ import annotations

import json
import re
import urllib.request
from pathlib import Path

CONNECT_GOOGLE = re.compile(
    r"\b(connect|link|sign\s*in|log\s*in|hook\s*up|set\s*up|add|authori[sz]e|integrate)\b"
    r"[\s\S]{0,40}\b(google|gmail|g-?mail|google\s+calendar|google\s+drive)\b"
    r"|\b(google|gmail)\b[\s\S]{0,20}\b(connect|link|sign\s*in|log\s*in|access)\b",
    re.IGNORECASE)


def wants_google_connect(text: str | None) -> bool:
    return bool(text) and len(text) < 300 and bool(CONNECT_GOOGLE.search(text))


def instruction(url: str | None, error: str | None) -> str:
    line = f"Tap to connect your Google account: {url}" if url else f"I couldn't make a Google link: {error}"
    return ("The user asked to connect a Google account. Do not use any tools. "
            f"Reply with exactly this one line and nothing else:\n{line}")


def _mint() -> tuple[str | None, str | None]:
    token = (Path.home() / ".vertus" / "token").read_text().strip()
    req = urllib.request.Request("http://127.0.0.1:8787/api/connect/google",
                                 headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        body = json.loads(exc.read() or b"{}")
    return body.get("url"), body.get("error") or (None if body.get("url") else "the hub did not answer")


def _dispatch(event=None, **_):
    text = getattr(event, "text", None)
    if not wants_google_connect(text):
        return None
    try:
        url, error = _mint()
    except Exception as exc:  # noqa: BLE001
        url, error = None, str(exc)[:200]
    return {"action": "rewrite", "text": instruction(url, error)}


def register(ctx) -> None:
    ctx.register_hook("pre_gateway_dispatch", _dispatch)
