# Alfred Architecture Report

## Repository Overview

```
ALFRED/
├── AlfredMac/                  # macOS SwiftUI app (primary codebase)
│   ├── Alfred/                 # Source code
│   │   ├── App/                # App entry & state
│   │   ├── LLM/                # LLM routing & providers
│   │   ├── Capabilities/       # All capability implementations
│   │   ├── Learning/           # Memory, learning, workflows, reflection
│   │   ├── Proactive/          # Context monitoring & proactive suggestions
│   │   ├── Presence/           # UI presence (bar/notch)
│   │   ├── Bar/                # Bar window & hotkey
│   │   ├── Memory/             # Memory store (SQLite)
│   │   └── Transparency/       # Privacy & personalization dashboard
│   ├── Tests/
│   └── scripts/
├── Fine Tune/                  # Local fine-tuned model (Llama 3.2 1B)
└── website/                    # Marketing site
```

**Language:** Swift (macOS native, SwiftUI + AppKit)
**Database:** SQLite via GRDB.swift
**Architecture Pattern:** Actor-based pipeline with service-oriented design

---

## 1. EXISTING CAPABILITIES

### 1.1 Memory

| Component | File | Description |
|---|---|---|
| **SQLite Store** | `AlfredMac/Alfred/Memory/MemoryStore.swift` | GRDB-backed SQLite database at `~/.alfred/db/memory.db` with `memories`, `conversation_history`, `suggestion_interactions` tables + FTS5 full-text search |
| **Memory Extraction** | `AlfredMac/Alfred/AssistantCore.swift:787-809` | Post-processing call to LLM to extract 0-3 facts from each conversation turn |
| **Memory Search** | `AlfredMac/Alfred/Memory/MemoryStore.swift:108-145` | FTS5 full-text search with `MATCH` query, falls back to `LIKE`, updates `accessed_at` on read |
| **Conversation History** | `AlfredMac/Alfred/Memory/MemoryStore.swift:149-183` | Saves user/assistant messages, prunes beyond retention days |
| **Relationship Memory** | `AlfredMac/Alfred/Learning/RelationshipMemoryService.swift` | In-memory + JSON file store of categorized memories (goals, projects, preferences, etc.) with importance scoring, decay, promotion, linking |
| **Memory Reflections** | `AlfredMac/Alfred/Learning/MemoryReflectionService.swift` | Cross-memory pattern detection: patterns, contradictions, milestones, time associations, tool preferences |
| **Memory Linking** | `AlfredMac/Alfred/Learning/MemoryLinkService.swift` | Graph-based linking between memories using Jaccard keyword overlap, temporal proximity, category relationships, contradiction, cause-effect |
| **Backup** | `AlfredMac/Alfred/Learning/MemoryBackupService.swift` | Auto-backup of relationship memories and reflections to `~/.alfred/backups/` |
| **Proactive Surfacing** | `AlfredMac/Alfred/Learning/ProactiveMemorySurfacingService.swift` | 10 rules for surfacing memories (project continuation, time patterns, tool preferences, goals, etc.) |

### 1.2 Screen Monitoring

| Component | File | Description |
|---|---|---|
| **Screen Capability** | `AlfredMac/Alfred/Capabilities/ScreenCapability.swift` | Uses ScreenCaptureKit `SCScreenshotManager.captureImage()` to capture screen as JPEG |
| **Screen Monitoring Manager** | `AlfredMac/Alfred/Capabilities/ScreenMonitoringManager.swift` | Periodic capture every 45s, in-memory only (no persistence), auto-clears after 120s, checks for sensitive fields |
| **Sensitive Field Detection** | `AlfredMac/Alfred/Capabilities/ScreenMonitoringManager.swift:97-123` | Uses Accessibility API to detect secure/password/credit-card focused UI elements |

### 1.3 App Control

| Component | File | Description |
|---|---|---|
| **App Control** | `AlfredMac/Alfred/Capabilities/AppControlCapability.swift` | Open, activate, hide, quit applications via `NSWorkspace` |
| **Tool Call** | `AlfredMac/Alfred/Capabilities/AppControlCapability.swift:234-257` | `executeToolCall` static method for LLM function-calling |
| **Intent Detection** | `AlfredMac/Alfred/Capabilities/QueryIntent.swift` | Regex-based detection of app control, shell, web search, calendar, screen intents |

