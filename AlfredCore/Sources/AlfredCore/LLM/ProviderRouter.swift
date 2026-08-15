import Foundation

/// Platform-agnostic router over `LLMProvider` instances.
///
/// Owns provider selection and rotates providers when the active one hits a
/// rate limit — the fallback behavior the pre-refactor `LLMRouter` had —
/// without any app-state, Combine, or UI coupling. Providers are injected at
/// init, so the macOS and iOS apps can register their own concrete providers
/// (OpenAI-compatible hosts, Ollama, …) and both share this router.
public final class ProviderRouter {

    /// All registered providers, in fallback order.
    public let providers: [any LLMProvider]

    /// The provider the next request will use.
    public private(set) var activeProvider: any LLMProvider

    private let lock = NSLock()
    private var activeIndex: Int

    /// - Parameters:
    ///   - providers: providers in fallback order. Must not be empty.
    ///   - initialID: the provider to start on; defaults to the first.
    public init(providers: [any LLMProvider], initialID: String? = nil) {
        precondition(!providers.isEmpty, "ProviderRouter requires at least one provider")
        self.providers = providers
        if let initialID, let index = providers.firstIndex(where: { $0.id == initialID }) {
            activeIndex = index
        } else {
            activeIndex = 0
        }
        activeProvider = providers[activeIndex]
    }

    /// Switch the active provider by id. No-op (returns false) for unknown ids.
    @discardableResult
    public func select(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return false }
        activeIndex = index
        activeProvider = providers[index]
        return true
    }

    /// Rotate to the next provider in fallback order. No-op when only one
    /// provider is registered. Returns the newly active provider.
    @discardableResult
    public func advance() -> any LLMProvider {
        lock.lock(); defer { lock.unlock() }
        guard providers.count > 1 else { return activeProvider }
        activeIndex = (activeIndex + 1) % providers.count
        activeProvider = providers[activeIndex]
        return activeProvider
    }

    // MARK: - Dispatch

    /// Complete a turn on the active provider, rotating to the next provider
    /// when the active one reports `.rateLimited`. Throws the last rate-limit
    /// error once every provider has been tried.
    public func complete(messages: [LLMMessage], system: String) async throws -> String {
        try await withFallback { provider in
            try await provider.complete(messages: messages, system: system)
        }
    }

    /// Stream a turn on the active provider with the same rate-limit
    /// rotation as `complete`.
    public func stream(
        messages: [LLMMessage],
        system: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await withFallback { provider in
            try await provider.stream(messages: messages, system: system, onToken: onToken)
        }
    }

    /// Stream a tool-calling turn. Providers that don't adopt
    /// `ToolCallingProvider` throw `.unsupported`, which the caller can catch
    /// and degrade to plain `stream`.
    public func streamWithTools(
        messages: [LLMMessage],
        system: String,
        tools: [any LLMTool]?,
        executeToolCall: ((String, String) async -> String)?,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> String {
        try await withFallback { provider in
            guard let toolCalling = provider as? any ToolCallingProvider else {
                throw LLMError.unsupported
            }
            return try await toolCalling.streamWithTools(
                messages: messages,
                system: system,
                tools: tools,
                executeToolCall: executeToolCall,
                onEvent: onEvent
            )
        }
    }

    // MARK: - Fallback

    /// Runs `body` on the active provider, rotating on `.rateLimited` and
    /// retrying until every provider has been tried.
    private func withFallback(_ body: (any LLMProvider) async throws -> String) async throws -> String {
        var remaining = providers.count
        var provider = activeProvider
        while remaining > 0 {
            do {
                return try await body(provider)
            } catch LLMError.rateLimited {
                remaining -= 1
                guard remaining > 0 else { throw LLMError.rateLimited() }
                let next = advance()
                NSLog("[core] provider %@ rate limited — rotating to %@", provider.id, next.id)
                provider = next
            }
        }
        throw LLMError.rateLimited()
    }
}
