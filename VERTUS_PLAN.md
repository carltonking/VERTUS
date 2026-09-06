# VERTUS — Full Blueprint (as built)

VERTUS is a **multi-agent fleet** that runs named agent instances on one Mac,
each with its own identity, config root, and gateway process, coordinated by a
single hub. The original plan — a single pi-based agent with a Bun/TS server,
NVIDIA NIM, and a Tailscale phone app — is history. What exists today, and the
decisions behind it, are below.

The short version is [README.md](README.md); the tested fresh-machine
walkthrough is [docs/FIRST_RUN.md](docs/FIRST_RUN.md). This document is the
blueprint: architecture, invariants, decisions, limits.

---

## 1. Architecture

```
┌─────────────────────────┐      ┌──────────────────────────────┐
│  VERTUS.app (SwiftUI)   │      │  Vertus hub (Python)         │
│  one process:           │─────▶│  vertus_server.py            │
│  • notch panel, ⇧⌘J,    │ HTTP │  - session manager (bridges) │
│    fast path only       │ SSE  │  - run store (SQLite)        │
│  • full window: roster, │      │  - routine scheduler         │
│    chat, runs,          │      │  - message bus               │
│    routines, approvals, │      │  - screen target registry    │
│    activity, memory     │      │  - approval ledger (ro)      │
└─────────────────────────┘      └──────────────────────────────┘
                                        │ spawn (env allowlist,
                                        │ per-agent HOME)
                                        ▼
                     ~/.hermes/hermes-agent (fork, branch `vertus`)
                     TUI-gateway JSON-RPC per agent — one gateway
                     process per agent, killed/reaped by the hub
```

- **One hub process**, stdlib `ThreadingHTTPServer`, binds 127.0.0.1 + the
  Tailscale IP, bearer-token auth, SSE for events. Launched by launchd
  (`disabled-launchagents/com.vertus.server.plist`), KeepAlive.
- **One gateway per agent** (`hermes_bridge.py`): the hermes fork's
  `tui_gateway` JSON-RPC server, spawned with an explicit allowlisted env and
  a per-agent home. The hub is the only client of the fork; the fork is never
  modified.
- **One event stream for the whole fleet.** Every emitted event carries
  `agent_id`, `run_id`, `seq`, `ts`. Clients subscribe to the fleet stream and
  demultiplex; `since=` replay makes disconnects recoverable.
- **SQLite as the source of truth** for runs, events, messages, bot_messages,
  threads, approvals, routines. One dedicated writer thread; readers use their
  own connections. WAL mode. No ORM.

---

## 2. Per-agent identity and homes

Each agent's profile lives in `~/.vertus/agents/<id>/profile.json`
(`agent_registry.py`) — the **single source of truth**. Schema-versioned
(v3 today) with lossless, idempotent migrations: v1→v2 added persona/model/
provider/color/emoji/autonomy; v2→v3 added `computer_use` and `cua_targets`.
Unknown keys are never dropped.

The on-disk home is **derived state**, re-materialized on create and on every
profile update:

```
~/.vertus/agents/<id>/home/
    config.yaml     # model/provider, permission mode from autonomy
    SOUL.md         # written from profile.persona
    memories/USER.md
    FLEET.md        # hub URL + curl templates for messaging/delegation
~/.vertus/agents/<id>/memory/     # this bot's own notes (per-bot)
~/.vertus/memory/shared/          # fleet-wide notes (all bots read/write)
```

The hub spawns each gateway with its own `HOME`-equivalent so config, persona,
and memory never leak across bots (see §7 — this replaced the original
`env={**os.environ}` inheritance and a `VERTUS_REMOTE` process-global race).

## 3. Run store and replay

`run_store.py` — `~/.vertus/fleet.db` (env `VERTUS_DB_PATH`), WAL, one writer
thread with a queue.

