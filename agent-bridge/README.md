# Alfred Agent Bridge

External capability bridges injected into every Hermes session Alfred starts.
The live config lives at `~/.alfred/agent-servers.json`; this directory holds
the wrappers, servers, and setup script that produce it.

## Quick reference

| Server | What it gives Alfred | Backing process | Status command |
|---|---|---|---|
| `odyssey-memory` | persistent vector memory | `~/02 - REPOS/odysseus` | — |
| `odyssey-rag` | document RAG over local files | `~/02 - REPOS/odysseus` | — |
| `odyssey-email` | email triage | `~/02 - REPOS/odysseus` | — |
| `odyssey-image-gen` | image generation | `~/02 - REPOS/odysseus` | — |
| `omp-agent` | `omp` (oh-my-pi) coding agent — enhanced fork of pi | `omp` (bun global) | `omp --version` |
| `openswarm` | multi-agent deliverables | FastAPI :8080 | `curl localhost:8080/openapi.json` |
| `browser-use` | browser automation (16 tools) | `.venvs/browser-use` | `./setup.sh --status` |
| `agentmemory` | persistent coding memory (53 tools) | agentmemory server :3111 | `curl localhost:3111/agentmemory/health` |
| `prime-agent` | self-improving RLM coding agent | `prime-agent` (npm global) | `prime-agent --version` |
| `graphiti` | temporal knowledge graph | FalkorDB :6379 + MCP server | `docker ps \| grep falkordb` |
| `memory-graph` | merged agentmemory+graphiti people/relationship search | `memory_graph_mcp_server.py` | `python3 test_memory_graph.py` |

## Setup

```bash
./setup.sh             # install/verify services, merge servers into config
./setup.sh --status    # verify backing services, then smoke-test every MCP bridge
```

`setup.sh` writes `~/.alfred/agent-servers.json` if missing, and merges in new
servers idempotently via `scripts/merge_agent_servers.py` (repo root) when the
file already exists.

`./setup.sh --status` runs the service checks first (vault, OpenSwarm,
agentmemory/FalkorDB launchd services), then the MCP bridge
smoke test (`smoke_test_servers.py --concurrency 4`) as its final step. The
smoke test's exit code becomes `setup.sh`'s: any server that can't boot or
answer `tools/list` makes `--status` exit nonzero, so the one command doubles
as a release gate — run it bare (piping masks the exit code).

## Launchd services (auto-start at login)

Three long-lived services are registered as launchd agents so Alfred's
capabilities come up at login without a terminal:

| Label | What runs | When |
|---|---|---|
| `com.alfred.openswarm` | OpenSwarm FastAPI server (:8080) | login + KeepAlive |
| `com.alfred.agentmemory` | agentmemory REST server (:3111) | login + KeepAlive |
| `com.alfred.falkordb` | ensures the FalkorDB Docker container (:6379) | login + KeepAlive |

Plists live in `~/Library/LaunchAgents/` and are written + bootstrapped by
`setup.sh` (`setup_agentmemory_service`, `setup_falkordb`, `setup_openswarm`).
Control them with:

```bash
launchctl list | grep alfred            # are they loaded?
launchctl kickstart -k gui/$(id -u)/com.alfred.falkordb   # restart one
launchctl bootout gui/$(id -u)/com.alfred.agentmemory     # stop one
```

- **agentmemory** runs the CLI (`~/.npm-global/bin/agentmemory`) in the
  foreground; the engine stays resident under launchd's KeepAlive. Logs:
  `~/.agentmemory/launchd.{log,err}`.
- **falkordb** runs `falkordb-launchd.sh`, a self-healing wrapper: it waits for
  Docker Desktop to boot, creates the container if it's missing (the container
  can vanish on a Docker restart — seen 2026-08-10), starts it if stopped, and
  re-checks every 30s. Logs: `~/.alfred/logs/falkordb-launchd.log`.
- Both plists set `PATH=/usr/local/bin:/opt/homebrew/bin:…` — launchd's default
  PATH omits `/usr/local/bin`, which would make the agentmemory CLI's
  `#!/usr/bin/env node` shebang exit 127 and hide `docker` from the wrapper.

## The four newest bridges (added 2026-08)

### browser-use (`browser-use/browser-use`, MIT)

Real web control: navigate, click, type, screenshot, extract — via a
Playwright-driven agent. Installed in `.venvs/browser-use`; `browser-use --mcp`
exposes the MCP server. LLM provider keys come from Alfred's ProviderKeyRing
via the session environment.

```bash
python3 -m venv .venvs/browser-use && .venvs/browser-use/bin/pip install browser-use
```

### agentmemory (`rohitg00/agentmemory`, Apache-2.0)

Hybrid BM25 + vector + knowledge-graph memory (95.2% R@5 on LongMemEval-S).
The server auto-starts at login via the `com.alfred.agentmemory` launchd
service (`setup_agentmemory_service`); Alfred's own `AgentMemoryServer`
(ProviderKeyRing.swift) remains as the on-demand fallback that launches the
CLI, patches `~/.agentmemory/.env`, and health-checks :3111. This integration
adds:

