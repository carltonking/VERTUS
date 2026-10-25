"""VERTUS guard policy — which tool calls must stop for a human yes.

The rule the user set (Oct 2026): VERTUS acts on its own, but it asks before
anything that leaves the Mac or cannot be taken back — sending, posting,
spending, deleting. Modeled on open-instinct's policy (capabilities default to
"ask" for money and outbound messages, deny beats ask beats allow), cut down to
what this agent can actually do: it has no payment tool, so "spend" is
recognized by intent (checkout/buy/pay actions in a browser or a command), not
by an amount.

Pure: ``decide(tool_name, args)`` reads nothing and changes nothing, so the
plugin hook stays trivial and every rule is pinned by a test.

Hermes's own dangerous-command detection still runs for terminal commands and
asks on its own; this layer adds the categories it does not consider
dangerous (an outgoing email, a ``git push``, a POST). A command the engine
will already ask about is left to it (``engine_asks``), so one action never
raises two approval cards. Read-only actions never match.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Optional


@dataclass(frozen=True)
class Verdict:
    category: str          # send | post | spend | delete
    reason: str            # what the approval card says
    rule_key: str          # the grain an "always allow" remembers


# Tool names whose every call goes outward. send_message is Hermes's
# cross-platform messenger (Telegram, Discord, email, SMS…).
_ALWAYS_ASK_TOOLS: dict[str, tuple[str, str]] = {
    "send_message": ("send", "send a message"),
}

_COMMAND_RULES: list[tuple[str, str, str, re.Pattern[str]]] = [
    # (category, rule name, reason, pattern) — matched against a shell
    # command or code body, case-insensitively.
    ("send", "applescript-send", "send a message or email from Mail/Messages",
     re.compile(r"\bosascript\b[\s\S]*\b(send|reply|forward)\b")),
    ("send", "cli-mail", "send an email",
     re.compile(r"\b(sendmail|msmtp|mutt)\b|\bmail\s+-s\b|\bhimalaya\b[\s\S]*\b(send|reply|forward)\b")),
    ("post", "git-push", "push to a remote repository",
     re.compile(r"\bgit\s+push\b")),
    ("post", "github-write", "post to GitHub",
     re.compile(r"\bgh\s+(pr\s+(create|merge|close|comment|review)|issue\s+(create|close|comment)"
                r"|release\s+create|repo\s+(create|delete))\b")),
    ("post", "publish", "publish a package",
     re.compile(r"\b(npm|pnpm|yarn)\s+publish\b|\btwine\s+upload\b|\bcargo\s+publish\b")),
    ("post", "http-write", "send data to a web service",
     re.compile(r"\bcurl\b[\s\S]*(\s-X\s*(POST|PUT|PATCH|DELETE)\b|\s--data(-raw|-binary)?\b|\s-d\s|\s-F\s)",
                re.IGNORECASE)),
    ("delete", "remove-files", "delete files",
     re.compile(r"(^|[;&|`('\"]\s*|\bsudo\s+)(rm|rmdir|srm|shred|trash)\b|\bfind\b[\s\S]*\s-delete\b"
                r"|\bunlink\s+\S|\b(os\.(remove|unlink|rmdir|removedirs)|shutil\.rmtree|send2trash)\s*\(")),
    ("delete", "git-discard", "discard git work",
     re.compile(r"\bgit\s+(reset\s+--hard|clean\s+-\w*f|branch\s+-D|stash\s+(drop|clear)"
                r"|push\s+[\s\S]*--force)\b")),
    ("delete", "applescript-delete", "delete items through AppleScript",
     re.compile(r"\bosascript\b[\s\S]*\bdelete\b")),
    ("spend", "purchase-command", "make a purchase",
     re.compile(r"\b(purchase|place[\s_-]?order|buy[\s_-]?now|pay[\s_-]?now)\b", re.IGNORECASE)),
]

# Words on a control a browser action is about to press or fill that mean the
# click commits something: money, a message, a post.
_BROWSER_COMMIT = [
    ("spend", "browser-purchase", "complete a purchase or payment",
     re.compile(r"\b(buy|purchase|pay|checkout|check\s+out|place\s+(your\s+)?order|confirm\s+(order|payment|booking)"
                r"|book\s+now|subscribe|complete\s+(order|purchase|booking))\b", re.IGNORECASE)),
    ("send", "browser-send", "send a message from a website",
     re.compile(r"\b(send|reply|forward)\b", re.IGNORECASE)),
    ("post", "browser-post", "post or publish on a website",
     re.compile(r"\b(post|publish|tweet)\b", re.IGNORECASE)),
    ("delete", "browser-delete", "delete something on a website",
     re.compile(r"\b(delete|remove|cancel\s+(subscription|account|order))\b", re.IGNORECASE)),
]

_COMMAND_TOOLS = {"terminal", "execute_code", "process"}
# Browser actions that commit a page: a click, a key press, a form submit,
# or script run in it. Typing into a field commits nothing, and reading,
# scrolling and screenshots never ask.
_BROWSER_ACTING = re.compile(r"(click|press|submit|exec)", re.IGNORECASE)


def _command_text(args: dict) -> str:
    for key in ("command", "code", "cmd", "script"):
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return ""


def _browser_text(args: dict) -> str:
    """Everything an acting browser call names: selector, label, text, code."""
    parts: list[str] = []
    for value in args.values():
        if isinstance(value, str):
            parts.append(value)
        elif isinstance(value, (list, tuple)):
            parts.extend(v for v in value if isinstance(v, str))
    return "\n".join(parts)


def _short(text: str, limit: int = 160) -> str:
    one_line = " ".join(text.split())
    return one_line if len(one_line) <= limit else one_line[: limit - 1] + "…"


def decide(tool_name: str, args: dict | None,
           engine_asks: Optional[Callable[[str], bool]] = None) -> Verdict | None:
    """The approval a call needs, or None when it may simply run.

    ``engine_asks(command)`` says whether the engine's own gate will already
    stop this shell command; when it will, the guard stays out of the way."""
    args = args if isinstance(args, dict) else {}
    name = (tool_name or "").strip()

    if name in _ALWAYS_ASK_TOOLS:
        category, what = _ALWAYS_ASK_TOOLS[name]
        target = args.get("target") or args.get("to") or args.get("chat_id") or args.get("platform") or ""
        reason = f"VERTUS wants to {what}" + (f" to {_short(str(target), 60)}" if target else "")
        return Verdict(category, reason, f"vertus-guard:{category}:{name}")

    if name in _COMMAND_TOOLS:
        command = _command_text(args)
        if not command:
            return None
        if name == "terminal" and engine_asks is not None:
            try:
                if engine_asks(command):
                    return None
            except Exception:  # noqa: BLE001 — a broken detector must not unguard
                pass
        for category, rule, what, pattern in _COMMAND_RULES:
            if pattern.search(command):
                return Verdict(category, f"VERTUS wants to {what}: {_short(command)}",
                               f"vertus-guard:{category}:{rule}")
        return None

    if name.startswith("browser") and _BROWSER_ACTING.search(name + " " + str(args.get("action", ""))):
        text = _browser_text(args)
        for category, rule, what, pattern in _BROWSER_COMMIT:
            if pattern.search(text):
                return Verdict(category, f"VERTUS wants to {what}: {_short(text)}",
                               f"vertus-guard:{category}:{rule}")
    return None
