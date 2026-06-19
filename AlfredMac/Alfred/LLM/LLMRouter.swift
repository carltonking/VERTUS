import Foundation
import Combine

final class LLMRouter: ObservableObject {

    @Published var activeProvider: any LLMProvider

    // All available provider instances (shared; mutate model selection on them directly).
    // The bundled "local" Qwen FastAPI server was retired (M8) — Ollama remains the on-device path.
    static let ollama      = OllamaProvider()
    static let openRouter  = OpenRouterProvider()
    static let gemini = OpenAICompatibleProvider(
        id: "gemini", displayName: "Google Gemini (Free)",
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        keychainAccount: "gemini", defaultModel: "gemini-2.0-flash")
    static let groq = OpenAICompatibleProvider(
        id: "groq", displayName: "Groq (Free)",
        baseURL: "https://api.groq.com/openai/v1/chat/completions",
        keychainAccount: "groq", defaultModel: "llama-3.3-70b-versatile")

    static let allProviders: [any LLMProvider] = [groq, gemini, openRouter, ollama]

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
        cloudDisabled = appState.cloudDisabled
        activeProvider = Self.provider(for: appState.selectedProvider)
        activeProvider.model = appState.selectedModel

        // Stay in sync when the user changes providers in settings
        appState.$selectedProvider
            .dropFirst()
            .sink { [weak self] id in
                guard let self else { return }
                var provider = Self.provider(for: id)
                provider.model = self.appState.selectedModel
                self.activeProvider = provider
            }
            .store(in: &cancellables)

        // Keep the active provider's model in sync when selectedModel changes
        appState.$selectedModel
            .dropFirst()
            .sink { [weak self] model in
                self?.activeProvider.model = model
            }
            .store(in: &cancellables)

        // Privacy mode: keep the cloud-egress gate in sync.
        appState.$cloudDisabled
            .dropFirst()
            .sink { [weak self] disabled in self?.cloudDisabled = disabled }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState

    private static func provider(for id: String) -> any LLMProvider {
        allProviders.first { $0.id == id } ?? groq
    }

    // MARK: - Egress safety (Blueprint v1 §7)

    /// Provider ids that run on-device. Everything else is cloud egress.
    private static let localProviderIDs: Set<String> = ["local", "ollama"]

    /// Privacy mode: when true, any cloud-bound call is blocked rather than sent.
    @Published var cloudDisabled: Bool

    private let redactor = Redactor()

    /// True when the active provider sends data off-device.
    var isActiveProviderCloud: Bool { !Self.localProviderIDs.contains(activeProvider.id) }

    /// Summary of what (redacted) payload left the device on the most recent call.
    /// Empty string = nothing was sent to cloud (local provider). Read by the audit log
    /// + the AlfredBar routing line after a call completes.
    private(set) var lastEgressSummary = ""

    enum EgressError: Error, LocalizedError {
        case cloudDisabled
        var errorDescription: String? {
            "Cloud is disabled (privacy mode). Switch to a local provider or enable cloud in Settings."
        }
    }

    /// Applies the privacy gate + mandatory redaction. Returns the payload actually sent.
    /// For local providers, nothing is redacted and nothing leaves the device.
    private func guardEgress(_ messages: [LLMMessage], _ system: String) throws -> ([LLMMessage], String) {
        guard isActiveProviderCloud else {
            lastEgressSummary = ""
            return (messages, system)
        }
        if cloudDisabled { throw EgressError.cloudDisabled }
        let redacted = redactor.redact(messages: messages, system: system)
        lastEgressSummary = redacted.count > 0
            ? "\(activeProvider.id): sent, \(redacted.count) item(s) [REDACTED]"
            : "\(activeProvider.id): sent, no redactions"
        return (redacted.messages, redacted.system)
    }

    // MARK: - Forwarding

    func complete(messages: [LLMMessage], system: String = "") async throws -> String {
        let (m, s) = try guardEgress(messages, system)
        return try await activeProvider.complete(messages: m, system: s)
    }

    func stream(
        messages: [LLMMessage],
        system: String = "",
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let (m, s) = try guardEgress(messages, system)
        return try await activeProvider.stream(messages: m, system: s, onToken: onToken)
    }

    /// Stream with tool‑calling support. Pass `tools` definitions and an `executeToolCall`
    /// closure that runs each tool synchronisation‑free. Only supported on OpenAI‑compatible
    /// providers (local, Gemini); other providers fall back to plain streaming.
    func streamWithTools(
        messages: [LLMMessage],
        system: String = "",
        tools: [[String: Any]]?,
        executeToolCall: @escaping @Sendable (String, String) async -> String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let (m, s) = try guardEgress(messages, system)
        guard let provider = activeProvider as? OpenAICompatibleProvider else {
            return try await activeProvider.stream(messages: m, system: s, onToken: onToken)
        }
        return try await provider.streamWithTools(
            messages: m,
            system: s,
            tools: tools,
            executeToolCall: executeToolCall,
            onToken: onToken
        )
    }

    // Convenience single-turn wrappers
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
