import Foundation

// MARK: - Wire models
// These mirror the hub's JSON exactly (vertus/server/vertus_server.py and
// run_store.py). Event envelopes are flat: the stored `payload` dict is
// merged with type/agent_id/run_id/seq/ts at the top level.

public struct Agent: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var title: String
    public var description: String
    public var persona: String
    public var model: String?
    public var provider: String?
    public var color: String?
    public var emoji: String?
    public var autonomy: String
    /// v3: may this agent drive the desktop at all (else its gateway spawns
    /// with the noop CUA backend and captures come back blank).
    public var computerUse: Bool
    /// v3: declared app bundle ids / window titles this agent works in. A
    /// DECLARATION for conflict gating, not a sandbox (see the caveat on
    /// /api/fleet/screens); null = unrestricted.
    public var cuaTargets: [String]?
    public var createdAt: String
    public var updatedAt: String
    public var sandboxPath: String
    public var homePath: String
    public var schemaVersion: Int
    public var isPrimary: Bool

    public var displayName: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? name : t
    }

    /// Emoji + name, e.g. "🦊 researcher" (empty emoji tolerated).
    public var rosterLabel: String {
        let e = (emoji ?? "").trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? displayName : "\(e) \(displayName)"
    }

    public static func == (lhs: Agent, rhs: Agent) -> Bool { lhs.id == rhs.id }

    private enum CodingKeys: String, CodingKey {
        case id, name, title, description, persona, model, provider, color
        case emoji, autonomy, createdAt, updatedAt, sandboxPath, homePath
        case schemaVersion, isPrimary, computerUse, cuaTargets
    }

    public init(id: String, name: String, title: String, description: String,
                persona: String, model: String?, provider: String?,
                color: String?, emoji: String?, autonomy: String,
                createdAt: String, updatedAt: String, sandboxPath: String,
                homePath: String, schemaVersion: Int, isPrimary: Bool,
                computerUse: Bool = false, cuaTargets: [String]? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.description = description
        self.persona = persona
        self.model = model
        self.provider = provider
        self.color = color
        self.emoji = emoji
        self.autonomy = autonomy
        self.computerUse = computerUse
        self.cuaTargets = cuaTargets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sandboxPath = sandboxPath
        self.homePath = homePath
        self.schemaVersion = schemaVersion
        self.isPrimary = isPrimary
    }

    // Tolerant decode: computer_use/cua_targets default to off/null so an
    // older hub (or a stub that omits them) never breaks roster decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        persona = try c.decodeIfPresent(String.self, forKey: .persona) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        autonomy = try c.decodeIfPresent(String.self, forKey: .autonomy) ?? "ask"
        computerUse = try c.decodeIfPresent(Bool.self, forKey: .computerUse) ?? false
        cuaTargets = try c.decodeIfPresent([String].self, forKey: .cuaTargets)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
        sandboxPath = try c.decodeIfPresent(String.self, forKey: .sandboxPath) ?? ""
        homePath = try c.decodeIfPresent(String.self, forKey: .homePath) ?? ""
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    }
}

/// One target a blocked agent is waiting on, and who holds it.
public struct BlockedTarget: Codable, Equatable {
    public var target: String
    public var holderAgent: String
    public var holderRun: String?

    public var summary: String {
        "\(target) (held by \(holderAgent))"
    }
}

/// GET /api/agents/<id>/status payload. `blockedOnTarget` appears only while
/// the agent's turn is gated on a declared screen target held by another run.
/// v4 supervision fields: `stallTimeoutS`/`hardTimeoutS` are the per-agent
/// limits and `silenceS` is how long the engine has emitted nothing — a
/// slow-but-healthy turn is distinguishable from a stuck one. `degraded`
/// carries a readable reason while the agent's gateway is failing/thrashing.
public struct AgentStatus: Codable, Equatable {
    public var state: String          // idle | running | queued
    public var queueDepth: Int
    public var turnStartedAt: Double?
    public var gatewayAlive: Bool
    public var blockedOnTarget: [BlockedTarget]?
    public var stallTimeoutS: Double?
    public var hardTimeoutS: Double?
    public var lastEventAt: Double?
    public var silenceS: Double?
    public var degraded: String?