### 1.4 Computer Control

| Component | File | Description |
|---|---|---|
| **Computer Control** | `AlfredMac/Alfred/Capabilities/ComputerControlCapability.swift` | Mouse movement/click, keyboard (key press, hotkeys, text typing), waits — via `CGEvent` and `CGWarpMouseCursorPosition` |
| **Plan Parsing** | `AlfredMac/Alfred/Capabilities/ComputerControlCapability.swift:90-137` | Parses natural language into `Plan` of `Action` enum values |
| **Safety Checks** | `AlfredMac/Alfred/Capabilities/ComputerControlCapability.swift:326-336` | Blocks passwords, destructive actions (delete, erase, format, purchase, send money) |

### 1.5 Workflows

| Component | File | Description |
|---|---|---|
| **Workflow Plan** | `AlfredMac/Alfred/Capabilities/WorkflowPlan.swift` | Multi-step plan: read files, web search, generate content, write files, app control, shell, computer control |
| **Workflow Executor** | `AlfredMac/Alfred/Learning/WorkflowExecutor.swift` | Executes learned workflows with steps: query, notify, wait, confirm, execute |
| **Workflow Detection** | `AlfredMac/Alfred/Learning/WorkflowDetectionService.swift` | Detects workflow patterns from query history and relationship memories |
| **Workflow Suggestion** | `AlfredMac/Alfred/Learning/WorkflowSuggestionService.swift` | Generates workflow-based suggestions |
| **Workflow Models** | `AlfredMac/Alfred/Learning/WorkflowModels.swift` | Data models for workflows and steps |

### 1.6 Tool Use (LLM Function Calling)

| Component | File | Description |
|---|---|---|
| **Tool Definitions** | `AlfredMac/Alfred/LLM/LLMProvider.swift:40-64` | `LLMTool.openApplication` — opens macOS apps via function calling |
| **Stream with Tools** | `AlfredMac/Alfred/LLM/LLMRouter.swift:77-94` | Routes tool calls to `OpenAICompatibleProvider.streamWithTools()` |
| **Tool Dispatch** | `AlfredMac/Alfred/AssistantCore.swift:396-402` | Dispatches via `AppControlCapability.executeToolCall` |

### 1.7 File Management

| Component | File | Description |
|---|---|---|
| **File Write** | `AlfredMac/Alfred/Capabilities/FileWriteCapability.swift` | Detects write intent, shows NSSavePanel, writes text/PDF/DOCX/PPTX |
| **File Read** | `AlfredMac/Alfred/Capabilities/SelectedFileReader.swift` | Reads selected files: plain text, PDF (PDFKit), DOCX (XML parsing), PPTX (XML parsing) |
| **Folder Read** | `AlfredMac/Alfred/Capabilities/SelectedFolderReader.swift` | Lists folder contents |
| **File Access** | `AlfredMac/Alfred/Capabilities/FileAccessCapability.swift` | macOS file open panel |
| **Security Bookmarks** | `AlfredMac/Alfred/Capabilities/SecurityScopedBookmarkStore.swift` | Persistent security-scoped bookmarks via Keychain |
| **Selection Context** | `AlfredMac/Alfred/Capabilities/SelectedFileContext.swift` | Tracks selected files/folders in memory |

### 1.8 Calendar Integration

| Component | File | Description |
|---|---|---|
| **Calendar/Reminders** | `AlfredMac/Alfred/Capabilities/CalendarRemindersCapability.swift` | Reads/writes events (full access) and reminders via `EKEventStore` |
| **Calendar Creation** | `AlfredMac/Alfred/AssistantCore.swift:469-533` | Extracts event details from screenshot via LLM vision, creates calendar event |
| **Calendar Context** | `AlfredMac/Alfred/AssistantCore.swift:459-467` | Fetches upcoming events/reminders when user asks |

### 1.9 Notifications

| Component | File | Description |
|---|---|---|
| **Notification Manager** | `AlfredMac/Alfred/Capabilities/NotificationManager.swift` | macOS user notifications with actions |
| **Workflow Notifications** | `AlfredMac/Alfred/Learning/WorkflowExecutor.swift:77-83` | `NSUserNotification` for workflow status |

