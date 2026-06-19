#!/usr/bin/env python3
"""
Prepare a fine-tuning dataset from Alfred's conversation history.

Reads ~/.alfred/db/memory.db (SQLite), extracts user-assistant turns,
deduplicates, augments with synthetic tool-use examples, and writes
train.jsonl / valid.jsonl in OpenAI/Fireworks JSONL format.

Usage:
  python3 AlfredMac/scripts/prepare_finetune_dataset.py
  python3 AlfredMac/scripts/prepare_finetune_dataset.py --validate-only
"""

import argparse
import hashlib
import json
import math
import os
import random
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = (
    "You are Alfred, a macOS AI assistant. You have access to: "
    "relationship memory (user's goals, projects, preferences), "
    "file export (text/PDF/DOCX/PPTX via save panel), app launching, "
    "shell execution (if enabled), web search, screen context. "
    "Keep responses concise. Use tools when appropriate. "
    "Never invent file paths. Never execute destructive commands without confirmation."
)

DB_PATH = os.path.expanduser("~/.alfred/db/memory.db")
OUTPUT_DIR = os.path.expanduser("~/.alfred/finetune/dataset")

MIN_EXAMPLES = 5_000
TARGET_EXAMPLES = 10_000
MIN_RESPONSE_LENGTH = 20
DEDUP_THRESHOLD = 0.85

# Fireworks maximum context length for Llama 3.3 is 8192 tokens.
# Leave a 192-token safety margin for response generation overhead.
MAX_TOKENS_PER_EXAMPLE = 8192 - 192

SYNTHETIC_TOOL_MIN = 1000
SYNTHETIC_MEMORY_MIN = 1000
SYNTHETIC_JSON_MIN = 500

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def estimate_tokens(text: str) -> int:
    """Rough upper-bound token count (~4 chars/token for English text)."""
    return max(1, len(text) // 4)


def example_tokens(example: dict) -> int:
    return sum(estimate_tokens(m["content"]) for m in example["messages"])


def make_example(user_msg: str, asst_msg: str) -> dict:
    return {
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
            {"role": "assistant", "content": asst_msg},
        ]
    }

# ---------------------------------------------------------------------------
# Step 1 – Read raw rows from SQLite
# ---------------------------------------------------------------------------

