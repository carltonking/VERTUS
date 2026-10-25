"""VERTUS guard — escalate sending, posting, spending and deleting to a human.

Registers one ``pre_tool_call`` hook. A matching call returns Hermes's
``{"action": "approve"}`` directive, which routes it through the same human
gate as Hermes's own dangerous commands (once / session / always / deny,
fail-closed on timeout), so the model cannot skip it. The hub answers that
gate from whichever surface the user is on — the island today.

The rules live in policy.py; this module only adapts them to the hook.
"""

from __future__ import annotations

from .policy import decide


def _engine_asks(command: str) -> bool:
    """Whether Hermes's own dangerous-command gate will stop this command.
    Its terminal tool runs that gate after this hook, so asking here too
    would show the same action twice."""
    from tools.approval_detection import detect_dangerous_command
    return bool(detect_dangerous_command(command)[0])


def _guard(tool_name: str = "", args: dict | None = None, **_: object) -> dict | None:
    verdict = decide(tool_name, args, engine_asks=_engine_asks)
    if verdict is None:
        return None
    return {"action": "approve", "message": verdict.reason, "rule_key": verdict.rule_key}


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", _guard)
