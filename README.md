# VERTUS

A fleet of named AI agents on one Mac. Each agent has its own identity
(persona, model), its own home and working directory, its own engine
gateway — and they talk to each other, delegate work, run on schedules, and
report back. You watch them from the VERTUS app (one window, one notch
QuickBar, one process) or the terminal; every turn is durable, replayable,
and cancellable.

```
┌──────────────────────┐      ┌──────────────────────────────────────┐
│  VERTUS.app (macOS)  │─────▶│  VERTUS Hub (Python, launchd)        │
│  one window + notch  │      │  per-agent gateways → hermes fork    │
│  QuickBar (⇧⌘J)      │      │  SQLite run store (WAL, one writer)  │
│  (one process)       │      │  SSE fleet stream (since= replay)    │
├──────────────────────┤      │  scheduler + message bus + leases    │
│  terminal REPL       │─────▶└──────────────┬───────────────────────┘
│  (pi UI, hub mode)   │                     │ per-agent spawn
└──────────────────────┘                     ▼
                          ~/.hermes/hermes-agent (fork) — gateway
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
│   │   ├── guest_manager.py      # disposable Linux VM per agent (QEMU)
│   │   ├── vnc_rfb.py            # pure-stdlib RFB client + PNG encoder
│   │   ├── seed_iso.py           # cloud-init NoCloud seed (pure ISO9660)
│   │   ├── vertus_logging.py     # one rotating log for the whole hub
│   │   └── test_*.py             # ~160 pytest tests, no engine spawned
│   ├── apps/                     # one Swift Package, two targets
│   │   ├── Sources/VertusKit     # client, models, store, fleet stream
│   │   ├── Sources/Vertus        # the app: window + notch panel + menubar
│   │   └── scripts/build-app.sh  # ONE command → dist/Vertus.app
│   └── extensions/               # legacy pi-era skills (pi engine path)
├── disabled-launchagents/        # canonical launchd plists (hub)
└── pi/                           # terminal UI fork (the REPL)
```

The engine is a local fork of NousResearch/hermes-agent
(`~/.hermes/hermes-agent`, branch `vertus`) spoken to over its TUI-gateway
JSON-RPC. The terminal UI is a fork of earendil-works/pi.

## Agents

Every agent is a directory under `~/.vertus/agents/<id>/`:

```
profile.json          # schema v5 — the SINGLE SOURCE OF TRUTH
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
computer_use, cua_targets, stall_timeout_s, hard_timeout_s,
memory_capture (automatic|off), created_at, updated_at, is_primary,
sandbox_path, home_path, schema_version`.

- `id` is the directory name and never changes; `name` is display-only.
  `primary` is auto-created at boot and cannot be deleted.
- Each agent's gateway is spawned with its `home/` as `HERMES_HOME` (the
  fork's per-process config-root override) and an explicit **env allowlist**
  — the hub never hands a gateway the whole environment, so no bot's
  context leaks into another's engine.
- Two agents run fully in parallel (own queue + worker + gateway each).
  Within one agent, prompts serialize in submission order.

## Memory

Memory is a **hub-owned resource with one source of truth**; files remain
the model's interface (bots read and write them by tool call — nothing
changes there). The hub owns, indexes, and broadcasts them.

```
~/.vertus/memory/shared/              CANONICAL — fleet-wide, every agent reads/writes
~/.vertus/agents/<id>/memory/         CANONICAL — private to that agent
~/.vertus/agents/<id>/home/memories/  FORK-OWNED MIRROR ({USER.md, MEMORY.md})
~/.vertus/agents/<id>/home/memory-digest.md   hub-generated recall digest (derived state)
~/.vertus/memory/.hub-index.json     hub-maintained index (never model-written)
```

**Automatic capture (`facts.md`).** The hub captures durable facts itself at
turn end — it does not trust the model to remember to write notes (qm-style;
see VERTUS_PLAN §8). After a run completes, the hub batches the run's folded
user/assistant messages (per agent/thread, 3-minute quiet window, 10-turn
cap), runs a one-shot extraction completion through the fork's own venv with
the agent's own model/provider and keys (the same machinery the doctor
probes), and folds the facts into `facts.md` in the agent's memory dir (or
`shared/facts.md` for `SHARED:`-prefixed facts) with deterministic dedupe,
`- (YYYY-MM-DD)` date stamps, and a 300-fact cap. `facts.md` is hub-owned —
models read it, never edit it; every write is atomic, indexed, and broadcast
as a `memory_changed` event. Best-effort by design: a provider failure just
means nothing is captured that turn. Per-agent switch: `memory_capture`
profile field (`automatic` default, `off` disables); hub-wide
`VERTUS_MEMORY_CAPTURE=0` kills it globally. Autonomous turns (bot messages,
handoffs, routines) capture operational facts only, never preferences.