def read_conversations(db_path: str) -> list[dict]:
    """Read chat_history or conversation_history, adapting to schema differences.

    The running app uses `conversation_history` with a `timestamp` column,
    but some on-disk databases were created by older builds that used
    `chat_history` with a `created_at` column.  We detect and adapt.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    # Detect which table exists
    tables = [r["name"] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    if "chat_history" in tables:
        table = "chat_history"
        ts_col = "created_at"
    elif "conversation_history" in tables:
        table = "conversation_history"
        ts_col = "timestamp"
    else:
        conn.close()
        return []

    rows = conn.execute(f"""
        SELECT id, role, content, {ts_col} AS timestamp
        FROM {table}
        ORDER BY id ASC
    """).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def group_into_pairs(rows: list[dict]) -> list[dict]:
    """Group interleaved user/assistant rows into (user, assistant) pairs.

    Handles edge cases:
      - Consecutive user messages  → keep the last one before the assistant reply.
      - Orphan assistant messages   → skipped (no preceding user).
      - Unanswered user messages   → skipped (no following assistant).
    """
    pairs: list[dict] = []
    pending_user: tuple[str, float] | None = None

    for row in rows:
        role = row["role"].strip().lower()
        content = row["content"].strip()
        ts = row["timestamp"]

        if role == "user":
            pending_user = (content, ts)
        elif role == "assistant" and pending_user is not None:
            user_msg, user_ts = pending_user
            pending_user = None
            if len(content) >= MIN_RESPONSE_LENGTH:
                pairs.append({
                    "user": user_msg,
                    "assistant": content,
                    "timestamp": user_ts,
                })
        # else: orphan assistant → skip

    return pairs

# ---------------------------------------------------------------------------
# Step 2 – Deduplication (Levenshtein‑based)
# ---------------------------------------------------------------------------

def _lev_dist(a: str, b: str) -> int:
    """Classic Levenshtein distance (Wagner–Fischer, O(n*m))."""
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i]
        for j, cb in enumerate(b, 1):
            curr.append(min(
                curr[-1] + 1,       # deletion
                prev[j] + 1,        # insertion
                prev[j - 1] + (ca != cb),  # substitution
            ))
        prev = curr
    return prev[-1]


def _ratio(a: str, b: str) -> float:
    """Normalised Levenshtein similarity in [0, 1]."""
    if not a and not b:
        return 1.0
    d = _lev_dist(a, b)
    return 1.0 - d / max(len(a), len(b), 1)


def deduplicate(pairs: list[dict], threshold: float = DEDUP_THRESHOLD) -> list[dict]:
    """Greedy dedup: keep first occurrence, discard later near-duplicates."""
    kept: list[dict] = []
    for p in pairs:
        dupe = any(_ratio(p["user"], e["user"]) > threshold for e in kept)
        if not dupe:
            kept.append(p)
    return kept

# ---------------------------------------------------------------------------
# Step 3 – Synthetic data generation (template‑based, no LLM calls)
# ---------------------------------------------------------------------------

_TOOL_TEMPLATES = [
    # --- File export ---
    {"user": "Export this as a PDF please: {body}",
     "asst":  "I'll create a PDF from that content.\n\n[file_write: {filename}.pdf]\n\n{body}"},
    {"user": "Save the following to a text file: {body}",
     "asst":  "Writing a text file now.\n\n[file_write: {filename}.txt]\n\n{body}"},
    {"user": "Make a Word document with this: {body}",
     "asst":  "Creating a DOCX file.\n\n[file_write: {filename}.docx]\n\n{body}"},
    {"user": "Give me this as a PowerPoint: {body}",
     "asst":  "Converting to PowerPoint.\n\n[file_write: {filename}.pptx]\n\n{body}"},
    {"user": "Export my notes {body} as a markdown file",
     "asst":  "Exporting as Markdown.\n\n[file_write: {filename}.md]\n\n# Notes\n\n{body}"},
    # --- App launch ---
    {"user": "Open Safari",
     "asst":  "[launch_app: Safari]\n\nSafari is now open."},
    {"user": "Launch VS Code",
     "asst":  "[launch_app: Visual Studio Code]\n\nVS Code is open and ready."},
    {"user": "Open the Terminal",
     "asst":  "[launch_app: Terminal]\n\nTerminal is open."},
    {"user": "Start Slack",
     "asst":  "[launch_app: Slack]\n\nSlack is now running."},
    {"user": "Can you open Finder?",
     "asst":  "[launch_app: Finder]\n\nFinder is open to your home directory."},
    # --- Shell commands ---
    {"user": "How much free disk space do I have?",
     "asst":  "Let me check.\n\n[shell: df -h / | tail -1]\n\nYou have about 200 GB free on your main volume."},
    {"user": "List my Downloads folder",
     "asst":  "[shell: ls -la ~/Downloads | head -20]\n\nHere are the contents of your Downloads folder."},
    {"user": "What processes are consuming the most memory?",
     "asst":  "[shell: ps aux --sort=-%mem | head -15]\n\nTop memory consumers are shown above."},
    {"user": "Check my Python version",
     "asst":  "[shell: python3 --version]\n\nYou are running Python 3."},
    {"user": "Find the process using port 3000 and stop it",
     "asst":  "Let me find and terminate it.\n\n[shell: lsof -ti:3000 | xargs kill -9]\n\nProcess on port 3000 has been stopped."},
    # --- Memory recall ---
    {"user": "What projects am I currently working on?",
     "asst":  "Based on our conversations, your active projects include: Alfred (your macOS assistant) and the claude-skills repository. You are focused on shipping the v1.0 release."},
    {"user": "Do you remember what we talked about last session?",
     "asst":  "Yes — you were working on the file export capability and had questions about integrating with the native save panel."},
    {"user": "What are my preferred development tools?",
     "asst":  "From our chats you mentioned VS Code for editing, iTerm2 as your terminal, and Notion for notes."},
    {"user": "Remind me of my priorities this week",
     "asst":  "Your goals this week: (1) complete the onboarding flow, (2) ship the first beta, (3) write memory-system docs."},
    {"user": "What's my general approach to error handling?",
     "asst":  "You prefer explicit error messages that tell the user what went wrong and how to fix it, rather than silent failures."},
]


def generate_tool_use(count: int = SYNTHETIC_TOOL_MIN) -> list[dict]:
    """Template-based tool-use examples covering file export, app launch, shell, memory."""
    bodies = [
        "the quarterly revenue report",
        "my project meeting notes",
        "this research summary",
        "the code review findings",
        "the API documentation draft",
        "the database schema overview",
        "the deployment checklist",
        "the test coverage report",
        "the user feedback summary",
        "the sprint retrospective notes",
    ]
    filenames = [
        "quarterly_report", "meeting_notes", "research_summary",
        "code_review", "api_docs", "schema_overview",
        "deployment_checklist", "coverage_report",
        "user_feedback", "sprint_retro",
    ]
    examples: list[dict] = []
    for i in range(count):
        tmpl = _TOOL_TEMPLATES[i % len(_TOOL_TEMPLATES)]
        body = bodies[i % len(bodies)]
        fname = filenames[i % len(filenames)]
        user = tmpl["user"].format(body=body, filename=fname)
        asst = tmpl["asst"].format(body=body, filename=fname)
        examples.append(make_example(user, asst))
    return examples


_MEMORY_QUERIES = [
    "What was I working on last time about {t}?",
    "Do you remember what I said regarding {t}?",
    "What did we discuss about {t}?",
    "Can you recall my preferences for {t}?",
    "What do you know about {t} from our chats?",
    "Tell me about our previous conversation on {t}",
    "I mentioned something about {t} earlier — what was it?",
    "Any notes about {t}?",
    "Remind me what I asked you about {t}",
    "What have I told you about {t}?",
]

_MEMORY_TOPICS = [
    "project planning", "coding style conventions", "automation workflows",
    "file organisation", "keyboard shortcuts", "productivity habits",
    "app development", "testing strategy", "documentation style",
    "design patterns", "API design", "database choices",
    "deployment pipeline", "CI/CD setup", "security practices",
    "performance optimisation", "code review process", "git workflow",
    "monitoring and alerting", "error handling patterns",
]


def generate_memory_injection(count: int = SYNTHETIC_MEMORY_MIN) -> list[dict]:
    """Synthetic examples where user refers to prior conversations."""
    examples: list[dict] = []
    responses = [
        "From our previous conversations, I recall you've discussed {t}. You mentioned you prefer a structured approach with clear documentation. Would you like me to elaborate on any specific part?",
        "Yes — we talked about {t} before. You shared that you value simplicity and maintainability over clever solutions. The key points were around establishing consistent patterns.",
        "I remember our discussion about {t}. Your main takeaway was to prioritise clarity and invest in good tooling. I have this stored in my relationship memory.",
        "Based on what you've told me, you approach {t} by first understanding the requirements, then prototyping quickly, and iterating based on feedback. That's been a consistent theme.",
        "You've mentioned {t} several times. Your philosophy is to keep things modular, well-documented, and easy to change. You also emphasised the importance of good testing.",
    ]
    for i in range(count):
        q = _MEMORY_QUERIES[i % len(_MEMORY_QUERIES)]
        t = _MEMORY_TOPICS[i % len(_MEMORY_TOPICS)]
        r = responses[i % len(responses)]
        examples.append(make_example(q.format(t=t), r.format(t=t)))
    return examples


_JSON_TEMPLATES = [
    {
        "user": "Summarise {t} in JSON with keys: title, key_points, conclusion",
        "asst": (
            "```json\n"
            '{{\n'
            '  "title": "{title}",\n'
            '  "key_points": [\n'
            '    "Structured data improves machine readability",\n'
            '    "JSON is the most widely supported format",\n'
            '    "A clear schema reduces ambiguity"\n'
            '  ],\n'
            '  "conclusion": "{t} benefits strongly from structured formatting"\n'
            '}}\n'
            "```\n\n"
            "Here is the structured summary."
        ),
    },
    {
        "user": "List the options as a JSON array of objects with name and description",
        "asst": (
            "```json\n"
            '[\n'
            '  {{\n'
            '    "name": "Option A",\n'
            '    "description": "Best for most users — balanced trade-offs"\n'
            '  }},\n'
            '  {{\n'
            '    "name": "Option B",\n'
            '    "description": "Optimised for scale and throughput"\n'
            '  }},\n'
            '  {{\n'
            '    "name": "Option C",\n'
            '    "description": "Minimal setup, limited flexibility"\n'
            '  }}\n'
            ']\n'
            "```\n\n"
            "Here are the options formatted as JSON."
        ),
    },
    {
        "user": "Extract the key entities from this and output JSON: {t}",
        "asst": (
            "```json\n"
            '{{\n'
            '  "entities": [\n'
            '    {{"name": "Primary Concept", "type": "idea"}},\n'
            '    {{"name": "Implementation Detail", "type": "technique"}}\n'
            '  ],\n'
            '  "relationships": [\n'
            '    {{"source": "Primary Concept", "target": "Implementation Detail", "relation": "requires"}}\n'
            '  ]\n'
            '}}\n'
            "```\n\n"
            "Entities extracted as JSON."
        ),
    },
    {
        "user": "Convert this into a JSON schema: {t}",
        "asst": (
            "```json\n"
            '{{\n'
            '  "$schema": "http://json-schema.org/draft-07/schema#",\n'
            '  "type": "object",\n'
            '  "properties": {{\n'
            '    "id": {{"type": "integer"}},\n'
            '    "name": {{"type": "string"}},\n'
            '    "description": {{"type": "string"}},\n'
            '    "metadata": {{"type": "object"}}\n'
            '  }},\n'
            '  "required": ["id", "name"]\n'
            '}}\n'
            "```\n\n"
            "Here is the JSON Schema representing {t}."
        ),
    },
]

_JSON_TOPICS = [
    "the project roadmap",
    "the architecture overview",
    "the API endpoints",
    "the data model",
    "the deployment plan",
    "the testing strategy",
    "the user research findings",
    "the performance benchmarks",
]


def generate_json_mode(count: int = SYNTHETIC_JSON_MIN) -> list[dict]:
    """Synthetic examples requesting structured / JSON output."""
    examples: list[dict] = []
    for i in range(count):
        tmpl = _JSON_TEMPLATES[i % len(_JSON_TEMPLATES)]
        t = _JSON_TOPICS[i % len(_JSON_TOPICS)]
        title = t.strip().title()
        user = tmpl["user"].format(t=t, title=title)
        asst = tmpl["asst"].format(t=t, title=title)
        examples.append(make_example(user, asst))
    return examples

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_file(path: str, label: str) -> dict:
    """Read a JSONL file and return validation stats."""
    stats = {"file": path, "label": label, "count": 0, "over_limit": 0, "malformed": 0, "token_counts": []}
    with open(path) as f:
        for line in f:
            stats["count"] += 1
            line = line.strip()
            if not line:
                continue
            try:
                ex = json.loads(line)
            except json.JSONDecodeError:
                stats["malformed"] += 1
                continue
            # Validate structure
            if "messages" not in ex or not isinstance(ex["messages"], list):
                stats["malformed"] += 1
                continue
            roles = [m.get("role") for m in ex["messages"]]
            if roles != ["system", "user", "assistant"]:
                stats["malformed"] += 1
                continue
            tc = example_tokens(ex)
            stats["token_counts"].append(tc)
            if tc > MAX_TOKENS_PER_EXAMPLE:
                stats["over_limit"] += 1
    if stats["token_counts"]:
        stats["avg_tokens"] = sum(stats["token_counts"]) / len(stats["token_counts"])
        stats["max_tokens"] = max(stats["token_counts"])
        stats["min_tokens"] = min(stats["token_counts"])
    else:
        stats["avg_tokens"] = stats["max_tokens"] = stats["min_tokens"] = 0
    del stats["token_counts"]
    return stats

# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def run_pipeline(db_path: str, output_dir: str, target: int, min_examples: int) -> dict:
    os.makedirs(output_dir, exist_ok=True)

    # 1 – Read
    rows = read_conversations(db_path)
    print(f"[1/7] Read {len(rows)} conversation rows")

    # 2 – Group
    pairs = group_into_pairs(rows)
    print(f"[2/7] Grouped into {len(pairs)} user–assistant pairs")

    # 3 – Deduplicate
    pairs = deduplicate(pairs)
    print(f"[3/7] After deduplication: {len(pairs)} pairs")

    # 4 – Format real examples
    real = [make_example(p["user"], p["assistant"]) for p in pairs]
    real = [ex for ex in real if example_tokens(ex) <= MAX_TOKENS_PER_EXAMPLE]
    print(f"[4/7] Real examples within token limit: {len(real)}")

    # 5 – Synthetic augmentation (auto-scale to meet target)
    deficit = target - len(real)
    if deficit > 0:
        total_synth_min = SYNTHETIC_TOOL_MIN + SYNTHETIC_MEMORY_MIN + SYNTHETIC_JSON_MIN
        scale = max(1, math.ceil(deficit / total_synth_min))
        synth_tool = generate_tool_use(SYNTHETIC_TOOL_MIN * scale)
        synth_mem = generate_memory_injection(SYNTHETIC_MEMORY_MIN * scale)
        synth_json = generate_json_mode(SYNTHETIC_JSON_MIN * scale)
        synthetic = synth_tool + synth_mem + synth_json
        print(f"[5/7] Synthetic examples: {len(synthetic)} (tool={len(synth_tool)}, "
              f"memory={len(synth_mem)}, json={len(synth_json)}, scale={scale}x)")
    else:
        synth_tool = generate_tool_use(SYNTHETIC_TOOL_MIN)
        synth_mem = generate_memory_injection(SYNTHETIC_MEMORY_MIN)
        synth_json = generate_json_mode(SYNTHETIC_JSON_MIN)
        synthetic = synth_tool + synth_mem + synth_json
        print(f"[5/7] Synthetic examples: {len(synthetic)} "
              f"(real only meets target, using base synthetic count)")

    # 6 – Combine and split
    all_examples = real + synthetic
    random.shuffle(all_examples)

    selected = all_examples[:target]
    if len(selected) < min_examples:
        print(f"  WARNING: only {len(selected)} examples available "
              f"(minimum requested: {min_examples})")

    split = int(len(selected) * 0.9)
    train = selected[:split]
    valid = selected[split:]

    train_path = os.path.join(output_dir, "train.jsonl")
    valid_path = os.path.join(output_dir, "valid.jsonl")

    with open(train_path, "w") as f:
        for ex in train:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")
    with open(valid_path, "w") as f:
        for ex in valid:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    print(f"[6/7] Wrote train={len(train)}  valid={len(valid)}  → {output_dir}/")

    # 7 – Stats
    stats = {
        "total_raw_rows": len(rows),
        "real_pairs": len(pairs),
        "real_examples": len(real),
        "synthetic_tool": len(synth_tool),
        "synthetic_memory": len(synth_mem),
        "synthetic_json": len(synth_json),
        "train_count": len(train),
        "valid_count": len(valid),
        "target": target,
        "min_examples": min_examples,
        "token_limit": MAX_TOKENS_PER_EXAMPLE,
        "real_in_train": sum(1 for ex in train if ex in real),
        "output_dir": output_dir,
    }

    # Validate
    train_stats = validate_file(train_path, "train")
    valid_stats = validate_file(valid_path, "valid")
    stats["train_validation"] = train_stats
    stats["valid_validation"] = valid_stats

    stats_path = os.path.join(output_dir, "stats.json")
    with open(stats_path, "w") as f:
        json.dump(stats, f, indent=2, default=str)

    print(f"[7/7] Stats written to {stats_path}")
    return stats


def print_examples(path: str, n: int = 3):
    with open(path) as f:
        lines = [line.strip() for line in f if line.strip()][:n]
    for i, line in enumerate(lines, 1):
        ex = json.loads(line)
        print(f"\n--- Example {i} (tokens={example_tokens(ex)}) ---")
        for msg in ex["messages"]:
            preview = msg["content"][:120].replace("\n", " ")
            print(f"  [{msg['role']}] {preview}...")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Prepare Alfred fine-tuning dataset from conversation history."
    )
    parser.add_argument("--db", default=DB_PATH,
                        help=f"Path to memory.db (default: {DB_PATH})")
    parser.add_argument("--output", default=OUTPUT_DIR,
                        help=f"Output directory (default: {OUTPUT_DIR})")
    parser.add_argument("--target", type=int, default=TARGET_EXAMPLES,
                        help=f"Target example count (default: {TARGET_EXAMPLES})")
    parser.add_argument("--min-examples", type=int, default=MIN_EXAMPLES,
                        help=f"Minimum acceptable (default: {MIN_EXAMPLES})")
    parser.add_argument("--validate-only", action="store_true",
                        help="Skip generation, just validate existing files")
    parser.add_argument("--seed", type=int, default=42,
                        help="Random seed (default: 42)")
    parser.add_argument("--show-examples", type=int, default=3,
                        help="Print this many examples after generation (default: 3)")
    args = parser.parse_args()

    random.seed(args.seed)

    db_path = os.path.expanduser(args.db)
    output_dir = os.path.expanduser(args.output)

    if args.validate_only:
        for fname in ("train.jsonl", "valid.jsonl"):
            path = os.path.join(output_dir, fname)
            if not os.path.exists(path):
                print(f"File not found: {path}")
                continue
            stats = validate_file(path, fname.replace(".jsonl", ""))
            print(f"\n{stats['label']}:")
            for k, v in stats.items():
                if k in ("label", "file"):
                    continue
                print(f"  {k}: {v}")
        return

    if not os.path.exists(db_path):
        print(f"ERROR: database not found at {db_path}")
        print("Make sure Alfred has been run at least once to create the database.")
        sys.exit(1)

    stats = run_pipeline(
        db_path=db_path,
        output_dir=output_dir,
        target=args.target,
        min_examples=args.min_examples,
    )

    train_path = os.path.join(output_dir, "train.jsonl")
    print(f"\n{'='*60}")
    print(f"Dataset summary:")
    print(f"  Real examples:     {stats['real_examples']}")
    print(f"  Synthetic tool:    {stats['synthetic_tool']}")
    print(f"  Synthetic memory:  {stats['synthetic_memory']}")
    print(f"  Synthetic json:    {stats['synthetic_json']}")
    print(f"  Train:             {stats['train_count']}")
    print(f"  Valid:             {stats['valid_count']}")
    print(f"  Train over limit:  {stats['train_validation']['over_limit']}")
    print(f"  Valid over limit:  {stats['valid_validation']['over_limit']}")
    print(f"  Train avg tokens:  {stats['train_validation']['avg_tokens']:.0f}")
    print(f"  Valid avg tokens:  {stats['valid_validation']['avg_tokens']:.0f}")

    if args.show_examples and stats["train_count"] > 0:
        print(f"\n{'='*60}")
        print(f"Sample rows from train.jsonl:")
        print_examples(train_path, args.show_examples)


if __name__ == "__main__":
    main()
