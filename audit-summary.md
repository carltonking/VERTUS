# Alfred Codebase Audit — Summary

> **HISTORICAL — superseded (August 2026).** This audit describes the
> pre-refactor architecture (GRDB memory store, AssistantCore pipeline,
> LLMRouter, 26-file capability monolith). That architecture has since been
> replaced by the Hermes-client refactor and the unified memory consolidation.
> See `ARCHITECTURE_REPORT.md` and `ALFRED_MAP.md` for the current state. Kept
> as a record of what the audit found and which personalization gaps were
> subsequently closed (structured user model, behavioral learning, entity
> graph, session coherence).

## Architecture Overview (as audited — superseded)

Alfred is a macOS AI assistant (`@main` struct `AlfredApp` → `AppDelegate`) with a **notch-triggered floating bar window** (`BarWindow`). The architecture follows a **pipeline pattern**:

```
User query → AppDelegate.handleQuery()
  → WorkflowPlanner (multi-step workflows)
  → ComputerControlPlanner (bounded UI automation)
  → AssistantCore (standard query pipeline)
    → parallel context gathering (memories, screen, web, shell, app control, YouTube, calendar, files, folder)
    → LLMRouter → active LLMProvider
    → post-processing (memory extraction, text insertion)
```

## Existing Systems (built)

### 1. User Memory (GRDB + FTS5)
- **`MemoryStore`** (`Memory/MemoryStore.swift`): SQLite via GRDB with two tables: `memories` (id, content, tags, created_at, accessed_at) and `conversation_history` (id, role, content, timestamp)
- **FTS5** full-text search on memories content
- **Two write paths**: explicit `save(content:tags:)` and auto-extraction via Haiku LLM call (`extractAndSaveFacts`)
- **Context injection**: up to 5 relevant memories + last 6 conversation turns injected into system prompt via `buildSystem()`
- Tags stored as comma-separated strings; `saveMessage` runs for every user/assistant exchange

### 2. Context Monitoring (App + Browser Awareness)
- **`ContextMonitor`** (`Proactive/`): Polls `NSWorkspace.shared.frontmostApplication` every 1.5s, reads window title via Accessibility API, fetches browser URL/title via AppleScript (Safari, Chrome, Brave, Edge, Arc)
- **`ProactiveSuggestion`** model: title, prompt, icon — purely UI hints
- **`SuggestionEngine`**: Rule-based — maps current app context (coding, writing, browser, YouTube, generic) to 2-3 static suggestions with templated prompts
- Supports 5 browser types, 12 coding apps, 10 writing apps

### 3. Screen Awareness (on-demand + continuous)
- **`ScreenCapability`** (`Capabilities/`): ScreenCaptureKit-based screenshot capture, returns JPEG at 75% quality as base64
- **`ScreenMonitoringManager`**: Continuous loop at 45s intervals, 2-minute in-memory retention, auto-clears on sensitive field detection (secure/password/payment via AX API)
- On-demand mode: triggers on keywords ("screen", "this", "here", "page", "window", "see", "show", "look at")

### 4. Capability System (20+ capabilities)
- **26 files** in `Capabilities/` covering: app control, calendar/reminders, computer control (CGEvent mouse/keyboard), document export (PDF/DOCX/PPTX), file access (security-scoped bookmarks), MCP client, notifications, shell execution, text insertion, voice input, web search, YouTube transcripts, workflow planning, focus sessions
- **`WorkflowPlanner`**: Heuristic multi-step workflow detection (connectors like "and", "then"), max 8 steps, confirmation dialog for side effects
- **`ComputerControlCapability`**: CGEvent-based mouse/keyboard automation, max 20 actions, blocks sensitive input (passwords/secrets/destructive ops)

### 5. LLM Abstraction
- **`LLMProvider` protocol** + **`LLMRouter`**: 8 providers (Anthropic, OpenAI, Ollama, OpenRouter, Groq, Gemini, Cerebras, Mistral), switchable at runtime from Settings
- **`AssistantPersona`**: Static system prompt — "polished butler" persona, configurable `ownerName`
- **`LLMMessage`**: Supports role, content, optional image base64 attachment (multimodal)
- Streaming is first-class

### 6. Focus Sessions
- **`FocusSessionManager`**: Time-based (60s evaluation, 10min nudge cooldown), sensitivity levels (low/medium/high), keyword/token overlap detection, obvious distractor list, sends macOS notifications as nudges

