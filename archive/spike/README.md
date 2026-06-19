# Alfred

A self-learning, personalizing macOS AI agent. Alfred **remembers** what you do
(via [Screenpipe](https://screenpipe.com)), **learns** your writing style and the
people you talk to, and **acts** on your computer through a steerable local LLM
([Hermes](https://huggingface.co/NousResearch)) — local-first, with permission
required for every state-changing action.

> Status: **Phase 0 — Foundations & de-risk spikes.** This repo currently contains
> only a SwiftPM CLI used to prove the foundation (Screenpipe capture + local
> Hermes tool-calling) is real on the target machine before the app is built.

## The stack (one stack, three layers)

| Layer | What | Project |
|---|---|---|
| Senses | 24/7 screen + audio memory, OCR, transcription | Screenpipe (adopted) |
| Brain | Steerable, tool-calling local LLM | Hermes 3 8B via Ollama |
| Hands + glue | Memory retrieval, personalization, relationship map, **gated** actions | Alfred (this repo) |

See the full strategy + roadmap: `~/.claude/plans/i-m-building-alfred-a-binary-puppy.md`.

## Target machine reality (M1 Pro · 16GB · ~93GB free)

- **Model:** `hermes3:8b` (primary), `hermes3:3b` (fallback under RAM pressure).
  Hermes 4 (14B+) does not fit 16GB. Local only — no subscriptions, no cloud for private data.
- **Loaded on demand**, not resident 24/7, so capture keeps its RAM.
- **Storage is the tight constraint:** keep OCR/transcript *text* long-term, prune raw
  video/audio after a few days. See the storage policy in the plan.

## Prerequisites

```bash
# Already present on this machine: Swift 6.3, Ollama, git.
# Needed for the Phase 0 spikes:
ollama pull hermes3:8b            # ~4.9 GB
ollama pull nomic-embed-text      # ~0.27 GB (embeddings, used later)
# Screenpipe: install per https://screenpipe.com (runs a localhost REST API, default :3030)
```

## CLI

```bash
# Phase 0 — de-risk
swift run alfred-spike doctor     # check Ollama + RAM/disk
swift run alfred-spike model      # hermes3:8b tool-call + JSON-schema test
swift run alfred-spike screen     # native ScreenCaptureKit grab + Vision OCR (needs Screen Recording perm)
swift run alfred-spike ocr <img>  # Vision OCR on an image file (no permission needed)

# Phase 1 — memory + retrieval
swift run alfred-spike watch [s]  # capture loop: screen → OCR → embed → store every s sec (default 5)
swift run alfred-spike ask "q"    # answer from your screen memory (RAG via hermes3:8b)
swift run alfred-spike stats      # memory store counts + path

# Phase 2 — writing style
swift run alfred-spike style-add "a real thing you wrote"   # seed clean samples
swift run alfred-spike style-build                          # distill style card
swift run alfred-spike draft "reply to Sam declining 3pm"   # write in your voice (read-only)
swift run alfred-spike style-export                         # MLX LoRA-ready JSONL (later fine-tuning)

# Phase 3 — relationship map
swift run alfred-spike people-scan                          # extract people + interactions from memory
swift run alfred-spike people                               # who you talk to (counts, last contact)
swift run alfred-spike people-clean                         # drop orgs/self/junk + merge duplicates
swift run alfred-spike person "Sam"                         # summarize your relationship + threads
# draft auto-grounds in a person's history when their name appears in the intent

# Phase 4 — action gateway (the trust core)
swift run alfred-spike act create /tmp/note.txt "hello"   # contained action → runs free
swift run alfred-spike act run "echo hi"                  # local shell → free
swift run alfred-spike act delete /tmp/note.txt           # irreversible → confirms
swift run alfred-spike act run "rm -rf x"                 # destructive/outward → confirms
swift run alfred-spike act screen-test                    # screen-originated action → BLOCKED
swift run alfred-spike audit                              # append-only action log

# Phase 5 — agent loop (the capstone)
swift run alfred-spike do "make a note at /tmp/todo.txt with: buy milk, call mom"
swift run alfred-spike do "summarize my chat with Jonas and save it to a file"
# NL → hermes3:8b tool calls → executed via the gateway, grounded in memory + people.
# Risky/outward steps still confirm; everything is audited.

# Phase 6 — self-learning
swift run alfred-spike feedback good                 # reinforce the last output
swift run alfred-spike feedback bad "too long, no emojis at work"   # learn a rule
swift run alfred-spike feedback edit "your better version"          # learn from an edit
swift run alfred-spike prefs                          # show learned preferences
# Learned preferences are injected into every future draft + agent action.

# Phase 7 — UI automation (needs Accessibility permission)
# System Settings ▸ Privacy & Security ▸ Accessibility → enable your terminal/IDE
swift run alfred-spike ui list                 # clickable controls in the frontmost app
swift run alfred-spike ui type "hello"         # type into the focused field
swift run alfred-spike ui click "Send"         # click a button (confirms — outward)
# The agent (`do`) can also click_ui / type_text. AX is brittle by nature — scripted,
# human-in-loop, and every UI action still flows through the gateway.
```

**Safety model (Phase 4):** two independent protections. (1) **Source isolation** — only actions
*you* initiate run; anything derived from screen/memory is blocked outright, so attacker text on
your screen can never act (prompt-injection defense). (2) **Risk gating** — contained/reversible
actions (create, append, open, local read-only shell) run with no friction; only *irreversible or
outward-facing* ones (delete, overwrite, network/destructive shell) ask first. Every action is
written to an append-only audit log.

Memory lives at `~/Library/Application Support/Alfred/alfred.db` — OCR **text only**, frames
discarded on capture. Plaintext for now; at-rest encryption is a Phase 4 hardening item.

**Capture pivot:** Alfred uses Apple ScreenCaptureKit + Vision (free, on-device, text-only) rather
than Screenpipe, whose signed app went paid and whose free build path is fragile. A `ScreenpipeClient`
remains as an optional alternate source (`alfred-spike capture`).
