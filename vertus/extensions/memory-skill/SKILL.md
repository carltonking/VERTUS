---
name: vertus-memory
description: "Long-term memory for this agent ({{AGENT_ID}}): per-bot notes plus fleet-shared notes — use at session start and whenever a durable fact is learned"
---

# VERTUS Memory

You have two persistent memory locations, injected for THIS agent at spawn:

- **Your own memory** — `{{AGENT_MEMORY_DIR}}/`:
  - `profile.md` — stable facts about the user you handle. Read at the start
    of every session. Update only with durable, unlikely-to-change facts.
  - `notes/` — dated task notes, one file per topic, named
    `YYYY-MM-DD-topic.md`. Read recent notes when relevant. Write a note
    for any non-trivial task whose outcome may matter later.
  - `index.json` — lightweight map of topics to note files. Keep it in
    sync when adding or renaming notes.
  This directory is YOURS alone — other agents cannot see it.

- **Fleet-shared memory** — `{{SHARED_MEMORY_DIR}}/`:
  Every VERTUS agent reads and writes this directory. Use it for facts
  that concern the whole fleet: the user's identity, standing preferences
  that apply everywhere ("always use pnpm", timezone), machine layouts,
  cross-agent coordination notes. Prefix shared note files with the topic,
  not your name; never delete another agent's shared notes.

## Rules

1. At session start, read your `profile.md` and the most recent notes
   (both locations) before answering the first question.
2. When the user states a durable preference or fact ("always use pnpm",
   "I'm on Pacific time"), decide the scope: user-wide → shared memory;
   task-specific to your duties → your own memory. Write it immediately,
   then confirm briefly.
3. When a task produces reusable knowledge (a fix that worked, a decision
   made), write a short dated note and update `index.json` (own memory for
   your topics; shared for fleet topics).
4. Never store secrets (API keys, passwords, tokens) in memory files.
5. Keep notes short; memory is a working tool, not an archive.
6. Use the `read` and `write`/`edit` tools on the memory paths — they are
   ordinary files.

(Your identity lives at `{{AGENT_SOUL_PATH}}` — see your persona skill.)
