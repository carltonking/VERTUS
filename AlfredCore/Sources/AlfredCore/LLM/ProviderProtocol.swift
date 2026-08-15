import Foundation

// MARK: - Tool call

/// A structured tool invocation emitted by an LLM during a tool-calling turn.
public struct ToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let function: Function

    public struct Function: Codable, Equatable, Sendable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public init(id: String, type: String, function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

// MARK: - Message

/// One message in a chat turn. Platform-agnostic — never references AppKit,
/// SwiftUI, or any macOS-only framework.
public struct LLMMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    public var imageBase64: String?
    public var imageMediaType: String?
    public var toolCallID: String?
    public var toolCalls: [ToolCall]?

    public init(
        role: String,
        content: String,
        imageBase64: String? = nil,
        imageMediaType: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.imageBase64 = imageBase64
        self.imageMediaType = imageMediaType
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    public static func user(_ content: String) -> LLMMessage { .init(role: "user", content: content) }
    public static func user(_ content: String, imageBase64: String, imageMediaType: String = "image/jpeg") -> LLMMessage {
        .init(role: "user", content: content, imageBase64: imageBase64, imageMediaType: imageMediaType)
    }
    public static func assistant(_ content: String) -> LLMMessage { .init(role: "assistant", content: content) }
    public static func assistant(toolCalls: [ToolCall]) -> LLMMessage { .init(role: "assistant", content: "", toolCalls: toolCalls) }
    public static func system(_ content: String) -> LLMMessage { .init(role: "system", content: content) }
    public static func toolResult(_ content: String, toolCallID: String) -> LLMMessage { .init(role: "tool", content: content, toolCallID: toolCallID) }
}

// MARK: - Tool definition

/// JSON-serializable tool definition for OpenAI-compatible function-calling.
/// This is the *wire* shape sent in the `tools` array of a request; the
/// executable side of a tool lives in the `LLMTool` protocol.
/// Use `LLMToolDefinition.openApplication` for the built-in open-app tool.
public struct LLMToolDefinition {
    public let name: String
    public let payload: [String: Any]

    public init(name: String, payload: [String: Any]) {
        self.name = name
        self.payload = payload
    }

    public static let openApplication = LLMToolDefinition(
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

// MARK: - Tool

/// A tool the assistant can invoke. Conforming types know how to describe
/// themselves to a model (name, description, JSON-schema parameters) and how
/// to execute from a JSON-encoded arguments string. Tools are registered with
/// a provider so a tool-calling turn can offer them to the model and run the
/// calls the model emits.
public protocol LLMTool: Sendable {
    /// The tool's stable wire name, e.g. "read_file".
    var name: String { get }
    /// One-line description the model sees when deciding to call the tool.
    var description: String { get }
    /// JSON-schema object describing the tool's parameters (type/properties/required).
    var parameters: [String: Any] { get }

    /// Executes the tool with a JSON-encoded arguments string (e.g.
    /// `{"path": "/Users/x/note.md"}`) and returns the result text. Throws a
    /// descriptive error on bad arguments or execution failure.
    func execute(arguments: String) async throws -> String
}

public extension LLMTool {
    /// The OpenAI-compatible wire definition derived from this tool, for the
    /// `tools` array of a tool-calling request.
    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            payload: [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": parameters,
                ],
            ]
        )
    }
}

// MARK: - Stream events

/// Events emitted by a tool-calling stream. A provider emits `.contentDelta`
/// for each text fragment, `.toolCallDelta` carrying the *accumulated* tool
/// call as its arguments stream in across chunks, and exactly one `.done`
/// when the turn finishes cleanly.
public enum LLMStreamEvent: Sendable {
    /// A fragment of assistant text. Append, never replace.
    case contentDelta(String)
    /// A (possibly partial) tool call whose arguments have grown since the
    /// last emission for that `tool_call` index.
    case toolCallDelta(ToolCall)
    /// The stream finished. The provider's return value holds the full text.
    case done
}

// MARK: - Tool-call accumulation

/// Accumulates streaming `tool_calls` deltas into complete `ToolCall`s.
///
/// OpenAI-compatible SSE streams emit `delta.tool_calls[i]` fragments whose
/// `function.arguments` arrive split across chunks — Hermes, for example,
/// sends `{"function": {"arguments": "{\"path\":"` as one fragment and the
/// remainder in later ones. The `index` field identifies which tool call is
/// being built, so arguments are appended per index until each call is
/// complete. Feed every `delta.tool_calls` chunk from the stream; each call
/// returns the accumulated state for the deltas it advanced.
public struct ToolCallAccumulator: Sendable {

    /// The growing state of one in-flight tool call.
    public struct Partial: Sendable {
        public var id: String
        public var name: String
        public var arguments: String
    }

    /// In-flight tool calls, keyed by the stream's `tool_call` index.
    private(set) public var calls: [Int: Partial]

    public init() {
        calls = [:]
    }

