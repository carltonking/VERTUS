import CryptoKit
import Foundation
import Network

// MARK: - Briefing socket server
//
// The Mac side of the ACP-over-WebSocket contract the iOS app's
// AlfredWebSocketClient was built against. The client advertises a Bonjour
// service (`_alfred._tcp`, port 8766) and speaks JSON-RPC 2.0 — this is that
// service.
//
// Wire contract (one JSON object per text frame):
//
//   Phone → Mac (request):  { "jsonrpc": "2.0", "id": 1, "method": "briefing.get" }
//   Mac → Phone (response): { "jsonrpc": "2.0", "id": 1, "result": { ...BriefingContent } }
//   Mac → Phone (notify):   { "jsonrpc": "2.0", "method": "briefing.update",
//                             "params": { ...BriefingContent } }
//
// Handled methods:
//   * briefing.get          → the latest briefing, generating one if none exists yet.
//   * briefing.get_now      → force a fresh generation, then return it (pull-to-refresh).
//   * routines.list         → all routines (id, name, steps, schedule, next run…).
//   * routines.run          → run a routine now, returns its RoutineResult.
//   * routines.create       → make a routine from {name, description, steps, schedule}.
//   * routines.update       → edit name/description/steps/schedule/enabled.
//   * routines.delete       → remove a routine by id.
//   * routines.schedule     → queue a one-off run at a future timestamp.
//   * code.sessions         → all remote coding sessions.
//   * code.start_session    → spawn a coding agent at a project folder and begin.
//   * code.pause_session    → SIGSTOP the session's agent.
//   * code.resume_session   → SIGCONT a paused agent.
//   * code.stop_session     → kill the agent, keep the transcript.
//   * code.delete_session   → remove the session record.
//   * code.refine           → send a refinement request to the running agent.
//   * code.run_tests        → run the project's test command.
//   * code.git_status       → branch + working-tree dirtiness.
//   * code.git_diff         → `git diff` output.
//   * code.git_commit       → stage all + commit with a message.
//   * code.git_branch_create→ create and check out a new branch.
//   * code.git_branch_switch→ check out an existing branch.
//   * code.git_push         → push the current branch.
//   * code.git_pull         → pull the current branch.
//   * code.projects         → candidate project folders for the phone's picker.
//   * mail.accounts         → every Himalaya account with unread counts.
//   * mail.inbox            → the cached unified (or per-account) inbox.
//   * mail.folders          → one account's mailboxes with counts.
//   * mail.message          → a full message: envelope + body + attachments.
//   * mail.search           → subject/sender/snippet search over the cache.
//   * mail.sync             → force a sync now (pull-to-refresh).
//   * mail.send             → send a new message through the account's SMTP.
//   * mail.reply            → reply to a message, keeping the thread.
//   * mail.mark_read        → mark a message read/unread.
//   * mail.flag             → flag/unflag a message.
//   * mail.trash            → move a message to the account's trash.
//   * mail.archive          → move a message to the account's archive.
//   * ping                  → answered with -32601 like Hermes ACP does, which the
//                             phone's heartbeat treats as proof of life.
//
// Mail lifecycle pushes (mail.sync_complete / mail.unread_count_changed) are
// broadcast by MailManager's callbacks, wired in AppDelegate exactly like the
// briefing's onGenerated.
//
// Code lifecycle pushes (code.chunk / code.status / code.test_result /
// code.git_status) are broadcast by AlfredCodeManager's callbacks, wired in
// AppDelegate exactly like the briefing's onGenerated.
//
// Routine lifecycle pushes (routine.started / routine.progress /
// routine.completed) are broadcast by RoutineManager's callbacks, wired in
// AppDelegate exactly like the briefing's onGenerated.
//
// Every other method is answered with a -32601 "method not found" error, so an
// unknown call fails loudly instead of hanging the phone's pending request.

/// A connected phone. Owns the connection and the frame state machine; all
/// callbacks hop to the server's queue so state stays serialized.
private final class BriefingClient {
    enum State {
        /// Reading the HTTP Upgrade request.
        case handshake
        /// Reading WebSocket frames.
        case open
        case closed
    }

    let connection: NWConnection
    var state: State = .handshake
    /// Bytes read but not yet consumed.
    var buffer = Data()
    /// The HTTP request headers, until the handshake completes.
    var requestHeaders = ""

    init(connection: NWConnection) {
        self.connection = connection
    }
}

/// One RFC 6455 frame, decoded.
private struct WSFrame {
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    let opcode: Opcode
    let payload: Data
}

final class BriefingSocketServer {

    static let shared = BriefingSocketServer()

    /// Must match the iOS client's `AlfredWebSocketClient.defaultPort`.
    static let port: UInt16 = 8766
    /// Must match the iOS client's `TailscaleConnection.serviceType`.
    static let serviceType = "_alfred._tcp"
    static let serviceName = "alfred"

    private var listener: NWListener?
    private var clients: [BriefingClient] = []
    private let queue = DispatchQueue(label: "alfred.briefing-server")
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Start listening and advertising. Idempotent. Failure (port in use) is
    /// logged, never fatal — the briefing still generates locally.
    func start() {
        guard !started else { return }
        do {
            var options = NWProtocolTCP.Options()
            options.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: options)
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            // Advertise the Bonjour service the phone browses for.
            listener.service = NWListener.Service(
                name: Self.serviceName, type: Self.serviceType, domain: "local.")

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("[briefing-server] listening on :\(Self.port), advertising \(Self.serviceType)")
                case .failed(let error):
                    NSLog("[briefing-server] listener failed: %@", error.localizedDescription)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            started = true
        } catch {
            NSLog("[briefing-server] could not listen on :\(Self.port): %@", error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients { client.connection.cancel() }
        clients.removeAll()
        started = false
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let client = BriefingClient(connection: connection)
        // The client must be strongly held for as long as the connection lives:
        // the receive loop's closures hold it weakly, so an unowned client would
        // deallocate the moment accept returns and the handshake would never
        // be answered.
        clients.append(client)
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled:
                self.drop(client)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: client)
    }

