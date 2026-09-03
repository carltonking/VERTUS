# VERTUS — Full Blueprint

Personal AI assistant with full computer control: a fork of the **pi** agent harness (earendil-works/pi), a **menubar-driven quick bar** under the macOS notch, and **native phone access** over Tailscale.

## Architecture

```
┌─────────────────────────┐      ┌──────────────────────────────┐
│  Quick Bar (SwiftUI)    │      │  VERTUS Server (Bun/TS)      │
│  menubar icon, ⇧⌘J,     │─────▶│  pi-agent-core session loop  │
│  850×400, frames notch  │ HTTP │  tools: files/shell/web      │
└─────────────────────────┘ SSE  │  memory store (JSON+MD)      │
                                 │  auth: tailnet + token       │
┌─────────────────────────┐      │  LLM: NVIDIA NIM (OpenAI-    │
│  Phone app (native)     │─────▶│  compatible, pi-ai provider) │
│  over Tailscale         │ WSS  └──────────────────────────────┘
└─────────────────────────┘               │ full control of
                                          ▼ your Mac (cwd = $HOME)
```

One long-running **VERTUS server** owns the agent (sessions, tools, memory, NIM calls). Three thin clients — CLI, quick bar, phone app — all talk to it.

## Phase 1 — Agent core (fork pi → VERTUS)

1. **Fork & brand**: clone earendil-works/pi, rename the CLI entry to `vertus`, custom system prompt/persona (VERTUS personality, your preferences, house rules).
2. **NVIDIA NIM provider** — no fork of pi-ai needed. One extension file (`extensions/nim-provider.ts`):
   ```ts
   pi.registerProvider("nvidia-nim", {
     baseUrl: "https://integrate.api.nvidia.com/v1",
     apiKey: "$NVIDIA_API_KEY",
     api: "openai-completions",
     models: [ /* NIM model ids, contextWindow, maxTokens */ ]
   });
   ```
3. **Full-control tools**: keep pi's read/bash/edit tools, default cwd `$HOME`, plus an approval-guard extension for destructive commands initiated **remotely** (local runs trusted).
4. **Long-term memory**: `~/.vertus/memory/` — `profile.md` (stable facts about you), `notes/` (task notes), JSON index; a pi skill makes VERTUS read it at session start and update it when it learns something durable.

## Phase 2 — VERTUS server + CLI client

5. **Server daemon** (`vertus serve`): wraps `createAgentSessionRuntime` from pi's SDK; exposes `POST /api/prompt`, `GET /api/events` (SSE stream), `POST /api/steer`, `/api/abort`; binds to the Tailscale interface only + bearer token. **The SSE stream emits structured `text` / `activity` / `done` / `error` events** so clients can render streamed replies nicely.
6. **CLI client** (`vertus "<request>"`): forked pi TUI for interactive work + one-shot mode through the server so all clients share one session history.

## Phase 3 — Quick-access bar (macOS)

7. **SwiftUI overlay app**: borderless non-activating `NSPanel` at **status level**, **850×400 px**, pinned **top-center on the full screen frame** so it frames the 16" notch footprint (220×38 dead space at top center, content wrapping around it); toggled by the **menubar icon** (VERTUS.icns) or global hotkey (default **⇧⌘J**); animated grow/retract out of and back into the notch; stays pinned (ignores outside clicks) until **Cancel**/**Upload** is pressed; logo flank = attach file (system picker on top layer), New Session flank = clear output; vibrancy material; Enter → `POST /api/prompt`; live streaming reply (scrollable transcript); launch-at-login + menu-bar extra.

## Phase 4 — Phone app (native, over Tailscale)

8. **Native iOS app** (SwiftUI): Mac's MagicDNS tailnet address + token in Keychain; streaming chat, tool-activity feed, remote-approval prompts; Android via KMP later if wanted.

## Security posture

- Server binds **only** to the tailnet interface; never 0.0.0.0.
- Bearer token on every request; token stored in the phone's Keychain only.
- Remote requests run in **approval mode** for destructive shell commands; local requests trusted.
- NIM API key only in the server env, never in clients.

## Build order

