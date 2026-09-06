import Darwin
import Foundation

/// A hermetic stub of the VERTUS hub (vertus/server/vertus_server.py) for
/// VertusKit unit tests. Real sockets so the full client path (URLSession →
/// SSE parsing → store) is exercised, but every behavior is test-controlled:
/// events are injected programmatically, connections can be dropped, and
/// endpoints can be forced to error.
///
/// Unlike the real hub's SQLite store, the stub keeps its event log in
/// memory; since= replay and live tail work the same way (replay seq > since,
/// then live).
final class StubHub {
    struct ReceivedRequest {
        let method: String
        let path: String
        let rawPath: String
        let body: [String: Any]?
    }

    // Test knobs.
    var forceStatus409 = false
    var forceDelete409 = false
    var forceQueueDepth = 0
    var respawnPending = false

    private(set) var port: UInt16 = 0
    private(set) var received: [ReceivedRequest] = []
    var receivedCount: Int { lock.withLock { received.count } }

    // Agent store (id → profile dict, snake_case like the hub).
    private var agents: [String: [String: Any]] = [:]
    private var agentOrder: [String] = []
    private var primaryID: String?
    private var agentSeq = 0

    // Runs + messages (mirror of the hub's tables).
    private var runs: [[String: Any]] = []
    private var messages: [[String: Any]] = []
    private var runSeq = 0
    private var messageSeq = 0

    // Bot-to-bot messaging (mirror of bot_messages/threads).
    private var botThreads: [[String: Any]] = []
    private var botMessages: [[String: Any]] = []

    // Event log: global seq → envelope (type/agent_id/run_id/ts + payload).
    private var eventLog: [Int: [String: Any]] = [:]
    private var liveSeq = 0

    // Open SSE connections (file descriptors).
    private var sseFDs: [Int32] = []

    // Per-run accumulated assistant text (folds into a message row on
    // done/error, mirroring the hub's _end_run).
    private var runText: [String: String] = [:]

    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()
    private var threads: [Thread] = []

    // MARK: - Test seeds (message bus + runs)

    func addBotThread(_ thread: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        botThreads.append(thread)
    }

    func addBotMessage(_ msg: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        botMessages.append(msg)
    }