## Data Collected (what Alfred persists)

| Data | Where | Duration | User Control |
|------|-------|----------|-------------|
| Conversation history (role, content, timestamp) | `conversation_history` table | Forever (no TTL) | `clearHistory()` method, no UI toggle |
| Extracted memory facts | `memories` table | Forever (no TTL, `accessed_at` updated on read) | Disable via `memoryExtractionEnabled` toggle in Settings |
| Selected provider, model, owner name | UserDefaults | Forever | Settings UI |
| API keys | Keychain | Until deleted | Settings UI |
| Toggle preferences | UserDefaults | Forever | Settings UI |
| Security-scoped bookmarks | `SecurityScopedBookmarkStore` | Until forgotten via menu | Menu items: Forget Remembered File/Folder Access |
| Screenshots (monitoring) | In-memory only | 2 minutes max | Toggle in Settings, auto-clears on sensitive fields |
| Capability event log | `CapabilityEventLogger` | Not inspected | Not exposed |

## User Understanding (what Alfred infers about the user)

- **Explicit only**: `ownerName` from settings
- **Inferred trivia**: via auto-extracted `MemoryRecord` content — preferences, names, recurring tasks, decisions (paraphrased, lossy)
- **No structured user model**: no persona, no preference profile, no skill level, no communication style vector
- **No learning from behavior**: focus session counts are in-memory only, not persisted or used to adapt suggestions
- **No episodic memory**: conversation history is flat, no summarization, no event/decision extraction beyond trivia
- **Suggestion engine is entirely static**: rule-based `SuggestionEngine` with hardcoded prompts — no personalization

## Gaps for Personalization

### Critical
1. **No user profile/persona** — no structured representation of who the user is, their role, preferences, communication style, skill level, or common tasks
2. **No behavioral learning** — suggestions never adapt based on past acceptance/rejection, preferred response style, or workflow patterns
3. **Memory is flat trivia, not structured knowledge** — facts are stored as free text with comma-separated tags; no entity resolution, no relationship graph, no confidence scoring
4. **No session-level coherence** — responses don't reference earlier context within a session beyond raw conversation history; no summarization of what was discussed

### Moderate
5. **Suggestion engine is rule-based, not learned** — `SuggestionEngine` uses hardcoded `if/else` chains per app category; impossible to adapt per user
6. **No context quality signals** — no distinction between stale memories (last accessed vs. when fact was true), no decay, no importance scoring
7. **System prompt is static** — `AssistantPersona.systemIntro` is the same for every query; only `ownerName` and injected context change
8. **No data about what users want** — no tracking of suggestion acceptance, topic frequency, or feature usage

### Minor
9. **No proactive outreach beyond focus nudges** — no "you haven't asked about X in a while, here's a reminder"
10. **No personal vocabulary/style adaptation** — response always uses assistant's butler persona, never known user phrasing

## Smallest Architectural Changes for Personalization

### Phase 1 (1-2 files)
1. **Add user profile JSON** at `~/.alfred/profile.json` — schema with fields like `role`, `technical_level`, `communication_preference`, `common_topics`, `avoid_topics`, `response_style` — read on startup, injected into system prompt
2. **Track suggestion engagement** — add a lightweight SQLite table `suggestion_log` (timestamp, app_context, suggestion_id, accepted: bool) — fed back into context for prompt enrichment

### Phase 2 (3-5 files)
3. **Memory scoring & decay** — add `importance` (0-1) and `expires_at` columns to `memories` table; auto-decay low-importance or aged-out facts
4. **Structured entity extraction** — replace the Haiku extraction prompt with a structured JSON extraction (entities, relationships, topics) stored in a new `entities` table
5. **Personalized system prompt injection** — inject profile fields into `buildSystem()`: "The user is a [role] with [technical_level] technical expertise. They prefer [concise/detailed] responses."

### Phase 3 (more involved)
6. **Session summarization** — on close/dismissal, summarize the session via lightweight model call and store as a `session_summary` record
7. **Contextual suggestion ranking** — replace hardcoded `SuggestionEngine` with a ranker that considers profile, session context, and recent suggestion engagement
8. **Adaptive persona** — log user response to assistant tone and gradually adjust system prompt tone based on observed preferences