### 1.10 LLM Routing

| Component | File | Description |
|---|---|---|
| **Router** | `AlfredMac/Alfred/LLM/LLMRouter.swift` | Routes to active provider; supports `complete`, `stream`, `streamWithTools` |
| **Provider Protocol** | `AlfredMac/Alfred/LLM/LLMProvider.swift:94-109` | Protocol: `complete`, `stream`; vision support determined by model name |
| **Provider Selection** | `AlfredMac/Alfred/App/AppState.swift` | `selectedProvider` + `selectedModel` persisted to UserDefaults |
| **Capability Diagnostics** | `AlfredMac/Alfred/Capabilities/CapabilityDiagnostics.swift` | Reports all capability statuses |

### 1.11 Local Models

| Component | File | Description |
|---|---|---|
| **Local Server Manager** | `AlfredMac/Alfred/LLM/LocalModelServerManager.swift` | Manages Python server process (`local_alfred_server.py`) on port 8080, health-check polling |
| **Local Provider** | `AlfredMac/Alfred/LLM/OpenAICompatibleProvider.swift` | Wraps local HTTP server as OpenAI-compatible |

### 1.12 Provider Integrations

| Provider | Class | File |
|---|---|---|
| **Gemini** | `OpenAICompatibleProvider` (id: "gemini") | `AlfredMac/Alfred/LLM/OpenAICompatibleProvider.swift` |
| **Groq** | `OpenAICompatibleProvider` (id: "groq") | `AlfredMac/Alfred/LLM/OpenAICompatibleProvider.swift` |
| **Local** | `OpenAICompatibleProvider` (id: "local") | `AlfredMac/Alfred/LLM/OpenAICompatibleProvider.swift` |
| **OpenRouter** | `OpenRouterProvider` | `AlfredMac/Alfred/LLM/OpenRouterProvider.swift` |
| **Ollama** | `OllamaProvider` | `AlfredMac/Alfred/LLM/OllamaProvider.swift` |

### 1.13 Additional Capabilities

| Capability | File | Description |
|---|---|---|
| **Web Search** | `AlfredMac/Alfred/Capabilities/WebSearchCapability.swift` | Brave Search (primary) + DuckDuckGo (fallback); page fetch with HTML stripping |
| **Shell** | `AlfredMac/Alfred/Capabilities/ShellCapability.swift` | Bash execution with 30s timeout via `Process` |
| **Voice Input** | `AlfredMac/Alfred/Capabilities/VoiceInputCapability.swift` | Speech-to-text via `SFSpeechRecognizer` |
| **Text Insertion** | `AlfredMac/Alfred/Capabilities/TextInserter.swift` | macOS Accessibility API to type/paste text |
| **YouTube Transcript** | `AlfredMac/Alfred/Capabilities/YouTubeTranscriptCapability.swift` | Fetches YouTube video transcripts |
| **PDF/DOCX/PPTX Export** | `AlfredMac/Alfred/Capabilities/PDFExportCapability.swift` + `DOCXExportCapability.swift` + `PPTXExportCapability.swift` | Document generation |
| **Focus Session** | `AlfredMac/Alfred/Capabilities/FocusSessionManager.swift` | Focus mode with screen monitoring + nudges |
| **Project Awareness** | `AlfredMac/Alfred/Learning/ProjectAwarenessService.swift` | Detects active project from window title + Finder context |
| **Behavioral Learning** | `AlfredMac/Alfred/Learning/BehavioralLearningService.swift` | Tracks suggestion acceptance rates, detects interests, builds user profile |
| **Personal Context** | `AlfredMac/Alfred/Learning/PersonalContextService.swift` | Assembles identity summary, focuses, projects from multiple sources |
| **Suggestions Engine** | `AlfredMac/Alfred/Proactive/SuggestionEngine.swift` | Context-based suggestion generation (YouTube, coding, writing, browser, generic) |
| **Adaptive Suggestions** | `AlfredMac/Alfred/Learning/AdaptiveSuggestionEngine.swift` | Scores suggestions by acceptance rate, project relevance, app relevance, recency, engagement |
| **Privacy Controls** | `AlfredMac/Alfred/Transparency/PrivacyManager.swift` | Three modes: minimal (no learning), standard (project awareness), personalized (all) |
| **Onboarding** | `AlfredMac/Alfred/Onboarding/OnboardingView.swift` | Step-by-step setup wizard |
| **Auto-Updater** | `AlfredMac/Alfred/App/UpdaterManager.swift` | Sparkle-based software updates |
| **MCP Client** | `AlfredMac/Alfred/Capabilities/MCPClientCapability.swift` | Model Context Protocol client for external tool servers |

