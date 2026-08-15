import Foundation
import Combine
import AlfredCore

/// Owns the chat session: message history, the AlfredCore `ProviderRouter`,
/// and the send loop. A fresh router is built per request so Settings changes
/// (base URL, model, API key) take effect immediately.
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending = false
    @Published var errorMessage: String?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// The assistant's standing instructions.
    private static let systemPrompt =
        "You are Alfred, a helpful assistant running on iOS. Answer concisely and directly. " +
        "When the user asks about a file or your memory vault, use the read_file tool."

    /// The tools offered on every turn. read_file reads only vault-allowed paths.
    private func makeTools() -> [any LLMTool] {
        [FileReadTool(vaultPath: settings.vaultPath)]
    }

    /// Append the user's text and run a tool-calling turn through the provider
    /// router, streaming content into a live assistant bubble. When the model
    /// emits a tool call, it is executed and its result fed back for another
    /// round — a bounded agent loop, so a model that keeps calling tools can't
    /// loop forever.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        messages.append(ChatMessage(role: "user", content: trimmed))
        isSending = true
        errorMessage = nil

        let system = Self.systemPrompt
        let tools = makeTools()

        Task { @MainActor in
            var history = messages.map { LLMMessage(role: $0.role, content: $0.content) }
            do {
                for _ in 0..<3 {
                    // A fresh bubble for this round's streamed answer.
                    let assistantID = UUID()
                    messages.append(ChatMessage(id: assistantID, role: "assistant", content: ""))

                    // Events arrive off the main actor; the box accumulates
                    // state and UI updates hop back to the main actor.
                    let box = StreamBox()
                    let router = makeRouter()
                    let _ = try await router.streamWithTools(
                        messages: history,
                        system: system,
                        tools: tools,
                        executeToolCall: nil,
                        onEvent: { [weak self] event in
                            switch event {
                            case .contentDelta(let chunk):
                                box.streamed += chunk
                                guard let self else { return }
                                Task { @MainActor in
                                    guard let index = self.messages.firstIndex(where: { $0.id == assistantID }) else { return }
                                    self.messages[index].content = box.streamed
                                }
                            case .toolCallDelta(let call):
                                // Same-name deltas are the same call growing;
                                // replace, don't duplicate.
                                if let last = box.calls.last, last.function.name == call.function.name {
                                    box.calls[box.calls.count - 1] = call
                                } else {
                                    box.calls.append(call)
                                }
                            case .done:
                                break
                            }
                        }
                    )

                    if box.calls.isEmpty {
                        // Plain answer — the bubble already shows it.
                        break
                    }

                    // Record what the model said and the calls it made, then
                    // run each completed call and feed the results back.
                    history.append(LLMMessage(role: "assistant", content: box.streamed, toolCalls: box.calls))
                    for call in box.calls {
                        let result: String
                        do {
                            result = try await Self.execute(toolCall: call, tools: tools)
                        } catch {
                            result = "Error: \(error.localizedDescription)"
                        }
                        history.append(.toolResult(result, toolCallID: call.id))
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    func clear() {
        messages.removeAll()
        errorMessage = nil
    }

    // MARK: - Tool execution

    /// Run one completed tool call against the registered tools.
    private static func execute(toolCall: ToolCall, tools: [any LLMTool]) async throws -> String {
        guard let tool = tools.first(where: { $0.name == toolCall.function.name }) else {
            throw LLMError.inferenceFailed("unknown tool: \(toolCall.function.name)")
        }
        return try await tool.execute(arguments: toolCall.function.arguments)
    }

    /// AlfredCore's router with the Hermes provider as configured.
    private func makeRouter() -> ProviderRouter {
        let provider = HermesProvider(
            baseURL: settings.resolvedBaseURL,
            model: settings.model,
            apiKey: settings.apiKey
        )
        return ProviderRouter(providers: [provider])
    }
}

/// Mutable accumulation shared between the streaming callback (off the main
/// actor) and the send loop (on it). The provider invokes `onEvent`
/// synchronously before its stream resolves, so by the time the enclosing
/// `await` returns every event has been delivered — reading `streamed` and
/// `calls` then is safe.
private final class StreamBox: @unchecked Sendable {
    var streamed = ""
    var calls: [ToolCall] = []
}
