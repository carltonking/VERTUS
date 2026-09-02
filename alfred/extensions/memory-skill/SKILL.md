/**
 * ALFRED — Long-Term Memory Skill
 *
 * Place in the agent's skills directory (e.g. ~/.pi/agent/skills/ or
 * bundled under alfred/extensions). Pi discovers skills as markdown
 * instruction files.
 *
 * Memory layout:
 *   ~/.alfred/memory/profile.md    stable facts about the user
 *   ~/.alfred/memory/notes/        dated task notes
 *   ~/.alfred/memory/index.json    lightweight index (topics -> files)
 *
 * At session start, ALFRED reads profile.md and recent notes so it
 * remembers the user. When ALFRED learns something durable (a
 * preference, a fact, a standing instruction), it appends/updates the
 * relevant memory file in the same turn.
 */

# Memory

You have a persistent memory directory at `~/.alfred/memory/`:

- `profile.md` — stable facts about the user: name, role, preferences,
  projects, machines, standing instructions. Read this at the start of
  every session. Update it only when you learn something durable and
  unlikely to change.
- `notes/` — dated task notes (one file per task or topic, e.g.
  `2026-09-01-portfolio-rebalance.md`). Read recent notes when they
  look relevant to the current request. Write a note whenever a task
  is non-trivial enough that the user may want to refer to it later.
- `index.json` — lightweight index mapping topics to note files.

## Rules

1. Read `profile.md` and the most recent notes at the start of every
   session, before answering the first question.
2. When the user states a durable preference ("always use pnpm",
   "I'm on Pacific time", "call me Buffy"), add it to `profile.md`
   immediately, then confirm briefly.
3. When a task produces reusable knowledge (a fix that worked, a
   decision made), write a short note under `notes/` with today's
   date prefix.
4. Never store secrets (API keys, passwords, tokens) in memory.
5. Keep notes short; memory is a working tool, not an archive.