    public var isBusy: Bool { state != "idle" || queueDepth > 0 }

    /// Short UI line, e.g. "waiting on Safari (held by doc)".
    public var blockedSummary: String? {
        blockedOnTarget?.first.map { "waiting on \($0.summary)" }
    }

    private enum CodingKeys: String, CodingKey {
        case state, queueDepth, turnStartedAt, gatewayAlive, blockedOnTarget
        case stallTimeoutS, hardTimeoutS, lastEventAt, silenceS, degraded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        queueDepth = try c.decodeIfPresent(Int.self, forKey: .queueDepth) ?? 0
        turnStartedAt = try c.decodeIfPresent(Double.self, forKey: .turnStartedAt)
        gatewayAlive = try c.decodeIfPresent(Bool.self, forKey: .gatewayAlive) ?? false
        blockedOnTarget = try c.decodeIfPresent([BlockedTarget].self, forKey: .blockedOnTarget)
        stallTimeoutS = try c.decodeIfPresent(Double.self, forKey: .stallTimeoutS)
        hardTimeoutS = try c.decodeIfPresent(Double.self, forKey: .hardTimeoutS)
        lastEventAt = try c.decodeIfPresent(Double.self, forKey: .lastEventAt)
        silenceS = try c.decodeIfPresent(Double.self, forKey: .silenceS)
        degraded = try c.decodeIfPresent(String.self, forKey: .degraded)
    }

    public init(state: String, queueDepth: Int, turnStartedAt: Double?,
                gatewayAlive: Bool, blockedOnTarget: [BlockedTarget]? = nil,
                stallTimeoutS: Double? = nil, hardTimeoutS: Double? = nil,
                lastEventAt: Double? = nil, silenceS: Double? = nil,
                degraded: String? = nil) {
        self.state = state
        self.queueDepth = queueDepth
        self.turnStartedAt = turnStartedAt
        self.gatewayAlive = gatewayAlive
        self.blockedOnTarget = blockedOnTarget
        self.stallTimeoutS = stallTimeoutS
        self.hardTimeoutS = hardTimeoutS
        self.lastEventAt = lastEventAt
        self.silenceS = silenceS
        self.degraded = degraded
    }
}

// MARK: - Fleet screens roster (GET /api/fleet/screens)

/// Who runs on a declared target and who waits for it.
public struct FleetScreenEntry: Codable, Identifiable, Equatable {
    public var target: String
    public var declaredBy: [String]
    public var running: FleetScreenRunning?
    public var waiting: [String]

    public var id: String { target }
}

public struct FleetScreenRunning: Codable, Equatable {
    public var agentId: String
    public var runId: String
    public var since: Double
}

public struct FleetScreensResponse: Codable, Equatable {
    public var screens: [FleetScreenEntry]
    public var caveat: String?
}

/// POST /api/prompt → 202 payload.
public struct PromptAcceptance: Codable, Equatable {
    public var accepted: Bool
    public var agentId: String
    public var runId: String
    public var sandboxPath: String
}

/// DELETE /api/agents/<id> → 200 payload.
public struct DeleteResult: Codable, Equatable {
    public var deleted: String
    public var archivedTo: String
}

/// One folded message row (messages table).
public struct MessageRow: Codable, Identifiable, Equatable {
    public var id: Int
    public var runId: String
    public var agentId: String
    public var role: String        // user | assistant
    public var text: String
    public var createdAt: Double
}

/// One run row (runs table). v4 attribution fields: `fromAgent` (who asked
/// for this turn — a bot id when message-driven), `threadId`, `runKind`
/// (user|message|handoff|result), `parentRunId` (the delegator's live run
/// for handoffs) — all optional and tolerated when absent.
public struct RunRow: Codable, Identifiable, Equatable {
    public var runId: String
    public var agentId: String
    public var prompt: String
    public var remote: Int
    public var source: String
    public var state: String       // queued|running|done|error|interrupted|abandoned|cancelled|timeout
    public var createdAt: Double
    public var startedAt: Double?
    public var endedAt: Double?
    public var error: String?
    public var gatewayRespawns: Int?
    public var fromAgent: String?
    public var threadId: String?
    public var runKind: String?
    public var parentRunId: String?
    public var routineId: String?

