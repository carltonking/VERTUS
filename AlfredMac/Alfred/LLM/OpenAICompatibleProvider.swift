import Foundation

final class OpenAICompatibleProvider: LLMProvider {
    let id: String
    let displayName: String
    private let endpoint: URL
    private let keychainAccount: String
    var model: String

    let requiresAuth: Bool

    init(id: String, displayName: String, baseURL: String, keychainAccount: String, defaultModel: String) {
        self.id = id
        self.displayName = displayName
        self.endpoint = URL(string: baseURL)!
        self.keychainAccount = keychainAccount
        self.model = defaultModel
        self.requiresAuth = !keychainAccount.isEmpty
    }

    private var apiKey: String {
        guard requiresAuth else { return "" }
        return KeychainHelper.load(service: "com.alfred.app", account: keychainAccount) ?? ""
    }

    // MARK: - LLMProvider

    func complete(messages: [LLMMessage], system: String) async throws -> String {
        let body = buildBody(messages: messages, system: system, stream: false)
        let request = try buildRequest(body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                    let toolCalls: [ToolCall]?

                    enum CodingKeys: String, CodingKey {
                        case content
                        case toolCalls = "tool_calls"
                    }
                }
                let message: Message
                let finishReason: String?

                enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        if decoded.choices.first?.finishReason == "tool_calls",
           let toolCalls = decoded.choices.first?.message.toolCalls {
            throw LLMError.toolCallDetected(toolCalls)
        }

        return decoded.choices.first?.message.content ?? ""
    }

    func stream(
        messages: [LLMMessage],
        system: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await streamWithTools(messages: messages, system: system, tools: nil, executeToolCall: nil, onToken: onToken)
    }

    /// Stream with optional tool calling support. When a tool call is detected the provider
    /// executes it via `executeToolCall`, appends the result to the conversation, and makes
    /// a follow‑up streaming request — all transparently to the caller.
    func streamWithTools(
        messages: [LLMMessage],
        system: String,
        tools: [[String: Any]]?,
        executeToolCall: ((String, String) async -> String)?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let body = buildBody(messages: messages, system: system, stream: true, tools: tools)
        let request = try buildRequest(body: body)

        let (byteStream, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errorData = Data()
            for try await byte in byteStream { errorData.append(byte) }
            try validate(response: response, data: errorData)
            return ""
        }

        // Accumulate text and incremental tool-call arguments in parallel
        var accumulatedText = ""
        var toolCallAccumulators: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }
            guard let data = payload.data(using: .utf8) else { continue }

            struct Event: Decodable {
                struct Choice: Decodable {
                    struct Delta: Decodable {
                        let content: String?
                        let toolCalls: [ToolCallDelta]?
                    }
                    let delta: Delta
                    let finishReason: String?
                }
                let choices: [Choice]
            }

            struct ToolCallDelta: Decodable {
                let index: Int
                let id: String?
                let function: FunctionDelta?
            }

            struct FunctionDelta: Decodable {
                let name: String?
                let arguments: String?
            }

            guard let event = try? JSONDecoder().decode(Event.self, from: data),
                  let choice = event.choices.first else { continue }

            if let text = choice.delta.content {
                accumulatedText += text
                onToken(text)
            }

            if let deltas = choice.delta.toolCalls {
                for delta in deltas {
                    var acc = toolCallAccumulators[delta.index] ?? ("", "", "")
                    if let id = delta.id { acc.id = id }
                    if let name = delta.function?.name { acc.name = name }
                    if let args = delta.function?.arguments { acc.args += args }
                    toolCallAccumulators[delta.index] = acc
                }
            }

            if let reason = choice.finishReason {
                finishReason = reason
            }
        }

        // No tool calls → return accumulated text
        guard finishReason == "tool_calls", !toolCallAccumulators.isEmpty, let executor = executeToolCall else {
            return accumulatedText
        }

        // Build assistant message with the tool calls
        let sortedCalls = toolCallAccumulators.sorted(by: { $0.key < $1.key })
        let toolCalls: [ToolCall] = sortedCalls.map { _, acc in
            ToolCall(id: acc.id, type: "function", function: .init(name: acc.name, arguments: acc.args))
        }
        let assistantMsg = LLMMessage.assistant(toolCalls: toolCalls)

        // Execute each tool and collect results
        var allMessages = messages
        allMessages.append(assistantMsg)

        for tc in toolCalls {
            let result = await executor(tc.function.name, tc.function.arguments)
            // Try to parse the tool result from the executor; it returns status text
            allMessages.append(.toolResult(result, toolCallID: tc.id))
        }

        // Follow-up stream WITHOUT tools, so the LLM just responds with natural language
        return try await streamWithTools(
            messages: allMessages,
            system: system,
            tools: nil,
            executeToolCall: nil,
            onToken: onToken
        )
    }

    // MARK: - Private

    private func buildBody(messages: [LLMMessage], system: String, stream: Bool, tools: [[String: Any]]? = nil) -> [String: Any] {
        var allMessages: [[String: Any]] = []
        if !system.isEmpty {
            allMessages.append(["role": "system", "content": system])
        }
        allMessages += messages.map { messagePayload($0) }

        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": allMessages,
        ]

        if let tools {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        return body
    }

    private func messagePayload(_ message: LLMMessage) -> [String: Any] {
        if let toolCallID = message.toolCallID {
            return [
                "role": "tool",
                "content": message.content,
                "tool_call_id": toolCallID,
            ]
        }

        if let toolCalls = message.toolCalls {
            return [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": tc.type,
                        "function": [
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        ],
                    ]
                },
            ]
        }

        guard let imageBase64 = message.imageBase64 else {
            return ["role": message.role, "content": message.content]
        }

        return [
            "role": message.role,
            "content": [
                ["type": "text", "text": message.content],
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
        if requiresAuth {
            guard !apiKey.isEmpty else { throw LLMError.invalidKey }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if requiresAuth {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