---

## 2. DATA FLOWS

### 2.1 Observation → Memory Pipeline

```
User Query
    │
    ▼
AssistantCore.process()  [AlfredMac/Alfred/AssistantCore.swift:203-417]
    │
    ├──► QueryIntent.analyze()  → determines intent (web/search/screen/calendar/shell/app)
    ├──► Parallel context gathering:
    │      ├── relevantMemories()    → MemoryStore.search() [FTS5 full-text search]
    │      ├── conversationHistory() → MemoryStore.loadHistory()
    │      ├── maybeScreenshot()     → ScreenCapability.captureScreenAsBase64()
    │      ├── maybeWebSearch()      → WebSearchCapability.search()
    │      ├── maybeShell()          → ShellCapability.run()
    │      ├── maybeAppControl()     → AppControlCapability.handle()
    │      ├── maybeYouTubeContext() → YouTubeTranscriptCapability.transcript()
    │      ├── maybeCalendarContext()→ CalendarRemindersCapability.readUpcomingEvents()
    │      ├── selectedFileResult    → SelectedFileReader.readIfRequested()
    │      └── selectedFolderResult  → SelectedFolderReader.readIfRequested()
    │
    ├──► buildSystem()  → constructs system prompt from:
    │      ├── AssistantPersona.systemIntro()
    │      ├── PersonalContextService.personalContext()
    │      ├── RelationshipMemoryService.promptInjection()
    │      ├── MemoryReflectionService.promptInjection()
    │      ├── MemoryRecord[] (relevant memories)
    │      ├── Conversation history
    │      └── ProjectAwarenessService.projectContext()
    │
    ├──► router.streamWithTools()  → LLM response + tool calls
    │
    └──► postProcess()
           ├── memory.saveMessage() (conversation history)
           ├── memory.pruneConversationHistory()
           └── memory extraction via LLM [AssistantCore.swift:787-809]
    ```

### 2.2 Memory Storage

```
MemoryStore ([File: MemoryStore.swift])
    │
    ├── SQLite at ~/.alfred/db/memory.db
    ├── Tables:
    │   ├── memories (id, content, tags, created_at, accessed_at)
    │   ├── memories_fts (FTS5 virtual table for full-text search)
    │   ├── conversation_history (id, role, content, timestamp)
    │   └── suggestion_interactions (id, suggestionId, category, accepted, dismissed, ...)
    │
    ├── save(content:tags:) → INSERT INTO memories
    ├── saveMessage(role:content:) → INSERT INTO conversation_history
    ├── search(query:limit:) → FTS5 MATCH or LIKE, returns [MemoryRecord]
    ├── loadHistory(limit:) → SELECT FROM conversation_history
    └── saveSuggestionInteraction() → INSERT INTO suggestion_interactions
```

**Relationship Memory** (`RelationshipMemoryService.swift`) stores in a separate JSON file via `RelationshipMemoryStore` (persisted to `~/.alfred/relationship_memory.json`).

### 2.3 Retrieval Flow

```
query
 │
 ▼
MemoryStore.search(query, limit: 5)
 │  ├── Build FTS5Pattern from query tokens
 │  ├── SELECT FROM memories JOIN memories_fts WHERE MATCH
 │  └── Update accessed_at for results
 │
 ▼
AssistantCore.buildSystem()
 ├── Appends relevant memories to system prompt
 ├── Injects relationship memory via promptInjection()
 ├── Injects reflections via promptInjection()
 └── Injects personal context via PersonalContextService.personalContext()
```

### 2.4 Workflow Execution

