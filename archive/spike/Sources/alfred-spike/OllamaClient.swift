import Foundation

/// Thin client for the local Ollama server (default http://localhost:11434).
/// Phase 0 goal: prove `hermes3:8b` returns a valid structured tool call.
struct OllamaClient {
    var baseURL = URL(string: "http://localhost:11434")!
    // Default to hermes3:8b; override with ALFRED_MODEL for testing against
    // another local model (e.g. the llama3.1:8b Hermes 3 is fine-tuned from).
    var model = ProcessInfo.processInfo.environment["ALFRED_MODEL"] ?? "hermes3:8b"

    struct ToolCall {
        let name: String
        let arguments: [String: Any]
    }

    /// Send one chat turn with a single tool defined, return any tool calls Hermes emits.
    /// This is the exact primitive Alfred's agent loop will depend on.
    func toolCall(userPrompt: String, tool: [String: Any]) async throws -> (calls: [ToolCall], raw: String) {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "user", "content": userPrompt]
            ],
            "tools": [tool],
            // keep it deterministic for a capability test
            "options": ["temperature": 0]
        ]
        let url = baseURL.appendingPathComponent("api/chat")
        let data = try await HTTP.postJSON(url, body: body)

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = json?["message"] as? [String: Any]
        let raw = String(data: data, encoding: .utf8) ?? ""

        var calls: [ToolCall] = []
        if let toolCalls = message?["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                // Ollama returns arguments as an object (sometimes a JSON string).
                var args: [String: Any] = [:]
                if let obj = fn["arguments"] as? [String: Any] {
                    args = obj
                } else if let str = fn["arguments"] as? String,
                          let parsed = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any] {
                    args = parsed
                }
                calls.append(ToolCall(name: name, arguments: args))
            }
        }
        return (calls, raw)
    }

    struct AssistantTurn {
        let content: String
        let toolCalls: [ToolCall]
        let rawMessage: [String: Any]   // append verbatim to the running message list
    }

    /// One assistant turn over a running message list, with tools available.
    /// Returns the assistant's text + any tool calls + the raw message to append.
    func chatTurn(messages: [[String: Any]], tools: [[String: Any]]) async throws -> AssistantTurn {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages,
            "tools": tools,
            "options": ["temperature": 0]
        ]
        let url = baseURL.appendingPathComponent("api/chat")
        let data = try await HTTP.postJSON(url, body: body)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["message"] as? [String: Any]) ?? [:]
        let content = (message["content"] as? String) ?? ""

        var calls: [ToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
                var args: [String: Any] = [:]
                if let obj = fn["arguments"] as? [String: Any] { args = obj }
                else if let str = fn["arguments"] as? String,
                        let parsed = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any] { args = parsed }
                calls.append(ToolCall(name: name, arguments: args))
            }
        }
        return AssistantTurn(content: content, toolCalls: calls, rawMessage: message)
    }

    /// Embed text with nomic-embed-text. Returns the vector.
    func embed(_ text: String, model: String = "nomic-embed-text") async throws -> [Float] {
        let url = baseURL.appendingPathComponent("api/embed")
        let data = try await HTTP.postJSON(url, body: ["model": model, "input": text])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // /api/embed returns {"embeddings": [[...]]}
        if let arrs = json?["embeddings"] as? [[Double]], let first = arrs.first {
            return first.map { Float($0) }
        }
        // fallback for older /api/embeddings shape
        if let arr = json?["embedding"] as? [Double] {
            return arr.map { Float($0) }
        }
        throw HTTP.Error(description: "no embedding in response: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
    }

    /// Plain chat completion (no tools) — used for RAG answers.
    func chat(system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "options": ["temperature": 0.2]
        ]
        let url = baseURL.appendingPathComponent("api/chat")
        let data = try await HTTP.postJSON(url, body: body)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = json?["message"] as? [String: Any]
        return (message?["content"] as? String) ?? ""
    }

    /// Chat with forced JSON output (Ollama `format: json`). Returns the raw JSON string.
    func chatJSON(system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "options": ["temperature": 0]
        ]
        let url = baseURL.appendingPathComponent("api/chat")
        let data = try await HTTP.postJSON(url, body: body)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = json?["message"] as? [String: Any]
        return (message?["content"] as? String) ?? "{}"
    }

    /// Is the server up and is the target model present?
    func status() async -> (up: Bool, hasModel: Bool, detail: String) {
        let url = baseURL.appendingPathComponent("api/tags")
        do {
            let data = try await HTTP.get(url, timeout: 5)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let models = (json?["models"] as? [[String: Any]]) ?? []
            let names = models.compactMap { $0["name"] as? String }
            let has = names.contains { $0.hasPrefix(model) }
            return (true, has, has ? "model present" : "model \(model) NOT pulled. Installed: \(names.joined(separator: ", "))")
        } catch {
            return (false, false, "ollama unreachable: \(error)")
        }
    }
}