    public var id: String { runId }

    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt - startedAt
    }

    /// True when a BOT asked for this turn (delegation or messaging).
    public var isBotInitiated: Bool {
        guard let fromAgent, !fromAgent.isEmpty else { return false }
        return true
    }

    /// True when a ROUTINE spawned this turn (run_kind=routine).
    public var isRoutine: Bool { runKind == "routine" }
}

/// One fleet-activity item (GET /api/fleet/activity).
public struct FleetActivityItem: Codable, Identifiable, Equatable {
    public var runId: String
    public var agentId: String
    public var prompt: String
    public var state: String
    public var remote: Bool
    public var source: String
    public var createdAt: Double
    public var startedAt: Double?
    public var endedAt: Double?
    public var gatewayRespawns: Int?
    public var fromAgent: String?
    public var runKind: String?
    public var parentRunId: String?
    public var routineId: String?

    public var id: String { runId }

    /// True when a BOT asked for this turn (delegation or messaging).
    public var isBotInitiated: Bool {
        guard let fromAgent, !fromAgent.isEmpty else { return false }
        return true
    }

    /// True when a ROUTINE spawned this turn (run_kind=routine).
    public var isRoutine: Bool { runKind == "routine" }
}

// MARK: - Message bus (bot-to-bot)

/// One bot-message row (bot_messages table).
public struct BotMessage: Codable, Identifiable, Equatable {
    public var msgId: String
    public var fromAgent: String
    public var toAgent: String
    public var threadId: String
    public var body: String
    public var kind: String        // message | handoff | result
    public var depth: Int
    public var status: String      // delivered | dropped_depth | dropped_rate
    public var runId: String?
    public var createdAt: Double
    public var readAt: Double?

    public var id: String { msgId }
}

/// One thread row (threads table). `participants` is already parsed.
public struct BotThread: Codable, Identifiable, Equatable {
    public var threadId: String
    public var subject: String
    public var participants: [String]
    public var createdAt: Double
    public var lastMessageAt: Double
    public var unread: Int

    public var id: String { threadId }
}

/// GET /api/runs/<id> — the run, its messages, and the delegation tree.
public struct RunDetail: Codable, Equatable {
    public var run: RunRow
    public var messages: [MessageRow]
    public var parent: RunRow?
    public var children: [RunRow]
}

// MARK: - Routines (scheduled/triggered per-agent work)

/// Schedule representation: interval seconds only (see fleet_routines.py —
/// one syntax, never two; sub-60s values are for tests/demos).
public struct RoutineSchedule: Codable, Equatable {
    public var intervalS: Int
}

/// Trigger vocabulary is deliberately small and enumerable: run_completed
/// (another agent's run hit a terminal state) or bot_message (a delivered
/// bot message arrived), each with optional filters. Not a rules engine.
public struct RoutineTrigger: Codable, Equatable {
    public var type: String            // run_completed | bot_message
    public var agentId: String?        // run_completed: whose run; bot_message: from_agent filter
    public var fromAgent: String?      // bot_message: sender filter (from_agent)
    public var threadId: String?       // bot_message only

    public init(type: String, agentId: String? = nil, fromAgent: String? = nil,
                threadId: String? = nil) {
        self.type = type
        self.agentId = agentId
        self.fromAgent = fromAgent
        self.threadId = threadId
    }
}

/// One routine row (routines table). `nextRunAt` is when the scheduler will
/// next fire it; `failureCount` >= 3 with enabled=false means it was
/// DISABLED BY FAILURES — the UI must show that loudly, not as a normal
/// toggle-off.
public struct Routine: Codable, Identifiable, Equatable {
    public var routineId: String
    public var agentId: String
    public var name: String
    public var prompt: String
    public var schedule: RoutineSchedule?
    public var trigger: RoutineTrigger?
    public var enabled: Bool
    public var createdAt: Double
    public var lastRunAt: Double?
    public var lastRunId: String?
    public var nextRunAt: Double?
    public var failureCount: Int

    public var id: String { routineId }