```
User Query
    │
    ▼
WorkflowPlanner.makePlan()  [WorkflowPlan.swift:69-119]
    │  ├── Detects multi-step intent ("then", "and", "after that")
    │  ├── Builds ordered [Step] list
    │  └── Returns WorkflowPlan or nil (single-step → normal processing)
    │
    ▼
AssistantCore.processWorkflow()  [AssistantCore.swift:56-199]
    │
    ├── For each Step:
    │   ├── .readSelectedFiles  → SelectedFileReader
    │   ├── .readSelectedFolder → SelectedFolderReader
    │   ├── .generateContent    → LLM call
    │   ├── .webSearch          → WebSearchCapability
    │   ├── .writeFile          → FileWriteCapability + NSSavePanel
    │   ├── .appControl         → AppControlCapability
    │   ├── .shell              → ShellCapability
    │   └── .computerControl    → ComputerControlCapability
    │
    └── postProcess() after completion
```

### 2.5 LLM Tool Call Dispatch

```
router.streamWithTools()  [LLMRouter.swift:77-94]
    │  Only available on OpenAICompatibleProvider
    │
    ├── provider.streamWithTools() sends `tools` param in API request
    ├── LLM responds with tool_calls array
    ├── executeToolCall closure invoked:
    │   └── AppControlCapability.executeToolCall(toolName: "open_application", argumentsJSON)
    ├── Tool result sent as additional user message
    └── LLM generates final response incorporating tool result

For non-OpenAI-compatible providers (Ollama, OpenRouter):
    ├── Falls back to plain stream()
    └── No tool calling supported
```

---

## 3. FILE RESPONSIBILITY MAP

### Memory Extraction
- **Primary:** `AlfredMac/Alfred/AssistantCore.swift:787-809` — `extractAndSaveFacts(query:response:)`
- **Backend:** `AlfredMac/Alfred/LLM/LLMProvider.swift` — LLM call to extract facts from dialog

### Memory Storage
- **SQLite:** `AlfredMac/Alfred/Memory/MemoryStore.swift` — All structured memory persistence
- **Relationship Memory:** `AlfredMac/Alfred/Learning/RelationshipMemoryService.swift` — In-memory + JSON persistence
- **Reflections:** `AlfredMac/Alfred/Learning/MemoryReflectionService.swift` — JSON persistence via `ReflectionStore`
- **Memory Links:** `AlfredMac/Alfred/Learning/MemoryLinkService.swift` — JSON persistence via `MemoryGraphStore`
- **Workflows:** `AlfredMac/Alfred/Learning/WorkflowDetectionService.swift` — JSON persistence via `WorkflowStore`
- **User Profile:** `AlfredMac/Alfred/Learning/UserProfile.swift` — JSON persistence via `UserProfileStore`

### Screen Observation
- **Capture:** `AlfredMac/Alfred/Capabilities/ScreenCapability.swift` — ScreenCaptureKit JPEG capture
- **Monitoring Loop:** `AlfredMac/Alfred/Capabilities/ScreenMonitoringManager.swift` — Periodic capture manager
- **Sensitive Field Detection:** `AlfredMac/Alfred/Capabilities/ScreenMonitoringManager.swift:97-123`

### Computer Control
- **Core Implementation:** `AlfredMac/Alfred/Capabilities/ComputerControlCapability.swift` — Mouse, keyboard, hotkey via `CGEvent`
- **Plan Parsing:** `AlfredMac/Alfred/Capabilities/ComputerControlCapability.swift:90-137`
- **Safety/Sensitive Checks:** `AlfredMac/Alfred/Capabilities/ComputerControlCapability.swift:326-336`

### Workflow Execution
- **Planner:** `AlfredMac/Alfred/Capabilities/WorkflowPlan.swift:62-244` — `WorkflowPlanner`
- **Main Processor:** `AlfredMac/Alfred/AssistantCore.swift:56-199` — `processWorkflow()`
- **Learned Workflow Executor:** `AlfredMac/Alfred/Learning/WorkflowExecutor.swift`
- **Detection:** `AlfredMac/Alfred/Learning/WorkflowDetectionService.swift`

### Prompt Construction
- **System Prompt Builder:** `AlfredMac/Alfred/AssistantCore.swift:684-754` — `buildSystem()`
- **Persona Definition:** `AlfredMac/Alfred/AssistantPersona.swift`
- **Personal Context Injection:** `AlfredMac/Alfred/Learning/PersonalContextService.swift`
- **Relationship Injection:** `AlfredMac/Alfred/Learning/RelationshipMemoryService.swift:180-223` — `promptInjection()`
- **Reflection Injection:** `AlfredMac/Alfred/Learning/MemoryReflectionService.swift:199-242` — `promptInjection()`

