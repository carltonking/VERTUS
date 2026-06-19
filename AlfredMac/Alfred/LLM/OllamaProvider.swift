import Foundation

final class OllamaProvider: LLMProvider, ObservableObject {
    let id = "ollama"
    let displayName = "Ollama (Local)"

    private let baseURL = URL(string: "http://localhost:11434/api/chat")!
    private let tagsURL = URL(string: "http://localhost:11434/api/tags")!

    @Published var availableModels: [String] = []
    var selectedModel: String

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

        for try await line in byteStream.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
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
        var ollamaMessages: [[String: String]] = []
        if !system.isEmpty {
            ollamaMessages.append(["role": "system", "content": system])
        }
        ollamaMessages += messages.map { ["role": $0.role, "content": $0.content] }

        return [
            "model": selectedModel,
            "stream": stream,
            "messages": ollamaMessages,
        ]
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
