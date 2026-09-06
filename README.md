# VERTUS

A fleet of named AI agents on one Mac. Each agent has its own identity
(persona, model), its own home and working directory, its own engine
gateway — and they talk to each other, delegate work, run on schedules, and
report back. You watch them from a full-window Fleet app or fire a prompt
from a notch QuickBar; every turn is durable, replayable, and cancellable.

```
┌──────────────────────┐      ┌──────────────────────────────────────┐
│  VertusFleet (macOS) │─────▶│  VERTUS Hub (Python, launchd)        │
│  roster + chat +     │      │  per-agent gateways → hermes fork    │
│  routines + threads  │      │  SQLite run store (WAL, one writer)  │
├──────────────────────┤      │  SSE fleet stream (since= replay)    │
│  VertusBar (notch)   │─────▶│  scheduler + message bus + leases    │
├──────────────────────┤      └──────────────┬───────────────────────┘
│  terminal REPL       │                     │ per-agent spawn
│  (pi UI, in-process) │                     ▼
└──────────────────────┘      ~/.hermes/hermes-agent (fork) — gateway
```

The hub is a Python `ThreadingHTTPServer` that keeps one engine gateway per
agent. Agents are **not** sandboxes — they are identities with honest limits
(see [LIMITS](#limits)).

## Repository layout

```
├── README.md                     # this file
├── VERTUS_PLAN.md                # architecture, decisions, roadmap
├── docs/FIRST_RUN.md             # tested fresh-machine setup
├── vertus/
│   ├── server/                   # the hub (all Python, pytest-tested)
│   │   ├── vertus_server.py      # HTTP + SSE, auth, routes, supervision
│   │   ├── agent_registry.py     # per-agent profiles (~/.vertus/agents)
│   │   ├── session_manager.py    # keyed, lazy, thread-safe bridges
│   │   ├── hermes_bridge.py      # gateway spawn (env allowlist, respawn)
│   │   ├── run_store.py          # SQLite: runs, events, messages, bus, routines
│   │   ├── fleet_routines.py     # scheduler + triggers + caps
│   │   ├── fleet_messaging.py    # bot-to-bot bus, delegation, auto-results
│   │   ├── screen_lease.py       # declared-target ownership policy
│   │   ├── vertus_logging.py     # one rotating log for the whole hub
│   │   └── test_*.py             # ~160 pytest tests, no engine spawned
│   ├── apps/                     # one Swift Package, three targets
│   │   ├── Sources/VertusKit     # client, models, store, fleet stream
│   │   ├── Sources/VertusFleet   # full-window fleet app
│   │   ├── Sources/VertusBar     # notch QuickBar (⇧⌘J)
│   │   └── scripts/build-apps.sh # ONE command → both .app bundles
│   └── extensions/               # legacy pi-era skills (pi engine path)
├── disabled-launchagents/        # canonical launchd plists (hub, bar)
└── pi/                           # terminal UI fork (the REPL)
```

The engine is a local fork of NousResearch/hermes-agent
(`~/.hermes/hermes-agent`, branch `vertus`) spoken to over its TUI-gateway
JSON-RPC. The terminal UI is a fork of earendil-works/pi.

## Agents

Every agent is a directory under `~/.vertus/agents/<id>/`:

```
profile.json          # schema v4 — the SINGLE SOURCE OF TRUTH
sandbox/              # the agent's working directory (session cwd)
memory/               # this bot's own notes
home/                 # per-agent engine root (HERMES_HOME):
  config.yaml         #   model/provider, derived from the profile
  SOUL.md             #   persona, derived from the profile
  memories/  auth.json  .env  skills/   # seeded, then engine-owned
```

`home/` is **derived state**: profile.json is authoritative and the tree is
re-materialized on every profile update. Older profiles migrate in place
(idempotent, unknown keys preserved). Profile fields: `id, name, title,
description, persona, model, provider, color, emoji, autonomy (ask|trusted),
computer_use, cua_targets, stall_timeout_s, hard_timeout_s, created_at,
updated_at, is_primary, sandbox_path, home_path, schema_version`.

- `id` is the directory name and never changes; `name` is display-only.
  `primary` is auto-created at boot and cannot be deleted.
- Each agent's gateway is spawned with its `home/` as `HERMES_HOME` (the
  fork's per-process config-root override) and an explicit **env allowlist**
  — the hub never hands a gateway the whole environment, so no bot's
  context leaks into another's engine.
- Two agents run fully in parallel (own queue + worker + gateway each).
  Within one agent, prompts serialize in submission order.

## Run store and replay

Every event of every run is committed to SQLite (`~/.vertus/fleet.db`,
WAL, one writer thread) **before** it is fanned out to subscribers — the
client stream is always a subset of the store. `events.seq` is one global
monotonic cursor across all agents: a client reconnects with
`since=<last seq>` and replays exactly what it missed, gap-free and
duplicate-free. Text deltas are stored per-emit and folded into one
`messages` row per turn for fast history reads. Runs and messages are never
pruned; events older than `VERTUS_EVENT_TTL_DAYS` (default 30) are.
`~/.vertus/fleet.db` is the record of what the bots did — it outlives
agents (DELETE archives the agent directory but keeps its history).

## Supervision and cancellation

- **Stall detection, not wall-clock:** a turn that emits nothing for
  `stall_timeout_s` (default 180) or runs past `hard_timeout_s` (default
  3600) is escalated; a slow-but-chatty turn (a 251s GUI demo) is fine.
  `status()` reports `silence_s` so the UI can distinguish stuck from busy.
- **Escalation ladder:** `session.interrupt` → wait `grace_s` → SIGTERM the
  gateway's process group → SIGKILL → mark the run terminal. Each rung is
  logged. Queued turns for that agent survive a cancel (unless
  `drain_queue`).
- **Gateway supervision:** respawn with backoff (3 attempts, 1s/4s/16s,
  jittered); after exhaustion the agent is `degraded` and further prompts
  get a readable 503 until a successful spawn clears it; an idle gateway
  that stops answering a cheap RPC is closed so the next prompt respawns;
  a thrash cap (4 deaths / 10 min) pauses auto-respawn instead of spinning.
- `POST /api/runs/<id>/cancel` (with `drain_queue`) and
  `POST /api/agents/<id>/cancel`. `cancelled` and `timeout` are first-class
  terminal states, distinct from `error` and `interrupted`.

## Computer use

An agent with `computer_use: true` can drive the desktop through the fork's
cua-driver; `cua_targets` is the list of app bundle ids / window titles it
declares. Declared targets gate **conflicts only** — see
[LIMITS](#limits) for exactly what that means.

## Messaging and delegation

Bots talk through a store-backed bus (`bot_messages` + `threads`): a
delivered message becomes a turn on the recipient (queued behind current
work), attributed with `from_agent`/`thread_id`/`run_kind`. A `handoff`
records the delegator's live run as parent, so the delegation graph is a
navigable tree (`GET /api/runs/<id>` shows parent + children). When a
message/handoff run ends, the hub itself sends a `kind=result` message
back — the return path is hub-deterministic, never model-dependent.

Loop protection: depth is hub-computed per (sender, thread) and capped at
5; a recipient is rate-capped at 10 messages/60s. A dropped message is
**stored** with its status and a `bot_message_rejected` event, never
silently discarded. Every agent's materialized `home/` carries a `FLEET.md`
with the hub URL and the exact handoff convention the model is instructed
to follow.

## Routines

Per-agent scheduled and triggered work, scheduled **in the hub** (no second
scheduling layer):

- `schedule` — interval seconds only (one syntax; `{"interval_s": N}`,
  N ≥ 30 at the API). Cron is deliberately unsupported: no stdlib parser,
  and wall-clock alignment buys nothing for irregular-length bot tasks.
- `trigger` — a small enumerable vocabulary: `{"type": "run_completed",
  "agent_id": "X"}` or `{"type": "bot_message", "from_agent": …}` — not a
  rules engine.
- Missed-fire: exactly **one** catch-up run at boot, then the schedule
  resyncs to now + interval — a laptop sleeping 10h never wakes to 40 runs.
- A routine never fires while its own previous turn is in flight; a fire at
  a degraded agent counts a failure; **3 consecutive failures disable the
  routine loudly** (event + orange UI state).
- Runs created by a routine carry `run_kind=routine` and `routine_id`, so
  attribution, graphs, and activity views pick them up with no
  special-casing.

## Observability

One logging path for the whole hub: every subsystem (and every print site)
flows into `~/.vertus/logs/vertus.log` (rotated 5MB × 5) plus stdout for
launchd. At boot the hub self-checks every subsystem — store writer
(real round-trip probe), scheduler thread, message bus, fleet listener,
session manager, registry — and logs one explicit line each. `GET
/api/health` re-probes live: uptime, per-subsystem ok/failed with reasons,
agent count, running runs, degraded agents, scheduler next fire. The Fleet
app shows a red "Hub degraded — failing: …" banner when anything fails, so
a dead scheduler is visible in the UI, not just in a log.

## Clients

- **VertusFleet** (`vertus/apps/dist/VertusFleet.app`) — the full window:
  roster with live busy indicators and "working for X", per-agent
  transcript (history-paginated + live deltas merged without duplication),
  run list with distinct cancelled/timeout states and parent/children
  navigation, bot threads view, fleet activity (user / bot / routine
  badges), bot editor (identity, computer use + targets, autonomy, and the
  per-agent routines block), declared-screen roster, and
  background-completion user notifications with per-agent mute.
- **VertusBar** (`vertus/apps/dist/VertusBar.app`) — the notch QuickBar
  (⇧⌘J): agent picker, fire-and-forget submit (closing the panel never
  abandons a run), a compact busy strip (with Stop and "working for X"),
  and "Open in Fleet".
- **Terminal REPL** — the pi UI runs its **own in-process session** (it
  does not talk to the hub); engine selection is in code (`sdk.ts`): the
  default is the native pi `AgentSession`, and `VERTUS_ENGINE=hermes`
  opts into the hermes brain. The README previously claimed hermes was the
  terminal default — it is not. One-shot `vertus "<question>"` proxies
  through the hub.
- **VertusPhone** — iOS scaffold over Tailscale; chat surface only.

Build everything with one command:

```bash
cd vertus/apps && bash scripts/build-apps.sh release
# → dist/VertusFleet.app + dist/VertusBar.app
```

The bundle step is not cosmetic: notifications require a real bundle, and
the bar's launchd agent points at the bundle. Test suites: `python3 -m
pytest vertus/server/` (~160 tests, no engine spawned) and `cd vertus/apps
&& swift test` (VertusKit against a stub hub over real sockets).

## Running

**`vertus doctor`** — `python3 vertus/server/vertus_server.py doctor [--json]`
(exit 1 on any failed check; ~3s; read-only). It verifies what nothing else
in the repo checks: that the forked hermes gateway still speaks the exact
JSON-RPC dialect the bridge depends on, by spawning a THROWAWAY gateway on a
temp HERMES_HOME and probing every RPC and the event vocabulary (no model
turns — turn-only checks report `unverified` rather than hanging). Also
checks the fork/venv, cua-driver + empirical TCC probes, hub health and
code currency, store integrity/WAL/schema, agent profile schema versions,
and the launchd agents. Safe against a live hub and with none running; it
never writes to ~/.vertus.

See [docs/FIRST_RUN.md](docs/FIRST_RUN.md) for the tested fresh-machine
walkthrough. In short: install the two launchd plists from
`disabled-launchagents/`, build the bundles, `launchctl bootstrap` both.
The hub binds 127.0.0.1 plus your Tailscale IP; every request needs
`Authorization: Bearer $(cat ~/.vertus/token)` (auto-created at first
boot). Point a dev build at a different hub with `VERTUS_HUB_URL` (takes
precedence over UserDefaults `vertus.baseURL`, then 127.0.0.1:8787).

## API surface

All bearer-guarded; unknown agents 404; degraded agents 503 on prompt.

| Endpoint | Meaning |
|---|---|
| `GET /api/health` | real health: subsystems, uptime, census, next fire |
| `GET /api/agents` · `POST /api/agents` | list / create (full field set) |
| `GET/PATCH/DELETE /api/agents/<id>` | profile / partial update (deferred respawn) / archive (409 when primary or busy) |
| `GET /api/agents/<id>/status` | live state incl. silence, degraded, blocked-on-target |
| `GET /api/agents/<id>/messages?limit=&before=` | paginated folded history |
| `POST /api/agents/<id>/cancel` | cancel the active turn |
| `POST /api/prompt` | queue a turn → 202 `{accepted, agent_id, run_id}` |
| `GET /api/events?agent_id=&since=&run_id=` | SSE — agent stream, fleet stream, or one run; replay from `since=`; `lagged` on drop |
| `GET /api/skills?agent_id=` | slash/skill catalog |
| `POST /api/messages` · `GET /api/messages` | bot-to-bot send / list |
| `GET /api/threads` · `POST /api/threads/<id>/read` | bot threads |
| `GET /api/approvals?state=` | approval ledger (read-only — see LIMITS) |
| `GET /api/runs?agent_id=&state=&limit=&before=` | run list |
| `GET /api/runs/<id>` · `POST /api/runs/<id>/cancel` | run detail (parent/children) / cancel (drain_queue) |
| `POST /api/routines` · `GET /api/routines` | create / list |
| `GET/PATCH/DELETE /api/routines/<id>` | routine row / edit / remove |
| `POST /api/routines/<id>/run` · `GET /api/routines/<id>/history` | fire now / runs produced |
| `GET /api/fleet/activity?limit=` | newest runs across all agents |
| `GET /api/fleet/screens` | declared targets, holders, waiters, driver inventory |

Wire events: `text`, `activity`, `done`, `error`, `cancelled`, `lagged`,
`bot_message`, `routine_fired`, `routine_skipped`, `routine_disabled`,
`approval_request` — every event carries `agent_id`, `run_id`, `seq`, `ts`.

## Configuration knobs

| Env var | Meaning |
|---|---|
| `VERTUS_HERMES_REPO` / `VERTUS_HERMES_PYTHON` | gateway repo / python (default `~/.hermes/hermes-agent` + its venv) |
| `VERTUS_AGENTS_DIR` / `VERTUS_DB_PATH` / `VERTUS_LOG_DIR` | where state lives (defaults under `~/.vertus`) |
| `VERTUS_HOST` / `VERTUS_PORT` | hub bind (default 8787) |
| `VERTUS_EVENT_TTL_DAYS` | event retention (default 30) |
| `VERTUS_LOG_LEVEL` | hub log level (default INFO) |
| `VERTUS_HUB_URL` | client base URL override (env > UserDefaults > default) |
| `VERTUS_ENGINE` | terminal REPL engine: `hermes` opts in; **default is pi** |
| `HERMES_YOLO_MODE` | bypass the fork's approval prompts (spawn-time) |

## Limits

Read this before trusting the fleet with anything consequential.

- **`cua_targets` is a declaration, not a sandbox.** The hub gates *conflicts
  between agents* on declared targets; it cannot see which window an agent
  actually touches, and an agent can target a window it never declared. The
  caveat is stated in `/api/fleet/screens` and in the UI.
- **No per-action GUI approval.** In gateway mode the fork never registers
  its approval callback for computer-use actions, so the hub cannot offer
  allow/deny per action — only spawn-time permission modes (`ask` →
  standard, `trusted` → standard until a manifest schema exists; `bounded`
  is not safely constructible today). The approvals table exists and is
  read-only; flipping `approvals.mode` in a per-agent config.yaml would
  make *shell/file* approvals hub-answerable, at the cost of a much wider
  blast radius.
- **One desktop means no per-agent screen isolation.** Two drivers on
  distinct windows work in parallel and never move the real cursor or steal
  focus, but they share your GUI session. The driver refuses background
  keyboard input when the target pid owns several top-level windows
  (`same_pid_keyboard_ambiguity`) — clicks work, typing into such apps may
  not. True isolation would mean VM-per-agent or headless displays, which
  this repo does not provide.
- **Model compliance with delegation conventions is not guaranteed.** The
  hub makes the *return path* deterministic (auto-results), but the
  outbound decision — whether a model actually curls the handoff — is model
  behavior. It usually works with the materialized persona + FLEET.md, and
  sometimes it doesn't (observed: a model answered a transcription task
  with "entropy 8" instead of doing it). Depth/rate caps bound the damage;
  they don't prevent the flake.
- **Sandbox is a default working directory, not a jail.** The engine can
  read/write any path the hub user can. Per-agent OS confinement is not
  implemented.
- **Delegated work and routines run while you are not there.** Stall and
  hard timeouts, the thrash cap, and the failure threshold are your brakes;
  set them per agent and check `/api/health` when behavior looks wrong.