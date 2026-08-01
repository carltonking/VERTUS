import Foundation

// MARK: - Events
//
// What the bar renders. One case per `session/update` variant we care about;
// the rest of the ACP surface (plan, config_option_update, …) is dropped here
// rather than in the view, so the UI never sees protocol noise.

enum HermesEvent: Sendable {
    /// Incremental assistant text. Append, never replace.
    case text(String)
    /// Reasoning trace — rendered dim, or hidden.
    case thought(String)
    /// A tool run started. `title` is human-readable ("Run shell command").
    case toolStarted(id: String, title: String, kind: String?)
    /// A tool run changed state: pending → in_progress → completed / failed.
    case toolProgress(id: String, status: String?, title: String?)
    /// Context-window telemetry.
    case usage(used: Int, size: Int)
    /// Turn finished cleanly. `stopReason` is typically "end_turn".
    case finished(stopReason: String)
    /// Turn failed. Already human-readable.
    case failed(String)
}

// MARK: - Errors

enum HermesError: LocalizedError {
    case binaryNotFound
    case launchFailed(String)
    case agentExited(Int32)
    case protocolError(String)
    /// Hermes has no `model.provider` set. Expected cold-start state, not a crash.
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Hermes isn't installed. Install it, then reopen Alfred."
        case .launchFailed(let m):
            return "Couldn't start Hermes: \(m)"
        case .agentExited(let code):
            return "Hermes stopped unexpectedly (exit \(code))."
        case .protocolError(let m):
            return "Hermes sent something unexpected: \(m)"
        case .notConfigured(let m):
            return m
        }
    }
}

// MARK: - Session

