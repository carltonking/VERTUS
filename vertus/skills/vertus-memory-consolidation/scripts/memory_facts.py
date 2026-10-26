#!/usr/bin/env python3
"""Snapshot and rewrite facts.md for the nightly memory consolidation.

    python3 memory_facts.py snapshot --agent-memory DIR --shared-memory DIR
                                     --out SNAPSHOT_ROOT [--keep 7]
    python3 memory_facts.py apply --facts PATH/facts.md --plan PLAN.md

``snapshot`` copies both facts.md and profile.md files into
``SNAPSHOT_ROOT/<YYYY-MM-DD>/`` (owner-only permissions) and keeps only the
newest ``--keep`` dated folders. The root must sit outside both memory dirs:
the hub indexes, searches and digests everything under memory/, and these
copies hold the very lines consolidation removes — secrets included — so
they must never reach a digest or another agent, nor pile up forever.

``apply`` edits a facts.md through the hub's own lock. The hub folds
auto-captured facts into facts.md under ``facts.md.lock`` (fcntl) for its
whole read-modify-write; this takes the same lock, re-reads the file, and
applies the plan as an edit — remove these exact bullets, add these — so a
fact captured after the agent read the file survives, and a capture can
never overwrite the consolidated file with a stale copy. A plan is::

    ## Remove
    - (2026-10-01) lives in Boston
    ## Add
    - (2026-10-20) moved to NYC

Bullets end up in date order under the hub's header. Prints a JSON summary.
Run as a file (not ``python3 -c`` or a heredoc) so the engine's approval
gate never parks the unattended nightly run.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

FACTS_FILE = "facts.md"
FACTS_HEADER = "# Facts (hub-maintained — read me, do not edit)"
SNAPSHOT_SOURCES = (
    ("agent", FACTS_FILE, "before-agent-facts.md"),
    ("shared", FACTS_FILE, "before-shared-facts.md"),
    ("agent", "profile.md", "before-agent-profile.md"),
    ("shared", "profile.md", "before-shared-profile.md"),
)
_DATE_DIR = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_DATED = re.compile(r"^\((\d{4}-\d\d-\d\d)\)\s*")


# -- facts.md shape (mirrors fleet_memory's bullet rules) --------------------

def is_bullet(line: str) -> bool:
    t = line.strip()
    return t.startswith("- ") or t.startswith("* ")


def bullet_text(line: str) -> str:
    return re.sub(r"^[-*]\s*", "", line.strip())


def normalize(line: str) -> str:
    """Dedupe key: no bullet, no leading (date), collapsed, lowercase."""
    text = _DATED.sub("", bullet_text(line))
    return " ".join(text.split()).lower()


def bullet_date(line: str) -> str:
    m = _DATED.match(bullet_text(line))
    return m.group(1) if m else ""


@contextlib.contextmanager
def facts_lock(path: Path):
    """The hub's per-file lock (fleet_memory.MemoryStore._file_lock)."""
    lock_path = path.with_name(path.name + ".lock")
    with open(lock_path, "a+", encoding="utf-8") as fd:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)


