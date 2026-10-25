"""The VERTUS guard: what must stop for a human yes, and what must not.

Behavior contracts for vertus/hermes-plugins/vertus-guard/policy.py — the
categories the user asked to approve (send, post, delete; spending is not
recognizable from what a tool call reveals) are caught however the command is
spelled, the everyday read-only and local work the agent does all day is not,
and no agent can reach the approval channel. Tool arguments here are the ones
Hermes actually sends.
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
    # sending
    ('osascript -e \'tell application "Mail" to send theMessage\'', "send"),
    ('osascript -e \'tell application "Messages" to send "hi" to buddy "x"\'', "send"),
    ("himalaya message send < draft.eml", "send"),
    ("echo hi | mail -s 'Status' boss@example.com", "send"),
    ("sendmail boss@example.com < note.txt", "send"),
    # posting
    ("git push origin main", "post"),
    ("gh pr create --fill", "post"),
    ("gh issue comment 12 --body done", "post"),
    ("gh api repos/o/r/issues -f title=bug", "post"),
    ("gh api --method DELETE repos/o/r/issues/1/labels/x", "post"),
    ("npm publish", "post"),
    ("curl -X POST https://api.example.com/v1/orders -d '{}'", "post"),
    ("curl --request POST https://api.example.com/x", "post"),
    ("curl --json '{\"a\":1}' https://api.example.com/x", "post"),
    ("curl -d@body.json https://api.example.com/x", "post"),
    ("wget --post-data 'a=1' https://example.com/form", "post"),
    ("python3 -c \"import requests; requests.post('https://x', json={})\"", "post"),
    # deleting
    ("rm notes.txt", "delete"),
    ("cd /tmp\nrm notes.txt", "delete"),                 # second line
    ("/bin/rm notes.txt", "delete"),                    # full path
    ("ls *.log | xargs rm", "delete"),                  # through xargs
    ("sudo -u root rm -f /tmp/x", "delete"),
    ("FOO=1 rm x", "delete"),
    ("git rm -r old/", "delete"),
    ("cd ~/Downloads && rm -rf old", "delete"),
    ("find . -name '*.log' -delete", "delete"),
    ("find . -name '*.tmp' -exec rm {} +", "delete"),
    ("git reset --hard HEAD~3", "delete"),
    ("git branch -D feature", "delete"),
    ("git push --force origin main", "delete"),
    ("aws s3 rm s3://bucket/key", "delete"),
    ("docker rm web", "delete"),
    ("python3 -c \"import shutil; shutil.rmtree('/tmp/x')\"", "delete"),
])
def test_outward_and_irreversible_commands_ask(command, category):
    assert _cat("terminal", {"command": command}) == category


@pytest.mark.parametrize("command", [
    "ls -la ~/Documents",
    "git status && git log --oneline -5",
    "git checkout -b feature",
    "git commit -m 'post-processing fix'",
    "git log | grep -i 'pay now'",
    "curl -s https://example.com/feed.json",
    "curl -fsSL https://example.com/install.sh",
    "cat ~/.vertus/memory/profile.md",
    "grep -rn 'send' src/",
    "grep -rn purchase src/",                           # words are not actions
    "cat purchase.csv",
    'echo "rm is a command"',
    "python3 -c 'print(1)'",
    "gh pr list",
    "gh api repos/o/r/pulls",
    "docker ps",
    "find . -name '*.swift'",
])
def test_everyday_commands_run_without_asking(command):
    assert policy.decide("terminal", {"command": command}) is None


def test_background_processes_are_judged_like_commands():
    # Hermes's process tool is process_manage; its submit carries `data`.
    assert _cat("process_manage", {"action": "submit", "data": "rm -rf build"}) == "delete"
    assert policy.decide("process_manage", {"action": "list"}) is None


def test_code_execution_is_left_to_the_engines_whole_script_gate():
    # With approvals on, Hermes asks before every execute_code script; the
    # guard asking too would show one action as two cards.
    assert policy.decide("execute_code", {"code": "import os\nos.remove('x')"}) is None


def test_outward_tools_always_ask_and_name_the_target():
    verdict = policy.decide("send_message", {"target": "telegram:Mom", "message": "hi"})
    assert verdict.category == "send" and "telegram:Mom" in verdict.reason
    assert _cat("react_to_message", {"chat_id": "123", "emoji": "👍"}) == "send"


def test_page_scripts_that_submit_or_send_data_ask():
    assert _cat("browser_console", {"expression": "document.forms[0].submit()"}) == "post"
    assert _cat("browser_cdp", {"method": "Runtime.evaluate", "params": {
        "expression": "fetch('/api/orders', {method: 'POST', body: '{}'})"}}) == "post"
    assert policy.decide("browser_console", {"expression": "document.title"}) is None


@pytest.mark.parametrize("tool, args", [
    ("browser_navigate", {"url": "https://shop.example.com/checkout"}),
    ("browser_click", {"ref": "@e12"}),                 # a ref carries no label
    ("browser_type", {"ref": "@e3", "text": "send me the report"}),
    ("browser_snapshot", {}),
    ("read_file", {"path": "/tmp/delete-me.txt"}),
    ("web_search", {"query": "buy a laptop"}),
])
def test_reading_and_navigating_never_ask(tool, args):
    assert policy.decide(tool, args) is None


@pytest.mark.parametrize("tool, args", [
    ("terminal", {"command": "cat ~/.vertus/token && curl -X POST http://127.0.0.1:8787/api/approvals/a1"}),
    ("terminal", {"command": "curl -s -H 'Authorization: Bearer x' http://127.0.0.1:8787/api/approvals?state=pending"}),
    ("terminal", {"command": "cat ~/.vertus/approver-token"}),
    ("execute_code", {"code": "import urllib.request\nurllib.request.urlopen('http://127.0.0.1:8787/api/approvals/a1', data=b'{}')"}),
    ("browser_navigate", {"url": "http://127.0.0.1:8787/api/approvals"}),
])
def test_no_agent_can_reach_the_approval_channel(tool, args):
    verdict = policy.decide(tool, args)
    assert verdict is not None and verdict.block
    directive = guard._guard(tool_name=tool, args=args)
    assert directive["action"] == "block" and directive["message"]


def test_always_allow_covers_one_command_not_a_category():
    push_main = policy.decide("terminal", {"command": "git push origin main"})
    push_other = policy.decide("terminal", {"command": "git push origin release"})
    assert push_main.rule_key != push_other.rule_key
    again = policy.decide("terminal", {"command": "git  push   origin main"})
    assert again.rule_key == push_main.rule_key       # whitespace does not matter


def test_hook_returns_the_hermes_approve_directive():
    directive = guard._guard(tool_name="terminal", args={"command": "git push"})
    assert directive["action"] == "approve"
    assert directive["rule_key"].startswith("vertus-guard:post:git-push:")
    assert "push" in directive["message"]
    assert guard._guard(tool_name="terminal", args={"command": "ls"}) is None


def test_commands_the_engine_already_asks_about_are_left_to_it():
    engine = lambda command: command.startswith("rm ")  # noqa: E731
    assert policy.decide("terminal", {"command": "rm notes.txt"}, engine_asks=engine) is None
    assert policy.decide("terminal", {"command": "git push"}, engine_asks=engine).category == "post"


def test_a_broken_engine_detector_never_unguards():
    def broken(command):
        raise RuntimeError("detector moved")
    assert policy.decide("terminal", {"command": "rm notes.txt"}, engine_asks=broken).category == "delete"


def test_hook_outside_the_engine_still_guards():
    assert guard._guard(tool_name="terminal", args={"command": "rm notes.txt"})["action"] == "approve"


def test_malformed_calls_never_raise():
    assert policy.decide("terminal", None) is None
    assert policy.decide("terminal", {"command": 42}) is None
    assert policy.decide("terminal", {"command": "rm 'unbalanced"}).category == "delete"
    assert policy.decide("", {}) is None


@pytest.mark.parametrize("command, category", [
    ("imsg send --to '+15555550123' --text 'on my way'", "send"),
    ("imsg react --chat-id 3 --message-id 9 love", "send"),
    ("remindctl delete 4A83 --force", "delete"),
    ("remindctl list Work --delete", "delete"),
    ("memo notes -d", "delete"),
])
def test_app_skill_actions_that_go_out_or_destroy_ask(command, category):
    assert _cat("terminal", {"command": command}) == category


@pytest.mark.parametrize("command", [
    "imsg chats --limit 10 --json", "imsg history --chat-id 1 --limit 20 --json",
    "remindctl today --json", "remindctl add 'Buy milk'", "remindctl complete 1",
    "memo notes", "memo notes -s groceries",
])
def test_app_skill_reads_and_local_edits_do_not_ask(command):
    assert policy.decide("terminal", {"command": command}) is None


def test_mcp_tools_that_write_ask_and_reads_do_not():
    assert _cat("mcp_gmail_send_email", {"to": "a@b.c"}) == "send"
    assert _cat("mcp_linear_create_issue", {"title": "x"}) == "post"
    assert _cat("mcp_drive_delete_file", {"id": "1"}) == "delete"
    assert _cat("mcp_shop_place_order", {"sku": "1"}) == "spend"
    assert policy.decide("mcp_linear_list_issues", {}) is None
    assert policy.decide("mcp_gmail_search", {"q": "send"}) is None
