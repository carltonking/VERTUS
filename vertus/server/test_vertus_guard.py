"""The VERTUS guard: what must stop for a human yes, and what must not.

Behavior contracts for vertus/hermes-plugins/vertus-guard/policy.py — the
categories the user asked to approve (send, post, spend, delete) are caught,
and the everyday read-only and local work the agent does all day is not.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_PLUGIN = Path(__file__).resolve().parents[1] / "hermes-plugins" / "vertus-guard"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path, submodule_search_locations=[str(_PLUGIN)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


guard = _load("vertus_guard_plugin", _PLUGIN / "__init__.py")
policy = sys.modules["vertus_guard_plugin.policy"]


def _cat(tool: str, args: dict) -> str | None:
    verdict = policy.decide(tool, args)
    return verdict.category if verdict else None


@pytest.mark.parametrize("command, category", [
    ('osascript -e \'tell application "Mail" to send theMessage\'', "send"),
    ('osascript -e \'tell application "Messages" to send "hi" to buddy "x"\'', "send"),
    ("himalaya message send < draft.eml", "send"),
    ("echo hi | mail -s 'Status' boss@example.com", "send"),
    ("git push origin main", "post"),
    ("gh pr create --fill", "post"),
    ("gh issue comment 12 --body done", "post"),
    ("npm publish", "post"),
    ("curl -X POST https://api.example.com/v1/orders -d '{}'", "post"),
    ("rm notes.txt", "delete"),
    ("cd ~/Downloads && rm -rf old", "delete"),
    ("find . -name '*.log' -delete", "delete"),
    ("git reset --hard HEAD~3", "delete"),
    ("git branch -D feature", "delete"),
    ("python3 shop.py --place-order 42", "spend"),
])
def test_outward_and_irreversible_commands_ask(command, category):
    assert _cat("terminal", {"command": command}) == category


@pytest.mark.parametrize("command", [
    "ls -la ~/Documents",
    "git status && git log --oneline -5",
    "git checkout -b feature",          # 'checkout' is not a purchase
    "git commit -m 'post-processing fix'",
    "curl -s https://example.com/feed.json",
    "cat ~/.vertus/memory/profile.md",
    "grep -rn 'send' src/",              # reading about sending is not sending
    "python3 -c 'print(1)'",
    "echo removed",
])
def test_everyday_commands_run_without_asking(command):
    assert policy.decide("terminal", {"command": command}) is None


def test_code_execution_is_checked_like_a_command():
    assert _cat("execute_code", {"code": "import os\nos.system('rm -rf build')"}) == "delete"
    assert policy.decide("execute_code", {"code": "print(sum(range(10)))"}) is None


def test_send_message_always_asks_and_names_the_target():
    verdict = policy.decide("send_message", {"target": "telegram:Mom", "message": "hi"})
    assert verdict.category == "send"
    assert "telegram:Mom" in verdict.reason


@pytest.mark.parametrize("tool, args, category", [
    ("browser_click", {"selector": "button#place-order", "text": "Place your order"}, "spend"),
    ("browser_click", {"text": "Buy now"}, "spend"),
    ("browser_click", {"text": "Send"}, "send"),
    ("browser_click", {"text": "Publish post"}, "post"),
    ("browser_click", {"text": "Delete account"}, "delete"),
    ("browser_exec", {"code": "document.querySelector('#checkout').click()"}, "spend"),
])
def test_browser_clicks_that_commit_ask(tool, args, category):
    assert _cat(tool, args) == category


@pytest.mark.parametrize("tool, args", [
    ("browser_navigate", {"url": "https://shop.example.com/checkout"}),   # looking is not buying
    ("browser_type", {"selector": "#message", "text": "send me the report"}),  # typing commits nothing
    ("browser_click", {"text": "Search"}),
    ("browser_snapshot", {}),
    ("read_file", {"path": "/tmp/delete-me.txt"}),
    ("web_search", {"query": "buy a laptop"}),
])
def test_reading_and_navigating_never_ask(tool, args):
    assert policy.decide(tool, args) is None


def test_hook_returns_the_hermes_approve_directive():
    directive = guard._guard(tool_name="terminal", args={"command": "git push"})
    assert directive["action"] == "approve"
    assert directive["rule_key"] == "vertus-guard:post:git-push"
    assert "push" in directive["message"]
    assert guard._guard(tool_name="terminal", args={"command": "ls"}) is None


def test_malformed_calls_never_raise():
    assert policy.decide("terminal", None) is None
    assert policy.decide("terminal", {"command": 42}) is None
    assert policy.decide("", {}) is None


def test_python_file_removal_asks():
    assert _cat("execute_code", {"code": "import shutil\nshutil.rmtree('/tmp/x')"}) == "delete"
    assert _cat("execute_code", {"code": "import os\nos.remove(path)"}) == "delete"


def test_commands_the_engine_already_asks_about_are_left_to_it():
    # Hermes's terminal tool runs its own dangerous-command gate after this
    # hook; asking here too would show one action as two approval cards.
    engine = lambda command: command.startswith("rm ")  # noqa: E731
    assert policy.decide("terminal", {"command": "rm notes.txt"}, engine_asks=engine) is None
    assert _cat("terminal", {"command": "git push"}) == "post"
    assert policy.decide("terminal", {"command": "git push"}, engine_asks=engine).category == "post"
    # code execution has no engine gate of its own here: the guard still asks.
    assert policy.decide("execute_code", {"code": "import os\nos.system('rm x')"},
                         engine_asks=lambda c: True).category == "delete"


def test_a_broken_engine_detector_never_unguards():
    def broken(command):
        raise RuntimeError("detector moved")
    assert policy.decide("terminal", {"command": "rm notes.txt"}, engine_asks=broken).category == "delete"


def test_hook_outside_the_engine_still_guards():
    # Run outside Hermes (tests, a moved module), the detector import fails;
    # the hook must still ask rather than wave the command through.
    assert guard._guard(tool_name="terminal", args={"command": "rm notes.txt"})["action"] == "approve"
