# ALFRED

Personal AI assistant for macOS: a **pi-style terminal** whose brain is the **hermes** agent engine, a **notch-framed menubar QuickBar**, and **phone access over Tailscale** — all speaking to one streaming hub server.

```
┌──────────────────────────┐      ┌─────────────────────────────┐
│  Terminal (pi-style UI)  │─────▶│  ALFRED Hub (Python)        │
│  `alfred` — hermes brain │      │  tailnet + bearer token     │
└──────────────────────────┘      │  SSE: text/activity/done    │
┌──────────────────────────┐      │  bridges: hermes (default), │
│  QuickBar (SwiftUI,      │─────▶│  pi (opt-in)                │
│  notch-framed menubar)   │      └─────────────┬───────────────┘
└──────────────────────────┘                    │ engine
┌──────────────────────────┐      ┌─────────────▼───────────────┐
│  AlfredPhone (iOS,       │─────▶│  hermes-agent fork (local)  │
│  over Tailscale)         │      │  TUI-gateway JSON-RPC       │
└──────────────────────────┘      └─────────────────────────────┘
```

The terminal UI is a fork of [earendil-works/pi](https://github.com/earendil-works/pi); agent turns execute on a local fork of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) via its documented TUI-gateway protocol. Every client keeps its own UI — hermes is only the brain.

## Repository layout

```
├── ALFRED_PLAN.md                    # full blueprint, phases, decisions
├── alfred/
│   ├── apps/
│   │   ├── alfred-bar/               # macOS QuickBar (SwiftUI, menubar, notch)
│   │   └── AlfredPhone/              # native iOS client (scaffold)
│   ├── server/
│   │   ├── alfred_server.py          # hub: HTTP + SSE, auth, bridges
│   │   ├── hermes_bridge.py          # engine bridge → hermes TUI gateway (default)
│   │   ├── pi_bridge.mjs             # legacy bridge → pi agent (ALFRED_BRIDGE=pi)
│   │   └── pi_coding_agent.py        # legacy pi python facade
│   ├── extensions/                   # memory, persona, iCloud, nim-provider
│   └── scripts/
├── disabled-launchagents/            # launchd keepalive manifests (hub, bar, falkordb)
├── pi/                               # pi fork — terminal UI + hermes session adapter
│   └── packages/coding-agent/src/core/
│       ├── hermes-gateway.ts         # spawns `python -m tui_gateway.entry`, JSON-RPC
│       ├── hermes-session.ts         # AgentSession subclass: hermes executes turns
│       └── sdk.ts                    # engine selection (hermes default)
├── cdx_fire.txt
└── README.md
```

The hermes fork itself lives outside this repo locally (`~/.hermes/hermes-agent`, branch
`alfred`) with an editable install into `~/.hermes/hermes-agent/venv`; its ALFRED
skin/banner work is not yet hosted on GitHub.

## Terminal

`alfred` runs the pi-style ALFRED terminal (block-letter header, "Welcome Back, Carlton",
`ALFRED v0.01.0`, monochrome theme) with the **hermes engine by default**:

| Command | What runs |
|---|---|
| `alfred` | pi UI + hermes brain (default) |
| `alfred "question"` | one-shot through the hub → hermes |
| `ALFRED_ENGINE=pi alfred` / `alfred-pi` | original pi engine (rollback) |
| `alfred-hermes` | hermes' own terminal with the ALFRED skin (opt-in) |

### How the hermes brain plugs in

- `HermesSession` subclasses pi's `AgentSession` and overrides only the turn
  machinery: `prompt()`/`steer()`/`abort()`/events/transcript/extensions all keep
  pi's behavior, so the UI is untouched.
- `HermesGateway` spawns the hermes TUI gateway
  (`~/.hermes/hermes-agent/venv/bin/python -u -m tui_gateway.entry`) and speaks
  its newline-framed JSON-RPC: `session.create`, `prompt.submit`,
  `message.delta`/`message.complete`, `tool.start`/`tool.complete`,
  `session.interrupt`.
- The gateway subprocess env is sanitized (all `PI_*` vars and `AI_AGENT` are
  stripped; `HERMES_*` kept) so the model can never find misleading evidence
  that it is the pi framework.
- Engine selection lives in code (`sdk.ts`, default hermes), not a shell
  wrapper, so stale shells can't silently revert.
- Build the bundle after changes:
  `cd pi/packages/coding-agent && npm run build`
  (the installed `~/.npm-global/bin/alfred` symlinks into `dist/bundle/cli.js`).

### hermes configuration (local machine)

- `~/.hermes/config.yaml` — model/provider (default: `nemotron-3-super:cloud`
  via the local Ollama custom provider) and `display.skin: alfred`.
- `skins/alfred.yaml` — monochrome ALFRED skin (logo art, version label,
  welcome line) installed to `~/.hermes/skins/`.
- If hermes' approval prompts are unwanted for local use,
  `HERMES_YOLO_MODE=1` bypasses them (already set in the author's shell; the
  pi UI's own approval flows still apply).

## Hub server

One long-running server owns hub sessions; all clients stream from it.

```bash
# from this repo, with the hermes venv available:
python3 alfred/server/alfred_server.py serve \
  --host "$(tailscale ip -4)" --port 8787
```

- **Auth:** bearer token, expected at `~/.alfred/token` (`Authorization: Bearer …`).
- **Endpoints:** `GET /api/health`, `GET /api/events` (SSE), `POST /api/prompt`.
- **Wire events:** `text`, `activity`, `done`, `error`.
- **Engine bridge:** `hermes_bridge.py` by default; `ALFRED_BRIDGE=pi` forces
  the legacy `pi_bridge.mjs` path.
- **Keepalive:** copy `disabled-launchagents/com.alfred.server.plist` into
  `~/Library/LaunchAgents/` and `launchctl load` it.

## QuickBar

macOS menubar app (SwiftUI) that frames the notch: chat session with message
bubbles (your prompts right-aligned), thinking indicator, streaming replies,
and a scrollable transcript capped below the notch and above the prompt bar.

```bash
cd alfred/apps/alfred-bar
swiftc -o AlfredBar AlfredQuickBarApp.swift QuickBarRootView.swift QuickBarViewModel.swift
./AlfredBar          # or launch via the plist in disabled-launchagents/
```

Toggle with ⇧⌘J or the menubar icon; the new-session button clears the chat.

## AlfredPhone

Native iOS client (SwiftUI) over Tailscale: streaming chat against the hub,
token stored in Keychain. Status: **scaffold only** — chat view and client are
in place; remote approvals and polish are pending.

## Configuration knobs

| Env var | Meaning |
|---|---|
| `ALFRED_ENGINE` | `hermes` (default) or `pi` — engine for the terminal REPL |
| `ALFRED_BRIDGE` | `hermes` (default) or `pi` — hub bridge |
| `ALFRED_HOST` / `ALFRED_PORT` | hub bind address/port (default 8787) |
| `ALFRED_SERVER_URL` | hub URL for one-shot CLI routing |
| `ALFRED_NO_SERVER` | `1` = skip hub integration |
| `HERMES_YOLO_MODE` | bypass hermes approval prompts |

State lives in `~/.pi/` (pi sessions, settings, extensions), `~/.hermes/`
(hermes config, skins, venv), and `~/.alfred/` (hub token, logs).

## Security

- The hub binds the Tailscale interface only, never `0.0.0.0`.
- Every hub request requires the bearer token; the phone holds it in Keychain.
- Remote-initiated destructive commands go through an approval guard
  (`alfred/extensions/remote-approval-guard.ts`); local terminal runs are
  trusted.
- No secrets are stored in this repo (configs, tokens, and API keys live in
  `~/.hermes`, `~/.pi`, `~/.alfred`, and the shell env).

## Status

| Milestone | Status |
|---|---|
| pi fork + ALFRED branding/theme | ✅ |
| Hermes brain in the terminal REPL (pi UI untouched) | ✅ |
| Hermes skin + banner in the hermes fork | ✅ (local fork only) |
| Hub server + SSE + auth | ✅ |
| QuickBar under the notch | ✅ |
| One-shot CLI through the hub | ✅ |
| AlfredPhone scaffold | ⬜ scaffold only |
| hermes fork on GitHub, remote approvals, polish | ⬜ pending |