    /// Hub's consecutive-failure threshold (FAILURE_THRESHOLD in
    /// fleet_routines.py) — at it, the hub disables the routine itself.
    public static let failureThreshold = 3

    public var disabledByFailures: Bool {
        failureCount >= Self.failureThreshold && !enabled
    }

    public var humanSchedule: String {
        guard let s = schedule?.intervalS else { return "triggered" }
        if s < 60 { return "every \(s)s" }
        if s % 3600 == 0 { return "every \(s / 3600)h" }
        if s % 60 == 0 { return "every \(s / 60)m" }
        return "every \(s)s"
    }

    public var humanTrigger: String {
        guard let t = trigger else { return "" }
        switch t.type {
        case "run_completed":
            return t.agentId.map { "when \($0) finishes" } ?? "when a run finishes"
        case "bot_message":
            return t.fromAgent.map { "message from \($0)" } ?? "on any bot message"
        default:
            return t.type
        }
    }

    private enum CodingKeys: String, CodingKey {
        case routineId, agentId, name, prompt, schedule, trigger, enabled
        case createdAt, lastRunAt, lastRunId, nextRunAt, failureCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routineId = try c.decode(String.self, forKey: .routineId)
        agentId = try c.decode(String.self, forKey: .agentId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        schedule = try c.decodeIfPresent(RoutineSchedule.self, forKey: .schedule)
        trigger = try c.decodeIfPresent(RoutineTrigger.self, forKey: .trigger)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        lastRunAt = try c.decodeIfPresent(Double.self, forKey: .lastRunAt)
        lastRunId = try c.decodeIfPresent(String.self, forKey: .lastRunId)
        nextRunAt = try c.decodeIfPresent(Double.self, forKey: .nextRunAt)
        failureCount = try c.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
    }
}

/// A single SSE envelope, decoded from the flat JSON line.
public struct WireEvent: Equatable {
    public let type: String        // text | activity | done | error | lagged
    public let text: String?       // text chunks + activity payloads
    public let message: String?    // error payloads
    public let agentId: String?
    public let runId: String?
    public let seq: Int?
    public let ts: Double?
    public let lastSeq: Int?       // lagged marker

    public init?(json: [String: Any]) {
        guard let type = json["type"] as? String else { return nil }
        self.type = type
        self.text = json["text"] as? String
        self.message = json["message"] as? String
        self.agentId = json["agent_id"] as? String
        self.runId = json["run_id"] as? String
        self.seq = json["seq"] as? Int ?? (json["seq"] as? NSString)?.integerValue
        self.ts = json["ts"] as? Double ?? (json["ts"] as? NSNumber)?.doubleValue
        self.lastSeq = json["last_seq"] as? Int ?? (json["last_seq"] as? NSString)?.integerValue
    }

    public var isTerminal: Bool { type == "done" || type == "error" }
    public var isTextDelta: Bool { type == "text" && text != nil }
}

/// One transcript line, as rendered by any client. `messageID` is the folded
/// messages-table id when the entry came from history; live deltas carry the
/// runId they belong to and `isDelta` so the store can merge without
/// duplicating the boundary between history and the live tail.
public struct TranscriptEntry: Identifiable, Equatable {
    public let id: String
    public let runId: String
    public let role: String        // user | assistant
    public var text: String
    public let messageID: Int?
    public var isDelta: Bool

    public init(runId: String, role: String, text: String,
                messageID: Int? = nil, isDelta: Bool = false) {
        self.id = messageID.map { "m\($0)" } ?? "d\(runId)-\(UUID().uuidString.prefix(8))"
        self.runId = runId
        self.role = role
        self.text = text
        self.messageID = messageID
        self.isDelta = isDelta
    }
}

// MARK: - JSON decoding helpers

extension JSONDecoder {
    /// Decoder configured for the hub's snake_case wire keys.
    public static func vertus() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

// MARK: - Shared UI state

/// Terminal run states (mirrors RUN_STATES in the hub). `cancelled` and
/// `timeout` are first-class terminal states — distinct from error — and
/// are surfaced distinctly in run lists and run chips.
public enum RunState: String {
    case queued, running, done, error, interrupted, abandoned, cancelled, timeout
}