- **`runs`**: `run_id, agent_id, prompt, remote, source, state, started_at,
  ended_at, error, gateway_respawns, run_kind, parent_run_id, routine_id,
  from_agent, thread_id`. States: `queued|running|done|error|interrupted|
  abandoned|cancelled|timeout`.
- **`events`**: every wire event, with a global monotonic `seq` across the
  whole fleet — one cursor, not per-agent. **Durability rule: an event is
  written to the store *before* it is fanned out.** No event reaches a client
  that is not in the store; a store failure fails the run.
- **`messages`**: folded user/assistant turns — deltas are stored as emitted,
  and the assembled assistant text is folded into one row per message at turn
  end, so history reads are O(messages), not O(deltas).
- Replay: `GET /api/events?since=<seq>` drains the store past the cursor then
  hands off to live with no gap and no duplicate (tested with an event
  landing mid-drain). A subscriber whose queue overflows is dropped (existing
  behavior) but the drop is recoverable: a `lagged` event carries the last
  `seq`, and the client resumes with `since=`.
- Crash recovery: runs left `queued|running` at boot are marked `interrupted`
  (count logged). `events` older than `VERTUS_EVENT_TTL_DAYS` (default 30)
  are pruned on boot and daily; `runs` and `messages` are never pruned — they
  are the record of what the fleet did, and outlive agent deletion.

## 4. Supervision and cancellation

The fork's `session.interrupt` RPC was never called by any code path before
this work; it is now the first rung of the escalation ladder:

1. `session.interrupt`, wait `grace_s` (default 10);
2. terminate the gateway process (group signal), wait;
3. `kill -9`;
4. mark the run terminal, release declared targets, drop the dead session so
   the next prompt respawns.

Each rung is logged with which one succeeded. Stalls are detected by **event
silence, not wall clock** (a healthy CUA turn is slow but chatty): per-agent
`stall_timeout_s` (default 180) and `hard_timeout_s` (default 3600, a backstop
for a turn that emits forever). Both are visible in `status()`, along with
elapsed silence, so a slow-but-healthy turn is distinguishable from a stuck
one. A timeout ends the run `state=timeout`.

Gateway supervision (`hermes_bridge.py`):

- respawn with backoff: 3 attempts, 1s/4s/16s, jittered; after exhaustion the
  agent is **degraded** (visible in `status()`, prompts 503 with a readable
  reason) until a successful spawn clears it;
- thrash cap: a gateway that dies more than **4 times in 10 minutes** stops
  auto-respawning and reports degraded — a couple of crashes can be transient,
  five is a broken configuration, and the hub should not thrash a wallet
  against a dead loop;
- idle-gateway health check on an interval (default 300s): a live but
  unresponsive gateway is closed so the next prompt spawns fresh;
- gateway teardown — natural exit, stale-respawn, close(), agent DELETE —
  **reaps the embedded cua-driver children** (process-group signals), and a
  boot sweep catches drivers orphaned by a previous hub life, identified by
  the embedded socket path, never by process name (the user's pre-existing
  `CuaDriver.app` daemon must never be touched).

Cancellation is a first-class terminal state, distinct from `error` and
`interrupted`: `POST /api/runs/<id>/cancel {drain_queue}` and
`POST /api/agents/<id>/cancel`, emitting a `cancelled` fleet event. A queued
run is dequeued and never spawns; a running run takes the ladder; a terminal
run 409s. Cancelling one run never touches the rest of the agent's queue
unless `drain_queue` is set.

## 5. Computer use — and its honest limits

Per-agent `computer_use: bool` and `cua_targets: [str] | null` (allowed app
bundle ids / window titles; null = unrestricted) sit in the profile (v3).
Disabled agents get `HERMES_COMPUTER_USE_BACKEND=noop` in their env
allowlist — a blank-capture stub. **Caveat stated in code and docs: a disabled
agent gets blank captures rather than a clean tool error, which a model may
misread as "nothing on screen".**