**Recall digest (`memory-digest.md`).** The hub regenerates a capped (6,000
char) digest per agent — its facts, fleet facts, profile, and recent notes —
at boot, on agent creation, and debounced after every memory change. The
memory skill tells each bot to read it at session start, so the hub
*guarantees* memory reaches the model instead of hoping the bot remembers to
look. The digest is derived state inside `home/` (never the fork-owned
`memories/` dir) and is safe to clobber.

- **Mirror sync rule (one direction, fork → canonical):** a fork write to
  `home/memories/` propagates into the agent's canonical `memory/` and is
  never destroyed by re-materialization — only SOUL.md, config.yaml and the
  skills are derived identity and get clobbered on PATCH, which is correct
  behavior. If canonical moved since the hub last mirrored (a human edit),
  the fork's version is staged as `*.conflict-<ts>` — both sides survive.
- **Concurrency:** shared memory is written with a per-file `fcntl` advisory
  lock plus temp-file + `os.replace`, so two agents (or a bot and a human)
  writing the same file can never interleave or truncate — a write is
  atomic or absent. The fork's own `memory_tool` additionally locks its two
  files with its own `.lock` sidecars.
- **Change detection:** a hub watcher polls canonical dirs and every agent's
  `home/memories/` pair every 2s, mirrors fork writes, and emits a
  `memory_changed` fleet event (writer-attributed: the agent id, `human`,
  or `external`) — every connected surface updates live, whether the change
  came from a bot's tool call or a human edit in the UI.
- **Migration:** legacy pre-fleet memory (`~/.vertus/memory/*`,
  `~/.hermes/memories/USER.md`) was backed up to `~/.vertus/backups/`,
  folded into `shared/` byte-for-byte, and the legacy paths replaced with
  symlinks; the migration is idempotent (marker `.migrated_v1`) and refuses
  to overwrite divergent canonical content.
- **`home/memories/` is fork-owned.** Hand-edits inside `home/` are derived
  state and are destroyed on re-materialization; the canonical locations
  above are the only places to edit memory directly.

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
agent count, running runs, degraded agents, scheduler next fire. The app
shows a red "Hub degraded — failing: …" banner when anything fails, so
a dead scheduler is visible in the UI, not just in a log.

## Clients

- **VERTUS** (`vertus/apps/dist/Vertus.app`) — one app, one process, both
  surfaces: the full window (roster with live busy indicators and
  "working for X", per-agent transcript history-paginated + live deltas
  merged without duplication, run list with distinct cancelled/timeout
  states and parent/children navigation, bot threads view, activity
  (user / bot / routine badges), bot editor (identity, computer use +
  targets, autonomy, per-agent routines), declared-screen roster, memory
  view, and background-completion user notifications with per-agent
  mute) and the notch QuickBar (⇧⌘J: agent picker, fire-and-forget
  submit — closing the panel never abandons a run — a compact busy strip
  with Stop, and an in-process "open the window" affordance). Installed
  to `/Applications`, launched at login via SMAppService. Closing the
  window keeps the menubar item; quitting from the menubar quits
  everything.
- **Terminal REPL** — the pi UI in three engine modes (selected in code,
  `sdk.ts`; the wrapper defaults to `pi`):
  - `VERTUS_ENGINE` unset / `pi` — the native pi `AgentSession`, fully
    local, byte-for-byte the pre-fleet REPL (verified: a local turn
    renders its reply and writes session state to `~/.vertus/agent`
    without creating any hub run). The README previously claimed hermes
    was the terminal default — it is not.
  - `VERTUS_ENGINE=hermes` — the hermes brain (unchanged).
  - `VERTUS_ENGINE=hub` — the terminal as a **fleet client**
    (`HubSession`): the pi UI unchanged, but every turn runs on a
    fleet agent's hub-managed gateway. Agent selection: `--agent <id>`
    > `VERTUS_AGENT` env > `primary`. Transcript seeds from
    `/api/agents/<id>/messages`; the live fleet stream resumes with
    `since=` and a persisted cursor, so closing the terminal never
    abandons a running turn. Steer (mid-turn correction) →
    `POST /api/steer`; abort → the hub's escalation ladder. Bot
    messages / handoffs / routines for that agent render as attributed
    bubbles. REPL features the hub cannot honor (thinking level, model
    switching, compaction, session naming, queue modes, interactive
    bash context injection) degrade EXPLICITLY — a visible notice says
    why; see the full degradation table in VERTUS_PLAN.md §9. Steer
    delivery is honest: the fork injects steers only at the next tool
    batch, so a generation-only turn may never receive one — the
    terminal says so, and the hub emits `steer_undelivered` when a turn
    ends with an undelivered steer. One-shot `vertus "<question>"`
    proxies through the hub.
