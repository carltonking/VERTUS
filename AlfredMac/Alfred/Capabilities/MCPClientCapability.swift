import Foundation

struct MCPServerConfig: Decodable {
    let command: String
    let args: [String]
    let env: [String: String]?
}

struct MCPConfig: Decodable {
    let mcpServers: [String: MCPServerConfig]
}

struct MCPClientCapability {
    private let configURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appending(path: ".alfred/mcp_servers.json")
    }

    func availableServers() -> [String] {
        guard let config = loadConfig() else { return [] }
        return Array(config.mcpServers.keys).sorted()
    }

    func listTools(server: String) async throws -> String {
        guard let config = loadConfig(), let serverConfig = config.mcpServers[server] else {
            throw LLMError.networkError("MCP server \"\(server)\" not found in config.")
        }
        let request = MCPRequest(id: 2, method: "tools/list", params: [:])
        let response = try await send(request: request, config: serverConfig)
        return response
    }

    func callTool(server: String, name: String, arguments: [String: Any]) async throws -> String {
        guard let config = loadConfig(), let serverConfig = config.mcpServers[server] else {
            throw LLMError.networkError("MCP server \"\(server)\" not found in config.")
        }
        let request = MCPRequest(id: 2, method: "tools/call", params: ["name": name, "arguments": arguments])
        let response = try await send(request: request, config: serverConfig)
        return response
    }

    private func loadConfig() -> MCPConfig? {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(MCPConfig.self, from: data)
        else { return nil }
        return config
    }

    // ponytail: one process per call, correct over fast. The handshake (initialize ->
    // notifications/initialized -> request) is required by the MCP spec; spec-compliant
    // servers reject a bare tools/list. Upgrade path if call latency matters: keep one
    // long-lived Process per server keyed by JSON-RPC id and cache tools/list.
    private func send(request: MCPRequest, config: MCPServerConfig) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + config.args

        if let env = config.env {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env {
                environment[key] = value
            }
            process.environment = environment
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            let state = MCPCallState(process: process, stdout: stdoutPipe, stderr: stderrPipe, continuation: continuation)

            // Collect stderr only for diagnostics — npx-based servers log to stderr in normal
            // operation, so it must NOT be treated as a failure on its own (the old code did).
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                state.appendStderr(handle.availableData)
            }

            // MCP stdio transport is newline-delimited JSON-RPC. Buffer stdout, parse complete
            // lines, and resolve on the first response whose id matches the real request.
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    state.finishClosedBeforeResponse()
                    return
                }
                state.consume(chunk, matchingId: request.id)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                state.finishTimeout()
            }

            do {
                try process.run()
                let stdin = stdinPipe.fileHandleForWriting
                try stdin.write(contentsOf: MCPRequest.initialize().encodedLine())
                try stdin.write(contentsOf: MCPNotification.initialized().encodedLine())
                try stdin.write(contentsOf: request.encodedLine())
                try? stdin.close()
            } catch {
                state.finish(.failure(LLMError.networkError("MCP process launch failed: \(error.localizedDescription)")))
            }
        }
    }
}

/// Owns the single-resume / cleanup bookkeeping for one MCP call so the read handlers,
/// EOF, and timeout can all race to finish exactly once.
private final class MCPCallState {
    private let process: Process
    private let stdout: Pipe
    private let stderr: Pipe
    private let continuation: CheckedContinuation<String, Error>
    private let lock = NSLock()
    private var resumed = false
    private var buffer = Data()
    private var errorData = Data()

    init(process: Process, stdout: Pipe, stderr: Pipe, continuation: CheckedContinuation<String, Error>) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
        self.continuation = continuation
    }

    func appendStderr(_ data: Data) {
        lock.lock(); errorData.append(data); lock.unlock()
    }

    func consume(_ chunk: Data, matchingId targetId: Int) {
        lock.lock()
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = obj["id"] as? Int, id == targetId
            else { continue }  // initialize response (id 1) and notifications are ignored

            lock.unlock()
            if let err = obj["error"] as? [String: Any] {
                let message = (err["message"] as? String) ?? "\(err)"
                finish(.failure(LLMError.networkError("MCP error: \(message)")))
            } else if let result = obj["result"],
                      let data = try? JSONSerialization.data(withJSONObject: result) {
                finish(.success(String(data: data, encoding: .utf8) ?? ""))
            } else {
                finish(.success(String(data: lineData, encoding: .utf8) ?? ""))
            }
            return
        }
        lock.unlock()
    }

    func finishClosedBeforeResponse() {
        lock.lock(); let stderrText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; lock.unlock()
        let suffix = stderrText.isEmpty ? "" : ": \(stderrText)"
        finish(.failure(LLMError.networkError("MCP server closed before responding\(suffix)")))
    }

    func finishTimeout() {
        finish(.failure(LLMError.networkError("MCP request timed out.")))
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        continuation.resume(with: result)
    }
}

struct MCPRequest: Codable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyJSON]

    init(id: Int, method: String, params: [String: Any]) {
        self.id = id
        self.method = method
        self.params = params.mapValues { AnyJSON(wrapped: $0) }
    }

    /// MCP `initialize` request (id 1) — the mandatory first message of the handshake.
    static func initialize() -> MCPRequest {
        MCPRequest(id: 1, method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Alfred", "version": "1.0"],
        ])
    }

    /// Serialize as one newline-delimited JSON-RPC frame for the stdio transport.
    func encodedLine() -> Data {
        (try? JSONEncoder().encode(self)).map { $0 + Data([0x0A]) } ?? Data([0x0A])
    }
}

/// A JSON-RPC notification (no id, no response). Used for `notifications/initialized`,
/// which the client must send after `initialize` to complete the handshake.
struct MCPNotification: Codable {
    let jsonrpc = "2.0"
    let method: String

    static func initialized() -> MCPNotification { MCPNotification(method: "notifications/initialized") }

    func encodedLine() -> Data {
        (try? JSONEncoder().encode(self)).map { $0 + Data([0x0A]) } ?? Data([0x0A])
    }
}

struct AnyJSON: Codable {
    let wrapped: Any

    init(wrapped: Any) {
        self.wrapped = wrapped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = wrapped as? String { try container.encode(value) }
        else if let value = wrapped as? Int { try container.encode(value) }
        else if let value = wrapped as? Double { try container.encode(value) }
        else if let value = wrapped as? Bool { try container.encode(value) }
        else if let value = wrapped as? [String: Any] {
            let dict = value.mapValues { AnyJSON(wrapped: $0) }
            try container.encode(dict)
        }
        else if let value = wrapped as? [Any] {
            let arr = value.map { AnyJSON(wrapped: $0) }
            try container.encode(arr)
        }
        else {
            try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { wrapped = value }
        else if let value = try? container.decode(Int.self) { wrapped = value }
        else if let value = try? container.decode(Double.self) { wrapped = value }
        else if let value = try? container.decode(Bool.self) { wrapped = value }
        else if let value = try? container.decode([String: AnyJSON].self) { wrapped = value.mapValues(\.wrapped) }
        else if let value = try? container.decode([AnyJSON].self) { wrapped = value.map(\.wrapped) }
        else { wrapped = NSNull() }
    }
}
