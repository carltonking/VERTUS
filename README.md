# VERTUS

Personal AI assistant for macOS: a **pi-style terminal** whose brain is the **hermes** agent engine, a **notch-framed menubar QuickBar**, and **phone access over Tailscale** — all speaking to one streaming hub server.

```
┌──────────────────────────┐      ┌─────────────────────────────┐
│  Terminal (pi-style UI)  │─────▶│  VERTUS Hub (Python)        │
│  `vertus` — hermes brain │      │  tailnet + bearer token     │
└──────────────────────────┘      │  SSE: text/activity/done    │
┌──────────────────────────┐      │  bridges: hermes (default), │
│  QuickBar (SwiftUI,      │─────▶│  pi (opt-in)                │
│  notch-framed menubar)   │      └─────────────┬───────────────┘
└──────────────────────────┘                    │ engine
┌──────────────────────────┐      ┌─────────────▼───────────────┐
│  VertusPhone (iOS,       │─────▶│  hermes-agent fork (local)  │
│  over Tailscale)         │      │  TUI-gateway JSON-RPC       │
└──────────────────────────┘      └─────────────────────────────┘
```

The terminal UI is a fork of [earendil-works/pi](https://github.com/earendil-works/pi); agent turns execute on a local fork of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) via its documented TUI-gateway protocol. Every client keeps its own UI — hermes is only the brain.

## Repository layout

```
├── VERTUS_PLAN.md                    # full blueprint, phases, decisions
├── vertus/
│   ├── apps/
│   │   ├── vertus-bar/               # macOS QuickBar (SwiftUI, menubar, notch)
│   │   └── VertusPhone/              # native iOS client (scaffold)
│   ├── server/
│   │   ├── vertus_server.py          # hub: HTTP + SSE, auth, bridges
│   │   ├── agent_registry.py         # durable multi-agent registry (~/.vertus/agents)
│   │   ├── session_manager.py        # per-agent session map (keyed, lazy, thread-safe)
│   │   ├── test_agent_registry.py    # registry unit tests (pytest)
│   │   ├── test_session_manager.py   # session/HTTP/concurrency tests (pytest)
│   │   ├── hermes_bridge.py          # engine bridge → hermes TUI gateway (default)
│   │   ├── pi_bridge.mjs             # legacy bridge → pi agent (VERTUS_BRIDGE=pi)
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
`vertus`) with an editable install into `~/.hermes/hermes-agent/venv`; its VERTUS
skin/banner work is not yet hosted on GitHub.

## Terminal

`vertus` runs the pi-style VERTUS terminal (block-letter header, "Welcome Back, Carlton",
`VERTUS v0.01.0`, monochrome theme) with the **hermes engine by default**:

| Command | What runs |
|---|---|
| `vertus` | pi UI + hermes brain (default) |
| `vertus "question"` | one-shot through the hub → hermes |
| `VERTUS_ENGINE=pi vertus` / `vertus-pi` | original pi engine (rollback) |
| `vertus-hermes` | hermes' own terminal with the VERTUS skin (opt-in) |

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
  (the installed `~/.npm-global/bin/vertus` symlinks into `dist/bundle/cli.js`).

### hermes configuration (local machine)

- `~/.hermes/config.yaml` — model/provider (default: `nemotron-3-super:cloud`
  via the local Ollama custom provider) and `display.skin: vertus`.
- `skins/vertus.yaml` — monochrome VERTUS skin (logo art, version label,
  welcome line) installed to `~/.hermes/skins/`.
- If hermes' approval prompts are unwanted for local use,
  `HERMES_YOLO_MODE=1` bypasses them (already set in the author's shell; the
  pi UI's own approval flows still apply).

## Hub server

One long-running server owns hub sessions; all clients stream from it.

```bash
# from this repo, with the hermes venv available:
python3 vertus/server/vertus_server.py serve \
  --host "$(tailscale ip -4)" --port 8787
```

- **Auth:** bearer token, expected at `~/.vertus/token` (`Authorization: Bearer …`).
- **Endpoints:** `GET /api/health`, `GET /api/events` (SSE), `POST /api/prompt`,
  plus the WIP multi-agent endpoints below.
- **Wire events:** `text`, `activity`, `done`, `error`.
- **Engine bridge:** `hermes_bridge.py` by default; `VERTUS_BRIDGE=pi` forces
  the legacy `pi_bridge.mjs` path.
- **Keepalive:** copy `disabled-launchagents/com.vertus.server.plist` into
  `~/Library/LaunchAgents/` and `launchctl load` it.

## Multi-agent (WIP)

The hub carries a durable registry of agents, and each agent now gets its own
**live session**: one bridge (own queue + worker thread + engine session) per
agent id, so two agents can be prompted concurrently without blocking each
other. Defaults preserve the old single-session behavior — omit `agent_id`
everywhere and you're talking to `primary` exactly as before.

On-disk layout (per agent, under `~/.vertus/agents/`):

```
~/.vertus/agents/
├── _primary                  # marker file: id of the primary agent
└── <agent_id>/
    ├── profile.json          # {"id", "name", "created_at", "sandbox_path"}
    └── sandbox/              # the agent's default working directory (cwd)
```

- `agent_id` is the directory name and never changes (lowercase slug,
  deduped with a short suffix on collision); `name` is display-only.
- `ensure_primary()` runs at hub startup: if no agents exist it creates
  `primary` / "Primary", and the hub prewarms that session exactly like the
  old single-session hub. Every other agent's session is lazy — its engine
  gateway spawns on that agent's first prompt or event stream.
- Deleting the last remaining agent is refused; deleting the primary
  reassigns primary to the oldest remaining agent.
- Sessions are keyed in a thread-safe `SessionManager`; an unknown agent id
  on any endpoint is a 404 (validated through the registry).
- **Sandbox isolation (Prompt 3):** each agent's session starts with its
  `sandbox/` as the working computer — never `$HOME` or the VERTUS repo root.
  Enforcement per engine:
  - **hermes (default):** the hub sends the sandbox as the explicit `cwd`
    param of the gateway's `session.create` RPC. The gateway treats an
    explicit cwd as the session workspace and registers it as the
    terminal-tool's env override, so shell/file tools start there. (Keys
    involved: `session.create.cwd` → session `cwd` → tools.terminal-tool
    `cwd` override; config `terminal.cwd` / env `TERMINAL_CWD` are only
    fallbacks when no explicit cwd is sent — the hub always sends one.)
  - **pi fallback (`VERTUS_BRIDGE=pi`):** the hub exports `VERTUS_CWD` to
    the `pi_bridge.mjs` child and spawns the child in the sandbox;
    `pi_bridge.mjs` passes it to pi's `createAgentSession({ cwd })`.
  - The hub re-ensures the sandbox dir on every session creation (a
    deleted `sandbox/` is recreated before the session starts).
- **Remaining escape hatches (honest list):** the sandbox is a *default*
  working directory, not a jail. The engine can still read/write absolute
  paths anywhere the hub user can, its gateway child inherits the hub's
  env, hermes' `session.cwd.set` RPC could move a session out (the hub
  never calls it), and memory/persona extensions still read `~/.hermes`.
  OS-level confinement (per-agent containers / seatbelt profiles) is the
  Prompt 4 boundary; computer-use locking stays out of scope here.

Hub endpoints (same bearer token as everything else):

| Endpoint | Meaning |
|---|---|
| `GET /api/agents` | list agents (ensures primary exists first) |
| `POST /api/agents` `{"name": "…"}` | create an agent, returns its profile |
| `GET /api/agents/<id>` | one agent's profile, 404 when unknown |
| `POST /api/prompt` `{"text"\|"prompt": "…", "agent_id": "…"?}` | queue a turn for that agent (default `primary`); 202 with `{"accepted": true, "agent_id": …, "sandbox_path": …}` |
| `GET /api/events?agent_id=…` | SSE stream for that agent only (default `primary`) |
| `GET /api/skills?agent_id=…` | slash/skill catalog from that agent's session |

Concurrency notes:

- Each bridge owns its queue; nothing crosses agents. Prompting two agents
  simultaneously keeps both turns in flight (proven by a test with fake
  sessions measuring peak in-flight turns ≥ 2 and wall-clock ≈ one turn,
  not two).
- Within one agent, prompts still serialize in submission order (same as
  the old behavior for a single client).

Tests (no engine subprocess is ever spawned; the bridge class is swapped
for a recording fake, but the production default factory — including the
per-agent sandbox cwd resolution — still runs):

```bash
python3 -m pytest vertus/server/test_agent_registry.py vertus/server/test_session_manager.py -v
```

The sandbox test (`test_default_factory_binds_each_agents_sandbox`) proves
agent A's bridge gets A's `sandbox/` and agent B's gets B's, and that both
dirs exist before any session starts. To verify against the real hub:

```bash
python3 vertus/server/vertus_server.py serve --host 127.0.0.1 --port 8791
curl -s -H "Bearer $(cat ~/.vertus/token)" localhost:8791/api/agents/scout | jq .sandbox_path
```

## QuickBar

macOS menubar app (SwiftUI) that frames the notch: chat session with message
bubbles (your prompts right-aligned), thinking indicator, streaming replies,
and a scrollable transcript capped below the notch and above the prompt bar.

```bash
cd vertus/apps/vertus-bar
swiftc -o VertusBar VertusQuickBarApp.swift QuickBarRootView.swift QuickBarViewModel.swift MathEval.swift
./VertusBar          # or launch via the plist in disabled-launchagents/
```

Toggle with ⇧⌘J or the menubar icon; the new-session button clears the chat.

## VertusPhone

Native iOS client (SwiftUI) over Tailscale: streaming chat against the hub,
token stored in Keychain. Status: **scaffold only** — chat view and client are
in place; remote approvals and polish are pending.

## Identity, persona, and shared memory

All three surfaces (terminal, QuickBar, phone) share **one brain and one
memory** — this is what makes VERTUS feel like the same assistant everywhere:

- **Persona:** `~/.hermes/SOUL.md` — the identity the hermes engine injects
  into every session on every surface. It defines who VERTUS is (butler for
  Carlton, addressed as "sir"), the operating rules (execute locally, confirm
  destructive remote actions), and the capability summary. Editing this file
  re-personalizes every surface at once.
- **Memory:** `~/.vertus/memory/` — the shared store VERTUS is instructed to
  read at session start and update when it learns durable facts:
  - `profile.md` — stable facts about Carlton (machines, projects, preferences)
  - `notes/` — dated task notes (`YYYY-MM-DD-topic.md`)
  - `index.json` — topic → note map
- The hermes-side fact file `~/.hermes/memories/USER.md` is kept aligned but
  the `~/.vertus/memory/` store is the source of truth.

The pi-era skill files (`vertus/extensions/vertus-persona`,
`vertus-memory`, `memory-skill`) describe the same contract for the legacy
pi engine path (`VERTUS_ENGINE=pi`); hermes loads the persona from SOUL.md
and the memory instructions live there too, so no per-surface configuration
is needed.

## Configuration knobs

| Env var | Meaning |
|---|---|
| `VERTUS_ENGINE` | `hermes` (default) or `pi` — engine for the terminal REPL |
| `VERTUS_BRIDGE` | `hermes` (default) or `pi` — hub bridge |
| `VERTUS_HOST` / `VERTUS_PORT` | hub bind address/port (default 8787) |
| `VERTUS_SERVER_URL` | hub URL for one-shot CLI routing |
| `VERTUS_NO_SERVER` | `1` = skip hub integration |
| `HERMES_YOLO_MODE` | bypass hermes approval prompts |

State lives in `~/.pi/` (pi sessions, settings, extensions), `~/.hermes/`
(hermes config, skins, venv), and `~/.vertus/` (hub token, logs).

## Security

- The hub binds the Tailscale interface only, never `0.0.0.0`.
- Every hub request requires the bearer token; the phone holds it in Keychain.
- Remote-initiated destructive commands go through an approval guard
  (`vertus/extensions/remote-approval-guard.ts`); local terminal runs are
  trusted.
- No secrets are stored in this repo (configs, tokens, and API keys live in
  `~/.hermes`, `~/.pi`, `~/.vertus`, and the shell env).

## Status

| Milestone | Status |
|---|---|
| pi fork + VERTUS branding/theme | ✅ |
| Hermes brain in the terminal REPL (pi UI untouched) | ✅ |
| Hermes skin + banner in the hermes fork | ✅ (local fork only) |
| Hub server + SSE + auth | ✅ |
| QuickBar under the notch | ✅ |
| One-shot CLI through the hub | ✅ |
| Multi-agent registry, parallel sessions, per-agent sandbox cwd | ✅ (default-cwd isolation; OS-level confinement pending) |
| VertusPhone scaffold | ⬜ scaffold only |
| hermes fork on GitHub, remote approvals, polish | ⬜ pending |