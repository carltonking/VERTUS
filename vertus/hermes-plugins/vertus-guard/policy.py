"""VERTUS guard policy — which tool calls must stop for a human yes.

The rule the user set (Oct 2026): VERTUS acts on its own, but it asks before
anything that leaves the Mac or cannot be taken back — sending, posting,
spending, deleting. Modeled on open-instinct's policy (outbound and
irreversible capabilities default to "ask"), cut down to what this agent can
actually do and what a tool call's arguments actually reveal.

Pure: ``decide(tool_name, args)`` reads nothing and changes nothing, so the
plugin hook stays trivial and every rule is pinned by a test.

How a shell command is judged: it is split into the commands it runs (lines,
``;``, ``&&``, ``||``, pipes, ``$(…)``, backticks), and each is judged by the
program it starts — after ``sudo``/``env``/``xargs``/``nohup`` and path
prefixes — never by words appearing anywhere in the text. ``echo "rm"`` and
``grep -rn purchase`` are reading; ``/bin/rm``, ``xargs rm`` and an ``rm`` on
line two are deleting.

What the guard deliberately leaves to the engine: Hermes's own
dangerous-command gate (``engine_asks``). ``execute_code`` is refused with a
pointer to the terminal: with approvals on the engine asks before every
script as a whole, which parked unattended routines for the full approval
timeout (Oct 2026), and a script's own subprocesses never pass either gate,
while the same Python run through the terminal (``python3 -c``, a heredoc)
is checked command by command.

What it cannot see, stated plainly: a browser click carries only an element
reference (``@e12``), not the button's label, so a purchase or a post made by
clicking through a website is not recognized. Scripts run inside a page are
checked for form submits and requests that send data.

The approval channel itself is out of bounds: any call that touches the
hub's approvals endpoint or the approver credential is blocked outright, so an
agent cannot approve its own (or another agent's) request.
"""

from __future__ import annotations

import hashlib
import re
import shlex
from dataclasses import dataclass
from typing import Callable, Optional


@dataclass(frozen=True)
class Verdict:
    category: str          # send | post | delete | approval-channel
    reason: str            # what the approval card (or the block) says
    rule_key: str          # the grain an "always allow" remembers
    block: bool = False    # refuse outright instead of asking


# --- the approval channel ---------------------------------------------------

_APPROVAL_CHANNEL = re.compile(r"api/approvals|approver[-_]token|X-Vertus-Approver", re.IGNORECASE)

# --- tools whose every call goes outward -------------------------------------

# send_message is Hermes's cross-platform messenger (reachable through MCP and
# platform plugins); react_to_message posts a reaction someone else sees.
_ALWAYS_ASK_TOOLS: dict[str, tuple[str, str]] = {
    "send_message": ("send", "send a message"),
    "react_to_message": ("send", "react to a message"),
}

# Tools that run a shell command, and the argument keys that carry it.
_SHELL_TOOLS = {"terminal", "process", "process_manage"}
_SHELL_KEYS = ("command", "cmd", "data", "script")
# execute_code is refused (see the module docstring); page scripts are
# scanned for requests that send data.
_CODE_TOOLS = {"execute_code"}
_PAGE_SCRIPT_TOOLS = {"browser_cdp", "browser_console"}

# --- shell commands -----------------------------------------------------------

_SEPARATORS = re.compile(r"\n|;|&&|\|\||\||\$\(|`|\)")
# Words that run the next word as the real command.
_PREFIXES = {"sudo", "env", "xargs", "nohup", "time", "command", "exec", "nice", "caffeinate", "doas"}
_DELETE_PROGRAMS = {"rm", "rmdir", "srm", "shred", "trash", "unlink"}
_MAIL_PROGRAMS = {"sendmail", "msmtp", "mutt", "neomutt"}
_HTTP_WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _words(segment: str) -> list[str]:
    try:
        return shlex.split(segment, posix=True)
    except ValueError:  # an unbalanced quote: fall back to whitespace
        return segment.split()


def _program(words: list[str]) -> tuple[str, list[str]]:
    """The program a command really starts, and its arguments."""
    i = 0
    while i < len(words):
        word = words[i]
        if _ASSIGNMENT.match(word):  # FOO=bar before the command (or after env)
            i += 1
            continue
        base = word.rsplit("/", 1)[-1]
        if base in _PREFIXES:
            i += 1
            # skip the prefix's own flags (sudo -u x, xargs -0, nice -n 5)
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-u", "-n", "-g", "-I") else 1
            continue
        return base, words[i + 1:]
    return "", []


def _segments(command: str) -> list[str]:
    return [s.strip() for s in _SEPARATORS.split(command) if s.strip()]