Conflict policy is **declared-target, not lease** (named in code
`screen_lease.py`): two drivers on distinct windows measurably do not
interfere (real cursor never moves, frontmost app undisturbed, `type` routes
via AX `insertText` to the target window), so GUI work is *not* serialized.
Instead a run whose agent declares non-null targets checks, at run start,
whether another **running** agent declares an overlapping target: overlap → the
run waits (`blocked_on_target` naming the holder in `status()`), released on
the holder's terminal state, gateway death, or agent DELETE — it is impossible
for a wait to outlive its holder (crash path tested). Disjoint or null
declarations run fully parallel. `GET /api/fleet/screens` returns declared
targets, holders, waiters, and the driver-process inventory.

**`cua_targets` is a declaration, not a sandbox.** The hub can see only
`tool.start` with a tool name — never the args, never the window an agent
actually touches. An agent can target a window it never declared and the hub
cannot see it. This is said in the code, in the `/api/fleet/screens` payload,
in the app UI, and in README LIMITS. Per-agent screen *isolation* would
require VM-per-agent or headless displays; this repo does not provide it.

Approval: **no per-action GUI approval exists.** In gateway mode the fork
never registers its approval callback for computer-use actions
(`tools/computer_use/tool.py:643-646`), so an allow/deny queue for GUI actions
is impossible without a fork change. `autonomy` therefore selects a spawn-time
permission mode (`ask` → `standard`, `trusted` → `standard`, with `bounded`
the intended target once a manifest schema exists — none is locally
available). The `approvals` table exists and `GET /api/approvals?state=`
works, but it is a read-only ledger of what the hub can actually observe —
which today is nothing. Flipping a per-agent `approvals: mode` to `manual` in
config.yaml would make *shell/file* approvals hub-answerable, at the cost of a
much wider blast radius; it is not flipped anywhere.

## 6. Messaging, delegation, routines

### Message bus

`bot_messages` and `threads` tables (separate from user/assistant
`messages`). A message to an idle agent starts a run with the message as the
prompt, attributed (`from_agent`, `thread_id` on the run row); a message to a
busy agent queues behind its work. Everything emits on the fleet stream.

Loop protection, both caps hub-computed so bots cannot spoof them:

- **Depth: 5 per (sender, thread)**. Results reuse the triggering depth so
  they never inflate a chain; a legitimate chain is 1–2 hops. A ping-pong
  dies at 5 hops per sender.
- **Rate: 10 messages/60s per recipient**, bounding burn *rate* on top of
  depth. A rejected attempt still consumes a slot so retrying can't beat it.

When a cap trips, exactly: the message is stored with
`status: dropped_depth|dropped_rate`, a `bot_message_rejected` event goes on
the stream, no run is created, and the POST response says so — the sending
bot sees it in its curl output.

### Delegation

Fork is off-limits and the hub cannot inject a tool into the gateway, so
delegation is **persona + message-bus convention with a hub-deterministic
return path**. Materialization writes `FLEET.md` (hub URL, exact curl
template, handoff semantics) into every agent home and appends a fleet block
to SOUL.md. The model delegates by `POST /api/messages {kind: "handoff"}`;
the hub creates the child run (`run_kind=handoff`, `parent_run_id` recorded,
depth checked) and returns a handle — it never blocks the delegator. When the
child run reaches a terminal state the hub itself sends `kind=result` back
(hub-side, not model-dependent), waking an idle delegator with a turn of its
own. Flakiness is confined to the *outbound* decision — a model that never
delegates simply doesn't — never the inbound result.

### Routines

Scheduled/triggered per-agent work (`fleet_routines.py`), the point of which
is work that happens while you are not there. `routines` table with
`schedule` (interval seconds only), `trigger` (null for pure schedule, else
an event condition: `run_completed` or `bot_message`, each with a small
enumerable filter vocabulary), `enabled`, `next_run_at`, `failure_count`.

Decisions:

- **Schedule representation: interval seconds only.** No cron parser in
  stdlib, intervals are deterministic and testable, and wall-clock alignment
  buys nothing for irregular-length bot tasks. One syntax, never two.
