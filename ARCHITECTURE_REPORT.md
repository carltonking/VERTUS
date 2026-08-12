# Alfred Architecture Report

**Date:** August 2026 — reflects the current post-refactor architecture.

Alfred is a **client–server pair with a thin cloud relay**: a macOS app that
owns the agent and all state, an iOS app that talks to it, and a Vercel relay
that bridges the two when the Mac isn't reachable directly.

```
iPhone ──WebSocket (Tailscale)──▶ AlfredMac ──ACP (JSON-RPC/stdio)──▶ hermes agent
   │                                │  │                                │
   └──POST /api/mac──▶ Vercel relay ◀──long-poll /api/mac──┘            │
                              │                                        tools
                              └── Telegram-era pipeline (legacy)   (MCP bridges)
```

## macOS app (`AlfredMac/`)

A dependency-free Swift Package (Swift 5.9, macOS 14+). No GRDB, no Sparkle —
GRDB went with Alfred's own memory store, Sparkle with its updater, and both
are now owned by Hermes.

### Targets

| Target | Path | Role |
|---|---|---|
| `Alfred` | `Alfred/` | The app: notch bar UI + Hermes client + services |
| `alfred-mcp` | `AlfredMCP/` | MCP shim Hermes spawns; relays bytes to the running app (which holds the TCC grants) |
| `AlfredTests` | `Tests/` | Unit tests |

### Core loop — `HermesAgent/`

- **`HermesSession`** (actor) — spawns `hermes acp`, streams
  text/thought/tool events, applies tool results, and grounds each prompt:
  - `UnifiedMemoryLayer.observeTurn` (local graph extraction) on user + reply
  - memory grounding text (`groundingText`, `getRelationshipSummary`)
  - writing-style injection (`WritingStyleService.toPromptInjection`)
  - behavior injection (`ActivityObserver.currentProfile().toPromptInjection`)
  - habit prediction ("The user is typically in X now; next is Y")
- **`RelayWorker`** — long-polls `POST /api/mac`, runs phone messages through
  the session, posts replies back to the relay.
- **`ToolHandlers`** — maps the newer MCP tool surface (`file_organize`,
  `calendar_plan`, `habit_predict`) onto the capability services.

### Server — `Briefing/`

- **`BriefingSocketServer`** — a hand-rolled WebSocket JSON-RPC server (no
  framework). Routes `briefing.*`, `routines.*`, `code.*`, `mail.*` to the
  services and pushes notifications (`routine.started`, `code.chunk`,
  `mail.unread_count_changed`, …) back to iOS.
- **`BriefingGenerator`** — hourly conversational briefings with cumulative
  change detection (calendar adds/cancels, mail, weather, reminders).

### Services

| Service | Role |
|---|---|
| `Routines/RoutineManager` | Predefined + custom scheduled workflows, minute-granular scheduler, `RoutineExecutor` |
| `Mail/MailManager` | Unified inbox via Himalaya; fetch/search/act through the WebSocket |
| `Code/AlfredCodeManager` | Remote agentic coding sessions: spawns a Hermes session per project, streams code, git/tests |
| `Capabilities/*` | Calendar (EventKit), email (Himalaya), contacts, messages, spotify, terminal, file management, screen monitoring |

### Learning & memory — `Learning/`

The centerpiece after the 2026 consolidation. **`UnifiedMemoryLayer`** is the
single SQLite home (`~/.alfred/db/memory.db`, raw sqlite3, per-call
FULLMUTEX connections) with five tables:

- `entities` — people, places, concepts, topics, projects, tools
- `relations` — directed graph edges (knows, works_with, communicates_about…)
- `screen_observations` — deduped captures + OCR text (FTS5 index)
- `conversations` — fine-tuning captures with acceptance signals
- `vault_notes` — read-only mirror of the Obsidian vault (refreshed on launch)

Supporting layers:

- **`MigrationManager`** — one-time, idempotent harvest from the decommissioned
  systems (legacy GRDB tables, `personal-memory.json`, `captures.json`,
  agentmemory graph dump). Flag is set only after all steps succeed.