    func addRun(_ run: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        runs.append(run)
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw StubHubError.socket }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw StubHubError.bind }
        guard listen(listenFD, 16) == 0 else { throw StubHubError.listen }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &len)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
        running = true

        // Accept loop.
        let acceptThread = Thread { [weak self] in
            while let self, self.running {
                let fd = accept(self.listenFD, nil, nil)
                guard fd >= 0 else { continue }
                self.threads.append(Thread { self.handleConnection(fd) })
                self.threads.last?.start()
            }
        }
        acceptThread.start()
        threads.append(acceptThread)
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        lock.withLock {
            for fd in sseFDs { shutdown(fd, SHUT_RDWR) }
            sseFDs.removeAll()
        }
    }

    enum StubHubError: Error { case socket, bind, listen }

    // MARK: - Test controls

    /// Add an event to the log (global seq) and push it to open SSE
    /// connections. Missing envelope fields are filled in.
    @discardableResult
    func inject(type: String, agentID: String? = nil, runID: String? = nil,
                payload: [String: Any] = [:]) -> Int {
        lock.withLock {
            liveSeq += 1
            var envelope = payload
            envelope["type"] = type
            if let agentID { envelope["agent_id"] = agentID }
            if let runID { envelope["run_id"] = runID }
            envelope["seq"] = liveSeq
            envelope["ts"] = Date().timeIntervalSince1970
            eventLog[liveSeq] = envelope

            // Mirrors the hub's run lifecycle: text accumulates per run,
            // terminal events fold it into an assistant message row and
            // flip the run row's state.
            if let runID, let agentID {
                if type == "text", let text = envelope["text"] as? String {
                    runText[runID, default: ""] += text
                    if var run = runs.first(where: { $0["run_id"] as? String == runID }) {
                        if run["state"] as? String == "queued" {
                            run["state"] = "running"
                            run["started_at"] = Date().timeIntervalSince1970
                            if let i = runs.firstIndex(where: { $0["run_id"] as? String == runID }) {
                                runs[i] = run
                            }
                        }
                    }
                }
                if type == "done" || type == "error" {
                    let text = runText[runID] ?? ""
                    if !text.isEmpty {
                        messageSeq += 1
                        messages.append([
                            "id": messageSeq,
                            "run_id": runID,
                            "agent_id": agentID,
                            "role": "assistant",
                            "text": text,
                            "created_at": Date().timeIntervalSince1970,
                        ])
                    }
                    if var run = runs.first(where: { $0["run_id"] as? String == runID }) {
                        run["state"] = type
                        run["ended_at"] = Date().timeIntervalSince1970
                        if let i = runs.firstIndex(where: { $0["run_id"] as? String == runID }) {
                            runs[i] = run
                        }
                    }
                    runText.removeValue(forKey: runID)
                }
            }

            if let data = try? JSONSerialization.data(withJSONObject: envelope) {
                let frame = "data: \(String(data: data, encoding: .utf8)!)\n\n"
                for fd in sseFDs {
                    frame.withCString { buf in
                        _ = send(fd, buf, strlen(buf), 0)
                    }
                }
            }
            return liveSeq
        }
    }

    /// Close every open SSE connection (simulates a network drop). Shutdown
    /// only: the connection thread's recv wakes up, exits, and its own defer
    /// closes the fd exactly once (no double-close of a possibly-reused fd).
    func dropAllSSE() {
        lock.withLock {
            for fd in sseFDs { shutdown(fd, SHUT_RDWR) }
            sseFDs.removeAll()
        }
    }

    var openSSECount: Int { lock.withLock { sseFDs.count } }

    /// Open an SSE connection exactly as a client would (for asserting the
    /// server side of replay).
    func openRawSSE() -> RawSSEConnection? {
        RawSSEConnection(port: port)
    }

    // MARK: - Connection handling

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        guard let request = readRequest(fd) else { return }
        lock.withLock {
            received.append(request)
        }
        if request.path.hasPrefix("/api/events") {
            serveSSE(fd, request: request)
            return
        }
        respond(fd, request: request)
    }

    private func readRequest(_ fd: Int32) -> ReceivedRequest? {
        var buffer = Data()
        var byte: UInt8 = 0
        var deadline = Date().addingTimeInterval(5)
        // Read headers.
        while Date() < deadline, buffer.count < 65536 {
            let n = read(fd, &byte, 1)
            if n <= 0 {
                if buffer.isEmpty { return nil }
                break
            }
            buffer.append(byte)
            if buffer.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        guard let headerText = String(data: buffer, encoding: .utf8),
              let headerEnd = headerText.range(of: "\r\n\r\n") else { return nil }
        let head = String(headerText[..<headerEnd.lowerBound])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        var path = rawPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        var body: [String: Any]? = nil
        if contentLength > 0 {
            var bodyData = Data()
            while bodyData.count < contentLength {
                var chunk = [UInt8](repeating: 0, count: contentLength - bodyData.count)
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                bodyData.append(contentsOf: chunk.prefix(n))
            }
            if let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                body = obj
            }
        }
        _ = deadline
        return ReceivedRequest(method: method, path: path, rawPath: rawPath, body: body)
    }

    // MARK: - Response writing

    /// Write an HTTP response. Connection: close on EVERY response (the real
    /// hub is Python's HTTP/1.0-style ThreadingHTTPServer, which closes each
    /// connection); this stops URLSession from pooling/reusing connections,
    /// which would otherwise deadlock a subsequent request while an SSE
    /// stream is open. SSE responses carry NO Content-Length so the body is
    /// close-delimited and the stream stays open until we drop it.
    private func writeHTTP(_ fd: Int32, status: Int, headers: [String: String],
                           body: Data?, omitContentLength: Bool = false) {
        let reason = status == 200 ? "OK"
            : status == 202 ? "Accepted"
            : status == 201 ? "Created"
            : status == 400 ? "Bad Request"
            : status == 401 ? "Unauthorized"
            : status == 404 ? "Not Found"
            : status == 409 ? "Conflict"
            : status == 503 ? "Service Unavailable" : "Error"
        // HTTP/1.0 exactly like the real hub (Python ThreadingHTTPServer +
        // default protocol_version): every response closes the connection and
        // the SSE body is close-delimited, so URLSession never pools or
        // mis-frames anything.
        var head = "HTTP/1.0 \(status) \(reason)\r\n"
        if !omitContentLength { head += "Content-Length: \(body?.count ?? 0)\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        payload.withUnsafeBytes { buf in
            _ = send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    private func json(_ status: Int, _ obj: Any) -> (Int, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return (status, data)
    }

    private func respond(_ fd: Int32, request: ReceivedRequest) {
        let path = request.path
        var response: (Int, Data) = (404, Data("{\"error\":\"not found\"}".utf8))
        if request.method == "GET" {
            switch path {
            case "/api/health":
                response = json(200, ["ok": true])
            case "/api/agents":
                response = json(200, ["agents": agents.values.sorted {
                    (agentOrder.firstIndex(of: $0["id"] as! String) ?? 0)
                        < (agentOrder.firstIndex(of: $1["id"] as! String) ?? 0)
                }])
            case "/api/fleet/activity":
                response = json(200, ["activity": runs])
            case "/api/threads":
                response = json(200, ["threads": botThreads])
            case "/api/messages":
                response = json(200, ["messages": botMessages])
            case "/api/runs":
                response = json(200, ["runs": runs])
            default:
                if path.hasPrefix("/api/agents/") {
                    let rest = String(path.dropFirst("/api/agents/".count))
                    if rest.hasSuffix("/status") {
                        let id = String(rest.dropLast("/status".count))
                        response = statusResponse(id)
                    } else if rest.hasSuffix("/messages") {
                        let id = String(rest.dropLast("/messages".count))
                        response = messagesResponse(id, request: request)
                    } else {
                        response = agentResponse(id: rest)
                    }
                } else if path.hasPrefix("/api/runs/") {
                    let id = String(path.dropFirst("/api/runs/".count))
                    response = runDetailResponse(id)
                }
            }
        } else if request.method == "POST" {
            if path.hasPrefix("/api/threads/"), path.hasSuffix("/read") {
                // Mirror the hub: mark every message in the thread read.
                let tid = String(path.dropFirst("/api/threads/".count).dropLast("/read".count))
                var marked = 0
                lock.lock()
                for i in botMessages.indices where botMessages[i]["thread_id"] as? String == tid {
                    if botMessages[i]["read_at"] == nil {
                        botMessages[i]["read_at"] = Date().timeIntervalSince1970
                        marked += 1
                    }
                }
                for i in botThreads.indices where botThreads[i]["thread_id"] as? String == tid {
                    botThreads[i]["unread"] = 0
                }
                lock.unlock()
                response = json(200, ["marked": marked])
            } else if path.hasPrefix("/api/runs/"), path.hasSuffix("/cancel") {
                let id = String(path.dropFirst("/api/runs/".count).dropLast("/cancel".count))
                response = cancelRunResponse(id, request: request)
            } else if path.hasPrefix("/api/agents/"), path.hasSuffix("/cancel") {
                let id = String(path.dropFirst("/api/agents/".count).dropLast("/cancel".count))
                response = cancelAgentResponse(id)
            } else {
                switch path {
                case "/api/prompt":
                    response = promptResponse(request)
                case "/api/agents":
                    response = createAgentResponse(request)
                default:
                    break
                }
            }
        } else if request.method == "PATCH", path.hasPrefix("/api/agents/") {
            let id = String(path.dropFirst("/api/agents/".count))
            response = patchAgentResponse(id, request: request)
        } else if request.method == "DELETE", path.hasPrefix("/api/agents/") {
            let id = String(path.dropFirst("/api/agents/".count))
            response = deleteAgentResponse(id)
        }
        writeHTTP(fd, status: response.0,
                  headers: ["Content-Type": "application/json"],
                  body: response.1)
    }

    private func writeSSEHeaders(_ fd: Int32) {
        writeHTTP(fd, status: 200,
                  headers: ["Content-Type": "text/event-stream",
                            "Cache-Control": "no-cache"],
                  body: nil, omitContentLength: true)
    }

    // MARK: - Routes

    private func statusResponse(_ id: String) -> (Int, Data) {
        guard let profile = agents[id] else {
            return json(404, ["error": "agent not found: \(id)"])
        }
        let running = hasRunningRun(agentID: id)
        let state = running ? "running" : (forceQueueDepth > 0 ? "queued" : "idle")
        return json(200, [
            "state": state,
            "queue_depth": forceQueueDepth,
            "turn_started_at": NSNull(),
            "gateway_alive": true,
            // v4 supervision fields (mirrors the hub's /status payload).
            "stall_timeout_s": 180.0,
            "hard_timeout_s": 3600.0,
            "last_event_at": NSNull(),
            "silence_s": 0.0,
            "degraded": NSNull(),
        ])
    }

    private func hasRunningRun(agentID: String) -> Bool {
        runs.contains { $0["agent_id"] as? String == agentID
            && ["queued", "running"].contains($0["state"] as? String) }
    }

    private func agentResponse(id: String) -> (Int, Data) {
        if let profile = agents[id] {
            return json(200, profile)
        }
        return json(404, ["error": "agent not found: \(id)"])
    }

    private func messagesResponse(_ id: String, request: ReceivedRequest) -> (Int, Data) {
        guard agents[id] != nil else {
            return json(404, ["error": "agent not found: \(id)"])
        }
        var rows = messages.filter { $0["agent_id"] as? String == id }
        // before = message id cursor (exclusive) — parse from the query.
        if let qRange = request.rawPath.range(of: "before=") {
            let rest = request.rawPath[qRange.upperBound...]
            let value = String(rest.prefix { $0 != "&" })
            if let before = Int(value) {
                rows = rows.filter { ($0["id"] as! Int) < before }
            }
        }
        rows.sort { ($0["id"] as! Int) > ($1["id"] as! Int) }
        // limit cap (newest-first page size), like the hub's _limit_param.
        var limit = 50
        if let qRange = request.rawPath.range(of: "limit=") {
            let rest = request.rawPath[qRange.upperBound...]
            let value = String(rest.prefix { $0 != "&" })
            if let parsed = Int(value) { limit = min(max(parsed, 1), 200) }
        }
        if rows.count > limit { rows = Array(rows.prefix(limit)) }
        return json(200, ["agent_id": id, "messages": rows])
    }

    private func runDetailResponse(_ id: String) -> (Int, Data) {
        guard let run = runs.first(where: { $0["run_id"] as? String == id }) else {
            return json(404, ["error": "run not found: \(id)"])
        }
        let msgs = messages.filter { $0["run_id"] as? String == id }
            .sorted { ($0["id"] as! Int) < ($1["id"] as! Int) }
        // Delegation tree: parent + children (v4 wire surface).
        let parent = runs.first { $0["run_id"] as? String == run["parent_run_id"] as? String }
        let children = runs.filter { $0["parent_run_id"] as? String == id }
        return json(200, ["run": run, "messages": msgs,
                          "parent": parent as Any, "children": children])
    }

    private func promptResponse(_ request: ReceivedRequest) -> (Int, Data) {
        guard let body = request.body,
              let text = body["text"] as? String, !text.isEmpty else {
            return json(400, ["error": "text required"])
        }
        let agentID = body["agent_id"] as? String ?? primaryID ?? ""
        guard agents[agentID] != nil else {
            return json(404, ["error": "agent not found: \(agentID)"])
        }
        lock.withLock {
            runSeq += 1
            let runID = "run-\(runSeq)"
            let now = Date().timeIntervalSince1970
            runs.append([
                "run_id": runID,
                "agent_id": agentID,
                "prompt": text,
                "remote": 0,
                "source": "local",
                "state": "queued",
                "created_at": now,
                "started_at": NSNull(),
                "ended_at": NSNull(),
                "error": NSNull(),
                "gateway_respawns": 0,
            ])
            messageSeq += 1
            messages.append([
                "id": messageSeq,
                "run_id": runID,
                "agent_id": agentID,
                "role": "user",
                "text": text,
                "created_at": now,
            ])
        }
        return json(202, [
            "accepted": true,
            "agent_id": agentID,
            "run_id": "run-\(runSeq)",
            "sandbox_path": "/tmp/stub/\(agentID)/sandbox",
        ])
    }

    private func createAgentResponse(_ request: ReceivedRequest) -> (Int, Data) {
        guard let body = request.body,
              let name = body["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return json(400, ["error": "name required"])
        }
        lock.withLock {
            agentSeq += 1
            let id = "agent-\(agentSeq)"
            let now = ISO8601DateFormatter().string(from: Date())
            var profile: [String: Any] = [
                "id": id,
                "name": name,
                "title": body["title"] as? String ?? name,
                "description": body["description"] as? String ?? "",
                "persona": body["persona"] as? String ?? "",
                "model": body["model"] as? String ?? NSNull(),
                "provider": body["provider"] as? String ?? NSNull(),
                "color": body["color"] as? String ?? NSNull(),
                "emoji": body["emoji"] as? String ?? NSNull(),
                "autonomy": body["autonomy"] as? String ?? "ask",
                "created_at": now,
                "updated_at": now,
                "sandbox_path": "/tmp/stub/\(id)/sandbox",
                "home_path": "/tmp/stub/\(id)/home",
                "schema_version": 2,
                "is_primary": primaryID == nil,
            ]
            if primaryID == nil { primaryID = id }
            agents[id] = profile
            agentOrder.append(id)
        }
        return json(201, agents["agent-\(agentSeq)"]!)
    }

    private func patchAgentResponse(_ id: String, request: ReceivedRequest) -> (Int, Data) {
        guard var profile = agents[id] else {
            return json(404, ["error": "agent not found: \(id)"])
        }
        if let body = request.body {
            for (key, value) in body {
                profile[key] = value
            }
            profile["updated_at"] = ISO8601DateFormatter().string(from: Date())
        }
        if respawnPending {
            profile["respawn_pending"] = true
        }
        agents[id] = profile
        return json(200, profile)
    }

    private func deleteAgentResponse(_ id: String) -> (Int, Data) {
        guard agents[id] != nil else {
            return json(404, ["error": "agent not found: \(id)"])
        }
        if forceDelete409 || id == primaryID {
            return json(409, ["error": "primary agent cannot be deleted"])
        }
        if hasRunningRun(agentID: id) {
            return json(409, ["error": "agent is busy (running or queued)"])
        }
        agents.removeValue(forKey: id)
        agentOrder.removeAll { $0 == id }
        return json(200, ["deleted": id, "archived_to": "/tmp/stub/.trash/\(id)-123"])
    }

    // MARK: - Cancellation (supervision)

    /// Mark a run cancelled (only from a non-terminal state); emits the
    /// ``cancelled`` wire event exactly like the hub does.
    private func cancelRunInStore(_ runID: String) -> Bool {
        lock.withLock {
            guard let i = runs.firstIndex(where: { $0["run_id"] as? String == runID }),
                  !["done", "error", "interrupted", "abandoned", "cancelled", "timeout"]
                    .contains(runs[i]["state"] as? String) else {
                return false
            }
            runs[i]["state"] = "cancelled"
            runs[i]["ended_at"] = Date().timeIntervalSince1970
            let agentID = runs[i]["agent_id"] as? String
            let payload: [String: Any] = ["text": "run cancelled"]
            Task { self.inject(type: "cancelled", agentID: agentID, runID: runID, payload: payload) }
            return true
        }
    }

    private func cancelAgentResponse(_ id: String) -> (Int, Data) {
        guard agents[id] != nil else {
            return json(404, ["error": "agent not found: \(id)"])
        }
        var cancelledID: String?
        lock.withLock {
            cancelledID = runs.first { $0["agent_id"] as? String == id
                && !["done", "error", "interrupted", "abandoned", "cancelled", "timeout"]
                    .contains($0["state"] as? String) }?["run_id"] as? String
        }
        guard let cancelledID else {
            return json(409, ["error": "agent \(id) is idle — nothing to cancel"])
        }
        _ = cancelRunInStore(cancelledID)
        return json(200, ["cancelled": cancelledID])
    }

    private func cancelRunResponse(_ id: String, request: ReceivedRequest) -> (Int, Data) {
        let drain = (request.body?["drain_queue"] as? Bool) ?? false
        guard runs.contains(where: { $0["run_id"] as? String == id }) else {
            return json(404, ["error": "run not found: \(id)"])
        }
        let cancelled = cancelRunInStore(id)
        guard cancelled else {
            return json(409, ["error": "run already terminal"])
        }
        if drain {
            // Mirrors the hub: every OTHER still-queued run of that agent
            // is dequeued and cancelled too.
            let agentID = lock.withLock { runs.first { $0["run_id"] as? String == id }?["agent_id"] as? String }
            if let agentID {
                let queued = lock.withLock {
                    runs.compactMap { run -> String? in
                        guard run["agent_id"] as? String == agentID,
                              run["run_id"] as? String != id,
                              run["state"] as? String == "queued" else { return nil }
                        return run["run_id"] as? String
                    }
                }
                for rid in queued { _ = cancelRunInStore(rid) }
            }
        }
        return json(200, ["cancelled": id, "drain_queue": drain])
    }

    // MARK: - SSE

    private func serveSSE(_ fd: Int32, request: ReceivedRequest) {
        // Parse since= from the query.
        let rawPath = request.rawPath
        var since = 0
        if let qRange = rawPath.range(of: "since=") {
            let rest = rawPath[qRange.upperBound...]
            let value = String(rest.prefix { $0 != "&" })
            since = Int(value) ?? 0
        }
        writeSSEHeaders(fd)
        lock.withLock { sseFDs.append(fd) }
        // Replay log rows with seq > since (ascending).
        let replay: [Int] = lock.withLock {
            eventLog.keys.filter { $0 > since }.sorted()
        }
        for seq in replay {
            guard let envelope = lock.withLock({ eventLog[seq] }) else { continue }
            if let data = try? JSONSerialization.data(withJSONObject: envelope) {
                let frame = "data: \(String(data: data, encoding: .utf8)!)\n\n"
                frame.withCString { buf in _ = send(fd, buf, strlen(buf), 0) }
            }
        }
        // Tail live until the socket dies.
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
        }
        lock.withLock { sseFDs.removeAll { $0 == fd } }
    }
}

/// A client-side raw SSE connection (used by tests to assert replay).
final class RawSSEConnection {
    private let fd: Int32
    private var buffer = Data()

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        let req = "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        req.withCString { buf in _ = send(fd, buf, strlen(buf), 0) }
    }

    func nextEvent(timeout: TimeInterval = 2) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let range = buffer.range(of: Data("\n\n".utf8)) {
                let frame = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(...range.lowerBound)
                if let text = String(data: frame, encoding: .utf8),
                   text.hasPrefix("data: "),
                   let data = String(text.dropFirst(6)).data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return obj
                }
            }
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            buffer.append(byte)
        }
        return nil
    }

    func close() {
        Darwin.close(fd)
    }

    deinit { Darwin.close(fd) }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}