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
**This routine is the one sanctioned exception**, under the rules below, and
it changes `facts.md` only through the helper shipped with this skill
(`memory_facts.py apply`). The hub appends captured facts while holding
`facts.md.lock` for its whole read-and-write; the helper takes the same lock,
re-reads the file and applies your edit plan to what is there *now*, so a fact
captured while you were thinking survives and the hub never writes back a
stale copy over your work.

## Scope

| File | May change |
| --- | --- |
| `{{AGENT_MEMORY_DIR}}/facts.md` | merge, prune, promote out |
| `{{SHARED_MEMORY_DIR}}/facts.md` | merge exact/near duplicates, prune clearly stale; other agents rely on it, so be conservative |
| `{{AGENT_MEMORY_DIR}}/profile.md` | add promoted agent-specific facts |
| `{{SHARED_MEMORY_DIR}}/profile.md` | add promoted user-wide facts; never remove or reword lines the user wrote |

Never touch: `facts.md` with `write_file`/`patch` (only through the helper),
`home/memories/` (`USER.md`, `MEMORY.md` — engine-owned),
`memory-digest.md`, any `index.json` / `.hub-index.json`, `*.lock` files,
`*.conflict-*` files (report them instead), another agent's private memory,
or notes other than the record you write.

## Hard rules

1. **Never delete without a record.** Every line you remove or rewrite
   appears verbatim in the record note (step 5) with the reason — except
   secrets (rule 4).
2. **No file deletion at all.** No `rm`, `trash`, `mv` to elsewhere: you
   only rewrite the files in scope. (Deleting would also stop for an
   approval nobody is awake to give.) Old snapshots are pruned by the
   helper, never by you.
3. Run the helper commands below exactly as written with the terminal; use
   the file tools (`read_file`, `write_file`, `patch`) for the profiles,
   your plan files and the record. Never `execute_code` (refused) and never
   inline scripts (`python3 -c`, heredocs) — they stop for an approval.
4. A fact that holds a secret (password, token, key, code) is removed and
   recorded as "secret-like value removed from <file>" — never copied into
   the record, a profile or a reply.
5. **Profiles: read immediately before you write** and write back in one
   step. `facts.md`: never write it yourself — the helper applies your plan
   under the hub's lock.

## Procedure

### 1. Snapshot

```bash
python3 "{{SKILLS_DIR}}/vertus-memory-consolidation/scripts/memory_facts.py" snapshot --agent-memory "{{AGENT_MEMORY_DIR}}" --shared-memory "{{SHARED_MEMORY_DIR}}" --out "{{AGENT_SNAPSHOT_DIR}}" --keep 7
```

It copies both `facts.md` and both `profile.md` into
`{{AGENT_SNAPSHOT_DIR}}/<YYYY-MM-DD>/` and keeps only the last 7 nights. That
folder is the safety net: the full pre-change state, owner-only, OUTSIDE
your memory dir, so no digest, search or other agent ever reads it. Never
copy it, quote it or link it into memory. If the command prints `error`,
stop here and reply with that one line — no snapshot, no changes.

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

### 4. Apply the facts changes

For each `facts.md` that changes, write a plan with `write_file` into the
`snapshot` folder step 1 printed — `plan-agent-facts.md` /
`plan-shared-facts.md`, next to the copies, never in memory:

```
## Remove
- (2026-09-02) lives in Boston
- (2026-10-11) Prefers short replies
## Add
- (2026-10-20) Prefers short, direct replies
```

`Remove` lists bullets exactly as they appear in the file (merged, pruned,
superseded, promoted, secret-like); `Add` lists the merged bullets (keep the
newest date). Then apply each plan:

```bash
python3 "{{SKILLS_DIR}}/vertus-memory-consolidation/scripts/memory_facts.py" apply --facts "{{AGENT_MEMORY_DIR}}/facts.md" --plan "{{AGENT_SNAPSHOT_DIR}}/<YYYY-MM-DD>/plan-agent-facts.md"
python3 "{{SKILLS_DIR}}/vertus-memory-consolidation/scripts/memory_facts.py" apply --facts "{{SHARED_MEMORY_DIR}}/facts.md" --plan "{{AGENT_SNAPSHOT_DIR}}/<YYYY-MM-DD>/plan-shared-facts.md"
```

The helper keeps the hub's header, every bullet the plan does not name
(including facts captured since you read the file) and the date order. It
prints a JSON summary; a non-zero `not_found` means a line had already
changed — list it under "Flagged", do not retry.

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

Snapshot: kept 7 nights outside memory (consolidation-snapshots/<YYYY-MM-DD>/)
```

### 6. Reply

- Nothing changed and nothing flagged → reply exactly `NOTHING_TO_REPORT`
  (the same silence sentinel the check-in uses; clients stay quiet).
- Otherwise at most three lines, e.g. "Memory tidied, sir: 4 merged, 2
  pruned, 1 promoted to your profile. Record: notes/consolidation/<date>.md".