- **Missed-fire policy: exactly one catch-up run at boot, then resync to
  now + interval.** A laptop sleeping 10h wakes to one run, never 40; the
  next fire is a full interval away. Bounded no matter what.
- **Failure threshold: 3 consecutive failures disables the routine loudly**
  (fleet event + orange UI state). One flake is transient, two is bad luck,
  three is a broken routine.
- A routine firing at a busy agent queues behind current work; at a degraded
  agent it does not fire and increments `failure_count`. A routine can never
  fire concurrently with itself. `POST /api/routines/<id>/run` fires now,
  ignoring schedule. Runs created by a routine carry `run_kind=routine` and
  the `routine_id`, so attribution, the run graph, and activity views pick
  them up with no special-casing. Deleting an agent disables its routines.
- **Interval floor: 30s at the API** (tests bypass via an internal path).
  Below the floor is a 400 with a readable message.

The scheduler lives **in the hub**, not launchd: the hub is already under
launchd KeepAlive, and a second scheduling layer is a second failure mode —
one that failed *silently* once (a logging split), which is what §10
exists to prevent.

## 7. Spawn isolation

`hermes_bridge.py` builds each gateway's env explicitly — no `**os.environ`
inheritance. Allowlist only what the engine needs (PATH, locale,
`HERMES_*`/provider-key vars), inject the agent's home as the gateway's
config root, and deny anything agent-specific from leaking across bots. The
per-agent home is the override mechanism the fork honors (its config root is
the env-injectable home; `~/.hermes` is only a fallback). `remote` is carried
on the queue item and passed at spawn, never via process-global mutation —
the `VERTUS_REMOTE` `os.environ` write is gone, and the whole repo is free of
module-level per-turn/per-agent mutable state (grep-verified).

## 8. Memory

Memory became hub-owned in this phase (`fleet_memory.py`) after discovery
proved the memory system had never actually run (the real fleet.db had zero
runs; the skills were real plumbing, never exercised). One canonical store,
files stay the model's interface:

```
~/.vertus/memory/shared/              CANONICAL — fleet-wide
~/.vertus/agents/<id>/memory/         CANONICAL — per-bot private
~/.vertus/agents/<id>/home/memories/  FORK-OWNED MIRROR ({USER.md, MEMORY.md})
```

**Mirror sync rule:** the fork's `home/memories/` pair is a one-way mirror
into the agent's canonical `memory/` — a fork write propagates to canonical
and is never destroyed by re-materialization (SOUL.md/config.yaml/skills
are derived identity and are clobbered, which is correct). Canonical writes
never flow back into the fork home, and a canonical move between mirrors
stages the fork's version as `*.conflict-<ts>` rather than overwriting — no
write is ever silently lost. **Concurrency:** per-file `fcntl` advisory
lock + temp-file + `os.replace` (atomic-or-absent) for hub writers; the
fork's `memory_tool` has its own `.lock` sidecars for its two files.
**Change detection:** a 2s watcher polls canonical dirs and every fork
mirror, then emits `memory_changed` fleet events with writer attribution
(agent id | `human` | `external`). The index (`memory/.hub-index.json`) is
hub-maintained — the old model-maintained `index.json` expectation was
removed from the skill. Legacy pre-fleet memory was backed up, folded into
`shared/` byte-for-byte with symlinks at the old paths, and marked
`.migrated_v1` (idempotent, conflict-refusing).

`vertus_paths.py` (added in this phase) is the ONE resolver for every path
root — concept env var → `VERTUS_ROOT` → production default — after an
env-divergence bug sent a temp hub's materialized skills at the real
`~/.vertus/memory`. The doctor's `memory.skill_path` check verifies each
materialized skill points at the resolved root; the hermeticity suite
proves a `VERTUS_ROOT`-only boot touches nothing real.

## 9. Clients

