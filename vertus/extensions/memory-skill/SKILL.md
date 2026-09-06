---
name: vertus-memory
description: "Long-term memory for this agent ({{AGENT_ID}}): per-bot notes plus fleet-shared notes — use at session start and whenever a durable fact is learned"
---

# VERTUS Memory

You have two persistent memory locations, injected for THIS agent at spawn.
The hub owns and indexes these files — you never maintain an index by hand;
the hub detects every change and broadcasts it to the whole fleet.

- **Your own memory** — `{{AGENT_MEMORY_DIR}}/`:
  - `profile.md` — stable facts about the user you handle. Read at the start
    of every session. Update only with durable, unlikely-to-change facts.
  - `notes/` — dated task notes, one file per topic, named
    `YYYY-MM-DD-topic.md`. Read recent notes when relevant. Write a note
    for any non-trivial task whose outcome may matter later.
  - `USER.md` / `MEMORY.md` — fleet-wide user preferences and environment
    notes mirrored here from your engine home by the hub (fork-owned
    originals; treat these copies as read-mostly).
  This directory is YOURS alone — other agents cannot see it.

- **Fleet-shared memory** — `{{SHARED_MEMORY_DIR}}/`:
  Every VERTUS agent reads and writes this directory. Use it for facts
  that concern the whole fleet: the user's identity, standing preferences
  that apply everywhere ("always use pnpm", timezone), machine layouts,
  cross-agent coordination notes. Prefix shared note files with the topic,
  not your name; never delete another agent's shared notes. `USER.md` here
  is the seeded fleet-wide preference file — read it, and update it when
  the user states a new fleet-wide preference.

## Rules

1. At session start, read your `profile.md`, `USER.md` and the most recent
   notes (both locations) before answering the first question. Never recite
   memory contents back — behave as if you already know.
2. When the user states a durable preference or fact ("always use pnpm",
   "I'm on Pacific time"), decide the scope: user-wide → shared memory;
   task-specific to your duties → your own memory. Write it immediately,
   then confirm briefly.
3. When a task produces reusable knowledge (a fix that worked, a decision
   made), write a short dated note (own memory for your topics; shared for
   fleet topics). Do NOT maintain any index file — the hub indexes
   automatically.
4. **Read before you write shared files.** Shared memory can be written by
   other agents at the same time: read the file, make your change, and
   write it back in one step. Never append blindly to a file you have not
   read this turn, and never delete another agent's notes.
5. Never store secrets (API keys, passwords, tokens) in memory files.
6. Keep notes short; memory is a working tool, not an archive.
7. Use the `read` and `write`/`edit` tools on the memory paths — they are
   ordinary files; the hub sees every change live.

(Your identity lives at `{{AGENT_SOUL_PATH}}` — see your persona skill.)