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
        let request = MCPRequest(method: "tools/list", params: [:])
        let response = try await send(request: request, config: serverConfig)
        return response
    }

    func callTool(server: String, name: String, arguments: [String: Any]) async throws -> String {
        guard let config = loadConfig(), let serverConfig = config.mcpServers[server] else {
            throw LLMError.networkError("MCP server \"\(server)\" not found in config.")
        }
        let request = MCPRequest(method: "tools/call", params: ["name": name, "arguments": arguments])
        let response = try await send(request: request, config: serverConfig)
        return response
    }

    private func loadConfig() -> MCPConfig? {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(MCPConfig.self, from: data)
        else { return nil }
        return config
    }

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
            do {
                try process.run()

                let requestData = try JSONEncoder().encode(request)
                stdinPipe.fileHandleForWriting.write(requestData)
                try stdinPipe.fileHandleForWriting.close()

                let group = DispatchGroup()
                var outputData = Data()
                var errorData = Data()

                group.enter()
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        group.leave()
                    } else {
                        outputData.append(data)
                    }
                }

                group.enter()
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        group.leave()
                    } else {
                        errorData.append(data)
                    }
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    if process.isRunning {
                        process.terminate()
                    }
                    group.leave()
                }

                group.wait()
                process.waitUntilExit()

                if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8), !errorString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: LLMError.networkError("MCP stderr: \(errorString.trimmingCharacters(in: .whitespacesAndNewlines))"))
                    return
                }

                guard let responseString = String(data: outputData, encoding: .utf8) else {
                    continuation.resume(throwing: LLMError.networkError("MCP response was not valid UTF-8."))
                    return
                }

                continuation.resume(returning: responseString.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                continuation.resume(throwing: LLMError.networkError("MCP process launch failed: \(error.localizedDescription)"))
            }
        }
    }
}

private struct MCPRequest: Codable {
    let jsonrpc = "2.0"
    let id = 1
    let method: String
    let params: [String: AnyJSON]

    init(method: String, params: [String: Any]) {
        self.method = method
        self.params = params.mapValues { AnyJSON(wrapped: $0) }
    }
}

private struct AnyJSON: Codable {
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
