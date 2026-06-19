import Foundation

// MARK: - Tool call

struct ToolCall: Codable, Equatable {
    let id: String
    let type: String
    let function: Function

    struct Function: Codable, Equatable {
        let name: String
        let arguments: String
    }
}

// MARK: - Message

struct LLMMessage: Codable, Equatable {
    var role: String
    var content: String
    var imageBase64: String?
    var imageMediaType: String?
    var toolCallID: String?
    var toolCalls: [ToolCall]?

    static func user(_ content: String) -> LLMMessage { .init(role: "user", content: content) }
    static func user(_ content: String, imageBase64: String, imageMediaType: String = "image/jpeg") -> LLMMessage {
        .init(role: "user", content: content, imageBase64: imageBase64, imageMediaType: imageMediaType)
    }
    static func assistant(_ content: String) -> LLMMessage { .init(role: "assistant", content: content) }
    static func assistant(toolCalls: [ToolCall]) -> LLMMessage { .init(role: "assistant", content: "", toolCalls: toolCalls) }
    static func system(_ content: String) -> LLMMessage { .init(role: "system", content: content) }
    static func toolResult(_ content: String, toolCallID: String) -> LLMMessage { .init(role: "tool", content: content, toolCallID: toolCallID) }
}

// MARK: - Tool definition

/// JSON‑serializable tool definition for OpenAI‑compatible function‑calling.
/// Use `LLMTool.openApplication` for the built‑in open‑app tool.
struct LLMTool {
    let name: String
    let payload: [String: Any]

    static let openApplication = LLMTool(
        name: "open_application",
        payload: [
            "type": "function",
            "function": [
                "name": "open_application",
                "description": "Open a specified application on the user's computer. Call this when the user asks to open, launch, or start an application.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "app_name": [
                            "type": "string",
                            "description": "The name of the application to open, e.g. 'Spotify', 'Terminal', 'Safari', 'Notion', 'Slack'"
                        ]
                    ],
                    "required": ["app_name"]
                ]
            ]
        ]
    )
}

// MARK: - Error

enum LLMError: Error, LocalizedError {
    case invalidKey
    case invalidRequest
    case inferenceFailed(String)
    case rateLimited(String? = nil)
    case networkError(String)
    case unsupported
    case toolCallDetected([ToolCall])

    var errorDescription: String? {
        switch self {
        case .invalidKey:        return "Invalid or missing API key."
        case .invalidRequest:    return "Invalid request format."
        case .inferenceFailed(let msg): return "Inference failed: \(msg)"
        case .rateLimited(let msg):
            if let msg, !msg.isEmpty { return "Rate limited: \(msg)" }
            return "Rate limit reached. Try again shortly."
        case .networkError(let msg): return "Network error: \(msg)"
        case .unsupported:       return "Operation not supported by this provider."
        case .toolCallDetected:  return "Tool call was detected (use streaming path for handling)."
        }
    }
}

// MARK: - Protocol

protocol LLMProvider {
    var id: String { get }
    var displayName: String { get }
    var model: String { get set }
    var supportsVision: Bool { get }

    /// Returns the full completion string.
    func complete(messages: [LLMMessage], system: String) async throws -> String

    /// Streams tokens via `onToken`, returns full accumulated string when done.
    func stream(
        messages: [LLMMessage],
        system: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

extension LLMProvider {
    var supportsVision: Bool {
        let lower = model.lowercased()
        return lower.contains("vision")
            || lower.contains("gemini-2")
            || lower.contains("gemini-1.5")
            || lower.contains("claude-3") || lower.contains("claude-4")
            || lower.contains("gpt-4")
            || lower.contains("llama-3.2-11b") || lower.contains("llama-3.2-90b")
            || lower.contains("llava") || lower.contains("pixtral")
            || lower.contains("qwen-vl") || lower.contains("qwen2-vl")
    }
}

// MARK: - Helpers shared across providers

extension LLMProvider {
    /// Convenience: single-user-turn completion.
    func complete(prompt: String, system: String = "") async throws -> String {
        try await complete(messages: [.user(prompt)], system: system)
    }

    func stream(
        prompt: String,
        system: String = "",
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await stream(messages: [.user(prompt)], system: system, onToken: onToken)
    }
}
