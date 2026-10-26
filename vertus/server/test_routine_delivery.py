"""Routine replies reach the user's phone — only when configured, only news."""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))  # noqa: E402

import routine_delivery as rd  # noqa: E402


class _Store:
    def __init__(self, run, routine, messages):
        self.run, self.routine, self.messages = run, routine, messages

    def get_run(self, run_id):
        return self.run

    def get_routine(self, routine_id):
        return self.routine

    def run_messages(self, run_id):
        return self.messages


def _deliver(tmp_path, run, routine, reply, configured=True):
    cfg = tmp_path / "notify.json"
    if configured:
        cfg.write_text(json.dumps({"imessage_to": "+15555550123"}))
    sent: list = []
    store = _Store(run, routine, [{"role": "user", "text": "go"}, {"role": "assistant", "text": reply}])
    d = rd.PhoneDelivery(lambda: store, send=lambda to, text: sent.append((to, text)), settle_s=0, path=cfg)
    if rd.destination(cfg):
        d._deliver("r1", rd.destination(cfg))
    return sent


RUN = {"run_kind": "routine", "state": "done", "routine_id": "x"}


def test_a_brief_is_texted_to_the_configured_number(tmp_path):
    sent = _deliver(tmp_path, RUN, {"name": "morning-brief"}, "Good morning, sir.")
    assert sent == [("+15555550123", "Good morning, sir.")]


def test_nothing_is_sent_without_a_number(tmp_path):
    assert _deliver(tmp_path, RUN, {"name": "morning-brief"}, "Good morning", configured=False) == []


def test_silence_and_housekeeping_are_never_texted(tmp_path):
    assert _deliver(tmp_path, RUN, {"name": "check-in"}, "`NOTHING_TO_REPORT`") == []
    assert _deliver(tmp_path, RUN, {"name": "memory-consolidation"}, "Memory tidied, sir.") == []


def test_only_finished_routine_runs_are_texted(tmp_path):
    assert _deliver(tmp_path, {**RUN, "run_kind": "user"}, None, "pong") == []
    assert _deliver(tmp_path, {**RUN, "state": "error"}, {"name": "morning-brief"}, "half") == []


def test_long_replies_are_cut(tmp_path):
    sent = _deliver(tmp_path, RUN, {"name": "morning-brief"}, "x" * 5000)
    assert len(sent[0][1]) == rd.MAX_CHARS and sent[0][1].endswith("…")


def test_hook_ignores_non_routine_runs_cheaply(tmp_path):
    d = rd.PhoneDelivery(lambda: None, send=lambda *a: (_ for _ in ()).throw(AssertionError()),
                         settle_s=0, path=tmp_path / "missing.json")
    d.on_run_done("r1", "primary", None, None, "user", "done")
    d.on_run_done("r1", "primary", None, None, "routine", "error")
