#!/usr/bin/env python3
"""DSPy bridge for Alfred's Personal Tutor skill.

Alfred (the macOS app) calls this script every 10 tutoring sessions, passing
the scored session history on stdin and reading proposed teaching directives
from stdout:

    stdin : {"sessions": [{"concept": "recursion", "mode": "explain",
                           "method": "code_example", "outcome": "understood"}, ...]}
    stdout: {"engine": "dspy", "directives": ["This user learns best with code examples...", ...]}

When DSPy is not installed or not configured, this prints
``{"engine": "unavailable", "directives": []}`` and Alfred falls back to its
own deterministic learner (LearningStyleAnalyzer in Swift), so the tutor
never depends on the Python toolchain.

DSPy is opt-in and configurable through the environment, mirroring
dspy_optimizer.py:

    DSPY_ENABLED=1          # enable the real-DSPy path (default: off)
    DSPY_MODEL=<dspy id>    # e.g. "openai/gpt-4o-mini"
    DSPY_API_BASE=<url>     # optional custom base URL (e.g. a local proxy)
    DSPY_API_KEY=<key>      # optional API key

The actual optimization is a DSPy `Predict` module whose signature asks the
model to propose teaching preferences from sessions that ended well vs
sessions that ended in confusion — the "learn what works for this learner"
loop the spec describes.
"""

import json
import os
import sys


def _dspy_configured():
    if os.environ.get("DSPY_ENABLED", "") != "1":
        return False
    if not os.environ.get("DSPY_MODEL"):
        return False
    try:
        import dspy  # noqa: F401
        return True
    except Exception:
        return False


def _split_sessions(sessions):
    good = [s for s in sessions if s.get("outcome") == "understood"]
    bad = [s for s in sessions if s.get("outcome") == "confused"]
    return good, bad


def _format_sessions(sessions, limit=10):
    lines = []
    for s in sessions[:limit]:
        lines.append("CONCEPT: %s" % s.get("concept", "").strip()[:120])
        lines.append("METHOD: %s (mode: %s) -> %s" % (
            s.get("method", ""), s.get("mode", ""), s.get("outcome", "")))
        lines.append("")
    return "\n".join(lines)


def _propose_with_dspy(sessions):
    import dspy

    good, bad = _split_sessions(sessions)
    if len(good) < 3 or not bad:
        return []

    model = os.environ["DSPY_MODEL"]
    kwargs = {}
    if os.environ.get("DSPY_API_BASE"):
        kwargs["api_base"] = os.environ["DSPY_API_BASE"]
    if os.environ.get("DSPY_API_KEY"):
        kwargs["api_key"] = os.environ["DSPY_API_KEY"]

    try:
        lm = dspy.LM(model, **kwargs)
        dspy.configure(lm=lm)
    except Exception:
        return []

    class ProposeTeaching(dspy.Signature):
        """Given tutoring sessions where the learner understood the concept
        and sessions where they reported being confused, propose 1-3 short,
        concrete teaching preferences (which method to lead with, how much
        structure, question-based vs direct). Preferences must be general
        statements about this learner, not one-off fixes."""

        good_sessions: str = dspy.InputField(desc="sessions that ended in understanding")
        bad_sessions: str = dspy.InputField(desc="sessions that ended in confusion")
        directives: list[str] = dspy.OutputField(desc="1-3 short teaching preferences")

    try:
        predict = dspy.Predict(ProposeTeaching)
        result = predict(
            good_sessions=_format_sessions(good),
            bad_sessions=_format_sessions(bad),
        )
        raw = getattr(result, "directives", None)
        if isinstance(raw, str):
            raw = [raw]
        directives = [d.strip() for d in (raw or []) if d and d.strip()]
    except Exception:
        return []

    return directives[:3]


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"engine": "unavailable", "directives": []}))
        return

    sessions = payload.get("sessions", [])
    if not _dspy_configured():
        print(json.dumps({"engine": "unavailable", "directives": []}))
        return

    directives = _propose_with_dspy(sessions)
    print(json.dumps({"engine": "dspy", "directives": directives}))


if __name__ == "__main__":
    main()