    /// Feed one chunk of tool-call deltas (a JSON array). Returns the
    /// accumulated `ToolCall` for each delta, in delta order — the last entry
    /// for an index carries the full accumulated arguments.
    public mutating func accumulate(deltas: [[String: Any]]) -> [ToolCall] {
        var advanced: [ToolCall] = []
        for delta in deltas {
            guard let index = Self.index(of: delta) else { continue }
            var partial = calls[index] ?? Partial(id: "", name: "", arguments: "")
            if let id = delta["id"] as? String { partial.id = id }
            if let function = delta["function"] as? [String: Any] {
                if let name = function["name"] as? String { partial.name = name }
                // Arguments stream in as JSON-encoded string fragments; append
                // them per index so partial JSON like `{"path":` joins with the
                // fragments that follow it.
                if let args = function["arguments"] as? String { partial.arguments += args }
            }
            calls[index] = partial
            advanced.append(ToolCall(
                id: partial.id,
                type: "function",
                function: ToolCall.Function(name: partial.name, arguments: partial.arguments)
            ))
        }
        return advanced
    }

    /// The current accumulated state, in index order. Call after the stream
    /// ends to get every tool call with its final arguments.
    public var completedCalls: [ToolCall] {
        calls.keys.sorted().compactMap { index in
            guard let partial = calls[index], !partial.name.isEmpty else { return nil }
            return ToolCall(
                id: partial.id,
                type: "function",
                function: ToolCall.Function(name: partial.name, arguments: partial.arguments)
            )
        }
    }

    private static func index(of delta: [String: Any]) -> Int? {
        if let int = delta["index"] as? Int { return int }
        if let number = delta["index"] as? NSNumber { return number.intValue }
        return nil
    }
}

// MARK: - Error

public enum LLMError: Error, LocalizedError, Sendable {
    case invalidKey
    case invalidRequest
    case inferenceFailed(String)
    case rateLimited(String? = nil)
    case networkError(String)
    case unsupported
    case toolCallDetected([ToolCall])

    public var errorDescription: String? {
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

/// The abstraction every LLM provider conforms to. Platform-agnostic: a
/// provider is identified, configured with a model, and can complete or
/// stream a turn. Concrete providers (OpenAI-compatible hosts, Ollama, …)
/// live in the app layers and are injected into `ProviderRouter`.
public protocol LLMProvider: AnyObject {
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

    /// Open a keep-alive connection to the provider host ahead of the first real request, so the
    /// first turn after launch / provider switch doesn't pay the TLS handshake. No-op by default
    /// (e.g. local providers don't benefit).
    func prewarmConnection()
}

extension LLMProvider {
    public func prewarmConnection() {}
}

/// Adopted by providers that can run a native tool-calling turn.
///
/// `ProviderRouter.streamWithTools` used to downcast to the concrete
/// `OpenAICompatibleProvider`, which meant any other provider — including
/// OpenAI-wire-compatible ones like `OpenRouterProvider` — silently degraded
/// to plain streaming with no tools and no diagnostic. Conforming to this
/// protocol is now the single thing that decides whether a provider gets
/// tools, so a new provider opts in explicitly instead of losing the
/// capability by omission.
public protocol ToolCallingProvider: LLMProvider {
    /// Stream a tool-calling turn.
    ///
    /// Emits exactly three event kinds on `onEvent`:
    ///   - `.contentDelta(String)` per text fragment,
    ///   - `.toolCallDelta(ToolCall)` per tool-call delta — arguments are
    ///     accumulated per `tool_call` index across chunks, so each emission
    ///     carries the growing arguments string, and
    ///   - `.done` once the stream finishes cleanly.
    ///
    /// The return value is the full accumulated assistant text. `tools` are
    /// offered to the model; completed tool calls surface through
    /// `.toolCallDelta` for the caller to execute (via `executeToolCall` when
    /// the provider runs them inline, or after the stream).
    func streamWithTools(
        messages: [LLMMessage],
        system: String,
        tools: [any LLMTool]?,
        executeToolCall: ((String, String) async -> String)?,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> String
}

extension LLMProvider {
    public var supportsVision: Bool {
        let lower = model.lowercased()
        return lower.contains("vision")
            || lower.contains("gemini-2")
            || lower.contains("gemini-1.5")
            || lower.contains("claude-3") || lower.contains("claude-4")
            || lower.contains("gpt-4")
            || lower.contains("llama-3.2-11b") || lower.contains("llama-3.2-90b")
            || lower.contains("llava") || lower.contains("pixtral")
            // Local Ollama vision tags (offline/free guidance): qwen2.5vl, qwen3-vl, llama3.2-vision,
            // minicpm-v, moondream, and the older qwen*-vl names.
            || lower.contains("qwen-vl") || lower.contains("qwen2-vl")
            || lower.contains("qwen2.5vl") || lower.contains("qwen2.5-vl")
            || lower.contains("qwen3-vl") || lower.contains("qwen3vl")
            || lower.contains("minicpm-v") || lower.contains("moondream")
    }
}

// MARK: - Helpers shared across providers

extension LLMProvider {
    /// Convenience: single-user-turn completion.
    public func complete(prompt: String, system: String = "") async throws -> String {
        try await complete(messages: [.user(prompt)], system: system)
    }

    public func stream(
        prompt: String,
        system: String = "",
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await stream(messages: [.user(prompt)], system: system, onToken: onToken)
    }
}

// MARK: - Tool-calling convenience

public extension ToolCallingProvider {
    /// Convenience: single-user-turn tool-calling stream.
    func streamWithTools(
        prompt: String,
        system: String = "",
        tools: [any LLMTool]? = nil,
        executeToolCall: ((String, String) async -> String)? = nil,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> String {
        try await streamWithTools(
            messages: [.user(prompt)],
            system: system,
            tools: tools,
            executeToolCall: executeToolCall,
            onEvent: onEvent
        )
    }
}