- **`ScreenMonitoringManager`** — 45s captures via the undetectable CG path,
  OCR (Vision), dedup, prune (7 days). Feeds `ActivityObserver`.
- **`ActivityObserver` / `BehaviorProfile`** — per-hour/per-day app usage,
  work hours, prompt injection for grounding.
- **`WritingStyleService` / `WritingStyleProfile`** — EMA-smoothed writing
  voice (formality, contractions, technical terms).
- **`HabitPredictionService`** — 2-state Markov chains over behavior profile.
- **`LocalGraphExtractor`** — on-device entity/relation extraction per turn.

### App wiring — `App/AlfredApp.swift`

Starts `ScreenMonitoringManager` and `MigrationManager` on launch, runs the
BriefingSocketServer, stops monitoring on termination. `ProviderKeyRing`
stores free-tier provider keys and injects them into Hermes + the coding agent
on spawn.

## iOS app (`Alfred/`)

SwiftUI, Xcode 16 synchronized file groups (no per-file project edits needed).

- **Connection layer** — `AlfredWebSocketClient` (@MainActor, JSON-RPC 2.0,
  pending-call correlation with watchdog timeouts, exponential-backoff
  reconnect), `TailscaleConnection` (mDNS → manual IP), `AlfredClient`
  (relay POST fallback).
- **Update stream** — `AlfredUpdate` enum + parser routing JSON-RPC
  notifications into view models.
- **Tabs** — Home (daily brief + todos), Chat (full-screen, voice entry),
  Email (Mac inbox over WebSocket + relay mailboxes), Calendar (EventKit),
  Routines (list + builder modal), Code (sessions + git + tests), Settings.
- **Stores** — `MailStore`/`MacMailStore`, `CalendarStore`, `RemindersStore`,
  `MessageListModel`, `ChatStore`, `VoiceStore`, `SubscriptionStore`.

## Cloud API (`api/`)

Vercel serverless TypeScript.

- `mac.ts` — opaque KV-mailbox relay (iPhone POST ↔ Mac long-poll)
- `app.ts` — chat front door through `routeMessage`
- `_lib/` — `route.ts` (transport-neutral routing), `chat.ts` (cloud brain),
  `llm.ts` (free-tier chain), `mail.ts`, `routines.ts`, `kv.ts`
- `cron-briefing.ts` / `cron-routines.ts` — scheduled cloud pushes

## Terminal TUI (`AlfredCode/`)

An Ink-based TUI replicating the Claude Code experience (sticky header,
conversation stream with tool/diff blocks, command palette, plan mode, vim
keys) on top of `freebuff acp` / `opencode acp` (JSON-RPC over stdio).

## Data flow — one turn, phone to answer

1. iPhone: `ChatStore.send` → `AlfredWebSocketClient` JSON-RPC
   (`session/prompt`) — or `AlfredClient` POST to the relay if the socket is
   down.
2. Mac: BriefingSocketServer (or `RelayWorker`) → `HermesSession`.
3. Hermes: observeTurn → grounding (memory graph + style + behavior + people)
   → `hermes acp` → tool calls via MCP bridges → reply.
4. Reply streams back over the same channel; the phone appends it to the
   transcript and the learning loop records the turn.

## Retired systems

- `archive/` — deleted (screenpipe spike, pre-refactor)
- `PersonMemoryService`, `AgentMemoryClient` — decommissioned; the graph lives
  in `UnifiedMemoryLayer`
- GRDB memory store, Sparkle updater, AssistantCore/LLMRouter monolith —
  replaced by the Hermes client refactor
- `freellmpool` — vendored upstream repo, synced via `scripts/sync_freellmpool.sh`

## Known debt

- `ALFRED_MAP.md` and `docs/` are maintained separately from this report; keep
  them in sync when the surface changes.
- The iOS cloud-mail client (`MailStore`) and Mac-mail client (`MacMailStore`)
  intentionally coexist (relay vs WebSocket transports); revisit if the relay
  path is retired.
- CI builds the macOS package and an unsigned iOS simulator build; the Hermes
  binary itself is not exercised in CI (local-only).
