import AppKit
import Foundation

/// Exposes Alfred's macOS capabilities to Hermes as MCP tools.
///
/// Hermes spawns `alfred-mcp` (see AlfredMCP/main.swift), which relays raw MCP
/// frames over a Unix domain socket to this server. The split exists because
/// macOS TCC grants attach to a code signature: Alfred.app already holds
/// Accessibility, Screen Recording and Automation, so doing the privileged work
/// here means one grant instead of two — and the shim, holding none, can be
/// rebuilt without re-prompting.
///
/// The protocol here is MCP (JSON-RPC 2.0, newline-delimited), which is a
/// different protocol from the ACP that HermesSession speaks. Alfred is an MCP
/// *server* and an ACP *client*.
final class AlfredToolServer {

    static let shared = AlfredToolServer()

    /// Keep in sync with `socketPath` in AlfredMCP/main.swift.
    static var socketPath: String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alfred", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp.sock").path
    }

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.alfred.toolserver", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.listen() }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
    }

    private func listen() {
        let path = Self.socketPath
        guard path.utf8.count < 104 else {
            NSLog("[alfred-mcp] socket path too long for sockaddr_un: %@", path)
            return
        }
        // A stale socket file from a crash would make bind() fail with EADDRINUSE.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[alfred-mcp] socket() failed: %s", strerror(errno))
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, capacity)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            NSLog("[alfred-mcp] bind() failed: %s", strerror(errno))
            close(fd)
            return
        }
        // Only this user may drive Alfred's computer control.
        chmod(path, 0o600)

        guard Darwin.listen(fd, 4) == 0 else {
            NSLog("[alfred-mcp] listen() failed: %s", strerror(errno))
            close(fd)
            return
        }
        listenFD = fd
        NSLog("[alfred-mcp] listening at %@", path)

        while listenFD >= 0 {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            Thread { [weak self] in self?.serve(client) }.start()
        }
    }

    // MARK: - Connection

    /// One MCP session. Reads newline-delimited JSON-RPC, answers in order.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 32768)

        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])

            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty,
                      let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }

                // Tool calls are async; block this connection's thread until the
                // reply is ready so responses stay ordered per connection.
                let semaphore = DispatchSemaphore(value: 0)
                var reply: [String: Any]?
                Task {
                    reply = await Self.respond(to: frame)
                    semaphore.signal()
                }
                semaphore.wait()

                if let reply, var data = try? JSONSerialization.data(withJSONObject: reply) {
                    data.append(0x0A)
                    data.withUnsafeBytes { raw in
                        let base = raw.bindMemory(to: UInt8.self).baseAddress!
                        var sent = 0
                        while sent < data.count {
                            let w = write(fd, base + sent, data.count - sent)
                            if w <= 0 { return }
                            sent += w
                        }
                    }
                }
            }
        }
    }

    // MARK: - MCP dispatch

    private static func respond(to frame: [String: Any]) async -> [String: Any]? {
        let method = frame["method"] as? String ?? ""
        let id = frame["id"]

        // Notifications carry no id and must not be answered.
        guard let id else { return nil }

        func ok(_ result: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": result]
        }

        switch method {
        case "initialize":
            // Echo the client's protocol version rather than pinning one, so a
            // Hermes upgrade doesn't strand us on a stale revision.
            let params = frame["params"] as? [String: Any] ?? [:]
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            return ok([
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "alfred", "version": appVersion],
            ])

        case "tools/list":
            return ok(["tools": toolDefinitions])

        case "tools/call":
            let params = frame["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await invoke(tool: name, arguments: args)
                return ok(["content": [["type": "text", "text": text]]])
            } catch {
                // Tool errors are reported in-band so the model can read and
                // recover from them, rather than as JSON-RPC errors which would
                // abort the call.
                return ok([
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                    "isError": true,
                ])
            }

        case "ping":
            return ok([:])

        default:
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Tools

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "screen_read",
            "description": """
                Read what is currently on the user's screen: the frontmost app's \
                visible text via the Accessibility API, plus OCR for text that \
                only exists inside images. Use this whenever the user says \
                "this", "here", "on screen", or refers to something they are \
                looking at without naming it.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "include_ocr": [
                        "type": "boolean",
                        "description": "Also OCR the screen for text inside images. Slower. Default true.",
                    ]
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "screen_ui_map",
            "description": """
                List the clickable UI elements of the frontmost app as a numbered \
                map (buttons, fields, menus) with their labels. Call this BEFORE \
                computer_control so you can click elements by their number \
                instead of guessing screen coordinates.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "max_elements": [
                        "type": "integer",
                        "description": "Cap on elements returned. Default 60.",
                    ]
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "computer_control",
            "description": """
                Control the user's Mac: click, type, press keys. Takes a newline- \
                separated action script, one action per line. Supported actions: \
                "click element N" (from screen_ui_map), "click X Y", \
                "double click X Y", "move mouse X Y", "type <text>", \
                "press <key>", "hotkey cmd shift 4", "wait <seconds>". \
                Refuses destructive actions and entry of passwords or secrets. \
                Prefer "click element N" over raw coordinates.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "script": [
                        "type": "string",
                        "description": "Newline-separated actions, e.g. \"click element 3\\ntype hello\".",
                    ]
                ],
                "required": ["script"],
            ],
        ],
        [
            "name": "memory_search",
            "description": """
                Search Alfred's on-device memory of this user: things they told \
                Alfred, and text seen on their screen over time. Use for personal \
                recall ("what was that link I was looking at", "what did I say \
                about the trip"). This is local to the Mac and never leaves it.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to search for."],
                    "limit": ["type": "integer", "description": "Max results. Default 10."],
                ],
                "required": ["query"],
            ],
        ],
    ]

    private enum ToolError: LocalizedError {
        case unknown(String)
        case missingArgument(String)
        case unavailable(String)
        case denied

        var errorDescription: String? {
            switch self {
            case .unknown(let n): return "Unknown tool '\(n)'."
            case .missingArgument(let a): return "Missing required argument '\(a)'."
            case .unavailable(let why): return why
            case .denied:
                // Phrased for the model: tell it this was a human decision so it
                // stops rather than rephrasing and retrying the same action.
                return "The user declined these actions. Do not retry; ask them what to do instead."
            }
        }
    }

    private static func invoke(tool: String, arguments: [String: Any]) async throws -> String {
        switch tool {

        case "screen_read":
            let includeOCR = arguments["include_ocr"] as? Bool ?? true
            let capture = ScreenTextCapability().captureFrontmost()
            let ocr = includeOCR ? await ScreenOCRCapability().recognizeScreenText() : nil

            var parts: [String] = []
            if let capture {
                parts.append("App: \(capture.appName)\nWindow: \(capture.windowTitle)")
                if !capture.text.isEmpty { parts.append("Visible text:\n\(capture.text)") }
            }
            if let ocr, !ocr.isEmpty { parts.append("Text found in images (OCR):\n\(ocr)") }

            guard !parts.isEmpty else {
                throw ToolError.unavailable("""
                    Couldn't read the screen. Alfred needs Accessibility and Screen \
                    Recording permission in System Settings → Privacy & Security.
                    """)
            }
            return parts.joined(separator: "\n\n")

        case "screen_ui_map":
            let max = arguments["max_elements"] as? Int ?? 60
            let (trusted, map) = await MainActor.run { () -> (Bool, String) in
                let control = ComputerControlCapability()
                return (control.hasAccessibilityPermission,
                        control.semanticObjectMapText(maxElements: max))
            }
            // Distinguish "not permitted" from "nothing clickable here". Both
            // produce an empty map, but only one is fixable by the user, and
            // telling the model the wrong one sends it down a dead end.
            guard trusted else {
                throw ToolError.unavailable("""
                    Alfred doesn't have Accessibility permission. The user must grant it in \
                    System Settings → Privacy & Security → Accessibility.
                    """)
            }
            guard !map.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.unavailable("""
                    The frontmost app exposes no clickable elements right now (this is \
                    common for video players and canvas-based apps). Try screen_read \
                    instead, or ask the user to focus a different window.
                    """)
            }
            return map

        case "computer_control":
            guard let script = arguments["script"] as? String, !script.isEmpty else {
                throw ToolError.missingArgument("script")
            }
            // planFromActionScript applies Alfred's own guards — it throws on
            // destructive requests and on attempts to type secrets — before
            // anything reaches the screen. That envelope is the reason this goes
            // through Alfred rather than Hermes' own computer-use backend.
            return try await runComputerControl(script: script)

        case "memory_search":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            let limit = arguments["limit"] as? Int ?? 10
            guard let store = await MainActor.run(body: { AppDelegate.shared?.memoryStore }) else {
                throw ToolError.unavailable("Alfred's memory isn't ready yet.")
            }

            var lines: [String] = []
            if let records = try? store.search(query: query, limit: limit), !records.isEmpty {
                lines.append("Remembered:")
                lines.append(contentsOf: records.map { "- \($0.content)" })
            }
            let seen = store.searchScreenText(query, limit: min(limit, 10))
            if !seen.isEmpty {
                lines.append("\nSeen on screen:")
                lines.append(contentsOf: seen.prefix(limit).map { "- \($0.text.prefix(300))" })
            }
            return lines.isEmpty ? "Nothing found for '\(query)'." : lines.joined(separator: "\n")

        default:
            throw ToolError.unknown(tool)
        }
    }

    /// ComputerControlCapability is main-actor isolated (it drives AX and posts
    /// CGEvents), so planning and execution both run there rather than hopping
    /// per call.
    @MainActor
    private static func runComputerControl(script: String) async throws -> String {
        // Primary gate: Alfred's own computer-control setting, which ships OFF and
        // must be turned on deliberately in Settings.
        //
        // This carries the safety weight because confirmControl below CANNOT be
        // relied on — see the comment there. Fail closed if AppState isn't
        // reachable rather than assuming permission.
        guard let appState = AppDelegate.shared?.appState, appState.computerControlEnabled else {
            throw ToolError.unavailable("""
                Computer control is turned off. The user must enable it in Alfred's \
                Settings (menu bar → Settings → Computer control) before you can click \
                or type on their Mac. Tell them that; do not retry.
                """)
        }

        let control = ComputerControlCapability()

        // First line of defence only. `containsDestructiveRequest` is a keyword
        // blocklist — it catches "delete"/"erase"/"send money" but not `rm -rf`,
        // `sudo`, or `mkfs`, and it false-positives on innocuous phrasing like
        // "remove this from the list". It is NOT what makes this safe.
        let plan = try control.planFromActionScript(script)

        // This is what makes it safe: a human approves every action that touches
        // the world. Screen reads run unattended; anything that clicks or types
        // stops here. Without this, an LLM with a tool call can drive the Mac
        // unsupervised, and no blocklist is adequate to that.
        //
        // Drawn in the bar, not as an NSAlert — the modal version auto-approved
        // itself after a few seconds. See ControlConfirmationBroker.
        guard await ControlConfirmationBroker.shared.confirm(summary: plan.summary) else {
            throw ToolError.denied
        }

        let result = try await control.execute(plan)
        return "\(result)\n\nActions run:\n\(plan.summary)"
    }

    // The NSAlert-based confirmation that used to live here was removed, not
    // fixed: it displayed and then dismissed itself after 2-4s, returning
    // `alertFirstButtonReturn` with nobody touching the machine — it
    // auto-approved. Driving an AppKit modal session from a background MCP call,
    // inside an `.accessory` app with live event monitors, is not something we
    // control end to end. ControlConfirmationBroker replaces it with a
    // continuation-based prompt drawn in the bar, which keeps the main thread
    // free and can only be resolved by an explicit user action or a
    // deny-by-default timeout.
}
