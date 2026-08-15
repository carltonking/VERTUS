#!/usr/bin/env python3
"""DSPy bridge for Alfred's self-optimization loop.

Alfred (the macOS app) calls this script once per weekly compile pass, passing
rated examples on stdin and reading proposed optimization rules from stdout:

    stdin : {"kind": "code", "examples": [{"prompt": ..., "output": ..., "rating": 4, "edited": false}, ...]}
    stdout: {"engine": "dspy", "rules": [{"rule": "...", "confidence": 0.8}, ...]}

When DSPy is not installed or not configured, this prints
``{"engine": "unavailable", "rules": []}`` and Alfred falls back to its own
deterministic heuristic learner (OptimizationHeuristics in Swift), so the
feature never depends on the Python toolchain.

DSPy is opt-in and configurable through the environment:

    DSPY_ENABLED=1          # enable the real-DSPy path (default: off)
    DSPY_MODEL=<dspy id>    # e.g. "openai/gpt-4o-mini"
    DSPY_API_BASE=<url>     # optional custom base URL (e.g. a local proxy)
    DSPY_API_KEY=<key>      # optional API key

The actual optimization is a DSPy `Predict` module whose signature asks the
model to propose prompt-improvement rules from good vs bad examples — the same
"learn from examples" loop the spec describes, so the rule proposals come from
a real LLM rather than string matching.
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


def _split_examples(examples):
    good = [e for e in examples if e.get("rating", 0) >= 4]
    bad = [e for e in examples if e.get("rating", 0) <= 2]
    return good, bad


def _format_examples(examples, limit=8):
    lines = []
    for e in examples[:limit]:
        lines.append("PROMPT: %s" % e.get("prompt", "").strip())
        lines.append("OUTPUT: %s" % e.get("output", "").strip()[:600])
        lines.append("RATING: %s%s" % (e.get("rating", 0), " (edited before use)" if e.get("edited") else ""))
        lines.append("")
    return "\n".join(lines)


def _propose_with_dspy(kind, examples):
    import dspy

    good, bad = _split_examples(examples)
    if len(good) < 2 or not bad:
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

    class ProposeRules(dspy.Signature):
        """Given examples of AI outputs the user rated highly and outputs the
        user rated poorly, propose 1-3 short, imperative prompt rules that
        would make future outputs more like the good ones and less like the
        bad ones. Rules must be general preferences, not one-off fixes."""

        task: str = dspy.InputField(desc="what kind of output this is")
        good_examples: str = dspy.InputField()
        bad_examples: str = dspy.InputField()
        rules: list[str] = dspy.OutputField(desc="1-3 short imperative rules")

    try:
        predict = dspy.Predict(ProposeRules)
        result = predict(
            task=kind,
            good_examples=_format_examples(good),
            bad_examples=_format_examples(bad),
        )
        raw = getattr(result, "rules", None)
        if isinstance(raw, str):
            raw = [raw]
        rules = [r.strip() for r in (raw or []) if r and r.strip()]
    except Exception:
        return []

    # Confidence is the model's own certainty; without a softmax to read we
    # assign a stable, conservative value and let the compile pass's own
    # rollback gate decide whether the rules actually helped.
    return [{"rule": r, "confidence": 0.6} for r in rules[:3]]


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"engine": "unavailable", "rules": []}))
        return

    kind = payload.get("kind", "general")
    examples = payload.get("examples", [])
    if not _dspy_configured():
        print(json.dumps({"engine": "unavailable", "rules": []}))
        return

    rules = _propose_with_dspy(kind, examples)
    print(json.dumps({"engine": "dspy", "rules": rules}))


if __name__ == "__main__":
    main()