| # | Milestone | Deliverable | Status |
|---|-----------|-------------|--------|
| 1 | Fork + NIM + persona | `vertus` CLI answers via NIM with your system prompt | ✅ |
| 2 | Memory | VERTUS remembers facts across sessions | ✅ |
| 3 | Server + auth | `vertus serve` on the tailnet, streaming API | ✅ |
| 4 | Quick bar | ⇧⌘J / menubar-icon notch bar (300×500) with live streaming replies | ✅ |
| 5 | Phone app | Native iOS chat over Tailscale with approvals | ⬜ scaffold only |
| 6 | Polish | Autostart, settings, model switching, logs | ⬜ |

Milestones 1–3 already give a phone-accessible VERTUS (mobile browser as stopgap); bar and native app layer on without rework.

## Hermes engine migration (2026-09-01)

The agent engine moved from the pi fork to a **fork of NousResearch/hermes-agent**
(`/Users/carltonking/01 - PROJECTS/Hermes desktop/hermes-agent`, branch `vertus`;
GitHub fork pending `gh auth login`). The VERTUS terminal UI and the phone/bar
clients are unchanged — only the engine underneath swapped.

**Terminal (`vertus`)** — the pi-style UI stays (user requirement: hermes is
only the brain, never the UI):

- `vertus` → the pi terminal bundle (unchanged UI/UX). `vertus-hermes` → the
  forked hermes terminal with the VERTUS skin, opt-in only.
- One-shot `vertus "…"` proxies through the hub when it is up → hermes brain,
  pi UI (verified: CLI_HERMES_OK streamed back). The interactive REPL runs the
  pi agent in-process (the pi TUI is fused to the in-process session; a
  hermes-backed session adapter for the REPL is a large build, not a config).
- The branded hermes terminal (opt-in) uses `skins/vertus.yaml` in the fork
  (monochrome palette, VERTUS logo, `Welcome Back, Carlton`, `VERTUS v0.01.0`),
  installed to `~/.hermes/skins/`, active via `display.skin: vertus` in
  `~/.hermes/config.yaml`. Fork edits are skin-driven (built-in skins
  unchanged): `hermes_cli/banner.py` + `cli.py` render the skin's
  welcome/version and skip the hermes info panel and tips for user skins;
  `hermes_cli/skin_engine.py` gained `is_user_skin()`.
- Providers: config default is local Ollama (`nemotron-3-super:cloud`); Nous
  Portal is native (`hermes auth add nous` — manual OAuth, pending).

**Hub (`vertus/server/vertus_server.py`)** — the bridge now defaults to
`hermes_bridge.py` (spawns `python -m tui_gateway.entry` in the hermes venv and
speaks the documented TUI-gateway JSON-RPC: `session.create`, `prompt.submit`,
streaming `message.delta` / `message.complete`). `VERTUS_BRIDGE=pi` forces the
old `pi_bridge.mjs` path. Re-armed as the `com.vertus.server` launchd keepalive
(plist: `disabled-launchagents/com.vertus.server.plist`).

Verified end-to-end: CLI one-shot (`vertus -z …` → VERTUS_OK), hub SSE
(`HUB_E2E_OK` streamed, `done` terminated), tailnet health at
`http://100.84.144.109:8787/api/health` (what the phone dials).

Manual steps still pending: `gh auth login` (fork to GitHub), `hermes auth add
nous` (Nous Portal OAuth; the old proxy daemon `com.vertus.hermes` stays down
until then).

## Key facts verified

- pi SDK: `createAgentSessionRuntime`, `session.prompt/steer/abort`, `session.subscribe` event streaming — everything the server and bar need.
- pi extension API: `registerProvider` supports OpenAI-compatible endpoints (NIM) incl. `$ENV` key refs, async model discovery, per-model `compat` flags.
- pi has **no built-in permission system** — hence the explicit approval-guard extension.
- NIM is OpenAI Chat Completions compatible → `api: "openai-completions"`.
- pi session events: `message_update` → `assistantMessageEvent.type == "text_delta"` carries streamed assistant text; `tool_execution_start` carries `toolName` for activity feed; `agent_end` marks turn completion.

## Next steps

1. Rebuild the bar: `cd vertus/apps/vertus-bar && swiftc -o VertusBar VertusQuickBarApp.swift QuickBarRootView.swift QuickBarViewModel.swift MathEval.swift` (typechecks clean, 0 errors).
2. Launch: `cd vertus/apps/vertus-bar && ./VertusBar` (background it; long-lived GUI processes don't survive this sandbox's shell timeouts, so launch from your own terminal or via `launchctl`).
3. Start Milestone 5: native iOS app scaffolding under `vertus/apps/VertusPhone/`.