def atomic_write(path: Path, text: str) -> None:
    # A dot-named temp: the hub's watcher skips dotfiles, so it never
    # indexes a half-written file.
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp",
                               dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        if path.exists():
            os.chmod(tmp, path.stat().st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def parse_plan(text: str) -> tuple[list[str], list[str]]:
    """(remove, add) bullet lines from a plan; anything else is ignored."""
    remove: list[str] = []
    add: list[str] = []
    section = None
    for line in text.splitlines():
        head = line.strip().lower()
        if head.startswith("#"):
            word = head.lstrip("#").strip()
            section = word if word in ("remove", "add") else None
            continue
        if section and is_bullet(line):
            (remove if section == "remove" else add).append(line.strip())
    return remove, add


def apply_plan(current: str, remove: list[str], add: list[str],
               today: str) -> tuple[str, dict]:
    """Pure: the new facts.md body and a summary. Removals match a bullet
    exactly, else by meaning (same text, any date); one removal removes one
    line. Bullets the plan does not name — including ones captured after
    the agent read the file — are kept as they are."""
    lines = current.splitlines()
    preamble = [l for l in lines if l.strip() and not is_bullet(l)
                and l.strip() != FACTS_HEADER]
    bullets = [l.rstrip() for l in lines if is_bullet(l)]
    removed, not_found = 0, []
    for target in remove:
        idx = next((i for i, b in enumerate(bullets) if b.strip() == target.strip()), None)
        if idx is None:
            key = normalize(target)
            idx = next((i for i, b in enumerate(bullets) if normalize(b) == key), None)
        if idx is None:
            not_found.append(target)
            continue
        del bullets[idx]
        removed += 1
    seen = {normalize(b) for b in bullets}
    added, duplicate = 0, 0
    for line in add:
        text = " ".join(bullet_text(line).split())
        if not _DATED.match(text):
            text = f"({today}) {text}"
        key = normalize(text)
        if not key or key in seen:
            duplicate += 1
            continue
        seen.add(key)
        bullets.append(f"- {text}")
        added += 1
    bullets.sort(key=bullet_date)  # stable: same-date bullets keep order
    body = "\n".join([FACTS_HEADER, "", *preamble, *bullets]).rstrip() + "\n"
    return body, {"removed": removed, "added": added,
                  "skipped_duplicates": duplicate,
                  "not_found": len(not_found), "bullets": len(bullets)}


def cmd_apply(facts: Path, plan: Path, today: str) -> dict:
    if facts.name != FACTS_FILE:
        raise ValueError(f"refusing to edit {facts.name}: only {FACTS_FILE}")
    remove, add = parse_plan(plan.read_text(encoding="utf-8"))
    facts.parent.mkdir(parents=True, exist_ok=True)
    with facts_lock(facts):
        try:
            current = facts.read_text(encoding="utf-8")
        except FileNotFoundError:
            current = ""
        body, summary = apply_plan(current, remove, add, today)
        if body != current:
            atomic_write(facts, body)
        summary["changed"] = body != current
    summary["facts"] = str(facts)
    return summary


# -- snapshot + retention ----------------------------------------------------

def _inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def cmd_snapshot(agent_mem: Path, shared_mem: Path, out_root: Path,
                 keep: int, today: str) -> dict:
    for mem in (agent_mem, shared_mem):
        if _inside(out_root, mem):
            raise ValueError("snapshot root must be outside the memory dirs "
                             "(the hub indexes and digests everything there)")
    keep = max(1, int(keep))
    out_root.mkdir(parents=True, exist_ok=True)
    os.chmod(out_root, 0o700)
    dest = out_root / today
    dest.mkdir(exist_ok=True)
    os.chmod(dest, 0o700)
    copied, existing = [], []
    for scope, name, target in SNAPSHOT_SOURCES:
        src = (agent_mem if scope == "agent" else shared_mem) / name
        out = dest / target
        if out.exists():
            # A rerun the same night must not replace the pre-change copy
            # with the already-consolidated file.
            existing.append(target)
            continue
        if not src.is_file():
            continue
        lock = facts_lock(src) if name == FACTS_FILE else contextlib.nullcontext()
        with lock:
            data = src.read_bytes()
        out.write_bytes(data)
        os.chmod(out, 0o600)
        copied.append(target)
    dated = sorted((p for p in out_root.iterdir()
                    if p.is_dir() and not p.is_symlink() and _DATE_DIR.match(p.name)),
                   key=lambda p: p.name, reverse=True)
    pruned = []
    for old in dated[keep:]:
        shutil.rmtree(old)
        pruned.append(old.name)
    return {"snapshot": str(dest), "copied": copied,
            "already_present": existing, "pruned": sorted(pruned),
            "kept": [p.name for p in dated[:keep]]}


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--agent-memory", required=True, type=Path)
    snap.add_argument("--shared-memory", required=True, type=Path)
    snap.add_argument("--out", required=True, type=Path)
    snap.add_argument("--keep", type=int, default=7)
    snap.add_argument("--date", default=None, help=argparse.SUPPRESS)
    app = sub.add_parser("apply")
    app.add_argument("--facts", required=True, type=Path)
    app.add_argument("--plan", required=True, type=Path)
    app.add_argument("--date", default=None, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    today = args.date or time.strftime("%Y-%m-%d")
    if not _DATE_DIR.match(today):
        print(json.dumps({"error": "bad --date"}))
        return 2
    try:
        if args.cmd == "snapshot":
            result = cmd_snapshot(args.agent_memory, args.shared_memory,
                                  args.out, args.keep, today)
        else:
            result = cmd_apply(args.facts, args.plan, today)
    except (OSError, ValueError) as exc:
        print(json.dumps({"error": str(exc)[:300]}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
