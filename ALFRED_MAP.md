# ALFRED_MAP

Condensed map of the files that handle **chat loops**, **LLM API calls**, and **state management** across Alfred's four subsystems (iOS app, macOS Hermes client, cloud API, freellmpool). Paths are relative to the repo root.

## Chat loops

- `Alfred/Alfred/Services/ChatStore.swift` — iOS conversation state + the send/retry loop that pushes a prompt to Alfred and appends the reply to a disk-persisted transcript.
- `Alfred/Alfred/Services/VoiceStore.swift` — iOS full-duplex voice loop: pumps 24 kHz mic frames to the Mac's WebSocket bridge and streams decoded speech back.
- `Alfred/Alfred/Services/AlfredClient.swift` — the iOS network layer that POSTs a message to the relay endpoint and maps 200/202/401/503 into user-facing errors.
- `AlfredMac/Alfred/HermesAgent/HermesSession.swift` — the Mac's main chat loop: owns a `hermes acp` subprocess and streams text/thought/tool events over ACP (JSON-RPC over stdio).
- `AlfredMac/Alfred/HermesAgent/RelayWorker.swift` — long-polls `/api/mac`, runs incoming phone messages through HermesSession, and posts the reply back to the relay.
- `AlfredMac/Server/alf_voice_bridge.py` — the Mac-side WebSocket voice bridge feeding mic frames through the Moshi-MLX encode→step→decode pipeline.
- `api/mac.ts` — the KV-mailbox relay that moves opaque messages between the iPhone (POST) and the Mac (long-poll GET), with no logic of its own.
- `api/app.ts` — cloud chat front door: `POST /api/app` auth-gates the request and runs it through the shared `routeMessage` pipeline.
- `api/_lib/route.ts` — transport-neutral routing: the shared "message in, reply text out" pipeline used by both the Telegram webhook and the iOS app.
- `api/_lib/reply.ts` — the Reply-sink abstraction that lets one brain serve two transports and collects multi-message handler output into one coherent reply.
- `api/_lib/chat.ts` — cloud chat brain: keyword-detects calendar/news needs, injects fetched context, then calls the LLM chain (and declines Mac-only asks deterministically).

## LLM API calls

- `api/_lib/llm.ts` — the cloud's single LLM entry point: an ordered chain of free-tier (Gemini, Groq, Cerebras, OpenRouter, Mistral) slots with KV-shared cooldowns and per-capability routing.
- `AlfredMac/Alfred/HermesAgent/HermesSession.swift` — also the ACP client that drives the local model on the Mac (listed above; Hermes itself owns provider config).
- `AlfredMac/Alfred/App/ProviderKeyRing.swift` — stores free-tier provider API keys and injects them as env vars into Hermes and the opencode coding agent on spawn.
- `freellmpool/src/freellmpool/router.py` — the `Pool`: provider selection and failover that walks ordered targets until one answers.
- `freellmpool/src/freellmpool/client.py` — the HTTP client and per-provider request/response adapters (openai/gemini/anthropic wire formats).
- `freellmpool/src/freellmpool/proxy.py` — a tiny OpenAI-compatible HTTP proxy backed by the Pool, so any OpenAI-SDK app can use the free tiers.
- `freellmpool/src/freellmpool/anthropic_shim.py` — translates the Anthropic Messages API to the pool's OpenAI-style chat so Claude Code can run on free models.
- `freellmpool/src/freellmpool/tokenmax.py` — fans one prompt out to a swarm of free models and synthesizes the results.
- `freellmpool/src/freellmpool/mcp_server.py` — MCP server exposing the pool's ask/tokenmax/second-opinion surfaces as tools.

## State management