The macOS client is ONE app — **VERTUS** (`com.vertus.app`) — a single
Swift Package target under `vertus/apps/Sources/Vertus` sharing
**VertusKit** — one client implementation: auth (token file or UserDefaults),
agent CRUD + status, prompt → 202/run_id, one fleet-stream SSE connection
demultiplexed by agent, `since=` resume with backoff, `lagged` recovery,
history endpoints, agent CRUD/409 typing, hub health. One process, one
store, one fleet-stream connection, one health poll, one memory index.

- **The window**: roster with live busy/blocked/degraded state, per-agent
  chat with scroll-back pagination merging live deltas, run list +
  past-run reopening, bot editor (identity, persona, model, provider,
  color, emoji, autonomy, computer_use toggle, cua_targets), routines
  block (create/edit/toggle/run-now, loud disabled-by-failures),
  bot-thread view distinct from your own chat, activity with
  user-vs-bot-vs-routine attribution, approvals view, screens view
  (with the not-a-sandbox caveat in the UI), memory view, hub-health
  banner, and **user notifications on background completion** — the
  feature that makes "fire it off and walk away" real, with per-agent
  mute and suppression for the foreground agent.
- **The notch panel**: ⇧⌘J, unchanged visual language — agent picker
  (remembers last used), fire-and-forget submit, compact busy strip,
  in-process "open the window". Closing the window keeps the menubar
  item; quitting from the menubar quits everything.

### Terminal REPL — hub mode (`VERTUS_ENGINE=hub`)

The pi UI is untouched (`HubSession` extends `AgentSession` through the same
seam `HermesSession` uses, swapping only the turn machinery). Engine
selection lives in code (`sdk.ts`), not the shell wrapper: unset/`pi` =
local native engine (the default, unchanged and verified), `hermes` = the
hermes brain, `hub` = fleet client. Agent selection: `--agent <id>` >
`VERTUS_AGENT` env > `primary`. Hub URL: `VERTUS_SERVER_URL` >
127.0.0.1:8787; token from `~/.vertus/token`.

Hub mode: transcript seeds from `/api/agents/<id>/messages`; the fleet SSE
stream resumes with `since=<persisted cursor>` so closing the terminal never
abandons a running turn; prompt → `POST /api/prompt` (202/run_id); steer →
`POST /api/steer`; abort → `POST /api/agents/<id>/cancel`. Bot messages,
handoffs, and routines for that agent render as attributed bubbles. Run
history, replay, memory, and the message bus are shared with every other
surface.

**Steer delivery is honest.** The fork's `session.steer` lands only at the
next tool-batch boundary; a generation-only turn can end with an accepted
steer that never reached the model. The terminal says so on every accepted
steer, and the hub infers delivery (an `activity` event starting with
`"running "` marks a tool boundary; a steer recorded after the last one was
undelivered) and emits `steer_undelivered` on the fleet stream at turn end.

**Degradation table** — every REPL feature in hub mode. Nothing fails
silently; each degraded feature posts a one-time or per-use visible notice:

| Feature | In hub mode | What the user sees |
|---|---|---|
| prompt / follow-up | works | queued on the hub, streamed back |
| steer mid-turn | works (tool-boundary delivery) | `Steering:` pending display + caveat notice on every accepted steer; `steer_undelivered` notice when a turn ends without delivering |
| abort (Esc/Ctrl-C flow) | works | hub escalation ladder via `/api/agents/<id>/cancel` |
| transcript seed + resume | works | history renders at start; reopen continues a closed terminal's turn |
| bot message / handoff / routine bubbles | works | `⟨message from X⟩ …` attributed user bubble |
| thinking-level set/cycle | disabled with message | "fixed by the agent profile — change it in the VERTUS app or PATCH /api/agents" |
| model set/cycle/picker (`setModel`, `cycleModel`, `setScopedModels`) | disabled with message | "model is owned by the agent profile; it applies on the next turn via the hub's deferred respawn" |
| compaction (`compact`, auto-compaction toggle) | disabled with message | "gateway manages its own context; restart the agent in the VERTUS app if a turn is losing the thread" |
| session naming | disabled with message | "the agent has one identity (its fleet name), not per-terminal sessions" |
| steering/follow-up queue modes | disabled with message | "steering is delivered straight to the live turn; follow-ups queue locally and drain as new hub turns" |
| interactive bash (`executeBash`/`recordBashResult`) | runs locally, never reaches the model | still executes as a scratch shell + one-time notice "the hub model cannot see it (the gateway has its own sandbox shell)" |
| context stats / exports / navigation / history | works (local view) | terminal-side only |
| `/login`, local auth, model discovery | falls back to local | startup happens as before; the hub agent's gateway owns the model |

