import Foundation

final class OllamaProvider: LLMProvider, ObservableObject {
    let id = "ollama"
    let displayName = "Ollama (Local)"

    private let baseURL = URL(string: "http://localhost:11434/api/chat")!
    private let tagsURL = URL(string: "http://localhost:11434/api/tags")!

    @Published var availableModels: [String] = []
    var selectedModel: String

    /// KV-cache context size. Ollama otherwise loads a model at its FULL trained context
    /// (llama3.1:8b = 131072 tokens ≈ 22 GB RAM for a 5 GB model). Capping this is the difference
    /// between ~6 GB and ~22 GB. Raise only if you truly need very long local contexts.
    var contextLength: Int = 8192

    /// How long Ollama keeps the model resident after a request. nil = Ollama's default (5 min).
    /// Background callers (e.g. the learning pipeline) set a short value like "30s" so a big model
    /// doesn't sit in RAM between infrequent ticks. Accepts Ollama duration strings, or "0" to unload.
    var keepAlive: String? = nil

    var model: String {
        get { selectedModel }
        set { selectedModel = newValue }
    }

    init(model: String = "llama3.2") {
        self.selectedModel = model
    }

    // MARK: - Model discovery

    func fetchAvailableModels() async {
        guard let (data, _) = try? await URLSession.shared.data(from: tagsURL) else { return }

        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }

        guard let response = try? JSONDecoder().decode(TagsResponse.self, from: data) else { return }
        let names = response.models.map(\.name)

        await MainActor.run {
            self.availableModels = names
            if !names.isEmpty && !names.contains(self.selectedModel) {
                self.selectedModel = names[0]
            }
        }
    }

    // MARK: - LLMProvider

    func complete(messages: [LLMMessage], system: String) async throws -> String {
        let body = buildBody(messages: messages, system: system, stream: false)
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        struct Response: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.message.content
    }

    func stream(
        messages: [LLMMessage],
        system: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let body = buildBody(messages: messages, system: system, stream: true)
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (byteStream, response) = try await URLSession.shared.bytes(for: request)
        try validate(response: response, data: nil)

        var accumulated = ""

        struct Chunk: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message?
            let done: Bool
        }

        // Reuse a single decoder across all streamed chunks instead of allocating one per line.
        let decoder = JSONDecoder()

        for try await line in byteStream.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let chunk = try? decoder.decode(Chunk.self, from: data),
                  let text = chunk.message?.content, !text.isEmpty
            else { continue }
            accumulated += text
            onToken(text)
            if chunk.done { break }
        }

        return accumulated
    }

    // MARK: - Private

    private func buildBody(messages: [LLMMessage], system: String, stream: Bool) -> [String: Any] {
        var ollamaMessages: [[String: Any]] = []
        if !system.isEmpty {
            ollamaMessages.append(["role": "system", "content": system])
        }
        for message in messages {
            var entry: [String: Any] = ["role": message.role, "content": message.content]
            // Ollama's /api/chat takes images as a per-message array of RAW base64 (no "data:" prefix).
            // Without this the screenshot for guidance ("point at my screen") is silently dropped and a
            // vision model gets a text-only prompt.
            if let image = message.imageBase64, !image.isEmpty {
                entry["images"] = [image]
            }
            ollamaMessages.append(entry)
        }

        var body: [String: Any] = [
            "model": selectedModel,
            "stream": stream,
            "messages": ollamaMessages,
            // Cap the KV cache so Ollama doesn't allocate the model's full 131072-token context
            // (~22 GB for llama3.1:8b). This is the single biggest RAM lever.
            // num_predict bounds output length so a runaway model can't generate unbounded tokens;
            // 8192 is far above normal replies (a single longer reply would be truncated).
            "options": ["num_ctx": contextLength, "num_predict": 8192],
        ]
        if let keepAlive { body["keep_alive"] = keepAlive }
        return body
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("Ollama not reachable at localhost:11434")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(http.statusCode)"
            throw LLMError.networkError(message)
        }
    }
}