def _shell_verdict(segment: str) -> tuple[str, str, str] | None:
    """(category, rule, what) for one simple command, or None."""
    program, args = _program(_words(segment))
    if not program:
        return None
    lowered = [a.lower() for a in args]

    if program in _DELETE_PROGRAMS:
        return ("delete", "remove-files", "delete files")
    if program == "find" and ("-delete" in args or any(a in ("rm", "/bin/rm") for a in args)):
        return ("delete", "find-delete", "delete files")
    if program == "osascript":
        text = " ".join(lowered)
        if re.search(r"\b(send|reply|forward)\b", text):
            return ("send", "applescript-send", "send a message or email from Mail/Messages")
        if re.search(r"\bdelete\b", text):
            return ("delete", "applescript-delete", "delete items through AppleScript")
        return None
    if program in _MAIL_PROGRAMS or (program == "mail" and "-s" in args):
        return ("send", "cli-mail", "send an email")
    if program == "himalaya" and any(a in ("send", "reply", "forward", "write") for a in lowered):
        return ("send", "cli-mail", "send an email")
    if program == "git" and args:
        sub = lowered[0]
        if sub == "push":
            if any(a in ("--force", "-f", "--force-with-lease") for a in lowered):
                return ("delete", "git-force-push", "force-push over a remote branch")
            return ("post", "git-push", "push to a remote repository")
        if sub == "rm":
            return ("delete", "git-rm", "delete tracked files")
        if (sub == "reset" and "--hard" in lowered) or (sub == "clean" and any(
                a.startswith("-") and "f" in a for a in lowered[1:])) \
                or (sub == "branch" and any(a in ("-d", "--delete") for a in lowered)) \
                or (sub == "stash" and len(lowered) > 1 and lowered[1] in ("drop", "clear")):
            return ("delete", "git-discard", "discard git work")
        return None
    if program == "gh" and args:
        sub = lowered[0]
        rest = lowered[1:]
        if sub == "api":
            method = next((rest[i + 1].upper() for i, a in enumerate(rest[:-1])
                           if a in ("-x", "--method")), "")
            writes = any(a in ("-f", "--field", "--raw-field", "--input") for a in rest)
            if method in _HTTP_WRITE_METHODS or (writes and method != "GET"):
                return ("post", "github-write", "write to GitHub")
            return None
        if (sub in ("pr", "issue") and rest and rest[0] in (
                "create", "merge", "close", "comment", "review", "edit", "reopen", "delete")) \
                or (sub == "release" and rest and rest[0] in ("create", "delete", "upload", "edit")) \
                or (sub == "repo" and rest and rest[0] in ("create", "delete", "archive", "edit", "rename")) \
                or (sub == "gist" and rest and rest[0] in ("create", "delete", "edit")):
            return ("post", "github-write", "write to GitHub")
        return None
    if program in ("npm", "pnpm", "yarn", "cargo", "gem") and "publish" in lowered \
            or program == "twine" and "upload" in lowered:
        return ("post", "publish", "publish a package")
    if program == "curl":
        method = next((args[i + 1].upper() for i, a in enumerate(args[:-1]) if a in ("-X", "--request")), "")
        method = method or next((a[2:].upper() for a in args if a.startswith("-X") and len(a) > 2), "")
        sends = any(a in ("--data", "--data-raw", "--data-binary", "--data-urlencode", "--json",
                          "--form", "-T", "--upload-file")
                    or a.startswith(("-d", "-F", "--data=", "--json=", "--form="))
                    for a in args)
        if method in _HTTP_WRITE_METHODS or (sends and method != "GET"):
            return ("post", "http-write", "send data to a web service")
        return None
    if program == "wget" and any(a.startswith(("--post-data", "--post-file", "--body-data", "--body-file"))
                                 or a.startswith("--method") for a in args):
        return ("post", "http-write", "send data to a web service")
    if program == "imsg" and lowered and lowered[0] in ("send", "react"):
        return ("send", "imessage", "send an iMessage or SMS")
    if program == "remindctl" and lowered and (lowered[0] == "delete" or
                                               (lowered[0] == "list" and "--delete" in lowered)):
        return ("delete", "reminders-delete", "delete reminders")
    if program == "memo" and "-d" in lowered:
        return ("delete", "notes-delete", "delete a note")
    if program == "aws" and len(lowered) >= 2 and lowered[0] == "s3" and lowered[1] in ("rm", "rb"):
        return ("delete", "cloud-delete", "delete cloud storage")
    if program == "docker" and lowered and (lowered[0] in ("rm", "rmi") or
                                            (len(lowered) > 1 and lowered[1] in ("rm", "prune"))):
        return ("delete", "docker-delete", "delete containers, images or volumes")
    return None


# Code that sends data over HTTP, wherever it appears (inline python -c,
# heredocs, page scripts).
_CODE_HTTP_WRITE = re.compile(
    r"\b(requests|httpx|aiohttp\.ClientSession\(\)|session|client)\.(post|put|patch|delete)\s*\("
    r"|urllib\.request\.urlopen\([^)]*data\s*="
    r"|\bfetch\s*\([^)]*method\s*:\s*['\"](POST|PUT|PATCH|DELETE)"
    r"|XMLHttpRequest[\s\S]*\.send\s*\(\s*[^)\s]"
    r"|\.submit\s*\(\s*\)|\.requestSubmit\s*\(",
    re.IGNORECASE)
