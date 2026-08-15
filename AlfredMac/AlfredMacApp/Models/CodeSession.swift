//
//  CodeSession.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Models/CodeSession.swift).
//

import Foundation

/// What kind of project a folder is — drives the test command offered.
enum CodeProjectType: String, Codable, Hashable {
    case node, python, swift, rust, go, ruby, java, other

    var displayName: String {
        switch self {
        case .node: return "Node.js"
        case .python: return "Python"
        case .swift: return "Swift"
        case .rust: return "Rust"
        case .go: return "Go"
        case .ruby: return "Ruby"
        case .java: return "Java"
        case .other: return "Other"
        }
    }

    /// The test command the Mac will run, when one exists.
    var testCommand: String? {
        switch self {
        case .node: return "npm test"
        case .python: return "python3 -m pytest -q"
        case .swift: return "swift test"
        case .rust: return "cargo test"
        case .go: return "go test ./..."
        case .ruby: return "bundle exec rspec"
        case .java: return "mvn test"
        case .other: return nil
        }
    }
}

/// Where a session is in its life cycle.
enum CodeSessionStatus: String, Codable, Hashable {
    case idle
    case generating
    case paused
    case completed
    case error

    var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .generating: return "Generating"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .error: return "Error"
        }
    }

    /// The tint used by status badges.
    var isError: Bool { self == .error }
    var isActive: Bool { self == .generating || self == .paused }
}

/// The git state of a session's project.
struct CodeGitStatusPayload: Codable, Hashable {
    var currentBranch: String
    var uncommittedChanges: Int
    var unstagedFiles: [String]

    private enum CodingKeys: String, CodingKey {
        case currentBranch = "current_branch"
        case uncommittedChanges = "uncommitted_changes"
        case unstagedFiles = "unstaged_files"
    }

    static func fromJSON(_ params: [String: Any]) -> CodeGitStatusPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let status = try? JSONDecoder().decode(CodeGitStatusPayload.self, from: data)
        else { return nil }
        return status
    }
}

/// The outcome of one test run.
struct CodeTestResultPayload: Codable, Hashable {
    var success: Bool
    var output: String
    var duration: TimeInterval
    var command: String

    static func fromJSON(_ params: [String: Any]) -> CodeTestResultPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let result = try? JSONDecoder().decode(CodeTestResultPayload.self, from: data)
        else { return nil }
        return result
    }
}

/// A remote coding session as the Mac reports it in `code.sessions` /
/// `code.start_session` results.
struct CodeSessionSummary: Codable, Hashable, Identifiable {
    var sessionId: UUID
    var prompt: String
    var projectPath: String
    var projectType: CodeProjectType
    var status: CodeSessionStatus
    var generatedCode: String
    var gitStatus: CodeGitStatusPayload?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastTestResult: CodeTestResultPayload?

    var id: UUID { sessionId }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case prompt
        case projectPath = "project_path"
        case projectType = "project_type"
        case status
        case generatedCode = "generated_code"
        case gitStatus = "git_status"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastTestResult = "last_test_result"
    }

    /// Decode from the wire dictionaries (JSON-RPC result payloads).
    static func fromJSON(_ params: [String: Any]) -> CodeSessionSummary? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let session = try? JSONDecoder().decode(CodeSessionSummary.self, from: data)
        else { return nil }
        return session
    }
}

/// A candidate project folder for the new-session picker.
struct CodeProjectPayload: Codable, Hashable, Identifiable {
    var path: String
    var type: CodeProjectType
    var name: String

    var id: String { path }
}