### LLM Routing
- **Router:** `AlfredMac/Alfred/LLM/LLMRouter.swift`
- **Provider Protocol:** `AlfredMac/Alfred/LLM/LLMProvider.swift`
- **OpenAI-Compatible:** `AlfredMac/Alfred/LLM/OpenAICompatibleProvider.swift`
- **OpenRouter:** `AlfredMac/Alfred/LLM/OpenRouterProvider.swift`
- **Ollama:** `AlfredMac/Alfred/LLM/OllamaProvider.swift`

---

## 4. GAP ANALYSIS

### Vision: Alfred as a Personal OS Agent

| Vision Goal | Current State | Gap | Priority |
|---|---|---|---|
| **Learns continuously from behavior** | BehavioralLearningService records suggestion acceptances every 5 min; Memory extraction runs per-query | ❌ **No passive observation.** Only learns from explicit queries and suggestion feedback. No background behavior tracking (app usage patterns, file access patterns, browsing habits). | High |
| **Observes screen activity** | ScreenCapability exists + ScreenMonitoringManager (45s interval, in-memory only, 120s TTL) | ❌ **No persistent screen history.** Screenshots are never stored, analyzed, or used for long-term learning. No OCR, no UI element tracking, no activity recording. | High |
| **Learns writing style** | No writing-style analysis exists | ❌ **Completely absent.** No model of user's writing voice, vocabulary preference, sentence structure, or communication patterns. | High |
| **Learns habits and routines** | WorkflowDetectionService detects workflow patterns; MemoryReflectionService detects time associations | ⚠️ **Partial.** Detection is query-based only. No calendar-aware habit tracking, no passive routine detection (e.g., "you always open Slack at 9am"). | Medium |
| **Builds relationship knowledge** | RelationshipMemoryService tracks goals, preferences, projects with importance scoring + decay | ⚠️ **Partial.** No concept of "people" — names of contacts, colleagues, family. No relationship graph (who works with whom, reporting lines). No communication history. | Medium |
| **Personalizes responses** | PersonalContextService injects identity summary, focuses, projects; AdaptiveSuggestionEngine scores suggestions | ⚠️ **Partial.** Personalization is prompt-injection only. No per-user response style adaptation. No learning from user corrections to responses. | Medium |
| **Proactively suggests actions** | ProactiveMemorySurfacingService (10 rules); SuggestionEngine (context-specific). Checks every 60s. | ✅ **Functional foundation.** But rules are hardcoded, not learned from behavior. Suggestions are context-triggered, not predictive. | Low (iterative) |
| **Controls the computer** | ComputerControlCapability (mouse, keyboard, hotkeys); AppControlCapability (open/quit/hide) | ✅ **Functional.** Could be extended with more gesture types (scroll, drag, right-click) and screen coordinate resolution. | Low (iterative) |
| **Manages files** | FileWriteCapability (write/save), SelectedFileReader/SelectedFolderReader (read), SecurityScopedBookmarks | ⚠️ **Partial.** No file organization (move/copy/rename/delete), no file search, no bulk operations. No file monitoring. | Medium |
| **Manages calendar activity** | CalendarRemindersCapability (read/write events + reminders); screenshot-based event creation | ⚠️ **Partial.** No reschedule, no delete, no free-busy search, no recurring event editing. No time-blocking/proactive scheduling. | Medium |
| **Improves over time** | Learning profile timer every 5 min; memory reflection every 6 hours; memory linking every 12 hours | ⚠️ **Partial.** No A/B testing of responses. No self-evaluation of suggestion quality. No meta-learning from user behavior trends. | Medium |

### Definitive Gaps (Not Addressed at All)

