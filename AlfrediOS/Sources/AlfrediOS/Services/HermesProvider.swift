import Foundation
import AlfredCore

/// An `LLMProvider` that talks to the Hermes agent's OpenAI-compatible
/// endpoint at `{baseURL}/v1/chat/completions`. Works against a local Hermes
/// server (localhost:8080 in the simulator) or any remote URL configured in
/// Settings. Conforms to AlfredCore's `LLMProvider` (and `ToolCallingProvider`),
/// so it routes through `ProviderRouter` like every other provider.
final class HermesProvider: LLMProvider, ToolCallingProvider {
    let id = "hermes"
    let displayName = "Hermes"
    var model: String
    var baseURL: URL
    var apiKey: String

    init(baseURL: URL, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    // MARK: - LLMProvider

    func complete(messages: [LLMMessage], system: String) async throws -> String {
        let request = try makeRequest(messages: messages, system: system, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("no HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 { throw LLMError.rateLimited() }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.inferenceFailed("HTTP \(http.statusCode): \(body.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.inferenceFailed("malformed completion response")
        }
        return text
    }

    func stream(
        messages: [LLMMessage],
        system: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // Non-streaming path for the first cut: deliver the full reply as one
        // token so streaming call sites behave identically.
        let text = try await complete(messages: messages, system: system)
        onToken(text)
        return text
    }

    // MARK: - ToolCallingProvider

    /// Streams a tool-calling turn from the Hermes endpoint.
    ///
    /// Reads the SSE stream line by line. Content fragments become
    /// `.contentDelta`; `delta.tool_calls` fragments are accumulated per
    /// `tool_call` index (arguments arrive split across chunks — Hermes sends
    /// `{"function": {"arguments": "{\"path\":"` and the rest in later
    /// chunks), and each accumulation emits `.toolCallDelta` carrying the
    /// growing call. Exactly one `.done` is emitted when the stream finishes.
    /// Completed tool calls are surfaced through `.toolCallDelta` (and the
    /// caller executes them — this provider's job is faithful emission).
    func streamWithTools(
        messages: [LLMMessage],
        system: String,
        tools: [any LLMTool]?,
        executeToolCall: ((String, String) async -> String)?,
        onEvent: @escaping @Sendable (LLMStreamEvent) -> Void
    ) async throws -> String {
        let request = try makeRequest(messages: messages, system: system, stream: true, tools: tools)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("no HTTP response")
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            if http.statusCode == 429 { throw LLMError.rateLimited(body) }
            throw LLMError.inferenceFailed("HTTP \(http.statusCode): \(body.prefix(200))")
        }

        var accumulator = ToolCallAccumulator()
        var fullText = ""

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any]
            else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                fullText += content
                onEvent(.contentDelta(content))
            }

            if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]], !toolCallDeltas.isEmpty {
                // Arguments stream in split across chunks; accumulate per index.
                for call in accumulator.accumulate(deltas: toolCallDeltas) {
                    onEvent(.toolCallDelta(call))
                }
            }
        }

        onEvent(.done)
        return fullText
    }

    // MARK: - Request building

    /// Builds the request body, mapping AlfredCore messages to the
    /// OpenAI-compatible wire shape: `tool` messages carry `tool_call_id`,
    /// assistant messages may carry completed `tool_calls`, and `tools`
    /// becomes the `tools` array when present.
    private func makeRequest(
        messages: [LLMMessage],
        system: String,
        stream: Bool,
        tools: [any LLMTool]? = nil
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var payloadMessages: [[String: Any]] = []
        if !system.isEmpty {
            payloadMessages.append(["role": "system", "content": system])
        }
        for message in messages {
            if let imageBase64 = message.imageBase64, let media = message.imageMediaType {
                payloadMessages.append([
                    "role": message.role,
                    "content": [
                        ["type": "text", "text": message.content],
                        ["type": "image_url", "image_url": ["url": "data:\(media);base64,\(imageBase64)"]],
                    ],
                ])
            } else {
                payloadMessages.append(["role": message.role, "content": message.content])
            }

            // Tool results need their call id; assistant turns with completed
            // tool calls must echo them back so the model sees its own calls.
            if let toolCallID = message.toolCallID, message.role == "tool" {
                payloadMessages[payloadMessages.count - 1]["tool_call_id"] = toolCallID
            }
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                payloadMessages[payloadMessages.count - 1]["tool_calls"] = toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": call.type,
                        "function": ["name": call.function.name, "arguments": call.function.arguments],
                    ]
                }
            }
        }

        var body: [String: Any] = ["model": model, "messages": payloadMessages, "stream": stream]
        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { $0.definition.payload }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
