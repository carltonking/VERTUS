import Foundation
import Combine
import os

final class LLMRouter: ObservableObject {

    // ponytail: token COUNTS only (no content) — rough chars/4 estimate, good enough to
    // spot a runaway background service. Swap in real provider usage fields when a bill surprises you.
    private static let costLog = Logger(subsystem: "com.alfred.llm", category: "cost")

    private func logCost(messages: [LLMMessage], system: String, output: String) {
        let inTokens = (messages.reduce(system.count) { $0 + $1.content.count }) / 4
        let outTokens = output.count / 4
        Self.costLog.info("llm \(self.activeProvider.id, privacy: .public): ~\(inTokens, privacy: .public) in + ~\(outTokens, privacy: .public) out tokens")
    }

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
        // Warm the connection at launch so the first query doesn't pay the TLS handshake.
        activeProvider.prewarmConnection()

        // Stay in sync when the user changes providers in settings
        appState.$selectedProvider
            .dropFirst()
            .sink { [weak self] id in
                guard let self else { return }
                var provider = Self.provider(for: id)
                provider.model = self.appState.selectedModel
                self.activeProvider = provider
                provider.prewarmConnection()
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

    // MARK: - Auto-fallback to local Ollama

    /// When a CLOUD provider fails with a rate limit / server (5xx) / network error, silently retry on
    /// local Ollama so the user never sees "hit an error". Ollama is on-device — no egress guard, no
    /// redaction needed. Only for cloud providers (if Ollama itself fails there's nowhere to fall back).
    private let fallbackOllama = OllamaProvider(model: "llama3.1:8b")

    /// A thread-safe "did the stream emit any tokens yet" flag, so we only fall back on a clean upfront
    /// failure (429/503 before any output) and never mid-stream (which would double the text).
    private final class EmitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func hit() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private func shouldFallback(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let llm = error as? LLMError else { return false }
        switch llm {
        case .rateLimited, .networkError: return true   // networkError carries 5xx/overload/timeout text
        default: return false                           // invalidKey etc. surface so the user fixes config
        }
    }

    private func fallbackModel() -> String { appState.providerModels["ollama"] ?? "llama3.1:8b" }

    // MARK: - Forwarding

    func complete(messages: [LLMMessage], system: String = "") async throws -> String {
        let (m, s) = try guardEgress(messages, system)
        do {
            let out = try await activeProvider.complete(messages: m, system: s)
            logCost(messages: m, system: s, output: out)
            return out
        } catch {
            guard isActiveProviderCloud, shouldFallback(error) else { throw error }
            NSLog("[LLMRouter] \(activeProvider.id) failed (\(error.localizedDescription)) — falling back to Ollama")
            fallbackOllama.model = fallbackModel()
            return try await fallbackOllama.complete(messages: messages, system: system)
        }
    }

    func stream(
        messages: [LLMMessage],
        system: String = "",
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let (m, s) = try guardEgress(messages, system)
        let emitted = EmitFlag()
        do {
            let out = try await activeProvider.stream(messages: m, system: s, onToken: { emitted.hit(); onToken($0) })
            logCost(messages: m, system: s, output: out)
            return out
        } catch {
            guard isActiveProviderCloud, shouldFallback(error), !emitted.value else { throw error }
            NSLog("[LLMRouter] \(activeProvider.id) stream failed (\(error.localizedDescription)) — falling back to Ollama")
            fallbackOllama.model = fallbackModel()
            return try await fallbackOllama.stream(messages: messages, system: system, onToken: onToken)
        }
    }

    /// Stream with tool‑calling support. Pass `tools` definitions and an `executeToolCall`
    /// closure that runs each tool synchronisation‑free. Only supported on OpenAI‑compatible
    /// providers (local, Gemini); other providers fall back to plain streaming. On a cloud failure
    /// it also falls back to Ollama (plain stream, no tools — degraded but responsive).
    func streamWithTools(
        messages: [LLMMessage],
        system: String = "",
        tools: [[String: Any]]?,
        executeToolCall: @escaping @Sendable (String, String) async -> String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let (m, s) = try guardEgress(messages, system)
        let emitted = EmitFlag()
        let tracked: @Sendable (String) -> Void = { emitted.hit(); onToken($0) }
        do {
            guard let provider = activeProvider as? OpenAICompatibleProvider else {
                let out = try await activeProvider.stream(messages: m, system: s, onToken: tracked)
                logCost(messages: m, system: s, output: out)
                return out
            }
            let out = try await provider.streamWithTools(
                messages: m, system: s, tools: tools, executeToolCall: executeToolCall, onToken: tracked)
            logCost(messages: m, system: s, output: out)
            return out
        } catch {
            guard isActiveProviderCloud, shouldFallback(error), !emitted.value else { throw error }
            NSLog("[LLMRouter] \(activeProvider.id) streamWithTools failed (\(error.localizedDescription)) — falling back to Ollama")
            fallbackOllama.model = fallbackModel()
            return try await fallbackOllama.stream(messages: messages, system: system, onToken: onToken)
        }
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