- Both ship as `.app` bundles from one command:
  `cd vertus/apps && bash scripts/build-apps.sh` (bundles are not cosmetic —
  `UNUserNotificationCenter` crashes outside a bundle). `VERTUS_HUB_URL`
  (env > UserDefaults > 127.0.0.1:8787) points dev builds at a temp hub.
- VertusPhone is untouched by the fleet work and remains a separate client.

## 10. Observability

One logging path for the whole hub (`vertus_logging.py`): every subsystem —
the hub's print sites, scheduler, messenger, bridges — through one logger to
`~/.vertus/logs/vertus.log` (rotated) with stdout kept for launchd. The boot
self-check verifies each subsystem is actually live (store writer thread,
routine scheduler thread, messenger, session manager, each listener
registered) and logs one explicit line per subsystem; a subsystem that fails
to start is **loud and visible in the API**, not just the log. `GET
/api/health` is real: uptime, subsystem status, agent count, running runs,
degraded agents, scheduler next-fire, store write health — while keeping the
original `{status, time}` keys so existing clients parse it. The app
surfaces an unhealthy subsystem as a banner; that is the difference between
"my bot didn't do the thing" and "the scheduler has been dead since Tuesday".

## 11. Limits

Same honesty, stated once, in full. The README carries the short version;
the code carries it in comments; `/api/fleet/screens` and the app UI carry
the parts users can act on.

- `cua_targets` is a **declaration, not a sandbox** — the hub gates
  conflicts between agents, not what an agent actually touches.
- **No per-action GUI approval** without a fork change; autonomy is a
  spawn-time permission mode, not per-action consent.
- **One desktop means no per-agent screen isolation.** Distinct windows run
  in parallel without disturbing the real cursor or focus, but the
  `same_pid_keyboard_ambiguity` guard means background typing is refused
  when the target pid owns several top-level windows. Clicks are unaffected;
  typing into such apps may fail. VM-per-agent or headless displays would
  provide real isolation; this repo does not.
- **Model compliance with delegation conventions is not guaranteed.** The
  return path is deterministic; the outbound decision is model behavior, and
  models flake (observed). Depth/rate caps bound the damage.
- **Sandbox is a default working directory, not a jail.**
- **Routines and delegated work run unattended**; stall/hard timeouts, the
  thrash cap, and the  failure threshold are the brakes, and the logs +
  health endpoint are the witness. (Thrash cap: 4 gateway deaths in 10
  minutes pauses auto-respawn until a manual/intervening success; routine
  failure threshold: 3 consecutive failures disables the routine.)

---

## 12. Build history (branch `fleet/per-agent-identity`)

The fleet was built in ordered, individually-testable commits. The lineage,
oldest to newest: identity/spawn isolation → HTTP surface + status + lock
discipline → run history + replay → macOS clients → computer use + approvals
ledger → driver reaping + messaging + delegation → hub URL override +
routines → observability + interval floor + packaging + docs. Every commit
has a green full test run (Python suite currently 157 tests; Swift suite
19 tests). Tests live beside the code: `vertus/server/test_*.py` and
`vertus/apps/Tests/VertusKitTests/`. Run either suite from the repo root:

```bash
python3 -m pytest vertus/server/ -q
cd vertus/apps && swift test
```