- `agentmemory` MCP server (53 tools) in `agent-servers.json`
- hermes plugin at `~/.hermes/plugins/agentmemory` (6 lifecycle hooks) with
  `memory.provider: agentmemory` in `~/.hermes/config.yaml`
- pi extension at `~/.pi/agent/extensions/agentmemory` (memory_search/save +
  before/after hooks), registered in `~/.pi/agent/settings.json`
- opencode MCP entry in `~/.config/opencode/opencode.json`

View memories live at http://localhost:3113.

### prime-agent (`PrimeIntellect-ai/prime-agent`)

Self-improving RLM coding agent (recursive subagents, IPython kernel as its
primary tool, `/refine` self-improvement loop). Not on npm — install the
release tarball:

```bash
curl -L -o /tmp/prime-agent.tgz \
  https://github.com/PrimeIntellect-ai/prime-agent/releases/download/v0.7.1/prime-agent-0.7.1.tgz
npm install -g /tmp/prime-agent.tgz
```

Exposed to Alfred via `prime_mcp_server.py` (spawns `prime-agent -p`).
Provider keys flow through from the session env.

### graphiti (`getzep/graphiti`, Apache-2.0)

Temporal knowledge graph (bi-temporal fact invalidation, provenance, hybrid
search) in FalkorDB. Runs entirely on Alfred's free tier. FalkorDB is kept
running by the `com.alfred.falkordb` launchd service (`falkordb-launchd.sh`)
so it survives logins and Docker restarts:

- **FalkorDB** (Docker): `docker run -d --name alfred-graphiti-falkordb --restart unless-stopped -p 6379:6379 falkordb/falkordb:latest`
- **MCP server**: `~/02 - REPOS/graphiti/mcp_server` (clone getzep/graphiti,
  `pip install -e '.[providers]'`), driven by `graphiti-mcp-wrapper.sh`
- **Config**: `graphiti/alfred-config.yaml` (copied to `~/.alfred/graphiti-config.yaml` by setup.sh) — gemini-flash-latest (LLM) + gemini-embedding-001 (embeddings), both from Alfred's keyring
- **Note**: the wrapper launches the server with `-u` (unbuffered stdout);
  without it the MCP handshake hangs. `redis` must be 7.x (falkordb's driver
  breaks on 5.x/8.x — `pip install redis==7.4.1`).

### memory-graph (unified people/relationship search)

A single MCP server that searches **both** stores together when Alfred is asked
about a person, organization, or relationship — one tool call instead of
teaching the model to call agentmemory and graphiti separately and merge them
itself:

- `memory_graph_query(query, limit)` — merged search: graphiti entity nodes
  + `RELATES_TO` relationship facts, plus agentmemory hybrid memories. Each
  section is labeled with its source store.
- `memory_graph_person(name)` — deep dive on one entity: stored profile,
  every relationship edge in/out, and memories mentioning them.

Implementation notes (why it's fast and light):

- **agentmemory** is queried over its documented REST API (`/smart-search` on
  :3111) — the same endpoint the hermes plugin and Alfred's `AgentMemoryClient`
  use.
- **graphiti** is queried directly over FalkorDB's Cypher (`GRAPH.QUERY` on
  graph `alfred` via the system `redis` client, :6379) rather than spawning
  graphiti's own MCP server — no second heavy python process, no cold start.
  The queries match graphiti's schema (`Entity` nodes with `.name`/`.summary`,
  `RELATES_TO` edges with `.fact`).
- User input is escaped before interpolation into Cypher string literals
  (quotes, backslashes, control chars), so a hostile query can't inject
  clauses.
- Both stores are best-effort: if one is down, the other still answers and
  the response says which store is unreachable.

Both stores' servers are launchd services (see above), so this tool works
right after login with no manual startup.

## Smoke tests

```bash
python3 smoke_test_servers.py                                  # all servers in one command (~15s)
python3 smoke_test_servers.py --concurrency 4                 # run up to 4 at once (faster full pass)
python3 smoke_test_servers.py --server graphiti --server memory-graph   # a subset
python3 smoke_test_servers.py --json                            # machine-readable summary (exit 1 on failure)
python3 smoke_test_servers.py --config agent-servers.example.json  # test the repo example instead
python3 test_mcp_server.py prime_mcp_server.py                 # single MCP servers
python3 test_mcp_server.py memory_graph_mcp_server.py          # memory-graph
python3 test_memory_graph.py                                   # live end-to-end (both stores)
python3 test_mcp_command.py ./browser-use-mcp-wrapper.sh       # bash/npx wrappers
python3 test_mcp_command.py ~/.npm-global/bin/agentmemory mcp
```

`smoke_test_servers.py` launches every server registered in
`~/.alfred/agent-servers.json`, completes the MCP handshake (initialize →
tools/list) against each, and prints a pass/fail table with tool counts. It
exits nonzero if any server fails, so it can gate a release checklist or CI.
A server passes if the bridge itself boots and speaks MCP — backing-service
health (FalkorDB, agentmemory :3111) is `./setup.sh --status`'s job.

Notes on what it covers: the `agentmemory` entry runs `npx -y @agentmemory/mcp`
exactly as Alfred does (the npx wrapper leaves a child holding the pipes after
it's killed, so cleanup SIGKILLs the whole process group).