/// The CodeGraph state for a project, as the Mac reports it in
/// `code.graph_index` results: a stable state string plus counts.
struct CodeGraphStatePayload: Codable, Hashable {
    var state: CodeGraphState
    var fileCount: Int?
    var symbolCount: Int?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case state
        case fileCount = "file_count"
        case symbolCount = "symbol_count"
        case message
    }

    static func fromJSON(_ params: [String: Any]) -> CodeGraphStatePayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(CodeGraphStatePayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// The stable graph states, mirroring the Mac's `code.graph_status` wire.
enum CodeGraphState: String, Codable, Hashable {
    case notInstalled = "not_installed"
    case notIndexed = "not_indexed"
    case indexing
    case ready
    case failed

    var isReady: Bool { self == .ready }
    var isIndexing: Bool { self == .indexing }
}

/// The graph's status for a project, as the Mac reports it in
/// `code.graph_status` results.
struct CodeGraphStatusPayload: Codable, Hashable {
    var indexed: Bool
    var fileCount: Int
    var symbolCount: Int
    var available: Bool
    var text: String

    private enum CodingKeys: String, CodingKey {
        case indexed
        case fileCount = "file_count"
        case symbolCount = "symbol_count"
        case available
        case text
    }

    static func fromJSON(_ params: [String: Any]) -> CodeGraphStatusPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(CodeGraphStatusPayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// The coding agents a session can run. Names must match what the Mac's
/// socket server accepts (`opencode` / `freebuff` / `prime-agent`).
enum CodeAgentChoice: String, CaseIterable, Identifiable {
    case opencode
    case freebuff

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opencode: return "opencode"
        case .freebuff: return "freebuff"
        }
    }

    var blurb: String {
        switch self {
        case .opencode: return "The forked coding agent — the default."
        case .freebuff: return "The external agentic coding CLI (must be on the Mac's PATH)."
        }
    }
}

// MARK: - Understand-Anything (interactive knowledge graph)

/// The knowledge graph's state for a project, as the Mac reports it in
/// `code.understand_analyze` / status broadcasts: a stable string plus counts.
struct UnderstandStatePayload: Codable, Hashable {
    var state: UnderstandState
    var nodeCount: Int?
    var edgeCount: Int?
    var layerCount: Int?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case state
        case nodeCount = "node_count"
        case edgeCount = "edge_count"
        case layerCount = "layer_count"
        case message
    }

    static func fromJSON(_ params: [String: Any]) -> UnderstandStatePayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(UnderstandStatePayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// The stable graph states, mirroring the Mac's `code.understand_status` wire.
enum UnderstandState: String, Codable, Hashable {
    case notInstalled = "not_installed"
    case notAnalyzed = "not_analyzed"
    case analyzing
    case ready
    case failed

    var isReady: Bool { self == .ready }
    var isAnalyzing: Bool { self == .analyzing }
    var isFailure: Bool { self == .failed }
}

/// The graph's full status for a project, from `code.understand_status`.
struct UnderstandStatusPayload: Codable, Hashable {
    var state: UnderstandState
    var available: Bool
    var installed: Bool
    var text: String

    private enum CodingKeys: String, CodingKey {
        case state, available, installed, text
    }

    static func fromJSON(_ params: [String: Any]) -> UnderstandStatusPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(UnderstandStatusPayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// One node in a knowledge-graph payload — a file, function, class, …
struct UnderstandNodePayload: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var type: String
    var filePath: String
    var summary: String
    var tags: [String]
    var signature: String
    var startLine: Int
    var endLine: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, type, summary, tags, signature
        case filePath = "file_path"
        case startLine = "start_line"
        case endLine = "end_line"
    }

    static func fromJSON(_ dict: [String: Any]) -> UnderstandNodePayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandNodePayload.self, from: data)
    }
}

/// One edge between two nodes.
struct UnderstandEdgePayload: Codable, Hashable, Identifiable {
    var source: String
    var target: String
    var type: String

    var id: String { "\(source)-\(target)-\(type)" }

    static func fromJSON(_ dict: [String: Any]) -> UnderstandEdgePayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandEdgePayload.self, from: data)
    }
}

/// A bounded subgraph (for the canvas): nodes + edges + the focused center.
struct UnderstandGraphPayload: Codable, Hashable {
    var nodes: [UnderstandNodePayload]
    var edges: [UnderstandEdgePayload]
    var center: String?

    static func fromJSON(_ dict: [String: Any]) -> UnderstandGraphPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandGraphPayload.self, from: data)
    }
}

/// One search hit, with the Mac's relevance score.
struct UnderstandHitPayload: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var type: String
    var filePath: String
    var summary: String
    var tags: [String]
    var score: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, type, summary, tags, score
        case filePath = "file_path"
    }

    static func fromJSON(_ dict: [String: Any]) -> UnderstandHitPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandHitPayload.self, from: data)
    }
}

/// One dependent found by impact analysis: how deep below the target, and the
/// node-id chain back to it.
struct UnderstandImpactHitPayload: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var type: String
    var filePath: String
    var summary: String
    var depth: Int
    var path: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, type, summary, depth, path
        case filePath = "file_path"
    }

    static func fromJSON(_ dict: [String: Any]) -> UnderstandImpactHitPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandImpactHitPayload.self, from: data)
    }
}

/// A layer summary from `code.understand_query` mode=architecture.
struct UnderstandLayerSummaryPayload: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String
    var nodeCount: Int
    var sampleNodes: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, description
        case nodeCount = "node_count"
        case sampleNodes = "sample_nodes"
    }

    static func fromJSON(_ dict: [String: Any]) -> UnderstandLayerSummaryPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandLayerSummaryPayload.self, from: data)
    }
}

/// A node's explanation: itself, its neighbors (with edge type and direction),
/// and the layers it belongs to.
struct UnderstandExplainPayload: Codable, Hashable {
    var node: UnderstandNodePayload
    var neighbors: [UnderstandNeighborPayload]
    var layers: [String]

    struct UnderstandNeighborPayload: Codable, Hashable {
        var direction: String
        var type: String
        var node: UnderstandNodePayload
    }

    static func fromJSON(_ dict: [String: Any]) -> UnderstandExplainPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandExplainPayload.self, from: data)
    }
}

/// A trace path: ordered node ids plus the edge types between consecutive ones.
struct UnderstandTracePayload: Codable, Hashable {
    var nodeIDs: [String]
    var edgeTypes: [String]

    private enum CodingKeys: String, CodingKey {
        case nodeIDs = "node_ids"
        case edgeTypes = "edge_types"
    }

    static func fromJSON(_ dict: [String: Any]) -> UnderstandTracePayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(UnderstandTracePayload.self, from: data)
    }
}
