import Foundation

// MARK: - Errors

public enum VertusError: Error, Equatable {
    case badURL
    case unauthorized                 // 401 — token missing/stale
    case notFound                     // 404 — agent or run unknown
    case conflict(String)             // 409 — primary/busy (readable message)
    case server(Int, String)          // any other non-2xx
    case decoding
    case transport(String)            // network layer

    public var localizedDescription: String {
        switch self {
        case .badURL: return "Invalid server URL"
        case .unauthorized: return "Unauthorized — check the token in ~/.vertus/token"
        case .notFound: return "Not found (agent or run does not exist)"
        case .conflict(let m): return m.isEmpty ? "Conflict" : m
        case .server(let code, let m): return "Server error \(code)\(m.isEmpty ? "" : ": \(m)")"
        case .decoding: return "Could not decode the server response"
        case .transport(let m): return m
        }
    }
}

// MARK: - Client

/// One HTTP client for every hub endpoint the apps use. All methods are
/// bearer-authed; errors carry the hub's message text so 409s can be shown
/// to the user as sentences, not status codes.
public final class VertusHTTPClient {
    public let config: ServerConfig
    private let session: URLSession

    public init(config: ServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Agents

    public func listAgents() async throws -> [Agent] {
        try await get([Agent].self, path: "/api/agents", key: "agents")
    }

    public func agent(_ id: String) async throws -> Agent {
        try await get(Agent.self, path: "/api/agents/\(escaped(id))", key: nil)
    }

    public func status(_ id: String) async throws -> AgentStatus {
        try await get(AgentStatus.self, path: "/api/agents/\(escaped(id))/status", key: nil)
    }

    /// POST /api/agents with the full v3 editable field set (name required;
    /// everything else optional — nulls mean "inherit fleet default").
    public func createAgent(name: String, title: String? = nil,
                            description: String? = nil, persona: String? = nil,
                            model: String? = nil, provider: String? = nil,
                            color: String? = nil, emoji: String? = nil,
                            autonomy: String? = nil,
                            computerUse: Bool? = nil,
                            cuaTargets: [String]? = nil,
                            clearTargets: Bool = false) async throws -> Agent {
        var body: [String: Any] = ["name": name]
        appendEditable(&body, title: title, description: description, persona: persona,
                       model: model, provider: provider, color: color,
                       emoji: emoji, autonomy: autonomy, computerUse: computerUse,
                       cuaTargets: cuaTargets, clearTargets: clearTargets)
        return try await send("POST", path: "/api/agents", body: body)
    }

    /// PATCH /api/agents/<id>. Returns the updated profile plus whether a
    /// gateway respawn is pending (a turn in flight keeps the old gateway).
    public func updateAgent(_ id: String, title: String? = nil,
                            description: String? = nil, persona: String? = nil,
                            model: String? = nil, provider: String? = nil,
                            color: String? = nil, emoji: String? = nil,
                            autonomy: String? = nil,
                            computerUse: Bool? = nil,
                            cuaTargets: [String]? = nil,
                            clearTargets: Bool = false) async throws -> (Agent, respawnPending: Bool) {
        var body: [String: Any] = [:]
        appendEditable(&body, title: title, description: description, persona: persona,
                       model: model, provider: provider, color: color,
                       emoji: emoji, autonomy: autonomy, computerUse: computerUse,
                       cuaTargets: cuaTargets, clearTargets: clearTargets)
        guard !body.isEmpty else {
            // Empty PATCH: fetch and return unchanged (no respawn).
            return (try await agent(id), false)
        }
        let json = try await sendJSON("PATCH", path: "/api/agents/\(escaped(id))", body: body)
        let decoder = JSONDecoder.vertus()
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let agent = try? decoder.decode(Agent.self, from: data) else {
            throw VertusError.decoding
        }
        let pending = (json as? [String: Any])?["respawn_pending"] as? Bool ?? false
        return (agent, pending)
    }

    /// GET /api/fleet/screens — declared screen targets, who runs each, who
    /// waits, and the policy caveat (declaration, not a sandbox).
    public func fleetScreens() async throws -> FleetScreensResponse {
        try await get(FleetScreensResponse.self, path: "/api/fleet/screens", key: nil)
    }

    public func deleteAgent(_ id: String) async throws -> DeleteResult {
        try await send("DELETE", path: "/api/agents/\(escaped(id))", body: [String: Any]())
    }

    // MARK: - Prompts

    /// POST /api/prompt. Queues the turn; the server returns immediately
    /// with the run_id. Busy agents queue server-side — callers never block.
    /// `sourceLabel` maps to X-Vertus-Client: anything but "local" is treated
    /// by the hub as a remote (approved-only) turn, so desktop apps send
    /// "local".
    public func prompt(agentID: String, text: String,
                       sourceLabel: String = "local") async throws -> PromptAcceptance {
        let body: [String: Any] = ["text": text, "agent_id": agentID]
        var req = try request("POST", path: "/api/prompt")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sourceLabel, forHTTPHeaderField: "X-Vertus-Client")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VertusError.transport("Not an HTTP response") }
        guard http.statusCode == 202 else {
            throw Self.error(from: http, data: data)
        }
        let decoder = JSONDecoder.vertus()
        guard let accepted = try? decoder.decode(PromptAcceptance.self, from: data),
              accepted.accepted else {
            throw VertusError.decoding
        }
        return accepted
    }

    // MARK: - History

    /// GET /api/agents/<id>/messages — newest-first; `before` = message id
    /// cursor (exclusive). Returns rows in descending id order.
    public func messages(agentID: String, limit: Int = 50, before: Int? = nil) async throws -> [MessageRow] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        let rows: [MessageRow] = try await get([MessageRow].self, path: "/api/agents/\(escaped(agentID))/messages", key: "messages", query: q)
        return rows
    }

    public func runs(agentID: String? = nil, state: String? = nil,
                     limit: Int = 50, before: Double? = nil) async throws -> [RunRow] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let agentID { q.append(URLQueryItem(name: "agent_id", value: agentID)) }
        if let state { q.append(URLQueryItem(name: "state", value: state)) }
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        return try await get([RunRow].self, path: "/api/runs", key: "runs", query: q)
    }

    /// GET /api/runs/<run_id> — the run row plus its chronological messages.
    public func runDetail(_ runID: String) async throws -> (RunRow, [MessageRow]) {
        let decoder = JSONDecoder.vertus()
        let json = try await sendJSON("GET", path: "/api/runs/\(escaped(runID))", body: nil)
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let run = try? decoder.decode(RunRow.self, from: data),
              let msgs = (json as? [String: Any])?["messages"] as? [[String: Any]],
              let messagesData = try? JSONSerialization.data(withJSONObject: msgs),
              let messages = try? decoder.decode([MessageRow].self, from: messagesData) else {
            throw VertusError.decoding
        }
        return (run, messages)
    }

    public func fleetActivity(limit: Int = 20) async throws -> [FleetActivityItem] {
        try await get([FleetActivityItem].self, path: "/api/fleet/activity",
                      key: "activity", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    // MARK: - Skills (QuickBar autocomplete)

    public func slashCommands() async throws -> [SlashCommandInfo] {
        let decoder = JSONDecoder.vertus()
        let json = try await sendJSON("GET", path: "/api/skills", body: nil)
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let commands = try? decoder.decode([SlashCommandInfo].self, from: data) else {
            throw VertusError.decoding
        }
        return commands
    }

    // MARK: - Internals

    private func appendEditable(_ body: inout [String: Any], title: String?,
                                description: String?, persona: String?,
                                model: String?, provider: String?,
                                color: String?, emoji: String?, autonomy: String?,
                                computerUse: Bool? = nil,
                                cuaTargets: [String]? = nil,
                                clearTargets: Bool = false) {
        // Only non-nil keys are sent; PATCH semantics treat null as clear.
        if let title { body["title"] = title }
        if let description { body["description"] = description }
        if let persona { body["persona"] = persona }
        if let model { body["model"] = model }
        if let provider { body["provider"] = provider }
        if let color { body["color"] = color }
        if let emoji { body["emoji"] = emoji }
        if let autonomy { body["autonomy"] = autonomy }
        if let computerUse { body["computer_use"] = computerUse }
        if clearTargets {
            // Explicit "unrestricted": cua_targets: null clears the list.
            body["cua_targets"] = NSNull()
        } else if let cuaTargets {
            body["cua_targets"] = cuaTargets
        }
    }

    private func escaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func request(_ method: String, path: String,
                         query: [URLQueryItem]? = nil) throws -> URLRequest {
        guard var comps = URLComponents(string: config.baseURL) else { throw VertusError.badURL }
        comps.path = path
        comps.queryItems = query
        guard let url = comps.url else { throw VertusError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        return req
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, key: String?,
                                   query: [URLQueryItem]? = nil) async throws -> T {
        let json = try await sendJSON("GET", path: path, body: nil, query: query)
        return try decode(type, from: json, key: key)
    }

    private func send<T: Decodable>(_ method: String, path: String,
                                    body: [String: Any]) async throws -> T {
        let json = try await sendJSON(method, path: path, body: body)
        return try decode(T.self, from: json, key: nil)
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: Any, key: String?) throws -> T {
        let decoder = JSONDecoder.vertus()
        let object: Any
        if let key {
            guard let dict = json as? [String: Any], let wrapped = dict[key] else {
                throw VertusError.decoding
            }
            object = wrapped
        } else {
            object = json
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? decoder.decode(type, from: data) else {
            throw VertusError.decoding
        }
        return value
    }

    private func sendJSON(_ method: String, path: String, body: [String: Any]?,
                          query: [URLQueryItem]? = nil) async throws -> Any {
        var req = try request(method, path: path, query: query)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw VertusError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw VertusError.transport("Not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(from: http, data: data)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Map a non-2xx response to a typed error, carrying the hub's "error"
    /// text (e.g. "primary agent cannot be deleted") so the UI can show it.
    private static func error(from http: HTTPURLResponse, data: Data) -> VertusError {
        var message = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String {
            message = err
        }
        switch http.statusCode {
        case 401: return .unauthorized
        case 404: return .notFound
        case 409: return .conflict(message)
        default: return .server(http.statusCode, message)
        }
    }
}

/// Slash-command catalog entry (GET /api/skills → {"commands": [...]}).
public struct SlashCommandInfo: Codable, Identifiable, Equatable {
    public var name: String
    public var description: String
    public var id: String { name }
}