| Gap | Why Important |
|---|---|
| **Passive observation layer** | No daemon that watches app usage, file access, browser history, keystrokes (ethical/non-recording) |
| **Writing style model** | Cannot adapt tone, vocabulary, sentence length, or formatting to user preference |
| **People/relationship graph** | No contact awareness, no named-entity recognition for people, no social graph |
| **Habit prediction** | Cannot anticipate user needs before they ask |
| **Self-improvement loop** | No mechanism to evaluate past suggestion quality and adjust strategy |
| **Fine-tuned local model** | Local model (Llama 3.2 1B) exists but is not actively trained on user data; no continuous fine-tuning pipeline |
| **Persistent screen understanding** | No OCR, no UI element detection, no activity timeline from screenshots |
| **File organization operations** | Cannot move, copy, rename, archive, or search files; cannot manage directory structure |
| **Proactive calendar management** | Cannot propose meeting times, identify conflicts, schedule recurring tasks |
| **Cross-app automation** | Cannot chain actions across apps (e.g., "download this PDF, extract the table, and email it"); limited to single-step capabilities |

---

## 5. ROADMAP

### Phase 1: Foundation (Highest ROI)

1. **Persistent Screen Analysis Pipeline**
   - Enable OCR on captured screenshots (Vision framework)
   - Store screen contexts with extracted text in SQLite (`screen_observations` table)
   - Build screen activity timeline queryable by memory search
   - Files: `ScreenCapability.swift`, `ScreenMonitoringManager.swift`, `MemoryStore.swift`

2. **Writing Style Learning**
   - Create `WritingStyleProfile` struct stored in UserProfile
   - Analyze user queries for vocabulary, sentence length, formality
   - Inject style preferences into system prompt
   - New file: `AlfredMac/Alfred/Learning/WritingStyleService.swift`

3. **Passive Behavior Observation**
   - Track which apps are used when (app + time of day)
   - Track file types accessed, websites visited (bundle ID only, not URLs)
   - Feed into BehavioralLearningService for habit detection
   - New file: `AlfredMac/Alfred/Learning/ActivityObserver.swift`

4. **Continuous Local Fine-Tuning Pipeline**
   - Collect conversation pairs (user query → Alfred response) with acceptance signal
   - Periodically fine-tune local Llama 3.2 1B model on accepted responses
   - File: Use existing `Fine Tune/` infrastructure + new training pipeline

### Phase 2: Relationship & Personalization

1. **People Relationship Graph**
   - Add contact extraction from email, messages, calendar participants
   - Create `PersonMemory` model with relationship strength, communication frequency, context
   - New file: `AlfredMac/Alfred/Learning/PersonMemoryService.swift`

2. **Response Style Personalization**
   - Learn from user corrections (via edit/correction feedback)
   - Adjust response temperature, verbosity, formality per user
   - Add feedback mechanism to `postProcess()` in `AssistantCore.swift`

3. **Proactive Calendar Management**
   - Free-busy lookup, conflict detection
   - Propose meeting times based on participant availability
   - Reschedule/cancel events
   - Enhance `CalendarRemindersCapability.swift`

4. **Habit Prediction Engine**
   - Use time-series patterns from ActivityObserver
   - Predict next action based on time + day + current app
   - Surface as proactive suggestions before user asks
   - New file: `AlfredMac/Alfred/Learning/HabitPredictionEngine.swift`

5. **File Organization Operations**
   - Add move, copy, rename, delete, archive file capabilities
   - Create folder structure management
   - Enhance `FileWriteCapability.swift` or create `FileManagementCapability.swift`

### Phase 3: Autonomous Agent

1. **Cross-App Workflow Automation**
   - Chain multiple app actions + file operations + web searches
   - Example: "Summarize the Slack thread → save as MD → email to team"
   - New capability: `WorkflowAutomationCapability`

2. **Self-Evaluation & Meta-Learning**
   - Evaluate suggestion quality based on user engagement (acceptance rate, time-to-accept, follow-up queries)
   - Auto-adjust suggestion rules, thresholds, and cooldowns
   - Monthly report of improvement metrics

3. **Predictive Proactive Suggestions**
   - Move from rule-based to ML-based suggestion ranking
   - Use behavioral features + time features + engagement features
   - Train a lightweight ranking model on local device

4. **Computer Control Expansion**
   - Scroll, drag-and-drop, right-click, keyboard shortcuts
   - Image-based screen coordinate resolution (find buttons by label)
   - Accessibility tree parsing for precise UI targeting

5. **Full OS Agent Interface**
   - Persistent memory across all apps
   - Context-aware automation (e.g., "when I open Xcode in the morning, start the build server")
   - Proactive calendar blocking for deep work
   - Automated file organization by project/type
