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

    public init(id: String, name: String, title: String, description: String,
                persona: String, model: String?, provider: String?,
                color: String?, emoji: String?, autonomy: String,
                createdAt: String, updatedAt: String, sandboxPath: String,
                homePath: String, schemaVersion: Int, isPrimary: Bool) {
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sandboxPath = sandboxPath
        self.homePath = homePath
        self.schemaVersion = schemaVersion
        self.isPrimary = isPrimary
    }
}

/// GET /api/agents/<id>/status payload.
public struct AgentStatus: Codable, Equatable {
    public var state: String          // idle | running | queued
    public var queueDepth: Int
    public var turnStartedAt: Double?
    public var gatewayAlive: Bool

    public var isBusy: Bool { state != "idle" || queueDepth > 0 }
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

/// One run row (runs table).
public struct RunRow: Codable, Identifiable, Equatable {
    public var runId: String
    public var agentId: String
    public var prompt: String
    public var remote: Int
    public var source: String
    public var state: String       // queued|running|done|error|interrupted|abandoned
    public var createdAt: Double
    public var startedAt: Double?
    public var endedAt: Double?
    public var error: String?
    public var gatewayRespawns: Int?

    public var id: String { runId }

    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt - startedAt
    }
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

    public var id: String { runId }
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

/// Terminal run states (mirrors RUN_STATES in the hub).
public enum RunState: String {
    case queued, running, done, error, interrupted, abandoned
}