/// Owns one long-lived `hermes acp` subprocess and speaks ACP (JSON-RPC 2.0 over
/// stdio) to it.
///
/// Contract verified live against hermes-agent 0.19.0 — see
/// `scratchpad/ACP_CONTRACT.md`. The parts that bite:
///
///   * **stdout is protocol only.** Hermes logs to stderr. Parsing stderr as
///     JSON produces phantom failures, so the two pipes are read separately.
///   * **`session/prompt` resolves only when the whole turn ends.** Streaming
///     text arrives out-of-band as `session/update` notifications, so the
///     response and the notifications must be consumed concurrently.
///   * **The agent calls back into us.** `session/request_permission` arrives
///     mid-turn and the turn *deadlocks* until answered.
///   * `ping`/`health` answer with JSON-RPC -32601 by design — not an error.
actor HermesSession {

    // MARK: Configuration

    /// Answer `session/request_permission` automatically.
    ///
    /// Phase 1 ships `true` so the loop runs unattended. Every request is still
    /// surfaced as a `.toolStarted` event, so nothing happens silently. The
    /// confirm affordance in the bar (Phase 2) flips this to `false` and routes
    /// the decision to the user — that is the natural home for the destructive
    /// and secret guards already in `ComputerControlCapability`.
    private let autoApprovePermissions: Bool

    private let workingDirectory: String

    // MARK: Process

    private var process: Process?
    private var stdinPipe: Pipe?
    private var sessionID: String?

    /// Accumulates stdout across reads — a JSON frame can span several chunks,
    /// and a single chunk can carry several frames.
    private var readBuffer = Data()

    // MARK: JSON-RPC

    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Sink for the turn currently streaming. Only one turn runs at a time.
    private var eventSink: AsyncStream<HermesEvent>.Continuation?

    init(workingDirectory: String = NSHomeDirectory(), autoApprovePermissions: Bool = true) {
        self.workingDirectory = workingDirectory
        self.autoApprovePermissions = autoApprovePermissions
    }

    // MARK: - Binary resolution

    /// Locate the `hermes` executable.
    ///
    /// A GUI app launched by Finder or launchd inherits a minimal `PATH` that
    /// usually excludes `~/.local/bin`, so relying on `PATH` alone fails
    /// exactly when the app is used normally. The venv binary is checked first
    /// because `~/.local/bin/hermes` is only a shell wrapper around it.
    private static func resolveBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.hermes/hermes-agent/venv/bin/hermes",
            "\(home)/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask a login shell, which does source the user's profile.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v hermes"]
        let out = Pipe()
        which.standardOutput = out
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        } catch { /* fall through */ }
        return nil
    }

    // MARK: - Lifecycle

    /// Spawn the agent and complete the ACP handshake. Idempotent.
    func start() async throws {
        guard process == nil else { return }
        guard let binary = Self.resolveBinary() else { throw HermesError.binaryNotFound }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["acp"]
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // stdout: protocol frames.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }

        // stderr: logs. Drained so the pipe buffer can't fill and wedge the
        // agent, but never parsed as protocol.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8) else { return }
            if line.contains("ERROR") || line.contains("Traceback") || line.contains("CRITICAL") {
                NSLog("[hermes] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { await self?.handleTermination(p.terminationStatus) }
        }

        do {
            try proc.run()
        } catch {
            throw HermesError.launchFailed(error.localizedDescription)
        }

        process = proc
        stdinPipe = inPipe

        // 1. initialize — advertise no filesystem capability; Alfred reaches the
        //    Mac through its own MCP tools (Phase 2), not through ACP's fs hooks.
        _ = try await request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
            "clientInfo": ["name": "alfred", "version": Self.appVersion],
        ])

        // 2. session/new
        let session = try await request("session/new", [
            "cwd": workingDirectory,
            "mcpServers": [],  // Phase 2 injects Alfred's macOS tools here.
        ])
        guard let sid = session["sessionId"] as? String else {
            throw HermesError.protocolError("session/new returned no sessionId")
        }
        sessionID = sid
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Terminate the agent. Safe to call repeatedly.
    func shutdown() {
        eventSink?.finish()
        eventSink = nil
        for (_, cont) in pending { cont.resume(throwing: HermesError.agentExited(0)) }
        pending.removeAll()
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
        sessionID = nil
        readBuffer.removeAll()
    }

    /// Drop the conversation and start a clean one.
    ///
    /// Tears the process down rather than reusing the session: Hermes keeps
    /// per-session context server-side, so "clear" has to reach that too or the
    /// old thread keeps colouring replies.
    func restart() async {
        shutdown()
        try? await start()
    }

    private func handleTermination(_ status: Int32) {
        eventSink?.yield(.failed(HermesError.agentExited(status).localizedDescription))
        eventSink?.finish()
        eventSink = nil
        for (_, cont) in pending { cont.resume(throwing: HermesError.agentExited(status)) }
        pending.removeAll()
        process = nil
    }

    // MARK: - Prompting

    /// Send a prompt and stream the turn.
    ///
    /// The stream finishes on `.finished` or `.failed`; the caller does not need
    /// to inspect the `session/prompt` result separately.
    func prompt(_ text: String) -> AsyncStream<HermesEvent> {
        AsyncStream { continuation in
            Task {
                await self.runTurn(text, into: continuation)
            }
        }
    }

    private func runTurn(_ text: String, into continuation: AsyncStream<HermesEvent>.Continuation) async {
        do {
            try await start()  // no-op when already running
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            continuation.finish()
            return
        }
        guard let sid = sessionID else {
            continuation.yield(.failed(HermesError.protocolError("no active session").localizedDescription))
            continuation.finish()
            return
        }

        eventSink = continuation

        do {
            let result = try await request("session/prompt", [
                "sessionId": sid,
                "prompt": [["type": "text", "text": text]],
            ])
            let stop = result["stopReason"] as? String ?? "end_turn"
            continuation.yield(.finished(stopReason: stop))
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }

        eventSink = nil
        continuation.finish()
    }

    /// Interrupt the running turn. Wired to Esc in the bar.
    func cancel() async {
        guard let sid = sessionID else { return }
        notify("session/cancel", ["sessionId": sid])
    }

    // MARK: - JSON-RPC plumbing

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextRequestID += 1
        let id = nextRequestID
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try write(frame)
            } catch {
                pending[id] = nil
                cont.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        try? write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func respond(id: Any, result: [String: Any]) {
        try? write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ frame: [String: Any]) throws {
        guard let handle = stdinPipe?.fileHandleForWriting else {
            throw HermesError.protocolError("agent stdin closed")
        }
        var data = try JSONSerialization.data(withJSONObject: frame)
        data.append(0x0A)  // newline-delimited
        try handle.write(contentsOf: data)
    }

    // MARK: - Reading

    /// Split the stdout byte stream into newline-delimited JSON frames.
    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<nl]
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handle(frame: obj)
        }
    }

    private func handle(frame: [String: Any]) {
        let method = frame["method"] as? String

        // Server → client request: must be answered or the turn deadlocks.
        if let method, frame["id"] != nil {
            handleAgentRequest(method: method, frame: frame)
            return
        }

        // Notification.
        if let method {
            if method == "session/update",
               let params = frame["params"] as? [String: Any],
               let update = params["update"] as? [String: Any] {
                handle(update: update)
            }
            return
        }

        // Response to one of ours.
        guard let id = frame["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let error = frame["error"] as? [String: Any] {
            cont.resume(throwing: Self.decode(error: error))
        } else {
            cont.resume(returning: frame["result"] as? [String: Any] ?? [:])
        }
    }

    /// Turn a JSON-RPC error into something worth showing a person.
    private static func decode(error: [String: Any]) -> HermesError {
        let detail = (error["data"] as? [String: Any])?["details"] as? String
        let message = error["message"] as? String ?? "unknown error"
        guard let detail else { return .protocolError(message) }
        // Cold start: no provider picked yet. Not a failure — a setup prompt.
        if detail.contains("No LLM provider configured") {
            return .notConfigured("Alfred needs an AI provider. Run `hermes model` in Terminal to pick one.")
        }
        return .protocolError(detail)
    }

    private func handleAgentRequest(method: String, frame: [String: Any]) {
        guard let id = frame["id"] else { return }

        guard method.hasSuffix("request_permission") else {
            // Unknown client method — answer so the agent isn't left blocking.
            respond(id: id, result: [:])
            return
        }

        let params = frame["params"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []

        guard autoApprovePermissions,
              let chosen = Self.allowOption(from: options),
              let optionID = chosen["optionId"] as? String else {
            respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }
        respond(id: id, result: ["outcome": ["outcome": "selected", "optionId": optionID]])
    }

    /// Pick the permissive option, preferring an explicit allow over position.
    private static func allowOption(from options: [[String: Any]]) -> [String: Any]? {
        func mentionsAllow(_ o: [String: Any]) -> Bool {
            let kind = (o["kind"] as? String ?? "").lowercased()
            let id = (o["optionId"] as? String ?? "").lowercased()
            return kind.contains("allow") || id.contains("allow")
        }
        return options.first(where: mentionsAllow) ?? options.first
    }

    // MARK: - Update fan-out

    private func handle(update: [String: Any]) {
        guard let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "agent_message_chunk":
            if let t = Self.text(in: update) { eventSink?.yield(.text(t)) }

        case "agent_thought_chunk":
            if let t = Self.text(in: update) { eventSink?.yield(.thought(t)) }

        case "tool_call":
            guard let id = update["toolCallId"] as? String else { return }
            eventSink?.yield(.toolStarted(
                id: id,
                title: update["title"] as? String ?? "Working…",
                kind: update["kind"] as? String))

        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            eventSink?.yield(.toolProgress(
                id: id,
                status: update["status"] as? String,
                title: update["title"] as? String))

        case "usage_update":
            let used = update["used"] as? Int ?? 0
            let size = update["size"] as? Int ?? 0
            eventSink?.yield(.usage(used: used, size: size))

        default:
            // plan / available_commands_update / current_mode_update /
            // config_option_update / session_info_update — not surfaced in v1.
            break
        }
    }

    /// Content blocks are `{type, text}`; non-text blocks (image, audio) have no
    /// text and are skipped rather than rendered as an empty string.
    private static func text(in update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              let text = content["text"] as? String,
              !text.isEmpty else { return nil }
        return text
    }
}