- `Alfred/Alfred/Services/AppSettings.swift` — holds where Alfred lives (host, token, voice host) with Keychain-backed persistence.
- `Alfred/Alfred/Services/Keychain.swift` — keeps the APP_TOKEN credential in the Keychain rather than UserDefaults.
- `Alfred/Alfred/Services/MailStore.swift` — the account and mailbox list that stays true across the whole Email tab.
- `Alfred/Alfred/Services/MessageListModel.swift` — one mailbox's worth of messages and every action the list can take on them.
- `Alfred/Alfred/Services/CalendarStore.swift` — the phone's EventKit calendar: events, permissions, and change observation.
- `Alfred/Alfred/Services/RemindersStore.swift` — the phone's EventKit reminders behind their own permission gate.
- `Alfred/Alfred/Services/SubscriptionStore.swift` — calendar subscriptions synced from backend-fetched .ics feeds.
- `Alfred/Alfred/Models/DailyBriefing.swift` — the Home-tab briefing: greeting rotation and calendar→plain-text summarization.
- `AlfredMac/Alfred/Presence/AssistantPresenceState.swift` — the five-state state machine driving the notch's hidden/collapsed/expanded UI.
- `AlfredMac/Alfred/Learning/Vault.swift` — where Alfred's memory lives (Obsidian vault path/config, default `~/.alfred/vault`).
- `AlfredMac/Alfred/Learning/MemoryStore.swift` — the in-memory index over vault markdown notes, plus grounding text for prompts.
- `AlfredMac/Alfred/Learning/PersonalMemoryStore.swift` — people/routines/communication-style memories and their grounding text.
- `AlfredMac/Alfred/App/UsageTracker.swift` — the estimated free-tier usage meter, one entry per stored API key.

## External capability bridges (agent-bridge)

Injected into every Hermes session Alfred starts via `~/.alfred/agent-servers.json` (see `agent-bridge/setup.sh` and `agent-bridge/agent-servers.example.json`):

- **odysseus** — memory/rag/email/image-gen MCP servers from `~/02 - REPOS/odysseus`.
- **omp-agent** — `omp` (oh-my-pi) coding agent wrapped by `omp_mcp_server.py` (enhanced fork of the former `pi` bridge).
- **openswarm** — multi-agent deliverables via FastAPI server (`openswarm_mcp_server.py`).
- **browser-use** — browser automation MCP server (`browser-use-mcp-wrapper.sh` → `.venvs/browser-use`, 16 browser tools).
- **agentmemory** — persistent coding-agent memory: 53 MCP tools + hermes plugin (`~/.hermes/plugins/agentmemory`) + pi extension (`~/.pi/agent/extensions/agentmemory`). Server on :3111 auto-starts at login via the `com.alfred.agentmemory` launchd service (`setup.sh` → `setup_agentmemory_service`), with the on-device `UnifiedMemoryLayer` (`AlfredMac/Alfred/Learning/UnifiedMemoryLayer.swift`) as the local graph since the consolidation (the former `AgentMemoryServer` is retired).
- **prime-agent** — self-improving RLM coding agent (PrimeIntellect) wrapped by `prime_mcp_server.py` (global npm install, v0.7.1+).
- **graphiti** — temporal knowledge graph in FalkorDB (`graphiti-mcp-wrapper.sh` → `~/02 - REPOS/graphiti`, config at `graphiti/alfred-config.yaml`): runs on free tier with gemini-flash-latest (LLM) + gemini-embedding-001 (embeddings), both keyed off Alfred's ProviderKeyRing. FalkorDB (:6379) is kept running by the `com.alfred.falkordb` launchd service (`agent-bridge/falkordb-launchd.sh`).
- **memory-graph** — unified people/relationship query tool (`memory_graph_mcp_server.py`): searches agentmemory (REST :3111) and graphiti (direct FalkorDB Cypher on graph `alfred`) together via `memory_graph_query` / `memory_graph_person`, so Hermes needs one call instead of two. Both backing stores are launchd services.

## Launchd services

Long-lived services registered in `~/Library/LaunchAgents/` (written + bootstrapped by `agent-bridge/setup.sh`, matching OpenSwarm's pattern): `com.alfred.openswarm` (:8080), `com.alfred.agentmemory` (:3111), `com.alfred.falkordb` (:6379 via `falkordb-launchd.sh`), plus `com.alfred.launcher` (Alfred.app) and `com.alfred.freellmpool` (:8210). All run at login with KeepAlive. The agentmemory + falkordb plists set an explicit PATH because launchd's default omits `/usr/local/bin` (node + docker).
