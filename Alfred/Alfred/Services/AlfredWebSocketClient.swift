//
//  AlfredWebSocketClient.swift
//  Alfred
//
//  The live link to the Mac. Where AlfredClient (the HTTP relay) is a request →
//  single-reply door, this socket is a conversation: the phone can ask for a
//  briefing and get it back as one JSON-RPC response, *and* the Mac can push
//  updates (streaming chat text, routine progress, notifications) that arrive
//  asynchronously as `AlfredUpdate` events.
//
//  Wire contract (the same JSON-RPC 2.0 shape Hermes ACP speaks over stdio, here
//  carried as one JSON object per WebSocket text frame):
//
//    Phone → Mac (request):  { "jsonrpc": "2.0", "id": 1, "method": "briefing.get",
//                              "params": { "force_refresh": false } }
//    Mac → Phone (response): { "jsonrpc": "2.0", "id": 1, "result": { ... } }
//    Mac → Phone (notify):   { "jsonrpc": "2.0", "method": "briefing.update",
//                              "params": { "summary": "...", "changes": [...] } }
//
//  The Mac-side server for this contract does not exist yet (Hermes ACP is stdio;
//  the 8765 voice bridge is binary audio). The client is built against the
//  contract so the two sides can land independently.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class AlfredWebSocketClient {

    static let shared = AlfredWebSocketClient()

    /// The port the Mac's ACP-over-WebSocket server should listen on. Kept as one
    /// constant so discovery, validation and the manual-entry fallback agree.
    /// `nonisolated` because discovery (TailscaleConnection) reads it off the main actor.
    nonisolated static let defaultPort = 8766

    /// Where the phone is in the connect/reconnect life cycle. Views render this
    /// directly, so a dead link is visible instead of silent.
    enum State: Equatable {
        case idle
        case connecting
        case connected
        /// Waiting to retry after a drop. `attempt` starts at 1 and the delay
        /// doubles each failure (1s, 2s, 4s, … capped at 30s).
        case reconnecting(attempt: Int)
        /// A terminal failure the client won't retry on its own (e.g. a bad URL).
        case failed(String)
    }

    private(set) var state: State = .idle
    var isConnected: Bool { state == .connected }

    /// The most recent briefing from the Mac — set by pushed `briefing.update`
    /// notifications and by `requestBriefing`. The Home tab renders from this.
    private(set) var latestBriefing: BriefingUpdate?

    /// Human-readable reason for the most recent failure — surfaced in Settings.
    private(set) var lastError: String?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connectAttempt = 0

    /// True while we're allowed to reconnect. Set false by `disconnect()`, so a
    /// deliberate close doesn't spin a reconnect loop.
    private var shouldReconnect = false

    // MARK: JSON-RPC correlation

    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    // MARK: Outgoing queue

    /// Frames waiting to be written. `URLSessionWebSocketTask.send` has a
    /// completion handler, so we drain one at a time to keep ordering.
    private var sendQueue: [URLSessionWebSocketTask.Message] = []
    private var isSending = false

    // MARK: Incoming updates

    /// Per-subscriber continuations for the pushed update stream. The client is
    /// the single producer; every view that calls `updates()` registers here and
    /// receives every event. AsyncStream itself is unicast — one iterator — so a
    /// single shared stream would silently starve all but the first consumer;
    /// fanning out per subscriber keeps every listener in the loop.
    private var subscribers: [UUID: AsyncStream<AlfredUpdate>.Continuation] = [:]

    private let session: URLSession
    private let logger = Logger(subsystem: "com.carlton.alfred", category: "socket")

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Connection

    /// Open the socket and start the receive loop. The first failure is never
    /// thrown here — URLSessionWebSocketTask has no handshake completion — so the
    /// method is `async` (not `async throws`); failures surface as the receive
    /// loop errors, flipping state to `.reconnecting` and retrying on its own.
    func connect(to url: URL) async {
        shouldReconnect = true
        connectAttempt = 0
        // A manual connect while auto-reconnect is backing off must cancel the
        // stale timer: otherwise the sleeping Task wakes, establishes a *second*
        // socket, and the two loops fight over `socket`.
        reconnectTask?.cancel()
        reconnectTask = nil
        await establish(url)
    }

    /// Tear down and stay down.
    func disconnect() {
        shouldReconnect = false
        connectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        failPending(HermesSocketError.closed)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendQueue.removeAll()
        isSending = false
        state = .idle
    }

    /// Convenience for the app-lifecycle hook: resolve the endpoint from settings
    /// (manual host, or discovered), then connect.
    func connectToAlfred() async {
        let settings = AppSettings()
        guard settings.isConfigured else { return }

        if let url = settings.socketURL {
            await connect(to: url)
            return
        }
        // No manual host — try discovery once. It's slow-ish (mDNS timeout), so
        // run it off the main thread.
        let discovered = await Task.detached(priority: .utility) {
            await TailscaleConnection().discoverAlfredOnTailscale()
        }.value
        guard let (host, port) = discovered else { return }
        settings.saveSocketHost(host, port: port)
        guard let url = settings.socketURL else { return }
        await connect(to: url)
    }

    // MARK: - Sending

    /// A request: gets a correlated response back (or throws if the socket dies
    /// or the Mac never answers).
    ///
    /// `timeout` bounds the wait, mirroring HermesSession's own turn watchdog:
    /// the Mac can answer a `briefing.get` slowly (it may read a calendar first),
    /// but it can also wedge — and a request with no timeout would hang the
    /// caller (and leak its continuation) forever.
    func sendCommand(name: String, params: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        nextRequestID += 1
        let id = nextRequestID
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": name, "params": params,
        ]
        return try await withCheckedThrowingContinuation { continuation in
            guard socket != nil else {
                continuation.resume(throwing: HermesSocketError.notConnected)
                return
            }
            pending[id] = continuation
            enqueue(.string(Self.jsonString(frame)))
            // Arm the watchdog. If it fires, the continuation is resumed (and
            // removed) here so the caller gets a timeout instead of an eternal
            // hang; the next disconnect's failPending finds nothing left to fail.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self,
                      let continuation = self.pending.removeValue(forKey: id)
                else { return }
                self.logger.info("Command \(name) timed out after \(Int(timeout))s")
                continuation.resume(throwing: HermesSocketError.timedOut)
            }
        }
    }

    /// A notification: fire-and-forget, no correlation, no reply expected.
    func send(_ message: [String: Any]) async throws {
        guard socket != nil else { throw HermesSocketError.notConnected }
        enqueue(.string(Self.jsonString(message)))
    }

    /// Ask the Mac for a briefing. `force: true` (pull-to-refresh) regenerates
    /// on the Mac; `false` returns the latest, generating only if none exists.
    /// The result is stored in `latestBriefing`, so callers just await this and
    /// the Home tab updates.
    func requestBriefing(force: Bool = false) async {
        do {
            let name = force ? "briefing.get_now" : "briefing.get"
            let result = try await sendCommand(name: name, params: ["force_refresh": force], timeout: 60)
            if let update = BriefingUpdate.fromJSON(result) {
                latestBriefing = update
            }
        } catch HermesSocketError.notConnected {
            // Nothing to say — the phone isn't linked to the Mac right now.
        } catch {
            logger.info("briefing request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Routines

    /// Schedule a one-off run of a routine at a specific moment.
    func scheduleRoutine(id: UUID, for date: Date) async -> RoutineSummary? {
        await routineResult(from: "routines.schedule", params: ["routine_id": id.uuidString, "at": date.timeIntervalSince1970])
    }

    /// All routines known to the Mac, newest first is the Mac's order (creation
    /// order, templates first). An empty array on any failure — the caller
    /// renders an empty state either way.
    func listRoutines() async -> [RoutineSummary] {
        do {
            let result = try await sendCommand(name: "routines.list", timeout: 20)
            guard let raw = result["routines"] as? [[String: Any]] else { return [] }
            return raw.compactMap(RoutineSummary.fromJSON)
        } catch {
            logger.info("routines.list failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Run a routine now. Long timeout: steps can include a Hermes turn or a
    /// shell command. The Mac also pushes started/progress/completed, which the
    /// view observes; this result is for the final refresh.
    func runRoutine(id: UUID) async -> RoutineResultPayload? {
        do {
            let result = try await sendCommand(
                name: "routines.run", params: ["routine_id": id.uuidString], timeout: 180)
            guard let data = try? JSONSerialization.data(withJSONObject: result),
                  let payload = try? JSONDecoder().decode(RoutineResultPayload.self, from: data)
            else { return nil }
            return payload
        } catch {
            logger.info("routines.run failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Build a custom routine from its parts.
    func createRoutine(
        name: String,
        description: String,
        steps: [RoutineStepPayload],
        schedule: RoutineSchedulePayload
    ) async -> RoutineSummary? {
        let params: [String: Any] = [
            "name": name,
            "description": description,
            "steps": Self.wireArray(steps),
            "schedule": Self.wireObject(schedule),
        ]
        return await routineResult(from: "routines.create", params: params)
    }

    /// One-tap template add — the Mac builds the steps from its own library.
    func addRoutineTemplate(named name: String) async -> RoutineSummary? {
        await routineResult(from: "routines.create", params: ["template": name])
    }

    /// Edit any subset of a routine. `nil` fields are left untouched on the Mac.
    func updateRoutine(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        steps: [RoutineStepPayload]? = nil,
        schedule: RoutineSchedulePayload? = nil,
        enabled: Bool? = nil
    ) async -> RoutineSummary? {
        var params: [String: Any] = ["routine_id": id.uuidString]
        if let name { params["name"] = name }
        if let description { params["description"] = description }
        if let steps { params["steps"] = Self.wireArray(steps) }
        if let schedule { params["schedule"] = Self.wireObject(schedule) }
        if let enabled { params["enabled"] = enabled }
        return await routineResult(from: "routines.update", params: params)
    }

    func deleteRoutine(id: UUID) async -> Bool {
        do {
            let result = try await sendCommand(
                name: "routines.delete", params: ["routine_id": id.uuidString], timeout: 20)
            return result["success"] as? Bool ?? false
        } catch {
            logger.info("routines.delete failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Shared plumbing for create/update: both answer with `{ routine: {...} }`.
    private func routineResult(from method: String, params: [String: Any]) async -> RoutineSummary? {
        do {
            let result = try await sendCommand(name: method, params: params, timeout: 20)
            guard let raw = result["routine"] as? [String: Any] else { return nil }
            return RoutineSummary.fromJSON(raw)
        } catch {
            logger.info("\(method) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Code sessions (AlfredCode)

    /// All remote coding sessions known to the Mac, newest first.
    func listCodeSessions() async -> [CodeSessionSummary] {
        do {
            let result = try await sendCommand(name: "code.sessions", timeout: 20)
            guard let raw = result["sessions"] as? [[String: Any]] else { return [] }
            return raw.compactMap(CodeSessionSummary.fromJSON)
        } catch {
            logger.info("code.sessions failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Start a coding session at a project folder. `agent` is the raw agent
    /// name ("opencode" / "freebuff"); the Mac maps it to its engine.
    func startCodeSession(prompt: String, projectPath: String, agent: String) async -> CodeSessionSummary? {
        do {
            let result = try await sendCommand(
                name: "code.start_session",
                params: ["prompt": prompt, "project_path": projectPath, "agent": agent],
                timeout: 30)
            guard let raw = result["session"] as? [String: Any] else { return nil }
            return CodeSessionSummary.fromJSON(raw)
        } catch {
            logger.info("code.start_session failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Freeze a session's agent process (SIGSTOP).
    func pauseCodeSession(id: UUID) async -> Bool {
        await codeAck("code.pause_session", sessionID: id)
    }

    /// Unfreeze a paused agent (SIGCONT).
    func resumeCodeSession(id: UUID) async -> Bool {
        await codeAck("code.resume_session", sessionID: id)
    }

    /// Kill the agent but keep the transcript.
    func stopCodeSession(id: UUID) async -> Bool {
        await codeAck("code.stop_session", sessionID: id)
    }

    /// Remove the session record entirely.
    func deleteCodeSession(id: UUID) async -> Bool {
        await codeAck("code.delete_session", sessionID: id)
    }

    /// Send a refinement request to the session's running agent.
    func refineCodeSession(id: UUID, request: String) async -> Bool {
        do {
            _ = try await sendCommand(
                name: "code.refine",
                params: ["session_id": id.uuidString, "request": request],
                timeout: 30)
            return true
        } catch {
            logger.info("code.refine failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Run the project's test command on the Mac.
    func runCodeTests(id: UUID) async -> CodeTestResultPayload? {
        do {
            let result = try await sendCommand(
                name: "code.run_tests", params: ["session_id": id.uuidString], timeout: 150)
            return CodeTestResultPayload.fromJSON(result)
        } catch {
            logger.info("code.run_tests failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The session's current branch + working-tree dirtiness.
    func codeGitStatus(id: UUID) async -> CodeGitStatusPayload? {
        do {
            let result = try await sendCommand(
                name: "code.git_status", params: ["session_id": id.uuidString], timeout: 20)
            return CodeGitStatusPayload.fromJSON(result)
        } catch {
            logger.info("code.git_status failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// `git diff` for the session's project.
    func codeGitDiff(id: UUID) async -> String {
        do {
            let result = try await sendCommand(
                name: "code.git_diff", params: ["session_id": id.uuidString], timeout: 20)
            return result["diff"] as? String ?? ""
        } catch {
            logger.info("code.git_diff failed: \(error.localizedDescription)")
            return ""
        }
    }

    /// Stage everything and commit. Returns the short hash, or nil on failure.
    func codeGitCommit(id: UUID, message: String) async -> String? {
        do {
            let result = try await sendCommand(
                name: "code.git_commit",
                params: ["session_id": id.uuidString, "message": message],
                timeout: 40)
            let ok = result["success"] as? Bool ?? false
            let hash = result["hash"] as? String ?? ""
            return ok && !hash.isEmpty ? hash : nil
        } catch {
            logger.info("code.git_commit failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Create and check out a new branch; returns the fresh git status.
    func codeGitCreateBranch(id: UUID, name: String) async -> CodeGitStatusPayload? {
        await codeGitBranchAction("code.git_branch_create", id: id, name: name)
    }

    /// Check out an existing branch; returns the fresh git status.
    func codeGitSwitchBranch(id: UUID, name: String) async -> CodeGitStatusPayload? {
        await codeGitBranchAction("code.git_branch_switch", id: id, name: name)
    }

    /// Local branches for the switch picker.
    func codeGitListBranches(id: UUID) async -> [String] {
        do {
            let result = try await sendCommand(
                name: "code.git_list_branches", params: ["session_id": id.uuidString], timeout: 20)
            return result["branches"] as? [String] ?? []
        } catch {
            logger.info("code.git_list_branches failed: \(error.localizedDescription)")
            return []
        }
    }

    private func codeGitBranchAction(_ method: String, id: UUID, name: String) async -> CodeGitStatusPayload? {
        do {
            let result = try await sendCommand(
                name: method,
                params: ["session_id": id.uuidString, "name": name],
                timeout: 20)
            return CodeGitStatusPayload.fromJSON(result)
        } catch {
            logger.info("\(method) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Push the current branch; returns a human-readable outcome.
    func codeGitPush(id: UUID) async -> String {
        await codeGitNetworkAction("code.git_push", id: id)
    }

    /// Pull the current branch; returns a human-readable outcome.
    func codeGitPull(id: UUID) async -> String {
        await codeGitNetworkAction("code.git_pull", id: id)
    }

    private func codeGitNetworkAction(_ method: String, id: UUID) async -> String {
        do {
            let result = try await sendCommand(
                name: method, params: ["session_id": id.uuidString], timeout: 90)
            return result["message"] as? String ?? "Done."
        } catch {
            logger.info("\(method) failed: \(error.localizedDescription)")
            return "Couldn't reach the Mac's git."
        }
    }

    /// Candidate project folders for the new-session picker.
    func listCodeProjects() async -> [CodeProjectPayload] {
        do {
            let result = try await sendCommand(name: "code.projects", timeout: 30)
            guard let raw = result["projects"] as? [[String: Any]] else { return [] }
            return raw.compactMap { dict in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let project = try? JSONDecoder().decode(CodeProjectPayload.self, from: data)
                else { return nil }
                return project
            }
        } catch {
            logger.info("code.projects failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Shared plumbing for the ack-only code methods: answer `{success: bool}`.
    private func codeAck(_ method: String, sessionID: UUID) async -> Bool {
        do {
            _ = try await sendCommand(
                name: method, params: ["session_id": sessionID.uuidString], timeout: 20)
            return true
        } catch {
            logger.info("\(method) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Encode a Codable value to the flat dictionary the wire expects.
    private static func wireObject<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func wireArray<T: Encodable>(_ values: [T]) -> [Any] {
        values.compactMap { value in
            guard let data = try? JSONEncoder().encode(value),
                  let obj = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return obj
        }
    }

    // MARK: - Receiving

    /// The stream of pushed updates. Each call registers a fresh subscriber that
    /// receives *every* event — multiple consumers (Home, Chat, Routines) each
    /// get the full feed. Subscribers are removed when their iterator ends or
    /// the task holding them is cancelled.
    func updates() -> AsyncStream<AlfredUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.subscribers.removeValue(forKey: id)
                }
            }
        }
    }

    // MARK: - Reconnect

    /// Backoff: 1s, 2s, 4s, 8s, 16s, then 30s forever (spec cap).
    private func delay(forAttempt attempt: Int) -> TimeInterval {
        min(pow(2.0, Double(attempt - 1)), 30.0)
    }

    private func scheduleReconnect(to url: URL) {
        guard shouldReconnect else { return }
        connectAttempt += 1
        let attempt = connectAttempt
        let delay = delay(forAttempt: attempt)
        state = .reconnecting(attempt: attempt)
        logger.info("Socket dropped — reconnecting in \(delay)s (attempt \(attempt))")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.shouldReconnect else { return }
            // establish() never throws; a failed attempt surfaces as the receive
            // loop erroring, which schedules the next retry. If the socket was
            // already gone by the time we wake, dropAndReconnect takes over.
            await self.establish(url)
        }
    }

    // MARK: - Internals

    private func establish(_ url: URL) async {
        state = .connecting
        lastError = nil

        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()

        // The handshake has no completion handler, so connection failures surface
        // as the first receive() throwing — refused/DNS failures throw almost
        // immediately, and a wedged handshake is cut by the session's 30s request
        // timeout. Either way the receive loop notices and schedules a retry.
        // State flips to .connected optimistically, like the voice bridge does:
        // the loop (and the 30s timeout) are what actually keep it honest.
        state = .connected

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task, url: url)
        }
        startHeartbeat()
    }

    /// Keep the socket alive and honest. Two jobs:
    ///
    ///   1. A wedged-but-open connection (peer gone, no FIN) is invisible to
    ///      receive() until the OS notices — a client ping forces the peer to
    ///      answer, and a failed ping drops us into the reconnect loop.
    ///   2. The session's 30s request timeout can tear down an idle-but-healthy
    ///      socket (the Mac may push nothing for a while); regular pings reset
    ///      the activity clock so quiet periods don't look like deaths.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)  // 20s
                guard let self, !Task.isCancelled, self.socket != nil else { return }
                await self.ping()
            }
        }
    }

    /// Send a JSON-RPC `ping` and wait briefly for *any* frame back (a live ACP
    /// endpoint answers ping with a "method not found" error, which still counts).
    /// No answer → drop and let the reconnect loop handle it.
    private func ping() async {
        guard let socket, let url = socket.originalRequest?.url else { return }
        do {
            _ = try await sendCommand(name: "ping", timeout: 5)
        } catch HermesSocketError.server {
            // A live ACP endpoint answers ping with "method not found" (-32601)
            // by design — that *is* the answer, and proof the server is alive.
            return
        } catch {
            logger.info("Heartbeat ping failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            dropAndReconnect(to: url)
        }
    }

    /// The loop that owns the socket until it dies. One Task per connection; on
    /// any error it tears down and (unless disconnected deliberately) schedules
    /// the next attempt.
    private func receiveLoop(_ task: URLSessionWebSocketTask, url: URL) async {
        while socket === task {
            do {
                let message = try await task.receive()
                // A live frame proves this connection held up; restart the
                // backoff so a flapping network doesn't escalate to 30s forever
                // after one blip.
                connectAttempt = 0
                handle(message)
            } catch {
                guard socket === task else { return }
                let description = (error as? URLError)?.localizedDescription ?? error.localizedDescription
                logger.info("Socket receive failed: \(description)")
                lastError = description
                dropAndReconnect(to: url)
                return
            }
        }
    }

    /// Forget the current socket and schedule the next attempt. Safe to call from
    /// anywhere on the main actor — checks `shouldReconnect` before acting.
    private func dropAndReconnect(to url: URL) {
        failPending(HermesSocketError.closed)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        sendQueue.removeAll()
        isSending = false
        scheduleReconnect(to: url)
    }

    private func failPending(_ error: Error) {
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    // MARK: - Outgoing queue drain

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        sendQueue.append(message)
        guard !isSending else { return }
        drain()
    }

    private func drain() {
        guard let socket else {
            sendQueue.removeAll()
            isSending = false
            return
        }
        isSending = true
        guard !sendQueue.isEmpty else {
            isSending = false
            return
        }
        let next = sendQueue.removeFirst()
        socket.send(next) { [weak self] error in
            // Unwrap once up front: the Task below must capture a strong value,
            // not the mutable weak reference (which trips the concurrency checker).
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    // A send failure usually means the socket is gone; the receive
                    // loop will notice too, but fail pending requests *now* so a
                    // caller isn't left awaiting a reply that can never come.
                    self.logger.info("Socket send failed: \(error.localizedDescription)")
                    self.lastError = error.localizedDescription
                    self.failPending(HermesSocketError.closed)
                    self.sendQueue.removeAll()
                    self.isSending = false
                } else {
                    self.drain()
                }
            }
        }
    }

    // MARK: - Incoming

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                // Malformed frame — skip, don't crash. The next frame may be fine.
                logger.warning("Skipping malformed socket frame")
                return
            }
            route(frame)
        case .data(let data):
            guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            route(frame)
        @unknown default:
            break
        }
    }

    private func route(_ frame: [String: Any]) {
        let method = frame["method"] as? String

        // Server → client *request*: must be answered or the Mac's turn deadlocks.
        if let method, frame["id"] != nil {
            handleServerRequest(method: method, frame: frame)
            return
        }

        // Notification → surface as an update.
        if let method {
            let params = frame["params"] as? [String: Any] ?? [:]
            if let update = AlfredUpdateParser.parse(method: method, params: params) {
                // Briefings are state as well as events: stash the latest so the
                // Home tab can render it without holding its own stream.
                if case .briefingUpdate(let briefing) = update {
                    latestBriefing = briefing
                }
                for continuation in subscribers.values {
                    continuation.yield(update)
                }
            } else if method == "error" {
                let message = params["message"] as? String ?? "Alfred's Mac reported an error."
                for continuation in subscribers.values {
                    continuation.yield(.error(message: message))
                }
            }
            return
        }

        // Response to one of ours.
        guard let id = frame["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = frame["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Alfred's Mac answered with an error."
            continuation.resume(throwing: HermesSocketError.server(message))
        } else {
            continuation.resume(returning: frame["result"] as? [String: Any] ?? [:])
        }
    }

    /// Answer client methods the same way the Mac's own HermesSession does: every
    /// `*_request_permission` is auto-approved (picking the permissive option),
    /// anything unknown gets an empty result so the agent isn't left blocking.
    private func handleServerRequest(method: String, frame: [String: Any]) {
        guard let id = frame["id"] else { return }

        guard method.hasSuffix("request_permission") else {
            respond(id: id, result: [:])
            return
        }

        let params = frame["params"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []
        guard let chosen = Self.allowOption(from: options),
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

    private func respond(id: Any, result: [String: Any]) {
        enqueue(.string(Self.jsonString(["jsonrpc": "2.0", "id": id, "result": result])))
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Errors the socket throws to callers. Localized so views can show them as-is.
enum HermesSocketError: LocalizedError {
    case notConnected
    case closed
    case timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Alfred isn't connected right now."
        case .closed:
            return "The connection to your Mac was lost."
        case .timedOut:
            return "Alfred didn't answer in time. He may still be working — try again in a moment."
        case .server(let message):
            return message
        }
    }
}
