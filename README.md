# Alfred

Alfred is a personal AI assistant that spans four surfaces:

1. **AlfredMac** (`AlfredMac/`) — the brain. A dependency-free macOS Swift
   Package (macOS 14+) that drives the Hermes agent over ACP (JSON-RPC over
   stdio), serves a notch bar UI, runs a WebSocket server for the phone, and
   owns all persistent memory and learning.
2. **Alfred iOS** (`Alfred/`) — a SwiftUI companion app. Six tabs (Home, Chat,
   Email, Calendar, Routines, Code, Settings) talking to the Mac over a
   Tailscale/WebSocket connection, with a Vercel relay as the fallback path.
3. **api/** — the Vercel serverless relay. Moves opaque messages between the
   iPhone and the Mac (`mac.ts`), plus the cloud mail relay, cron briefings,
   and the legacy Telegram-era pipeline.
4. **AlfredCode** (`AlfredCode/`) — a terminal TUI (Ink) that replicates the
   Claude Code experience on top of `freebuff` / `opencode` as the backend ACP
   agent.

Everything below the Mac app is thin. The model, the tools, the memory, and
the learning all live in `HermesSession` on the Mac.

## Requirements

- macOS 14+ (macOS 15 for the iOS build toolchain)
- Swift 5.9+
- The `hermes` binary on `PATH` (Hermes owns model/provider config)
- iOS: an iPhone running the Alfred app, on the same Tailscale network

## Quick Start (macOS)

```bash
cd AlfredMac
swift build                       # or: ./scripts/build_app.sh --install
```

`swift run Alfred` launches a CLI executable, not an app bundle — macOS
privacy permissions may not let you grant it Accessibility or Screen
Recording. Build a real bundle with `./scripts/build_app.sh --install` for
daily use.

Hermes sessions are configured through ProviderKeyRing (free-tier provider
keys injected as env vars) and the MCP bridges listed in
`~/.alfred/agent-servers.json` (see `agent-bridge/setup.sh`).

## What the Mac does

- **HermesSession** (`HermesAgent/`) — owns a `hermes acp` subprocess, streams
  text/thought/tool events, grounds every prompt on the unified memory graph,
  the user's writing style, behavior profile, and relationship summary.
- **RelayWorker** — long-polls `/api/mac` and runs incoming phone messages
  through HermesSession, posting replies back.
- **BriefingSocketServer** — the WebSocket JSON-RPC server the iPhone talks to:
  `briefing.*`, `routines.*`, `code.*`, `mail.*`, `habit.*`, `calendar_plan`,
  `file_organize`, and more.
- **Services** — `BriefingGenerator` (hourly briefings with change
  detection), `RoutineManager` (scheduled workflows), `MailManager` (unified
  inbox over Himalaya), `AlfredCodeManager` (remote agentic coding).
- **Memory** — `UnifiedMemoryLayer` (`Learning/`): one SQLite graph
  (`~/.alfred/db/memory.db`) holding entities + relations, screen
  observations, conversations, and a read-only mirror of the Obsidian vault,
  with FTS5 search. `MigrationManager` performed the one-time harvest from the
  legacy stores (GRDB, personal-memory.json, captures.json, agentmemory).
- **Learning loop** — `ScreenMonitoringManager` captures every 45s
  (undetectable CG path), OCRs, dedupes into the layer, and feeds
  `ActivityObserver`; `WritingStyleService` learns the user's voice;
  `HabitPredictionService` predicts the next app. All three inject into
  Hermes' system prompt.

## iOS app

- **Connection** — `AlfredWebSocketClient` (persistent socket, JSON-RPC,
  exponential-backoff reconnect) + `TailscaleConnection` (mDNS discovery of
  the Mac, manual-IP fallback). `AlfredClient` POSTs to the relay
  (`/api/mac`) as the cloud fallback.
- **Mail** — the Email tab reads the Mac's unified inbox over the WebSocket
  (`MacMailStore`); the cloud relay client (`MailStore`/`MailClient`) is still
  reachable from the toolbar for the older account-management flow.
- **Calendar / Reminders** — EventKit on the phone, observed live, feeding the
  Home-tab Daily Brief.

## Cloud API (Vercel)

- `api/mac.ts` — KV-mailbox relay between iPhone (POST) and Mac (long-poll GET)
- `api/app.ts` — chat front door through the shared routing pipeline
- `api/_lib/` — routing, chat brain, LLM chain (free-tier failover), mail,
  routines, cron briefings

## Project structure

```text
AlfredMac/          macOS app (Swift Package, dependency-free)
  Alfred/           Source: App, Bar, HermesAgent, Capabilities, Learning,
                    Briefing, Routines, Mail, Code, Presence, Services
  AlfredMCP/        MCP shim Hermes spawns (relays to the running app)
  Tests/            Swift tests
  scripts/          build_app, QA fixture generators, release helpers
  Server/           Voice bridge (alf_voice_bridge.py) + MiniOmni backend
Alfred/             iOS app (Xcode project, Xcode 16 synchronized groups)
  Alfred/           SwiftUI views, services, models
api/                Vercel serverless relay
AlfredCode/         Terminal TUI (Ink) for freebuff/opencode
agent-bridge/       MCP server wrappers injected into every Hermes session
Fine Tune/          Llama 3.2 1B fine-tuning pipeline
website/            Marketing site
graphiti/           Temporal knowledge-graph config (FalkorDB)
```

## Local data

Everything lives under `~/.alfred/`:

- `db/memory.db` — the unified memory graph (entities, relations, screen
  observations, conversations, vault mirror) + FTS5 indexes
- `screen_captures/` — JPEGs behind screen observations (pruned after 7 days)
- `agent-servers.json` — MCP bridge registration for Hermes sessions
- `vault/` — the Obsidian vault Alfred mirrors read-only

## Privacy

- API keys live in the macOS Keychain / ProviderKeyRing; nothing secret in git
- Conversation, screen, and behavior data stays local in `memory.db`
- Screen monitoring is opt-in, low-frequency, deduplicated, and pruned
- Git never tracks `AlfredMac/Frameworks/`, virtualenvs, runtime `data/`, or
  vendored repos (freellmpool, MiniOmni) — see `.gitignore`

## Tests

```bash
cd AlfredMac
swift build
swift test
```

CI (`.github/workflows/ci.yml`) runs the macOS build + tests, an unsigned iOS
simulator build, a TypeScript check on AlfredCode, and `py_compile` over the
Python tree.