- **VertusPhone** — iOS scaffold over Tailscale; chat surface only.

Build everything with one command:

```bash
cd vertus/apps && bash scripts/build-app.sh
# → dist/Vertus.app  (install: cp -R dist/Vertus.app /Applications/)
```

The bundle step is not cosmetic: notifications require a real bundle, and
launch-at-login is registered by the app itself via SMAppService (with a
launchd fallback). Test suites: `python3 -m pytest vertus/server/` (~220
tests, no engine spawned) and `cd vertus/apps && swift test` (VertusKit
against a stub hub over real sockets).

## Running

**`vertus doctor`** — `python3 vertus/server/vertus_server.py doctor [--json]`
(exit 1 on any failed check; ~3s; read-only). It verifies what nothing else
in the repo checks: that the forked hermes gateway still speaks the exact
JSON-RPC dialect the bridge depends on, by spawning a THROWAWAY gateway on a
temp HERMES_HOME and probing every RPC and the event vocabulary (no model
turns — turn-only checks report `unverified` rather than hanging). Also
checks the fork/venv, cua-driver + empirical TCC probes, hub health and
code currency, store integrity/WAL/schema, agent profile schema versions,
memory canonical/mirror consistency and the injected skill paths, the
launchd agents, a sweep for stray `com.vertus.*` launchd labels (a demo
agent must not outlive its demo), and the terminal's hub-mode attach path
(hub reachable, `VERTUS_AGENT` resolvable, steer endpoint live — probed
only on an idle agent). Safe against a live hub and with none running; it
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
| `GET /api/memory?scope=shared\|agent\|all&agent_id=` | index-backed listing |
| `GET /api/memory/search?q=` | substring search across all scopes |
| `GET /api/memory/<scope>/<path>` | read one entry (content as text) |
| `PUT /api/memory/<scope>/<path>` | write one entry, human-initiated |
| `DELETE /api/memory/<scope>/<path>` | delete one entry |

Wire events: `text`, `activity`, `done`, `error`, `cancelled`, `lagged`,
`bot_message`, `routine_fired`, `routine_skipped`, `routine_disabled`,
`approval_request`, `memory_changed` (no run_id; carries `scope`, `path`,
`writer`) — run-scoped events carry `agent_id`, `run_id`, `seq`, `ts`.

## Configuration knobs

| Env var | Meaning |
|---|---|
| `VERTUS_HERMES_REPO` / `VERTUS_HERMES_PYTHON` | gateway repo / python (default `~/.hermes/hermes-agent` + its venv) |
| `VERTUS_HERMES_SKILLS` | Hermes-shipped app skills copied into every agent home at boot (default `apple-notes,github`; each only when its CLI is on PATH). `off` = none; a list replaces the default; `+imessage` / `-github` adjust it. Per agent, Hermes's own `skills.disabled` in the home's config.yaml survives re-materialization |
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
- **One desktop means no per-agent screen isolation — unless the agent has
  a guest.** Two drivers on distinct windows work in parallel and never
  move the real cursor or steal focus, but they share your GUI session.
  The driver refuses background keyboard input when the target pid owns
  several top-level windows (`same_pid_keyboard_ambiguity`) — clicks work,
  typing into such apps may not. The fleet now ALSO ships a disposable
  guest path (`/api/fleet/guests`, `vertus-guest`): each agent can get its
  own QEMU Linux VM with its own disk, identity, and screen, streamed as
  PNG frames over the hub (multipart). Real per-agent isolation is
  VM-per-agent, and this is the first slice of exactly that — currently
  boot/stop/reset + live screen; input injection and desktop provisioning
  inside the guest are the next slices.
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