---
name: alfred-memory
description: Long-term memory read/write rules for ALFRED — use at session start and whenever a durable fact is learned
---

# ALFRED Memory

You have persistent memory at `~/.alfred/memory/`:

- `profile.md` — stable facts about the user: name, role, preferences,
  machines, projects, standing instructions. Read at the start of every
  session. Update only with durable, unlikely-to-change facts.
- `notes/` — dated task notes, one file per topic, named
  `YYYY-MM-DD-topic.md`. Read recent notes when relevant. Write a note
  for any non-trivial task whose outcome may matter later.
- `index.json` — lightweight map of topics to note files. Keep it in
  sync when adding or renaming notes.

## Rules

1. At session start, read `profile.md` and the most recent notes before
   answering the first question.
2. When the user states a durable preference or fact ("always use pnpm",
   "I'm on Pacific time"), add it to `profile.md` immediately, then
   confirm briefly.
3. When a task produces reusable knowledge (a fix that worked, a
   decision made), write a short dated note under `notes/` and update
   `index.json`.
4. Never store secrets (API keys, passwords, tokens) in memory files.
5. Keep notes short; memory is a working tool, not an archive.
6. Use the `read` and `write`/`edit` tools on the memory paths — they
   are ordinary files.