    /// Read whatever arrives; each chunk is fed to the frame state machine.
    private func receive(on client: BriefingClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let error {
                NSLog("[briefing-server] connection error: %@", error.localizedDescription)
                self.drop(client)
                return
            }
            if let data, !data.isEmpty {
                client.buffer.append(data)
            }
            self.process(client)
            if isComplete {
                self.drop(client)
            } else if client.state != .closed {
                self.receive(on: client)
            }
        }
    }

    /// Drain the buffer: finish the handshake first, then decode frames.
    private func process(_ client: BriefingClient) {
        switch client.state {
        case .handshake:
            if completeHandshake(client) {
                process(client)
            }
        case .open:
            while let frame = nextFrame(from: &client.buffer, dropping: client) {
                handle(frame, on: client)
            }
        case .closed:
            break
        }
    }

    // MARK: - Handshake (RFC 6455 §4.2)

    /// Consume the HTTP Upgrade request and answer 101. Returns true once open.
    private func completeHandshake(_ client: BriefingClient) -> Bool {
        client.requestHeaders += String(decoding: client.buffer, as: UTF8.self)
        client.buffer.removeAll()

        guard let headerEnd = client.requestHeaders.range(of: "\r\n\r\n") else { return false }
        let headerBlock = String(client.requestHeaders[..<headerEnd.lowerBound])
        let leftover = String(client.requestHeaders[headerEnd.upperBound...])
        client.requestHeaders = ""
        client.buffer.append(Data(leftover.utf8))

        guard let key = Self.secWebSocketKey(from: headerBlock) else {
            NSLog("[briefing-server] handshake missing Sec-WebSocket-Key — dropping")
            drop(client)
            return false
        }

        let accept = Self.secWebSocketAccept(key: key)
        // Explicit CRLF, not a multiline literal: Swift's `"""` swallows the
        // newline before the closing delimiter, which would leave the header
        // terminator one byte short and stall a strict client forever.
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        client.state = .open
        NSLog("[briefing-server] handshake complete — client open")
        return true
    }

    private static func secWebSocketKey(from headers: String) -> String? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func secWebSocketAccept(key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    // MARK: - Frame codec (RFC 6455 §5)

    /// Decode one frame from the front of the client's buffer, or nil if
    /// incomplete. Client→server frames are masked; server→client frames are
    /// not. A protocol violation (unknown opcode) drops just that client.
    private func nextFrame(from buffer: inout Data, dropping client: BriefingClient) -> WSFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let opcode = WSFrame.Opcode(rawValue: first & 0x0F)
        let masked = (second & 0x80) != 0
        var length = Int(second & 0x7F)
        var offset = 2

        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = Int(buffer[buffer.startIndex + offset]) << 8
                | Int(buffer[buffer.startIndex + offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var extended: UInt64 = 0
            for i in 0..<8 {
                extended = (extended << 8) | UInt64(buffer[buffer.startIndex + offset + i])
            }
            length = Int(extended)
            offset += 8
        }

        guard let opcode else {
            // Unknown opcode — protocol violation. One bad client shouldn't
            // take down the others, so drop just this one.
            NSLog("[briefing-server] unknown opcode — dropping client")
            drop(client)
            return nil
        }

        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[buffer.startIndex + offset..<buffer.startIndex + offset + 4])
            offset += 4
        }

        guard buffer.count >= offset + length else { return nil }
        var payload = Array(buffer[buffer.startIndex + offset..<buffer.startIndex + offset + length])
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + offset + length)
        return WSFrame(opcode: opcode, payload: Data(payload))
    }

    /// Encode a text frame (server→client: never masked).
    private func textFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data()
        frame.append(0x81)   // FIN + text opcode
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var length = UInt64(payload.count)
            for _ in 0..<8 {
                frame.append(UInt8(length & 0xFF))
                length >>= 8
            }
        }
        frame.append(payload)
        return frame
    }

    // MARK: - Frames

    private func handle(_ frame: WSFrame, on client: BriefingClient) {
        switch frame.opcode {
        case .text:
            guard let text = String(data: frame.payload, encoding: .utf8) else { return }
            handleJSON(text, on: client)
        case .ping:
            // RFC 6455 §5.5.3: pong with the same payload.
            send(pong: frame.payload, on: client)
        case .close:
            client.state = .closed
            client.connection.send(content: closeFrame, completion: .contentProcessed { _ in })
            drop(client)
        case .pong, .binary, .continuation:
            break
        }
    }

    private var closeFrame: Data {
        // FIN + close opcode, empty payload.
        Data([0x88, 0x00])
    }

    private func send(pong payload: Data, on client: BriefingClient) {
        var frame = Data([0x8A])   // FIN + pong
        frame.append(UInt8(payload.count))
        frame.append(payload)
        client.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func send(text: String, on client: BriefingClient) {
        client.connection.send(content: textFrame(text), completion: .contentProcessed { _ in })
    }

    // MARK: - JSON-RPC dispatch

    private func handleJSON(_ text: String, on client: BriefingClient) {
        guard let data = text.data(using: .utf8),
              let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        let method = frame["method"] as? String
        let id = frame["id"]

        // A request with an id expects a correlated response.
        if let method, let id {
            switch method {
            case "briefing.get":
                respondBriefing(id: id, force: false, on: client)
            case "briefing.get_now":
                respondBriefing(id: id, force: true, on: client)
            case "routines.list":
                respondRoutinesList(id: id, on: client)
            case "routines.run":
                respondRoutineRun(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "routines.create":
                respondRoutineCreate(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "routines.update":
                respondRoutineUpdate(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "routines.delete":
                respondRoutineDelete(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "routines.schedule":
                respondRoutineSchedule(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.sessions":
                respondCodeSessions(id: id, on: client)
            case "code.start_session":
                respondCodeStart(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.pause_session":
                respondCodePause(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.resume_session":
                respondCodeResume(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.stop_session":
                respondCodeStop(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.delete_session":
                respondCodeDelete(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.refine":
                respondCodeRefine(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.run_tests":
                respondCodeRunTests(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_status":
                respondCodeGitStatus(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_diff":
                respondCodeGitDiff(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_commit":
                respondCodeGitCommit(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_branch_create":
                respondCodeGitBranchCreate(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_branch_switch":
                respondCodeGitBranchSwitch(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_list_branches":
                respondCodeGitListBranches(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_push":
                respondCodeGitPush(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.git_pull":
                respondCodeGitPull(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "code.projects":
                respondCodeProjects(id: id, on: client)
            case "mail.accounts":
                respondMailAccounts(id: id, on: client)
            case "mail.inbox":
                respondMailInbox(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.folders":
                respondMailFolders(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.message":
                respondMailMessage(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.search":
                respondMailSearch(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.sync":
                respondMailSync(id: id, on: client)
            case "mail.send":
                respondMailSend(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.reply":
                respondMailReply(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.mark_read":
                respondMailMarkRead(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.flag":
                respondMailFlag(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.trash":
                respondMailMove(id: id, params: frame["params"] as? [String: Any] ?? [:], role: "trash", on: client)
            case "mail.archive":
                respondMailMove(id: id, params: frame["params"] as? [String: Any] ?? [:], role: "archive", on: client)
            case "mail.unarchive":
                respondMailMove(id: id, params: frame["params"] as? [String: Any] ?? [:], role: "inbox", on: client)
            case "mail.classify":
                respondMailClassify(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.summarize":
                respondMailSummarize(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.extract_tasks":
                respondMailExtractTasks(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.draft_reply":
                respondMailDraftReply(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.search_ai":
                respondMailSearchAI(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.scan":
                respondMailScan(id: id, on: client)
            case "mail.scan_summary":
                respondMailScanSummary(id: id, on: client)
            case "mail.settings":
                respondMailSettings(id: id, on: client)
            case "mail.set_settings":
                respondMailSetSettings(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.folder_messages":
                respondMailFolderMessages(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.move_folder":
                respondMailMoveFolder(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.save_draft":
                respondMailSaveDraft(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.draft_alternatives":
                respondMailDraftAlternatives(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "mail.draft_revise":
                respondMailDraftRevise(id: id, params: frame["params"] as? [String: Any] ?? [:], on: client)
            case "ping":
                // Deliberate -32601: a live ACP endpoint answers ping with
                // "method not found", and the phone's heartbeat treats any
                // answer as proof of life.
                respondError(id: id, code: -32601, message: "method not found", on: client)
            default:
                respondError(id: id, code: -32601, message: "method not found", on: client)
            }
            return
        }

        // Notifications (no id): nothing to answer.
    }

    private func respondBriefing(id: Any, force: Bool, on client: BriefingClient) {
        Task {
            let generator = BriefingGenerator.shared
            let content: BriefingContent
            if force {
                content = await generator.generate(focusedDay: "today")
            } else if let latest = generator.getCurrentBriefing() {
                content = latest
            } else {
                content = await generator.generate(focusedDay: "today")
            }
            let payload = Self.contentDictionary(content)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": payload,
            ]
            let json = Self.jsonString(response)
            self.send(text: json, on: client)
        }
    }

    // MARK: - Routines (JSON-RPC)

    private func respondRoutinesList(id: Any, on client: BriefingClient) {
        Task { @MainActor in
            let routines = RoutineManager.shared.listRoutines().map(Self.routineWireDictionary)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["routines": routines],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondRoutineRun(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let idString = params["routine_id"] as? String,
              let routineID = UUID(uuidString: idString) else {
            respondError(id: id, code: -32602, message: "routine_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let result = await RoutineManager.shared.runRoutine(id: routineID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": Self.resultDictionary(result),
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondRoutineCreate(id: Any, params: [String: Any], on client: BriefingClient) {
        // One-tap template add: the phone sends only the template name and the
        // Mac builds it from the single source of truth.
        if let templateName = params["template"] as? String {
            guard let template = RoutineTemplates.all.first(where: { $0.name == templateName }) else {
                respondError(id: id, code: -32602, message: "Unknown template.", on: client)
                return
            }
            Task { @MainActor in
                let routine = RoutineManager.shared.createRoutine(
                    name: template.name,
                    description: template.description,
                    steps: template.steps,
                    schedule: template.schedule)
                let response: [String: Any] = [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["routine": Self.routineWireDictionary(routine)],
                ]
                self.send(text: Self.jsonString(response), on: client)
            }
            return
        }
        guard let name = params["name"] as? String, !name.isEmpty else {
            respondError(id: id, code: -32602, message: "name is required", on: client)
            return
        }
        let steps = Self.steps(from: params["steps"])
        guard !steps.isEmpty else {
            respondError(id: id, code: -32602, message: "at least one step is required", on: client)
            return
        }
        guard let schedule = Self.schedule(from: params["schedule"]) else {
            respondError(id: id, code: -32602, message: "schedule is malformed", on: client)
            return
        }
        Task { @MainActor in
            let routine = RoutineManager.shared.createRoutine(
                name: name,
                description: params["description"] as? String ?? "",
                steps: steps,
                schedule: schedule,
                enabled: params["enabled"] as? Bool ?? true)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["routine": Self.routineWireDictionary(routine)],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondRoutineUpdate(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let idString = params["routine_id"] as? String,
              let routineID = UUID(uuidString: idString) else {
            respondError(id: id, code: -32602, message: "routine_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let manager = RoutineManager.shared

            // Malformed steps/schedule are errors, never silent degradation — a
            // bad schedule silently flipping a weekly routine to on-demand would
            // be invisible to the person who typed it.
            var stepsParam: [RoutineStep]?
            if params["steps"] != nil {
                let decoded = Self.steps(from: params["steps"])
                guard !decoded.isEmpty else {
                    self.respondError(id: id, code: -32602, message: "steps must be an array of valid steps", on: client)
                    return
                }
                stepsParam = decoded
            }
            var scheduleParam: RoutineSchedule?
            if params["schedule"] != nil {
                guard let decoded = Self.schedule(from: params["schedule"]) else {
                    self.respondError(id: id, code: -32602, message: "schedule is malformed", on: client)
                    return
                }
                scheduleParam = decoded
            }

            let updated = manager.updateRoutine(
                id: routineID,
                name: params["name"] as? String,
                description: params["description"] as? String,
                steps: stepsParam,
                schedule: scheduleParam,
                enabled: params["enabled"] as? Bool)
            guard let updated else {
                self.respondError(id: id, code: -32602, message: "No routine with that id.", on: client)
                return
            }
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["routine": Self.routineWireDictionary(updated)],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondRoutineDelete(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let idString = params["routine_id"] as? String,
              let routineID = UUID(uuidString: idString) else {
            respondError(id: id, code: -32602, message: "routine_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let deleted = RoutineManager.shared.deleteRoutine(id: routineID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": deleted],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondRoutineSchedule(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let idString = params["routine_id"] as? String,
              let routineID = UUID(uuidString: idString) else {
            respondError(id: id, code: -32602, message: "routine_id must be a UUID", on: client)
            return
        }
        let at = params["at"] as? TimeInterval ?? 0
        guard at > Date().timeIntervalSince1970 else {
            respondError(id: id, code: -32602, message: "at must be a future timestamp", on: client)
            return
        }
        Task { @MainActor in
            let scheduled = RoutineManager.shared.scheduleRoutine(
                id: routineID, for: Date(timeIntervalSince1970: at))
            guard let scheduled else {
                self.respondError(id: id, code: -32602, message: "No routine with that id.", on: client)
                return
            }
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["routine": Self.routineWireDictionary(scheduled)],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    // MARK: - Code sessions (JSON-RPC)

    private func respondCodeSessions(id: Any, on client: BriefingClient) {
        Task { @MainActor in
            let sessions = AlfredCodeManager.shared.listSessions().map(Self.codeSessionDictionary)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["sessions": sessions],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeStart(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let prompt = params["prompt"] as? String, !prompt.isEmpty else {
            respondError(id: id, code: -32602, message: "prompt is required", on: client)
            return
        }
        guard let projectPath = params["project_path"] as? String, !projectPath.isEmpty else {
            respondError(id: id, code: -32602, message: "project_path is required", on: client)
            return
        }
        let engine = Self.engine(from: params["agent"] as? String)
        Task { @MainActor in
            do {
                let session = try await AlfredCodeManager.shared.startSession(
                    prompt: prompt, projectPath: projectPath, agent: engine)
                let response: [String: Any] = [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["session": Self.codeSessionDictionary(session)],
                ]
                self.send(text: Self.jsonString(response), on: client)
            } catch {
                self.respondError(id: id, code: -32602, message: error.localizedDescription, on: client)
            }
        }
    }

    private func respondCodePause(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            await AlfredCodeManager.shared.pauseSession(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": true],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeResume(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            await AlfredCodeManager.shared.resumeSession(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": true],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeStop(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            await AlfredCodeManager.shared.stopSession(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": true],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeDelete(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            await AlfredCodeManager.shared.deleteSession(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": true],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeRefine(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        guard let request = params["request"] as? String, !request.isEmpty else {
            respondError(id: id, code: -32602, message: "request is required", on: client)
            return
        }
        Task { @MainActor in
            do {
                try await AlfredCodeManager.shared.refineCode(id: sessionID, request: request)
                let response: [String: Any] = [
                    "jsonrpc": "2.0", "id": id, "result": ["success": true],
                ]
                self.send(text: Self.jsonString(response), on: client)
            } catch {
                self.respondError(id: id, code: -32602, message: error.localizedDescription, on: client)
            }
        }
    }

    private func respondCodeRunTests(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let result = await AlfredCodeManager.shared.runTests(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": Self.testResultDictionary(result),
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitStatus(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let status = await AlfredCodeManager.shared.gitStatus(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": status.map(Self.gitStatusDictionary) ?? [:],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitDiff(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let diff = await AlfredCodeManager.shared.gitDiff(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["diff": diff],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitCommit(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        guard let message = params["message"] as? String, !message.isEmpty else {
            respondError(id: id, code: -32602, message: "message is required", on: client)
            return
        }
        Task { @MainActor in
            let hash = await AlfredCodeManager.shared.gitCommit(id: sessionID, message: message)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": hash != nil, "hash": hash ?? ""],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitBranchCreate(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        guard let name = params["name"] as? String, !name.isEmpty else {
            respondError(id: id, code: -32602, message: "name is required", on: client)
            return
        }
        Task { @MainActor in
            let status = await AlfredCodeManager.shared.gitCreateBranch(id: sessionID, name: name)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": status.map(Self.gitStatusDictionary) ?? [:],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitBranchSwitch(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        guard let name = params["name"] as? String, !name.isEmpty else {
            respondError(id: id, code: -32602, message: "name is required", on: client)
            return
        }
        Task { @MainActor in
            let status = await AlfredCodeManager.shared.gitSwitchBranch(id: sessionID, name: name)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": status.map(Self.gitStatusDictionary) ?? [:],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitListBranches(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let branches = await AlfredCodeManager.shared.gitListBranches(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["branches": branches],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitPush(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let message = await AlfredCodeManager.shared.gitPush(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": true, "message": message],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondCodeGitPull(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let sessionID = Self.sessionID(from: params) else {
            respondError(id: id, code: -32602, message: "session_id must be a UUID", on: client)
            return
        }
        Task { @MainActor in
            let message = await AlfredCodeManager.shared.gitPull(id: sessionID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["success": true, "message": message],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// Candidate project folders for the phone's project picker: a bounded
    /// scan of the usual dev roots for directories holding a manifest or a
    /// `.git` folder. The scan is pure (static), so it runs detached and the
    /// send hops to the main actor like every other handler.
    private func respondCodeProjects(id: Any, on client: BriefingClient) {
        let payload = Task.detached(priority: .utility) {
            Self.jsonString([
                "jsonrpc": "2.0", "id": id, "result": ["projects": Self.discoverProjects()],
            ])
        }
        Task { @MainActor in
            let json = await payload.value
            self.send(text: json, on: client)
        }
    }

    /// Scan a few common dev roots (and their immediate children) for project
    /// folders. Bounded so a huge home directory can't hang the phone's picker.
    private static func discoverProjects() -> [[String: Any]] {
        let home = NSHomeDirectory()
        let roots = [
            "\(home)/Projects", "\(home)/Developer", "\(home)/Documents",
            "\(home)/Desktop", "\(home)/02 - REPOS", "\(home)/01 - PROJECTS",
        ]
        let fm = FileManager.default
        let markers = ["package.json", "Package.swift", "Cargo.toml", "go.mod",
                       "requirements.txt", "pyproject.toml", "setup.py", "Gemfile",
                       "pom.xml", "build.gradle", ".git"]
        var found: [[String: Any]] = []
        var seen = Set<String>()

        func isProject(_ dir: String) -> Bool {
            markers.contains { fm.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }
        }
        func add(_ dir: String) {
            guard found.count < 40, seen.insert(dir).inserted else { return }
            let type = ProjectType.detect(at: dir).rawValue
            found.append(["path": dir, "type": type, "name": (dir as NSString).lastPathComponent])
        }

        for root in roots where fm.fileExists(atPath: root) {
            if isProject(root) { add(root) }
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for child in children where !child.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if isProject(path) { add(path) }
            }
        }
        return found
    }

    // MARK: - Mail (JSON-RPC)

    /// All accounts on the Mac, with unread counts for the filter chips.
    private func respondMailAccounts(id: Any, on client: BriefingClient) {
        Task { @MainActor in
            let manager = MailManager.shared
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "accounts": manager.accountsWire(),
                    "total_unread": manager.totalUnread,
                    "backend_available": manager.isBackendAvailable,
                ],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// The cached unified (or per-account) inbox, newest first.
    private func respondMailInbox(id: Any, params: [String: Any], on client: BriefingClient) {
        let accountID = params["account_id"] as? String
        let limit = (params["limit"] as? Int).map { min(max($0, 1), 200) } ?? 100
        Task { @MainActor in
            let manager = MailManager.shared
            let messages = manager.inbox(accountID: accountID, limit: limit).map(manager.messageWire)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["messages": messages, "total_unread": manager.totalUnread],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// One account's mailboxes with counts.
    private func respondMailFolders(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let accountID = params["account_id"] as? String, !accountID.isEmpty else {
            respondError(id: id, code: -32602, message: "account_id is required", on: client)
            return
        }
        Task { @MainActor in
            let manager = MailManager.shared
            let folders = await manager.folders(accountID: accountID)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["folders": folders.map(manager.folderWire)],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// A full message with body + attachments, for the reader screen. The body
    /// is fetched from Himalaya on demand — the cache only holds envelopes.
    private func respondMailMessage(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let account = params["account_id"] as? String,
              let mailbox = params["mailbox"] as? String,
              let uid = params["uid"] as? String else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        Task { @MainActor in
            let manager = MailManager.shared
            do {
                let parts = try await manager.messageParts(account: account, mailbox: mailbox, uid: uid)
                let envelope = manager.message(account: account, mailbox: mailbox, uid: uid)
                var dict = envelope.map(manager.messageWire) ?? [
                    "id": "\(account)\u{1F}\(mailbox)\u{1F}\(uid)",
                    "account_id": account, "mailbox": mailbox, "uid": uid,
                    "from": parts.from, "from_address": parts.fromAddress,
                    "subject": parts.subject, "date": parts.date?.timeIntervalSince1970 ?? 0,
                    "snippet": String(parts.text.prefix(120)),
                    "seen": true, "flagged": false,
                    "has_attachments": !parts.attachments.isEmpty,
                ]
                dict["body"] = ["text": parts.text, "html": parts.html ?? ""]
                dict["attachments"] = parts.attachments.map { attachment in
                    ["id": attachment.id, "filename": attachment.filename,
                     "mime": attachment.mime, "size": attachment.size]
                }
                let response: [String: Any] = [
                    "jsonrpc": "2.0", "id": id, "result": ["message": dict],
                ]
                self.send(text: Self.jsonString(response), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    /// Search the cached inbox — subject, sender, snippet.
    private func respondMailSearch(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let query = params["query"] as? String, !query.isEmpty else {
            respondError(id: id, code: -32602, message: "query is required", on: client)
            return
        }
        Task { @MainActor in
            let manager = MailManager.shared
            let messages = manager.search(query: query, accountID: params["account_id"] as? String)
                .map(manager.messageWire)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["messages": messages],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// Force a sync now (pull-to-refresh on the phone). The manager also
    /// broadcasts mail.sync_complete via its callback, wired in AppDelegate.
    private func respondMailSync(id: Any, on client: BriefingClient) {
        Task { @MainActor in
            let manager = MailManager.shared
            await manager.sync()
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["success": true, "unread": manager.totalUnread,
                            "at": Date().timeIntervalSince1970],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    private func respondMailSend(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let to = params["to"] as? String, !to.isEmpty else {
            respondError(id: id, code: -32602, message: "to is required", on: client)
            return
        }
        Task { @MainActor in
            do {
                try await MailManager.shared.send(
                    to: to,
                    cc: params["cc"] as? String,
                    subject: params["subject"] as? String ?? "",
                    body: params["body"] as? String ?? "",
                    accountID: params["account_id"] as? String ?? "",
                    inReplyTo: params["in_reply_to"] as? String)
                // What the owner actually sends teaches the drafter.
                MailLearningService.shared.observeSent(
                    subject: params["subject"] as? String ?? "",
                    body: params["body"] as? String ?? "")
                let response: [String: Any] = [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["sent": true, "message": "Message sent."],
                ]
                self.send(text: Self.jsonString(response), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    /// Reply to a message: re-reads it for the In-Reply-To header and the
    /// original sender, keeps the thread with a Re: subject.
    private func respondMailReply(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let account = params["account_id"] as? String,
              let mailbox = params["mailbox"] as? String,
              let uid = params["uid"] as? String,
              let body = params["body"] as? String else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox, uid and body are required", on: client)
            return
        }
        Task { @MainActor in
            let manager = MailManager.shared
            do {
                let parts = try await manager.messageParts(account: account, mailbox: mailbox, uid: uid)
                // The review screen can override subject/cc; defaults keep the
                // standard Re: subject and no cc.
                let subject: String
                if let override = params["subject"] as? String, !override.isEmpty {
                    subject = override
                } else {
                    subject = parts.subject.hasPrefix("Re:") ? parts.subject : "Re: " + parts.subject
                }
                let cc = (params["cc"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                try await manager.send(
                    to: parts.fromAddress, cc: cc, subject: subject, body: body,
                    accountID: account,
                    inReplyTo: parts.messageID.isEmpty ? nil : parts.messageID)
                // Replies are sent mail too — they teach the drafter.
                MailLearningService.shared.observeSent(subject: subject, body: body)
                let response: [String: Any] = [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["sent": true, "message": "Reply sent to \(parts.fromAddress)."],
                ]
                self.send(text: Self.jsonString(response), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    private func respondMailMarkRead(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let account = params["account_id"] as? String,
              let mailbox = params["mailbox"] as? String,
              let uid = params["uid"] as? String else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        let read = params["read"] as? Bool ?? true
        Task { @MainActor in
            do {
                try await MailManager.shared.markRead(account: account, mailbox: mailbox, uid: uid, read: read)
                self.send(text: Self.jsonString([
                    "jsonrpc": "2.0", "id": id, "result": ["success": true],
                ]), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    private func respondMailFlag(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let account = params["account_id"] as? String,
              let mailbox = params["mailbox"] as? String,
              let uid = params["uid"] as? String else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        let flagged = params["flagged"] as? Bool ?? true
        Task { @MainActor in
            do {
                try await MailManager.shared.setFlag(account: account, mailbox: mailbox, uid: uid, flagged: flagged)
                self.send(text: Self.jsonString([
                    "jsonrpc": "2.0", "id": id, "result": ["success": true],
                ]), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    /// Trash and archive are the same operation — a role-resolved move — with
    /// different destinations.
    private func respondMailMove(id: Any, params: [String: Any], role: String, on client: BriefingClient) {
        guard let account = params["account_id"] as? String,
              let mailbox = params["mailbox"] as? String,
              let uid = params["uid"] as? String else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        Task { @MainActor in
            do {
                try await MailManager.shared.move(account: account, mailbox: mailbox, uid: uid, to: role)
                self.send(text: Self.jsonString([
                    "jsonrpc": "2.0", "id": id, "result": ["success": true],
                ]), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    // MARK: - Mail AI (JSON-RPC)

    /// Classify a message for the inline list chips and the reader's tone line.
    /// Runs through MailAIService (Hermes + 24h cache); a busy session returns
    /// a null classification, which the phone renders as "no chip yet" rather
    /// than an error.
    private func respondMailClassify(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let triple = Self.mailTriple(from: params) else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        Task { @MainActor in
            let classification = await MailAIService.shared.classify(
                account: triple.account, mailbox: triple.mailbox, uid: triple.uid)
            let result: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["classification": classification.map(Self.mailClassificationWire) as Any],
            ]
            self.send(text: Self.jsonString(result), on: client)
        }
    }

    /// Summarize a message (and its conversation) for the reader's AI panel.
    private func respondMailSummarize(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let triple = Self.mailTriple(from: params) else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        Task { @MainActor in
            let summary = await MailAIService.shared.summarize(
                account: triple.account, mailbox: triple.mailbox, uid: triple.uid)
            let result: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["summary": summary.map(Self.mailSummaryWire) as Any],
            ]
            self.send(text: Self.jsonString(result), on: client)
        }
    }

    /// Extract action items for the reader's Tasks popover.
    private func respondMailExtractTasks(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let triple = Self.mailTriple(from: params) else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        Task { @MainActor in
            let tasks = await MailAIService.shared.extractTasks(
                account: triple.account, mailbox: triple.mailbox, uid: triple.uid)
            let result: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["tasks": tasks.map(Self.mailTaskWire)],
            ]
            self.send(text: Self.jsonString(result), on: client)
        }
    }

    /// Draft a reply in the owner's voice, for the reader's quick reply.
    private func respondMailDraftReply(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let triple = Self.mailTriple(from: params) else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        Task { @MainActor in
            let draft = await MailAIService.shared.draftReply(
                account: triple.account, mailbox: triple.mailbox, uid: triple.uid,
                tone: params["tone"] as? String)
            let result: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["draft": draft.map(Self.mailDraftWire) as Any],
            ]
            self.send(text: Self.jsonString(result), on: client)
        }
    }

    /// Natural-language search: the model compiles the query into a filter
    /// that runs over the cached inbox, plus a one-line note for the phone's
    /// results header. Degrades to plain LIKE search (note: null) when Hermes
    /// is busy — search itself never fails.
    private func respondMailSearchAI(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let query = params["query"] as? String, !query.isEmpty else {
            respondError(id: id, code: -32602, message: "query is required", on: client)
            return
        }
        Task { @MainActor in
            let manager = MailManager.shared
            let result = await MailAIService.shared.search(
                query: query, accountID: params["account_id"] as? String)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "messages": result.messages.map(manager.messageWire),
                    "note": (result.note.isEmpty ? NSNull() : result.note) as Any,
                ],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    // MARK: - Mail scan, settings & draft review (JSON-RPC)

    /// Run a full folder sweep now and return its summary (the scan header's
    /// pull-to-refresh). The periodic sweep also broadcasts `mail.scan_complete`.
    private func respondMailScan(id: Any, on client: BriefingClient) {
        Task { @MainActor in
            let summary = await MailScanService.shared.scanNow()
                ?? MailScanService.persistedSummary()
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["scan": Self.mailScanSummaryWire(summary)],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// The last completed sweep — what the phone's scan header shows without
    /// paying for a fresh one.
    private func respondMailScanSummary(id: Any, on client: BriefingClient) {
        let summary = MailScanService.persistedSummary()
        let response: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "result": ["scan": Self.mailScanSummaryWire(summary)],
        ]
        self.send(text: Self.jsonString(response), on: client)
    }

    /// Read the current email settings (signature, tone, scan frequency…).
    private func respondMailSettings(id: Any, on client: BriefingClient) {
        let settings = MailSettingsStore.shared.current
        let response: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "result": ["settings": Self.mailSettingsWire(settings)],
        ]
        self.send(text: Self.jsonString(response), on: client)
    }

    /// Update email settings from the phone; re-arm the sweep timer if the
    /// frequency changed.
    private func respondMailSetSettings(id: Any, params: [String: Any], on client: BriefingClient) {
        let frequency = params["scan_frequency_minutes"] as? Int
        let tone = params["draft_tone"] as? String
        let autoLearn = params["auto_learn_sent"] as? Bool
        let notify = params["notify_on_important"] as? Bool
        let excluded = params["excluded_folders"] as? [String]
        let signature = params["signature"] as? String
        let signatureAccount = params["signature_account"] as? String

        Task { @MainActor in
            MailSettingsStore.shared.update { settings in
                if let frequency, [5, 15, 30, 60].contains(frequency) {
                    settings.scanFrequencyMinutes = frequency
                }
                if let tone { settings.draftTone = tone }
                if let autoLearn { settings.autoLearnSent = autoLearn }
                if let notify { settings.notifyOnImportant = notify }
                if let excluded { settings.excludedFolders = excluded }
                if let signatureAccount, let signature {
                    settings.signatures[signatureAccount] = signature
                }
            }
            MailScanService.shared.reschedule()
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "success": true,
                    "settings": Self.mailSettingsWire(MailSettingsStore.shared.current),
                ],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// Messages cached for one folder (every folder when folder_id is omitted)
    /// — the "By Folder" drill-down.
    private func respondMailFolderMessages(id: Any, params: [String: Any], on client: BriefingClient) {
        let accountID = params["account_id"] as? String
        let folderID = params["folder_id"] as? String
        let limit = (params["limit"] as? Int).map { min(max($0, 1), 200) } ?? 100
        Task { @MainActor in
            let manager = MailManager.shared
            let messages = manager.folderMessages(accountID: accountID, mailbox: folderID, limit: limit)
                .map(manager.messageWire)
            let response: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["messages": messages],
            ]
            self.send(text: Self.jsonString(response), on: client)
        }
    }

    /// Move a message to an explicit destination folder — the one-tap "Move to
    /// Inbox" for junk finds, and general re-organization.
    private func respondMailMoveFolder(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let triple = Self.mailTriple(from: params),
              let destination = params["destination"] as? String, !destination.isEmpty else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox, uid and destination are required", on: client)
            return
        }
        Task { @MainActor in
            do {
                try await MailManager.shared.moveToFolder(
                    account: triple.account, mailbox: triple.mailbox,
                    uid: triple.uid, destination: destination)
                self.send(text: Self.jsonString([
                    "jsonrpc": "2.0", "id": id, "result": ["success": true],
                ]), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    /// Save a message as a draft (the review screen's "Save as Draft").
    private func respondMailSaveDraft(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let to = params["to"] as? String, !to.isEmpty else {
            respondError(id: id, code: -32602, message: "to is required", on: client)
            return
        }
        Task { @MainActor in
            do {
                try await MailManager.shared.saveDraft(
                    to: to,
                    cc: params["cc"] as? String,
                    subject: params["subject"] as? String ?? "",
                    body: params["body"] as? String ?? "",
                    accountID: params["account_id"] as? String ?? "",
                    inReplyTo: params["in_reply_to"] as? String)
                self.send(text: Self.jsonString([
                    "jsonrpc": "2.0", "id": id,
                    "result": ["saved": true, "message": "Draft saved."],
                ]), on: client)
            } catch {
                self.respondError(id: id, code: -32602,
                                  message: error.localizedDescription, on: client)
            }
        }
    }

    /// The review screen's "Show alternatives" — three tones for one message.
    private func respondMailDraftAlternatives(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let triple = Self.mailTriple(from: params) else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox and uid are required", on: client)
            return
        }
        Task { @MainActor in
            let drafts = await MailAIService.shared.draftAlternatives(
                account: triple.account, mailbox: triple.mailbox, uid: triple.uid)
            let result: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["alternatives": drafts.map(Self.mailDraftWire)],
            ]
            self.send(text: Self.jsonString(result), on: client)
        }
    }

    /// Revise a draft in place from a natural-language instruction.
    private func respondMailDraftRevise(id: Any, params: [String: Any], on client: BriefingClient) {
        guard let triple = Self.mailTriple(from: params),
              let instruction = params["instruction"] as? String, !instruction.isEmpty else {
            respondError(id: id, code: -32602,
                         message: "account_id, mailbox, uid and instruction are required", on: client)
            return
        }
        Task { @MainActor in
            let draft = await MailAIService.shared.reviseDraft(
                account: triple.account, mailbox: triple.mailbox, uid: triple.uid,
                currentSubject: params["subject"] as? String ?? "",
                currentBody: params["body"] as? String ?? "",
                instruction: instruction)
            let result: [String: Any] = [
                "jsonrpc": "2.0", "id": id,
                "result": ["draft": draft.map(Self.mailDraftWire) as Any],
            ]
            self.send(text: Self.jsonString(result), on: client)
        }
    }

    /// The (account, mailbox, uid) triple every message-addressed mail method
    /// guards on.
    private static func mailTriple(from params: [String: Any])
        -> (account: String, mailbox: String, uid: String)? {
        guard let account = params["account_id"] as? String,
              let mailbox = params["mailbox"] as? String,
              let uid = params["uid"] as? String
        else { return nil }
        return (account, mailbox, uid)
    }

    // MARK: - Code sessions (wire helpers)

    /// A CodeSession as the phone expects it.
    static func codeSessionDictionary(_ session: CodeSession) -> [String: Any] {
        var dict: [String: Any] = [
            "session_id": session.sessionId.uuidString,
            "prompt": session.prompt,
            "project_path": session.projectPath,
            "project_type": session.projectType.rawValue,
            "status": session.status.rawValue,
            "generated_code": session.generatedCode,
            "created_at": session.createdAt,
            "updated_at": session.updatedAt,
        ]
        if let gitStatus = session.gitStatus {
            dict["git_status"] = gitStatusDictionary(gitStatus)
        }
        if let lastTest = session.lastTestResult {
            dict["last_test_result"] = testResultDictionary(lastTest)
        }
        return dict
    }

    static func gitStatusDictionary(_ status: GitStatus) -> [String: Any] {
        [
            "current_branch": status.currentBranch,
            "uncommitted_changes": status.uncommittedChanges,
            "unstaged_files": status.unstagedFiles,
        ]
    }

    static func testResultDictionary(_ result: TestResult) -> [String: Any] {
        [
            "success": result.success,
            "output": result.output,
            "duration": result.duration,
            "command": result.command,
        ]
    }

    /// Parse the agent string the phone sent; anything unknown defaults to
    /// opencode, the primary coding agent.
    private static func engine(from agent: String?) -> AgentEngine {
        switch agent?.lowercased() {
        case "freebuff": return .freebuff
        case "prime", "prime-agent": return .primeAgent
        default: return .opencode
        }
    }

    private static func sessionID(from params: [String: Any]) -> UUID? {
        guard let idString = params["session_id"] as? String else { return nil }
        return UUID(uuidString: idString)
    }

    // MARK: - Routines (wire helpers)

    /// A Routine as the phone expects it: the Codable fields plus the
    /// now-dependent `nextFireAt` (0 = on-demand or disabled).
    static func routineWireDictionary(_ routine: Routine) -> [String: Any] {
        var dict: [String: Any] = [
            "id": routine.id.uuidString,
            "name": routine.name,
            "description": routine.description,
            "enabled": routine.enabled,
            "createdAt": routine.createdAt,
            "lastRun": routine.lastRun ?? 0,
            "steps": Self.stepsWire(routine.steps),
            "schedule": Self.scheduleWire(routine.schedule),
            "nextFireAt": routine.nextFireDate()?.timeIntervalSince1970 ?? 0,
        ]
        if let lastResult = routine.lastResult {
            dict["lastResult"] = Self.resultDictionary(lastResult)
        }
        return dict
    }

    static func stepsWire(_ steps: [RoutineStep]) -> [Any] {
        steps.compactMap { step in
            guard let data = try? JSONEncoder().encode(step),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    static func scheduleWire(_ schedule: RoutineSchedule) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(schedule),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return ["type": "onDemand"] }
        return obj
    }

    static func resultDictionary(_ result: RoutineResult) -> [String: Any] {
        [
            "success": result.success,
            "output": result.output,
            "duration": result.duration,
            "stepsCompleted": result.stepsCompleted,
            "stepsTotal": result.stepsTotal,
            "completedAt": result.completedAt,
            "stepResults": result.stepResults.map { step in
                [
                    "index": step.index,
                    "label": step.label,
                    "success": step.success,
                    "output": step.output,
                ]
            },
        ]
    }

    /// Decode the phone's step list (array of flat kind-objects) back into
    /// RoutineStep values. Unknown steps are dropped, not fatal.
    private static func steps(from raw: Any?) -> [RoutineStep] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(RoutineStep.self, from: data)
        }
    }

    /// Decode the phone's schedule object; nil on malformed input.
    private static func schedule(from raw: Any?) -> RoutineSchedule? {
        guard let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return try? JSONDecoder().decode(RoutineSchedule.self, from: data)
    }

    private func respondError(id: Any, code: Int, message: String, on client: BriefingClient) {
        let response: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": code, "message": message],
        ]
        send(text: Self.jsonString(response), on: client)
    }

    // MARK: - Broadcasting

    /// Push a fresh briefing to every connected phone as a `briefing.update`
    /// notification. Called by the generator's `onGenerated` — no push
    /// notifications, no polling; the phone just gets it.
    func broadcast(_ content: BriefingContent) {
        queue.async { [weak self] in
            guard let self else { return }
            let notification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "briefing.update",
                "params": Self.contentDictionary(content),
            ]
            let json = Self.jsonString(notification)
            for client in self.clients where client.state == .open {
                client.connection.send(content: self.textFrame(json), completion: .contentProcessed { _ in })
            }
        }
    }

    /// Push a routine lifecycle notification to every connected phone.
    /// `method` is one of routine.started / routine.progress / routine.completed.
    func broadcastRoutine(_ method: String, params: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            let notification: [String: Any] = [
                "jsonrpc": "2.0", "method": method, "params": params,
            ]
            let json = Self.jsonString(notification)
            for client in self.clients where client.state == .open {
                client.connection.send(content: self.textFrame(json), completion: .contentProcessed { _ in })
            }
        }
    }

    /// Push a code-session event (`code.chunk` / `code.status` /
    /// `code.test_result` / `code.git_status`) to every connected phone.
    func broadcastCode(_ method: String, params: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            let notification: [String: Any] = [
                "jsonrpc": "2.0", "method": method, "params": params,
            ]
            let json = Self.jsonString(notification)
            for client in self.clients where client.state == .open {
                client.connection.send(content: self.textFrame(json), completion: .contentProcessed { _ in })
            }
        }
    }

    /// Push a mail event (`mail.sync_complete` / `mail.unread_count_changed`)
    /// to every connected phone. Called by MailManager's callbacks, wired in
    /// AppDelegate exactly like the briefing's onGenerated.
    func broadcastMail(_ method: String, params: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            let notification: [String: Any] = [
                "jsonrpc": "2.0", "method": method, "params": params,
            ]
            let json = Self.jsonString(notification)
            for client in self.clients where client.state == .open {
                client.connection.send(content: self.textFrame(json), completion: .contentProcessed { _ in })
            }
        }
    }

    /// A MailClassification as the phone expects it. The sweep fields ride
    /// along when the model produced them; older cached classifications simply
    /// omit them.
    static func mailClassificationWire(_ classification: MailClassification) -> [String: Any] {
        var dict: [String: Any] = [
            "label": classification.label,
            "tone": classification.tone,
            "summary": classification.summary,
        ]
        if let importance = classification.importance { dict["importance"] = importance }
        if let category = classification.category { dict["category"] = category }
        if let confidence = classification.confidence { dict["confidence"] = confidence }
        if let reason = classification.reason { dict["reason"] = reason }
        return dict
    }

    /// A MailDraft as the phone expects it.
    static func mailDraftWire(_ draft: MailDraft) -> [String: Any] {
        ["subject": draft.subject, "body": draft.body]
    }

    /// A MailScanItem as the phone expects it.
    static func mailScanItemWire(_ item: MailScanItem) -> [String: Any] {
        [
            "account_id": item.account,
            "mailbox": item.mailbox,
            "uid": item.uid,
            "from": item.fromName,
            "from_address": item.fromAddress,
            "subject": item.subject,
            "date": item.date,
            "snippet": item.snippet,
            "importance": item.importance,
            "category": item.category,
            "confidence": item.confidence,
            "reason": item.reason,
        ]
    }

    /// A MailFolderStat as the phone expects it.
    static func mailFolderStatWire(_ stat: MailFolderStat) -> [String: Any] {
        [
            "account_id": stat.account,
            "id": stat.id,
            "name": stat.name,
            "role": stat.role,
            "total": stat.total,
            "unseen": stat.unseen,
            "flagged": stat.flagged,
        ]
    }

    /// An EmailScanSummary as the phone expects it (also the `mail.scan_complete`
    /// broadcast payload).
    static func mailScanSummaryWire(_ summary: EmailScanSummary) -> [String: Any] {
        [
            "folders": summary.folders.map(mailFolderStatWire),
            "unread_total": summary.unreadTotal,
            "flagged_total": summary.flaggedTotal,
            "important": summary.important.map(mailScanItemWire),
            "spam_miss": summary.spamMiss.map(mailScanItemWire),
            "scanned_at": summary.scannedAt,
        ]
    }

    /// MailSettings as the phone expects it.
    static func mailSettingsWire(_ settings: MailSettings) -> [String: Any] {
        [
            "scan_frequency_minutes": settings.scanFrequencyMinutes,
            "signatures": settings.signatures,
            "draft_tone": settings.draftTone,
            "auto_learn_sent": settings.autoLearnSent,
            "excluded_folders": settings.excludedFolders,
            "notify_on_important": settings.notifyOnImportant,
            "learned_phrase_count": settings.learnedPhraseCount,
        ]
    }

    /// A MailSummary as the phone expects it.
    static func mailSummaryWire(_ summary: MailSummary) -> [String: Any] {
        ["bullets": summary.bullets, "tone": summary.tone]
    }

    /// A MailTaskItem as the phone expects it.
    static func mailTaskWire(_ task: MailTaskItem) -> [String: Any] {
        ["title": task.title, "detail": task.detail]
    }

    /// The `mail.sync_complete` payload — what the sync pass found.
    static func mailSyncCompleteParams(_ result: MailSyncResult) -> [String: Any] {
        [
            "synced": result.synced,
            "unread": result.unread,
            "at": result.at,
            "failed_accounts": result.failedAccounts,
        ]
    }

    /// The `mail.unread_count_changed` payload.
    static func mailUnreadParams(_ unread: Int) -> [String: Any] {
        ["unread": unread]
    }

    /// The `routine.started` payload.
    static func routineStartedParams(_ routine: Routine) -> [String: Any] {
        ["routine_id": routine.id.uuidString, "routine_name": routine.name]
    }

    /// The `routine.progress` payload — step N of total, with the step's label.
    static func routineProgressParams(_ routine: Routine, step: Int, total: Int, label: String) -> [String: Any] {
        [
            "routine_id": routine.id.uuidString,
            "routine_name": routine.name,
            "step": step,
            "steps_total": total,
            "step_label": label,
        ]
    }

    /// The `routine.completed` payload — outcome plus the full result.
    static func routineCompletedParams(_ routine: Routine, result: RoutineResult) -> [String: Any] {
        [
            "routine_id": routine.id.uuidString,
            "routine_name": routine.name,
            "success": result.success,
            "duration": result.duration,
            "stepsCompleted": result.stepsCompleted,
            "stepsTotal": result.stepsTotal,
            "output": result.output,
        ]
    }

    // MARK: - Cleanup

    private func drop(_ client: BriefingClient) {
        client.state = .closed
        client.connection.cancel()
        clients.removeAll { $0 === client }
    }

    // MARK: - JSON helpers

    static func contentDictionary(_ content: BriefingContent) -> [String: Any] {
        let changes = content.changes.map { change -> [String: Any] in
            [
                "type": change.type,
                "title": change.title,
                "details": change.details,
                "timestamp": change.timestamp,
            ]
        }
        return [
            "summary": content.summary,
            "changes": changes,
            "generatedAt": content.generatedAt,
            "nextUpdateAt": content.nextUpdateAt,
            "focusedDay": content.focusedDay,
        ]
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
