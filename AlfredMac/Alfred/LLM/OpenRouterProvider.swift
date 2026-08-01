import Foundation

final class OpenRouterProvider: LLMProvider, ObservableObject {
    let id = "openrouter"
    let displayName = "OpenRouter (100+ Models)"

    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    @Published var selectedModel: String

    var model: String {
        get { selectedModel }
        set { selectedModel = newValue }
    }

    init(model: String = "mistralai/mistral-7b-instruct:free") {
        self.selectedModel = model
    }

    private var apiKey: String {
        KeychainHelper.load(service: "com.alfred.app", account: "openrouter") ?? ""
    }

    /// Warm the TLS/keep-alive connection to OpenRouter so the first real request reuses it instead
    /// of paying the ~100-400ms handshake inline. Fire-and-forget; the response is discarded.
    func prewarmConnection() {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }

    // MARK: - LLMProvider

    func complete(messages: [LLMMessage], system: String) async throws -> String {
        let body = buildBody(messages: messages, system: system, stream: false)
        let request = try buildRequest(body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    func stream(
        messages: [LLMMessage],
        system: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let body = buildBody(messages: messages, system: system, stream: true)
        let request = try buildRequest(body: body)

        let (byteStream, response) = try await URLSession.shared.bytes(for: request)
        try validate(response: response, data: nil)

        var accumulated = ""

        // Reuse a single decoder across all streamed chunks instead of allocating one per line.
        let decoder = JSONDecoder()

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }

            guard let data = payload.data(using: .utf8) else { continue }

            struct Delta: Decodable {
                struct Choice: Decodable {
                    struct Delta: Decodable { let content: String? }
                    let delta: Delta
                }
                let choices: [Choice]
            }

            if let event = try? decoder.decode(Delta.self, from: data),
               let text = event.choices.first?.delta.content {
                accumulated += text
                onToken(text)
            }
        }

        return accumulated
    }

    // MARK: - Private

    private func buildBody(messages: [LLMMessage], system: String, stream: Bool) -> [String: Any] {
        var allMessages: [[String: Any]] = []
        if !system.isEmpty {
            allMessages.append(["role": "system", "content": system])
        }
        allMessages += messages.map { messagePayload($0) }

        return [
            "model": selectedModel,
            "stream": stream,
            "messages": allMessages,
            // Bound runaway output (latency + cost); ~8k tokens is far above normal replies and
            // OpenRouter clamps to the model's limit. A single longer reply would be truncated.
            "max_tokens": 8192,
        ]
    }

    private func messagePayload(_ message: LLMMessage) -> [String: Any] {
        guard let imageBase64 = message.imageBase64 else {
            return ["role": message.role, "content": message.content]
        }

        return [
            "role": message.role,
            "content": [
                [
                    "type": "text",
                    "text": message.content,
                ],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(message.imageMediaType ?? "image/jpeg");base64,\(imageBase64)",
                    ],
                ],
            ],
        ]
    }

    private func buildRequest(body: [String: Any]) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw LLMError.invalidKey }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/alfred-app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Alfred", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("No HTTP response")
        }
        switch http.statusCode {
        case 200...299: return
        case 401:       throw LLMError.invalidKey
        case 429:
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw LLMError.rateLimited(detail.isEmpty ? nil : detail)
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(http.statusCode)"
            throw LLMError.networkError(message)
        }
    }
}
