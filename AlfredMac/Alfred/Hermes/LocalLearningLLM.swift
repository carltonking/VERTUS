import Foundation

/// Strictly on-device LLM for the Hermes learning pipeline. Pins to Ollama (localhost:11434) so
/// captured screen text, meeting transcripts, and profile data NEVER leave the Mac — independent
/// of whichever provider the user has selected for the assistant chat.
///
/// Every call degrades gracefully: if Ollama isn't running, `run` returns nil and callers keep the
/// raw captured data with no enrichment (no cloud fallback — local-only by design).
///
/// Setup: `ollama pull llama3.1:8b` once, then it just works.
actor LocalLearningLLM {
    static let shared = LocalLearningLLM()

    /// Default local model. Override per-call if a smaller model is preferred for speed.
    private let defaultModel: String

    init(model: String = "llama3.1:8b") {
        self.defaultModel = model
    }

    /// Cheap reachability probe (2s timeout) against the Ollama tags endpoint.
    func isAvailable() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
        return true
    }

    /// Runs a single prompt locally. Returns nil if Ollama is unreachable or errors, or if the
    /// output is empty. Never throws — learning enrichment must never break the capture path.
    func run(system: String, prompt: String, model: String? = nil) async -> String? {
        let provider = OllamaProvider(model: model ?? defaultModel)
        provider.contextLength = 4096   // enrichment prompts are short — no need for a big KV cache
        provider.keepAlive = "30s"       // unload shortly after each background tick — don't sit at GBs of RAM
        guard let out = try? await provider.complete(prompt: prompt, system: system) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
