import Foundation
import Combine
import os

final class LLMRouter: ObservableObject {

    // ponytail: token COUNTS only (no content) — rough chars/4 estimate, good enough to
    // spot a runaway background service. Swap in real provider usage fields when a bill surprises you.
    private static let costLog = Logger(subsystem: "com.alfred.llm", category: "cost")

    /// Routing/capability events (provider fallback, tool-support degradation). Never message content.
    private static let routingLog = Logger(subsystem: "com.alfred.llm", category: "routing")

    private func logCost(messages: [LLMMessage], system: String, output: String, provider: any LLMProvider) {
        let inTokens = (messages.reduce(system.count) { $0 + $1.content.count }) / 4
        let outTokens = output.count / 4
        Self.costLog.info("llm \(provider.id, privacy: .public): ~\(inTokens, privacy: .public) in + ~\(outTokens, privacy: .public) out tokens")
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
    private func guardEgress(_ messages: [LLMMessage], _ system: String, provider: any LLMProvider) throws -> ([LLMMessage], String) {
        guard isCloud(provider) else {
            lastEgressSummary = ""
            return (messages, system)
        }
        if cloudDisabled { throw EgressError.cloudDisabled }
        let redacted = redactor.redact(messages: messages, system: system)
        lastEgressSummary = redacted.count > 0
            ? "\(provider.id): sent, \(redacted.count) item(s) [REDACTED]"
            : "\(provider.id): sent, no redactions"
        return (redacted.messages, redacted.system)
    }

    /// True when a given provider sends data off-device (mirrors `isActiveProviderCloud`).
    func isCloud(_ provider: any LLMProvider) -> Bool { !Self.localProviderIDs.contains(provider.id) }

    // MARK: - Automatic provider fallback (the model chain)

    /// When a provider fails — rate limit, dead key, 5xx, network — Alfred walks an ordered chain of the
    /// OTHER configured free-tier providers and finishes on local Ollama, so the user never sees "hit an
    /// error" for something another backend can answer. A provider that just failed goes on a cooldown,
    /// so the next request skips straight past it instead of paying the same timeout again.

    /// A thread-safe "did the stream emit any tokens yet" flag, so we only fall back on a clean upfront
    /// failure (429/503 before any output) and never mid-stream (which would double the text).
    private final class EmitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func hit() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Per-provider "don't try this one for a while" registry, shared process-wide.
    final class Cooldowns: @unchecked Sendable {
        private let lock = NSLock()
        private var until: [String: Date] = [:]

        func penalize(_ id: String, seconds: TimeInterval) {
            lock.lock(); until[id] = Date().addingTimeInterval(seconds); lock.unlock()
        }
        func clear(_ id: String) { lock.lock(); until[id] = nil; lock.unlock() }
        func isCooling(_ id: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let t = until[id] else { return false }
            return t > Date()
        }
    }

    static let cooldowns = Cooldowns()

    /// A few words naming the failure kind, for the all-backends-failed summary. Deliberately does
    /// NOT include provider response bodies — those carry org ids and quota details.
    private static func shortReason(_ error: Error) -> String {
        if error is URLError { return "network" }
        guard let llm = error as? LLMError else { return "failed" }
        switch llm {
        case .rateLimited:     return "rate limited"
        case .invalidKey:      return "bad key"
        case .networkError:    return "network"
        case .inferenceFailed: return "inference failed"
        case .invalidRequest:  return "request rejected"
        case .unsupported:     return "unsupported"
        case .toolCallDetected: return "tool call"
        }
    }

    private func shouldFallback(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let llm = error as? LLMError else { return false }
        switch llm {
        // invalidKey included on purpose: with a chain, a dead/missing key is exactly when moving to the
        // next provider is right. If every provider fails, the original error still surfaces so the user
        // knows to fix the key.
        case .rateLimited, .networkError, .invalidKey, .inferenceFailed: return true
        case .toolCallDetected, .invalidRequest, .unsupported: return false
        }
    }

    /// How long to sideline a provider, by failure kind. Quota exhaustion is the long one.
    private func penalty(for error: Error) -> TimeInterval {
        guard let llm = error as? LLMError else { return 60 }
        switch llm {
        case .rateLimited: return 300   // rate limit or free-tier daily cap
        case .invalidKey:  return 3600  // bad/revoked key — stop hammering it
        default:           return 60    // 5xx, timeout, network blip
        }
    }

    private func fallbackModel() -> String { appState.providerModels["ollama"] ?? "llama3.1:8b" }

    /// The ordered list of providers to try for one call: the requested provider first, then every OTHER
    /// configured cloud provider (preference order), then local Ollama — which needs no key and no
    /// egress. Providers on cooldown keep their place at the BACK rather than being dropped: a
    /// rate-limited retry still beats no answer when everything is cooling.
    ///
    /// `requiringVision` drops every backup that can't read an image — handing a screenshot to a
    /// text-only model produces a confident hallucination, which is worse than the original error. The
    /// vision fallbacks use each provider's known vision model, not the user's chat model.
    func fallbackChain(after primary: any LLMProvider, requiringVision: Bool = false) -> [any LLMProvider] {
        var cloud: [any LLMProvider] = [primary]
        for id in Self.chainIDs(primary: primary.id).dropFirst() where id != "ollama" {
            let model = requiringVision
                ? (Self.visionModels[id] ?? "")
                : (appState.providerModels[id] ?? AppState.defaultProviderModels[id] ?? "")
            guard !model.isEmpty, let provider = Self.freshProvider(id: id, model: model) else { continue }
            cloud.append(provider)
        }
        let ready = cloud.filter { !Self.cooldowns.isCooling($0.id) }
        let cooling = cloud.filter { Self.cooldowns.isCooling($0.id) }

        // Local tail: always available, no key, no egress. Skipped when Ollama IS the primary (it's
        // already first) or when the call needs vision and the local model can't read images.
        let ollama = OllamaProvider(model: fallbackModel())
        let skipTail = Self.localProviderIDs.contains(primary.id) || (requiringVision && !ollama.supportsVision)
        return ready + cooling + (skipTail ? [] : [ollama])
    }

    /// The provider ids Alfred tries, in configured order, for a call starting at `primary`: the chosen
    /// provider, every other one with a key saved, then local Ollama. `fallbackChain` builds from this
    /// and the settings readout prints it, so what the UI promises is what actually runs.
    static func chainIDs(primary: String) -> [String] {
        var ids = [primary]
        ids += cloudPreference.filter { $0 != primary && configuredCloudIDs().contains($0) }
        if primary != "ollama" { ids.append("ollama") }
        return ids
    }

    /// Per-provider vision model, used only when a call carries an image (see `fallbackChain`).
    static let visionModels: [String: String] = [
        "gemini": "gemini-2.0-flash",
        "openrouter": "meta-llama/llama-4-maverick:free",
        "groq": "meta-llama/llama-4-scout-17b-16e-instruct",
    ]

    /// Runs `body` against the chain, returning the first provider's answer. Each provider gets its own
    /// egress guard (so a cloud fallback is redacted, a local one isn't). The FIRST error is what
    /// surfaces if everything fails — that's the one about the provider the user actually chose.
    private func runWithFallback(
        primary: any LLMProvider,
        messages: [LLMMessage],
        system: String,
        emitted: EmitFlag?,
        body: (any LLMProvider, [LLMMessage], String) async throws -> String
    ) async throws -> String {
        var firstError: Error?
        var attempts: [String] = []
        let needsVision = messages.contains { $0.imageBase64 != nil }
        let chain = fallbackChain(after: primary, requiringVision: needsVision)

        for provider in chain {
            let payload: ([LLMMessage], String)
            do {
                payload = try guardEgress(messages, system, provider: provider)
            } catch {
                // Privacy mode blocks this one (cloud). Keep the message — if the local tail also fails
                // it's the honest explanation — and try the next provider.
                if firstError == nil { firstError = error }
                continue
            }

            do {
                let out = try await body(provider, payload.0, payload.1)
                Self.cooldowns.clear(provider.id)
                if provider.id != primary.id {
                    NSLog("[LLMRouter] \(primary.id) → \(provider.id) answered (\(provider.model))")
                }
                logCost(messages: payload.0, system: payload.1, output: out, provider: provider)
                return out
            } catch {
                // Mid-stream failure: retrying would duplicate the text the user already saw.
                if emitted?.value == true { throw error }
                guard shouldFallback(error) else { throw error }
                if firstError == nil { firstError = error }
                attempts.append("\(provider.id): \(Self.shortReason(error))")
                Self.cooldowns.penalize(provider.id, seconds: penalty(for: error))
                Self.routingLog.notice("\(provider.id, privacy: .public) failed — next in chain")
                NSLog("[LLMRouter] \(provider.id) failed (\(error.localizedDescription)) — next in chain")
            }
        }

        // Every backend failed. Reporting only the FIRST error blames the provider the user chose
        // and hides that the whole chain is down — which is the actionable fact (e.g. "all three
        // cloud tiers are rate-limited and Ollama isn't running"). Summarize the whole walk.
        guard let firstError else { throw LLMError.networkError("No provider available") }
        if attempts.count > 1 {
            throw LLMError.networkError("All \(attempts.count) backends failed — \(attempts.joined(separator: "; "))")
        }
        throw firstError
    }

    // MARK: - Forwarding

    func complete(messages: [LLMMessage], system: String = "", provider: (any LLMProvider)? = nil) async throws -> String {
        try await runWithFallback(
            primary: provider ?? activeProvider, messages: messages, system: system, emitted: nil
        ) { p, m, s in
            try await p.complete(messages: m, system: s)
        }
    }

    func stream(
        messages: [LLMMessage],
        system: String = "",
        provider: (any LLMProvider)? = nil,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let emitted = EmitFlag()
        let tracked: @Sendable (String) -> Void = { emitted.hit(); onToken($0) }
        return try await runWithFallback(
            primary: provider ?? activeProvider, messages: messages, system: system, emitted: emitted
        ) { p, m, s in
            try await p.stream(messages: m, system: s, onToken: tracked)
        }
    }

    /// Stream with tool‑calling support. Pass `tools` definitions and an `executeToolCall`
    /// closure that runs each tool synchronisation‑free. Supported on any provider conforming to
    /// `ToolCallingProvider`; the rest of the chain (e.g. Ollama) degrades to plain streaming
    /// without tools rather than failing.
    ///
    /// Degradation is logged: a silent capability drop mid-fallback is otherwise indistinguishable
    /// from the model simply choosing not to call a tool.
    func streamWithTools(
        messages: [LLMMessage],
        system: String = "",
        tools: [[String: Any]]?,
        provider: (any LLMProvider)? = nil,
        executeToolCall: @escaping @Sendable (String, String) async -> String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let emitted = EmitFlag()
        let tracked: @Sendable (String) -> Void = { emitted.hit(); onToken($0) }
        return try await runWithFallback(
            primary: provider ?? activeProvider, messages: messages, system: system, emitted: emitted
        ) { p, m, s in
            guard let toolCapable = p as? any ToolCallingProvider else {
                if tools?.isEmpty == false {
                    Self.routingLog.notice("Tools dropped: provider \(p.id, privacy: .public) has no tool-calling support")
                }
                return try await p.stream(messages: m, system: s, onToken: tracked)
            }
            return try await toolCapable.streamWithTools(
                messages: m, system: s, tools: tools, executeToolCall: executeToolCall, onToken: tracked)
        }
    }

    // MARK: - Smart routing (opt-in, on-device analysis → best model)

    /// Cloud provider ids in preference order (fast + capable free tiers first).
    static let cloudPreference = ["groq", "gemini", "openrouter"]

    /// Cloud provider ids that currently have an API key in Keychain, in preference order.
    static func configuredCloudIDs() -> [String] {
        cloudPreference.filter { id in
            !((KeychainHelper.load(service: "com.alfred.app", account: id)) ?? "").isEmpty
        }
    }

    /// The best available VISION-capable provider for screen grounding (the "point at my screen"
    /// guidance feature), independent of the user's selected chat provider. Prefers strong grounders —
    /// Gemini, then Claude via OpenRouter (what Clicky uses) — over the weak Groq llama-vision. Returns
    /// nil if none of those is configured, so the caller can fall back to the active provider.
    func bestVisionProvider() -> (any LLMProvider)? {
        let configured = Set(Self.configuredCloudIDs())
        let candidates: [(id: String, model: String)] = [
            ("gemini", "gemini-2.0-flash"),
            ("openrouter", "anthropic/claude-3.5-sonnet"),
        ]
        for candidate in candidates where configured.contains(candidate.id) {
            if let provider = Self.freshProvider(id: candidate.id, model: candidate.model) { return provider }
        }
        return nil
    }

    /// Builds a FRESH provider instance for `id` (never a shared singleton, so a per-call override
    /// can't corrupt the interactive activeProvider or its model). Returns nil for unknown ids.
    static func freshProvider(id: String, model: String) -> (any LLMProvider)? {
        switch id {
        case "groq":
            let p = OpenAICompatibleProvider(id: "groq", displayName: "Groq (Free)",
                baseURL: "https://api.groq.com/openai/v1/chat/completions",
                keychainAccount: "groq", defaultModel: "llama-3.3-70b-versatile")
            p.model = model; return p
        case "gemini":
            let p = OpenAICompatibleProvider(id: "gemini", displayName: "Google Gemini (Free)",
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                keychainAccount: "gemini", defaultModel: "gemini-2.0-flash")
            p.model = model; return p
        case "openrouter":
            let p = OpenRouterProvider(); p.model = model; return p
        case "ollama":
            let p = OllamaProvider(); p.model = model; return p
        default:
            return nil
        }
    }

    /// SMART ROUTING (opt-in): analyze the prompt ON-DEVICE and return the best provider to run it
    /// on, or nil to keep the user's selected provider. The prompt is NEVER sent anywhere to decide —
    /// sensitivity comes from the local redactor, recency/complexity from local keyword checks.
    /// Policy: sensitive → keep LOCAL (Ollama); needs live web OR heavy reasoning → best configured
    /// CLOUD; otherwise → the selected provider. Only overrides with a clear reason and only to a
    /// provider that is actually available.
    func overrideProvider(for query: String) -> (any LLMProvider)? {
        guard appState.smartRoutingEnabled else { return nil }
        let activeID = activeProvider.id
        let sensitive = redactor.redact(query).didRedact
        let wantsWeb = QueryIntent.analyze(query).wantsWebSearch
        let lower = query.lowercased()
        let complex = query.count > 800 || query.contains("```")
            || ["analyze", "in detail", "step by step", "derive", "prove", "backtest", "rigorous"]
                .contains { lower.contains($0) }

        let targetID: String
        if sensitive {
            targetID = "ollama"                                      // privacy first — never auto-egress
        } else if wantsWeb || complex {
            targetID = Self.configuredCloudIDs().first ?? activeID   // research / heavy → strongest cloud
        } else {
            targetID = activeID                                      // no strong signal → keep default
        }
        guard targetID != activeID else { return nil }

        // Only route somewhere usable: a configured cloud provider, or local Ollama.
        let usable = Self.localProviderIDs.contains(targetID) || Self.configuredCloudIDs().contains(targetID)
        guard usable else { return nil }

        let model = appState.providerModels[targetID] ?? AppState.defaultProviderModels[targetID] ?? ""
        guard !model.isEmpty else { return nil }
        NSLog("[LLMRouter] smart-routing \(activeID) → \(targetID) (sensitive:\(sensitive) web:\(wantsWeb) complex:\(complex))")
        return Self.freshProvider(id: targetID, model: model)
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
