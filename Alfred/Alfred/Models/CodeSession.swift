//
//  CodeSession.swift
//  Alfred
//
//  The iOS half of the AlfredCode contract. These mirror the macOS wire shapes
//  in AlfredMac/Alfred/Code/AlfredCodeManager.swift exactly — the phone
//  decodes `code.sessions` results with these, and the new-session sheet
//  encodes the request back. Keep the two in lockstep.
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