_CODE_DELETE = re.compile(
    r"\b(os\.(remove|unlink|rmdir|removedirs)|shutil\.rmtree|send2trash)\s*\("
    r"|\b(system|run|call|check_call|check_output|Popen|popen)\s*\(\s*\[?\s*['\"]\s*(rm|rmdir|trash)\b")


_MCP_WRITE = re.compile(
    r"(?:^|_)(send|reply|forward|post|comment|publish|share|invite|create|update|edit|write|upload|"
    r"merge|archive|delete|remove|trash|cancel|pay|purchase|order|book|transfer|schedule)(?:_|$)",
    re.IGNORECASE)
_MCP_CATEGORY = {"send": "send", "reply": "send", "forward": "send", "invite": "send",
                 "delete": "delete", "remove": "delete", "trash": "delete", "cancel": "delete",
                 "archive": "delete", "pay": "spend", "purchase": "spend", "order": "spend",
                 "book": "spend", "transfer": "spend"}


def _short(text: str, limit: int = 160) -> str:
    one_line = " ".join(text.split())
    return one_line if len(one_line) <= limit else one_line[: limit - 1] + "…"


def _key(category: str, rule: str, subject: str) -> str:
    """The "always allow" grain: this rule for THIS command or recipient,
    never a whole category — one "always" on a curl POST must not allow every
    future POST."""
    digest = hashlib.sha256(" ".join(subject.split()).encode("utf-8")).hexdigest()[:16]
    return f"vertus-guard:{category}:{rule}:{digest}"


def _all_text(args: dict) -> str:
    parts: list[str] = []
    for value in args.values():
        if isinstance(value, str):
            parts.append(value)
        elif isinstance(value, (list, tuple)):
            parts.extend(v for v in value if isinstance(v, str))
        elif isinstance(value, dict):
            parts.append(_all_text(value))
    return "\n".join(parts)


def decide(tool_name: str, args: dict | None,
           engine_asks: Optional[Callable[[str], bool]] = None) -> Verdict | None:
    """The approval a call needs, or None when it may simply run.

    ``engine_asks(command)`` says whether the engine's own gate will already
    stop this shell command; when it will, the guard stays out of the way."""
    args = args if isinstance(args, dict) else {}
    name = (tool_name or "").strip()
    text = _all_text(args)

    if _APPROVAL_CHANNEL.search(text):
        return Verdict("approval-channel",
                       "Blocked: approvals are answered by the person, never by an agent.",
                       "vertus-guard:approval-channel", block=True)

    if name in _CODE_TOOLS:
        return Verdict("code", "Blocked: run this through the terminal tool instead "
                       "(python3 -c or a heredoc), where each command is checked; "
                       "execute_code needs a person to approve every script.",
                       "vertus-guard:code:execute_code", block=True)

    if name in _ALWAYS_ASK_TOOLS:
        category, what = _ALWAYS_ASK_TOOLS[name]
        target = str(args.get("target") or args.get("to") or args.get("chat_id")
                     or args.get("platform") or "")
        reason = f"VERTUS wants to {what}" + (f" to {_short(target, 60)}" if target else "")
        return Verdict(category, reason, _key(category, name, target or name))

    if name in _SHELL_TOOLS:
        command = next((args[k] for k in _SHELL_KEYS if isinstance(args.get(k), str) and args[k].strip()), "")
        if not command:
            return None
        if name == "terminal" and engine_asks is not None:
            try:
                if engine_asks(command):
                    return None
            except Exception:  # noqa: BLE001 — a broken detector must not unguard
                pass
        for segment in _segments(command):
            found = _shell_verdict(segment)
            if found:
                category, rule, what = found
                return Verdict(category, f"VERTUS wants to {what}: {_short(command)}",
                               _key(category, rule, command))
        if _CODE_HTTP_WRITE.search(command):
            return Verdict("post", f"VERTUS wants to send data to a web service: {_short(command)}",
                           _key("post", "http-write", command))
        if _CODE_DELETE.search(command):
            return Verdict("delete", f"VERTUS wants to delete files: {_short(command)}",
                           _key("delete", "remove-files", command))
        return None

    if name.startswith("mcp_"):
        # MCP connectors name their tools mcp_<server>_<tool>; a write verb
        # in the tool part means it acts on the outside world.
        verb = _MCP_WRITE.search(name[4:])
        if verb:
            category = _MCP_CATEGORY.get(verb.group(1).lower(), "post")
            return Verdict(category, f"VERTUS wants to use {name}: {_short(text) or 'no arguments'}",
                           _key(category, name, text))
        return None

    if name in _PAGE_SCRIPT_TOOLS and _CODE_HTTP_WRITE.search(text):
        return Verdict("post", f"VERTUS wants to submit or send data from a web page: {_short(text)}",
                       _key("post", "page-write", text))

    return None
