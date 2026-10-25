---
name: vertus-memory-consolidation
description: "Nightly memory consolidation for {{AGENT_NAME}}: merge duplicate facts, prune stale ones, promote durable facts to profile.md, and write a dated record of every change. Never removes anything without keeping a record."
---

# VERTUS Memory Consolidation

Run by the nightly `memory-consolidation` routine. Captured facts pile up:
the hub appends a dated bullet to `facts.md` after conversations and only
deduplicates exact repeats. This pass keeps memory small, current and
truthful.

`facts.md` is hub-maintained and the memory skill tells you never to edit it.
**This routine is the one sanctioned exception**, under the rules below. The
hub's capture re-reads `facts.md` before every append, so a consolidated file
stays consolidated.

## Scope

| File | May change |
| --- | --- |
| `{{AGENT_MEMORY_DIR}}/facts.md` | merge, prune, promote out |
| `{{SHARED_MEMORY_DIR}}/facts.md` | merge exact/near duplicates, prune clearly stale; other agents rely on it, so be conservative |
| `{{AGENT_MEMORY_DIR}}/profile.md` | add promoted agent-specific facts |
| `{{SHARED_MEMORY_DIR}}/profile.md` | add promoted user-wide facts; never remove or reword lines the user wrote |

Never touch: `home/memories/` (`USER.md`, `MEMORY.md` — engine-owned),
`memory-digest.md`, any `index.json` / `.hub-index.json`, `*.lock` files,
`*.conflict-*` files (report them instead), another agent's private memory,
or notes other than the record you write.

## Hard rules

1. **Never delete without a record.** Every line you remove or rewrite
   appears verbatim in the record note (step 5) with the reason — except
   secrets (rule 4).
2. **No file deletion at all.** No `rm`, `trash`, `mv` to elsewhere: you
   only rewrite the files in scope. (Deleting would also stop for an
   approval nobody is awake to give.)
3. Use the file tools (`read_file`, `write_file`, `patch`) and the terminal
   for `date`/`cp`; not `execute_code`.
4. A fact that holds a secret (password, token, key, code) is removed and
   recorded as "secret-like value removed from <file>" — never copied.
5. **Read immediately before you write** each file and write it back in one
   step; if new bullets appeared since your first read (a capture landed),
   keep them.

## Procedure

### 1. Snapshot

```bash
D=$(date +%F); A="{{AGENT_MEMORY_DIR}}/notes/consolidation/$D"; mkdir -p "$A"
cp "{{AGENT_MEMORY_DIR}}/facts.md"   "$A/before-agent-facts.md"   2>/dev/null
cp "{{SHARED_MEMORY_DIR}}/facts.md"  "$A/before-shared-facts.md"  2>/dev/null
cp "{{AGENT_MEMORY_DIR}}/profile.md" "$A/before-agent-profile.md" 2>/dev/null
cp "{{SHARED_MEMORY_DIR}}/profile.md" "$A/before-shared-profile.md" 2>/dev/null
```

These copies are the safety net: the full pre-change state, kept under a
dated folder (outside the digest's "recent notes", so they never crowd
recall).

### 2. Classify every bullet in both `facts.md` files

Bullets look like `- (YYYY-MM-DD) fact`. For each one decide:

- **Duplicate / near-duplicate** — same meaning, different words → merge into
  one bullet: the most specific wording, the NEWEST date.
- **Contradiction** — two facts disagree ("lives in Boston" vs "moved to
  NYC") → keep the newer, remove the older.
- **Stale** — time-bound and over: a dated event that has passed, "currently
  working on X" older than ~60 days with nothing newer about X, a one-off
  task that is done. Remove.
- **Durable** — identity, standing preferences, relationships, recurring
  patterns, long-running projects → promote (step 3).
- **Keep** — everything else stays exactly as written.

When unsure, keep. Removing a true fact is worse than keeping a stale one.

### 3. Promote durable facts

- User-wide (identity, preferences every agent should honour) →
  `{{SHARED_MEMORY_DIR}}/profile.md`.
- About your own duties → `{{AGENT_MEMORY_DIR}}/profile.md`.

Add it under the heading where it belongs (create a `## Learned` section at
the end if none fits), as plain prose or a bullet without the date. Skip it if
the profile already says the same thing. Then remove the bullet from
`facts.md` — the profile now holds it.

### 4. Write the files

Each `facts.md` keeps its first line exactly:
`# Facts (hub-maintained — read me, do not edit)`, a blank line, then the
surviving bullets in date order, one per line, format unchanged.

### 5. Write the record

If anything changed, write `{{AGENT_MEMORY_DIR}}/notes/consolidation/<YYYY-MM-DD>.md`:

```
# Memory consolidation — <YYYY-MM-DD>

## Merged
- <old line> + <old line> → <new line>   (<file>)
## Pruned
- <old line> — <reason: stale | superseded by …>   (<file>)
## Promoted
- <old line> → <profile file>, under "<heading>"
## Flagged (left alone)
- <conflict files, doubtful items, anything needing the user>

Snapshot: notes/consolidation/<YYYY-MM-DD>/
```

### 6. Reply

- Nothing changed and nothing flagged → reply exactly `NOTHING_TO_REPORT`
  (the same silence sentinel the check-in uses; clients stay quiet).
- Otherwise at most three lines, e.g. "Memory tidied, sir: 4 merged, 2
  pruned, 1 promoted to your profile. Record: notes/consolidation/<date>.md".
