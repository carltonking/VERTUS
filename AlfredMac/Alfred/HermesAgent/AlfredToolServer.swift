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
                //
                // ⚠️ Must be *detached*: a plain `Task {}` inherits the main
                // actor, and the main actor is busy streaming the Hermes turn —
                // the tool reply would wait for a main-actor slot that never
                // frees, and hermes would see the channel as dead
                // (ClosedResourceError). Detached keeps the tool server off the
                // main thread entirely; capability internals hop to MainActor
                // only where AppKit demands it.
                let semaphore = DispatchSemaphore(value: 0)
                var reply: [String: Any]?
                Task.detached(priority: .userInitiated) {
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
            "name": "terminal_run",
            "description": """
                Run one shell command on the user's Mac, in a fresh non-interactive \
                zsh (their PATH, not their open terminal). Returns the exit code \
                and combined stdout+stderr. Requires the "Terminal" setting to be \
                on. Use this when the user asks for anything command-line: "run ls", \
                "check if xcodebuild is installed", "what's using port 8080". \
                Commands that obviously destroy data or download-and-execute are \
                refused outright — show the user the safe spelling instead.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The command to run, e.g. \"ls -la\".",
                    ],
                    "directory": [
                        "type": "string",
                        "description": "Optional working directory. Defaults to the user's home.",
                    ],
                    "timeout_seconds": [
                        "type": "integer",
                        "description": "Optional timeout; the command is killed at it. Default 30.",
                    ],
                ],
                "required": ["command"],
            ],
        ],
        [
            "name": "email_list",
            "description": """
                List recent emails in Carlton's inbox. Returns numbered lines with \
                sender name and subject. Call this first whenever the user says \
                "read my email(s)" or names someone they exchanged mail with — the \
                number is the message ID the other email tools take.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mailbox": [
                        "type": "string",
                        "description": "Mailbox name. Default: Inbox.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "How many messages to show. Default 20, max 200.",
                    ],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "email_read",
            "description": """
                Read one email in full: sender, subject, and body text. Use the \
                message ID from email_list.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Message ID from email_list.",
                    ],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "calendar_list",
            "description": """
                List events starting in the next few days. Returns matching \
                calendar events as numbered lines, each ending with an \
                id=<eventIdentifier> you must copy to update or delete one. \
                Reminders are a separate tool (reminder_list). Today's date \
                is in your context; for other windows or searches ask the user \
                or use your own date arithmetic.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "days": [
                        "type": "integer",
                        "description": "How many days ahead to look. Default 7, max 90.",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Cap on events returned. Default 30.",
                    ],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "calendar_add",
            "description": """
                Create an event in the user's Apple Calendar (writes straight \
                into EventKit, so it appears in Calendar on the Mac and iCloud \
                on their iPhone). Times are ISO-8601, e.g. "2026-09-05T15:00:00" \
                (floating times mean local time). Default end: +1 hour, or +1 \
                day for all-day. The user's request is the permission — no extra \
                confirmation; only deletes ask again.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Event title."],
                    "start": ["type": "string", "description": "Start, ISO-8601."],
                    "end": ["type": "string", "description": "Optional end, ISO-8601."],
                    "all_day": ["type": "boolean", "description": "All-day event. Default false."],
                    "location": ["type": "string", "description": "Optional location."],
                    "notes": ["type": "string", "description": "Optional notes."],
                    "calendar": ["type": "string", "description": "Optional calendar name or id. Defaults to the user's default."],
                ],
                "required": ["title", "start"] as [String],
            ],
        ],
        [
            "name": "calendar_update",
            "description": """
                Edit an existing event found via calendar_list (pass its id).
                Only the fields you include change; the user's request is the \
                permission, so no extra confirmation.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Event id from calendar_list."],
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "ISO-8601."],
                    "end": ["type": "string", "description": "ISO-8601."],
                    "all_day": ["type": "boolean"],
                    "location": ["type": "string", "description": "Pass an empty string to clear."],
                    "notes": ["type": "string", "description": "Pass an empty string to clear."],
                    "calendar": ["type": "string", "description": "Optional calendar id or title."],
                ],
                "required": ["id"] as [String],
            ],
        ],
        [
            "name": "calendar_delete",
            "description": """
                Remove an event found via calendar_list (pass its id). The user \
                approves the deletion before it happens; it's not reversible.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Event id from calendar_list."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "reminder_list",
            "description": """
                List the user's reminders, outstanding first (soonest due first,
                undated last). Each line ends with id=<calendarItemIdentifier> \
                to pass back to reminder_complete / reminder_update / \
                reminder_delete.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "include_completed": ["type": "boolean", "description": "Also show completed reminders. Default false."],
                    "limit": ["type": "integer", "description": "Cap on reminders returned. Default 30."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "reminder_add",
            "description": """
                Create the user's Apple Reminders (writes into \
                their real lists, so it appears in Reminders on iOS and Mac). \
                `due` is optional ISO-8601; omit it for an undated task. The \
                user's request is the permission; only deletes ask again.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Reminder text."],
                    "due": ["type": "string", "description": "Optional due date/time, ISO-8601."],
                    "notes": ["type": "string"],
                    "list": ["type": "string", "description": "Optional list id or name. Defaults to the default list."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "reminder_update",
            "description": """
                Edit a reminder found via reminder_list (pass its id). Only the \
                fields you change; the user's request is the permission.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "id from reminder_list."],
                    "title": ["type": "string"],
                    "due": ["type": "string", "description": "ISO-8601, or empty string to make it undated."],
                    "notes": ["type": "string"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "reminder_complete",
            "description": """
                Mark a reminder complete or re-open it.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "id from reminder_list."],
                    "completed": ["type": "boolean", "description": "True to mark done, false to re-open. Default true."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "reminder_delete",
            "description": """
                Delete a reminder found via reminder_list (pass its id). The \
                user approves before it's gone.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "id from reminder_list."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "email_send",
            "description": """
                Send an EMAIL from Carlton's iCloud account (carltoniking@icloud.com). \
                Use ONLY when the user explicitly means email ("send an email", "email \
                X", "summarize my emails"). If they said "send a message" or "text X", \
                that means iMessage — use messages_send, not this tool. The user's request \
                is the permission; sending goes straight out. Use email_list + \
                email_read to find the recipient's address and thread context first.

                Siri rule: if the user says "email [name]" but has NOT told you \
                what to write, do not call this tool — reply with a short \
                confirmation question instead, e.g. "What would you like to say to \
                [name]?" Never invent message content they didn't dictate. When \
                they DO include the content ("email mom I'm running late"), \
                send it immediately — no confirmation needed.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to": [
                        "type": "string",
                        "description": "Recipient email address.",
                    ],
                    "subject": [
                        "type": "string",
                        "description": "Subject line.",
                    ],
                    "body": [
                        "type": "string",
                        "description": "Plain-text message body.",
                    ],
                    "cc": [
                        "type": "string",
                        "description": "Optional Cc address(es).",
                    ],
                    "in_reply_to": [
                        "type": "string",
                        "description": "Message-ID being replied to, so the reply threads. From email_read.",
                    ],
                ],
                "required": ["to", "subject", "body"],
            ],
        ],
        [
            "name": "contacts_find",
            "description": """
                Look up a person in Carlton's Apple Contacts by name (or part of a \
                name) and return their phone numbers and email addresses. Run this \
                BEFORE messages_send whenever the user names a person they want to \
                text, so you send to their real handle instead of inventing one. \
                If the contact's phone is an iPhone number the sent message arrives \
                as iMessage; otherwise as SMS.

                If the search returns several plausible people (or you're not sure \
                which "[name]" they mean), ask which one instead of guessing. If \
                the user asked to text someone but gave no message content yet, \
                resolving the contact here is fine — but still ask what to say \
                before sending (see messages_send's rule).
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Name or part of a name/email to search, e.g. \"Rohan\".",
                    ]
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "messages_list",
            "description": """
                List recent iMessage/SMS conversations: who it's with, unread \
                count, last message and roughly when. THIS is the "messages" \
                tool — per iMessage/SMS, not email (email has separate tools). \
                Call this first when the user says "text [name]"/"message \
                [name]"/"what did X say"/"summarize my messages" to find the \
                conversation's id, which messages_thread and messages_send take \
                as `guid`.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "messages_thread",
            "description": """
                Read one iMessage/SMS conversation in full (oldest first) via its \
                guid from messages_list. Use to see what you're replying to before \
                sending, or to summarize what was said.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "guid": ["type": "string", "description": "Conversation id from messages_list."],
                ],
                "required": ["guid"],
            ],
        ],
        [
            "name": "messages_send",
            "description": """
                Send an iMessage or SMS from Carlton's Mac via the Messages app. \
                THIS is the tool for "send a message"/"text [name]" — do NOT use \
                email_send for that. Give either `guid` (from messages_list, to \
                reply inside an existing conversation) or `participant` (a phone \
                number like "+15555550132" or Apple ID email, from contacts_find) \
                to start a new conversation.

                Siri rule: when the user says "text [name]" WITHOUT telling you \
                what to say, do not call this tool — reply with a short \
                confirmation question instead: "What would you like to say to \
                [name]?" (resolve the name via contacts_find only if useful; do \
                not send anything). Never invent message content. When they DO \
                include the content ("text mom I'm running late"), send it \
                immediately — no confirmation needed. If the contact lookup is \
                ambiguous, ask which person they mean before sending.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The message body."],
                    "guid": ["type": "string", "description": "Existing conversation id (mutually exclusive with participant)."],
                    "participant": ["type": "string", "description": "Handle to start a new conversation: phone number or Apple ID. Mutually exclusive with guid."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "spotify_play",
            "description": """
                Play a song on Spotify. Give the song the user asked for: a title, \
                "title artist", or a spotify:track: URI. The top search match is \
                played on their desktop Spotify app. Use when the user says "play \
                [song]", "put on [song]", "listen to [song]".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Song title, 'title artist', or a spotify:track: URI."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "spotify_control",
            "description": """
                Basic Spotify playback control: pause, resume (play), toggle, skip \
                (next), or go back (previous). For "stop the music"/"skip this song".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "description": "play, pause, toggle, next, or previous."],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "file_organize",
            "description": """
                Move, copy, delete, create folders, or list files on the user's \
                Mac. Never overwrites: a destination that already exists fails \
                with a clear error. Deleting requires the user to have explicitly \
                confirmed in their own words — pass their confirmation phrase in \
                `confirmation` (e.g. "confirm") or the tool refuses. Every \
                successful change is written to Alfred's memory journal for audit. \
                Use when the user says "move this file to", "organize my \
                Downloads", "delete this".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "move, copy, delete, create_folder, or list_folder.",
                    ],
                    "source_path": [
                        "type": "string",
                        "description": "Path to the file/folder. Required for move, copy, delete.",
                    ],
                    "destination_path": [
                        "type": "string",
                        "description": "Target path for move/copy; the folder to create or list otherwise.",
                    ],
                    "recursive": [
                        "type": "boolean",
                        "description": "Walk subfolders. Only for list_folder. Default false.",
                    ],
                    "confirmation": [
                        "type": "string",
                        "description": "Required for delete: quote the user's explicit approval verbatim.",
                    ],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "calendar_plan",
            "description": """
                Proactive calendar planning: find free windows for a meeting, \
                suggest a meeting time, detect overlapping events, or surface the \
                next deadline. Pure queries — never creates or edits anything. \
                Times are ISO-8601 (e.g. "2026-09-05T15:00:00", floating means \
                local). Use when the user asks "when's a good time to meet?", \
                "am I double-booked?", "what's my next deadline?".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "find_free_slots, suggest_meeting, detect_conflicts, or next_deadline.",
                    ],
                    "duration_minutes": [
                        "type": "integer",
                        "description": "Meeting length for find_free_slots / suggest_meeting. Default 60.",
                    ],
                    "start_date": [
                        "type": "string",
                        "description": "Range start, ISO-8601. Default now.",
                    ],
                    "end_date": [
                        "type": "string",
                        "description": "Range end, ISO-8601. Default now + 7 days.",
                    ],
                    "attendees": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Attendee names for suggest_meeting (no shared calendar, so best-effort).",
                    ],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "habit_predict",
            "description": """
                Predict the user's next app or action from passively learned usage \
                patterns (privacy-safe aggregates only — never screen text). \
                Returns a natural-language prediction with a confidence. Use for \
                proactive suggestions, e.g. "the user usually switches to Slack \
                after Xcode around now".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "next_app, next_action, or habit_chain.",
                    ],
                    "current_app": [
                        "type": "string",
                        "description": "Bundle ID of the app the user is in now, e.g. com.apple.dt.Xcode. Required for next_action.",
                    ],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "timer_set",
            "description": """
                Start a timer for the user. Prefers the real Clock app (the \
                countdown appears in the menu-bar clock, exactly like Siri) and \
                falls back to Alfred's own menu-bar timer + a notification when \
                it ends — the user gets a visible countdown either way. Use when \
                the user says "set a timer for X minutes/seconds", "timer for \
                X", "count down X". Do NOT use this for stopwatches, reminders, \
                or calendar events — those have their own tools.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": [
                        "type": "number",
                        "description": "Duration in minutes (accepts fractions for seconds, e.g. 0.5 = 30s). Min 1 second.",
                    ],
                    "label": [
                        "type": "string",
                        "description": "Optional name for the timer, e.g. \"pasta\". Shown in the notification.",
                    ],
                ],
                "required": ["minutes"],
            ],
        ],
        [
            "name": "timer_status",
            "description": """
                Report what timers are currently running and how much time is \
                left on each. Call this when the user asks "how much time is \
                left?", "is my timer still running?", or before setting a new \
                timer if they've set several.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "timer_cancel",
            "description": """
                Stop every running timer (the Clock app's and Alfred's own) and \
                clear their menu-bar countdowns. Use when the user says "cancel \
                the timer", "stop the timer", "turn it off".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "email_scan",
            "description": """
                Summarize the user's whole mailbox in one glance: unread counts \
                per folder, flagged follow-ups, and — most usefully — important \
                emails found sitting in Junk that should be moved back to the \
                Inbox. Use when the user says "scan my inbox", "any important \
                email", "what's in my junk", or asks what they've missed.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "folder": [
                        "type": "string",
                        "description": "Optional mailbox name to dig into (e.g. \"Junk\"). Omit for the summary.",
                    ]
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "email_move",
            "description": """
                Move an email to a different mailbox (IMAP UID MOVE). Use for \
                "move this to Inbox", "file it under X", or rescuing an \
                important email that landed in Junk. The message id comes from \
                email_list / email_scan; the user's request is the permission.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Message id from email_list or email_scan."],
                    "from_mailbox": ["type": "string", "description": "Mailbox the message is in now, e.g. \"Junk\"."],
                    "to_mailbox": ["type": "string", "description": "Destination mailbox, e.g. \"Inbox\"."],
                    "account": ["type": "string", "description": "Account name (default: icloud)."],
                ],
                "required": ["id", "from_mailbox", "to_mailbox"],
            ],
        ],
        [
            "name": "email_save_draft",
            "description": """
                Save an email to the user's Drafts folder without sending it. \
                Use when the user says "save that as a draft", "draft it and \
                I'll send later". Never sends — this only saves.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Recipient address."],
                    "subject": ["type": "string", "description": "Subject line."],
                    "body": ["type": "string", "description": "Plain-text body."],
                    "account": ["type": "string", "description": "Account name (default: icloud)."],
                ],
                "required": ["to", "subject", "body"],
            ],
        ],
        [
            "name": "polish_text",
            "description": """
                Rewrite a piece of AI-generated text so it stops reading generic \
                (anti-slop). Only touches text the deterministic boringness check \
                flags as bland; specific writing passes through unchanged. Never \
                invents facts. Use before delivering drafts, routine names, \
                summaries or comments to the user.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to polish."],
                    "style": ["type": "string", "description": "Optional voice: casual, formal, technical, or marketing."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "evaluate_boringness",
            "description": """
                Score how generic/bland a piece of text is, 0.0–1.0, with the \
                phrases that pushed it up. Deterministic and instant — no model \
                call. Use to decide whether a draft is worth polishing.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to score."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "suggest_improvements",
            "description": """
                Return concrete, actionable rewrite suggestions for a bland piece \
                of text (what to replace and with what). Costs a model turn; \
                prefer evaluate_boringness first.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to critique."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "understand_search",
            "description": """
                Search a project's Understand-Anything knowledge graph (the \
                interactive graph at .ua/knowledge-graph.json). Returns the \
                most relevant files, functions and classes for a natural \
                question like "where is the auth logic" — name, type, path \
                and a plain-English summary per hit. Deterministic and \
                instant (no model call). Pass the project you're working in \
                as project_path. Use instead of grepping when the graph \
                exists; it answers structural "where does X live" questions \
                in one shot.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look for, e.g. \"authentication\"."],
                    "project_path": ["type": "string", "description": "Absolute path of the project (the working directory)."],
                    "limit": ["type": "integer", "description": "Max results. Default 10."],
                ],
                "required": ["query", "project_path"],
            ],
        ],
        [
            "name": "understand_impact",
            "description": """
                Impact analysis over a project's knowledge graph: everything \
                that breaks — directly or transitively — if the given symbol \
                or file changes. Pass a function/class name or a node id \
                (e.g. "authenticate", "file:src/auth.ts"). Use before a \
                refactor to know exactly what to update, or to explain why a \
                change would ripple. Deterministic, local, instant.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "Symbol or node id to change, e.g. \"authenticate\"."],
                    "project_path": ["type": "string", "description": "Absolute path of the project."],
                    "max_depth": ["type": "integer", "description": "How many hops of dependents to include. Default 4."],
                ],
                "required": ["target", "project_path"],
            ],
        ],
        [
            "name": "understand_explain",
            "description": """
                Deep-dive on one node of a project's knowledge graph: its \
                plain-English summary, signature, what it calls/imports (out) \
                and what calls/imports it (in), plus the architectural layers \
                it belongs to. Pass the node id ("file:src/auth.ts", \
                "function:src/auth.ts:login") — get ids from understand_search. \
                Use to understand a file or function without reading it.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "node_id": ["type": "string", "description": "Node id from understand_search."],
                    "project_path": ["type": "string", "description": "Absolute path of the project."],
                ],
                "required": ["node_id", "project_path"],
            ],
        ],
        [
            "name": "understand_architecture",
            "description": """
                A project's architecture from its knowledge graph: the \
                architectural layers (API, Service, Data, UI, …) with node \
                counts and sample members, or — when the graph has no layers — \
                a fallback grouping by top-level directory. Use to answer \
                "what's the architecture / what are the layers" without \
                reading the tree. Deterministic and local.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "project_path": ["type": "string", "description": "Absolute path of the project."],
                ],
                "required": ["project_path"],
            ],
        ],
        [
            "name": "get_assignments",
            "description": """
                The owner's Canvas assignments from the NYU integration: name, \
                course, due date, status (not_started / in_progress / \
                submitted / graded) and score. Sorted by due date, pending \
                first. Use to answer \"what's due\", \"when is X due\", or \"what \
                did I miss\" — and pass assignment ids to mark_submitted. \
                Requires the NYU integration to be enabled with a Canvas \
                token (Settings → NYU).
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max rows. Default 25."],
                ],
            ],
        ],
        [
            "name": "get_current_grades",
            "description": """
                The owner's current grades from the NYU Canvas integration: \
                per-course score with trend (improving / declining / steady) \
                and the projected final score when Canvas computes one. Use to \
                answer \"where do I stand in my classes\" or check a target GPA. \
                Requires the NYU integration to be enabled and synced.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
            ],
        ],
        [
            "name": "get_next_deadline",
            "description": """
                The owner's single next assignment deadline (not yet submitted) \
                from the NYU Canvas integration. Use to answer \"what's due \
                next\" or \"what should I work on\". Returns nothing when every \
                assignment is done or the integration isn't configured.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
            ],
        ],
        [
            "name": "mark_submitted",
            "description": """
                Mark a Canvas assignment as submitted in Alfred's tracker (or \
                back to in_progress / not_started). This only updates Alfred's \
                local status — it never submits anything to Canvas. Pass the \
                assignment id from get_assignments.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "assignment_id": ["type": "integer", "description": "Assignment id from get_assignments."],
                    "status": ["type": "string", "description": "submitted | in_progress | not_started. Default submitted."],
                ],
                "required": ["assignment_id"],
            ],
        ],
        [
            "name": "get_syllabus_info",
            "description": """
                A course's syllabus from the NYU Canvas integration: grading \
                breakdown, professor, meeting schedule, and the plain-text \
                syllabus body. Pass the course id (from get_current_grades); \
                with no id, returns all courses. Use to answer \"how is my \
                grade computed\", \"when is the final exam\" or \"who teaches X\". \
                The final exam date is a best-effort extraction from the \
                syllabus text — verify it against Canvas.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "course_id": ["type": "integer", "description": "Canvas course id (optional — omit for all courses)."],
                ],
            ],
        ],
        [
            "name": "multi_agent_run",
            "description": """
                Run a complex, multi-step request through Alfred's multi-agent \
                team: a Planning agent designs the run, then specialized \
                Research, Code, Review and Writing agents work in sequence — or \
                in parallel where independent — sharing results through a \
                mailbox so later agents build on earlier ones. Use for deep \
                research, weekly planning, job search, code review and other \
                multi-domain tasks where division of labor beats one agent \
                doing everything. Returns each agent's deliverable, ending \
                with the final answer. Multi-agent must be enabled in Settings.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "The request to run through the team."],
                ],
                "required": ["task"],
            ],
        ],
        [
            "name": "create_presentation",
            "description": """
                Build a complete, ready-to-present slideshow on any topic: \
                researches the topic (web search + relevant images), writes \
                concise per-slide bullets and speaker notes, lays it out in a \
                design style (modern | minimal | colorful | academic) and \
                exports deck.pptx + deck.pdf into ~/.alfred/presentations/. \
                Returns the deck id and file paths. Used when the user asks \
                for slides or a presentation on a topic.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "Topic or title of the presentation."],
                    "num_slides": ["type": "number", "description": "Slide count (3-30). Defaults to the Settings default."],
                    "minutes": ["type": "number", "description": "Optional talk length in minutes — the slide count is derived (~1.5 min/slide)."],
                    "tone": ["type": "string", "description": "academic | business | casual. Defaults to academic."],
                    "style": ["type": "string", "description": "modern | minimal | colorful | academic. Defaults to the user's learned/settings style."],
                    "include_notes": ["type": "boolean", "description": "Include speaker notes (default from Settings)."],
                ],
                "required": ["topic"],
            ],
        ],
        [
            "name": "add_speaker_notes",
            "description": """
                Refine an existing deck's speaker notes into a full presenting \
                script — per-slide talking points with a time budget, plus a \
                conclusion and Q&A section — written to speaker_notes.md in \
                the deck's directory. Takes the presentation_id returned by \
                create_presentation.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "presentation_id": ["type": "string", "description": "The deck's UUID from create_presentation."],
                ],
                "required": ["presentation_id"],
            ],
        ],
        [
            "name": "design_presentation",
            "description": """
                Re-render an existing deck in a different design style \
                (modern | minimal | colorful | academic). Content is reused \
                — no new model turn — the exports are rebuilt to match. Takes \
                the presentation_id returned by create_presentation.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "presentation_id": ["type": "string", "description": "The deck's UUID from create_presentation."],
                    "style": ["type": "string", "description": "modern | minimal | colorful | academic."],
                ],
                "required": ["presentation_id", "style"],
            ],
        ],
        [
            "name": "export_presentation",
            "description": """
                Re-export an existing deck in a given format: pptx, pdf or \
                both. Rebuilds only the missing/allowed exports from the \
                deck's saved content. Takes the presentation_id returned by \
                create_presentation.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "presentation_id": ["type": "string", "description": "The deck's UUID from create_presentation."],
                    "format": ["type": "string", "description": "pptx | pdf | both. Defaults to both."],
                ],
                "required": ["presentation_id"],
            ],
        ],
        [
            "name": "learn_preference",
            "description": """
                Store a durable preference, working pattern, person detail, \
                goal, learning or constraint about the user in the MemPalace \
                vault. Repeating the same content raises its confidence, so \
                facts the user confirms several times climb above the \
                threshold that grounds every future session.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "category": ["type": "string", "description": "preference | project_pattern | person | goal | learning | constraint"],
                    "content": ["type": "string", "description": "One concise sentence."],
                ],
                "required": ["category", "content"],
            ],
        ],
        [
            "name": "get_learned_context",
            "description": """
                Fetch the highest-confidence memories about the user (above the \
                settings threshold) — the durable preferences, patterns and \
                constraints a fresh session should start knowing. No model \
                call; instant.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "number", "description": "How many to return (default 6)."],
                ],
            ],
        ],
        [
            "name": "recall_about_person",
            "description": """
                Fetch everything stored about one person (communication \
                preferences, what they care about, inside knowledge). Empty \
                when nothing is stored or the person category is \
                privacy-excluded in settings.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The person's name."],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "search_memory",
            "description": """
                Search the MemPalace vault for anything matching a query — \
                preferences, project patterns, people, learning, constraints. \
                Instant and local.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look for."],
                    "limit": ["type": "number", "description": "How many to return (default 12)."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "correct_memory",
            "description": """
                Learn from a user correction: replace a stored memory with the \
                corrected version and lift its confidence hard, so the corrected \
                fact outranks the old one everywhere.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "memory_id": ["type": "string", "description": "The memory id from search_memory / get_learned_context."],
                    "correction": ["type": "string", "description": "The corrected fact."],
                ],
                "required": ["memory_id", "correction"],
            ],
        ],
        [
            "name": "update_goal_progress",
            "description": """
                Report completion (or a miss) for a tracked goal. A completion \
                inside the cadence window extends the streak; a miss after the \
                window lapses resets it.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "goal_id": ["type": "string", "description": "Goal id (see goals in the briefing or memory.search)."],
                    "completed": ["type": "boolean", "description": "true = completed, false = missed."],
                ],
                "required": ["goal_id", "completed"],
            ],
        ],
        [
            "name": "get_optimization_report",
            "description": """
                Read Alfred's self-optimization report: the week-over-week \
                average-rating trend per domain (code, email, summaries, \
                routines, multi-step tasks), and the learned prompt rules \
                currently active. Use when the user asks how Alfred is \
                improving, what it has learned about their style, or for a \
                status check on the learning loop. Local data, instant, no \
                model call.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "optimization_compile",
            "description": """
                Force a self-optimization compile pass now: gather the past \
                week's rated outputs, learn new prompt rules from them, and \
                return the fresh report. Use when the user asks to \
                "optimize now", "relearn", or "update my prompts". Local and \
                offline; can take up to a minute.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "optimization_rollback",
            "description": """
                Revert one domain's learned prompt rules to its previous set \
                (or to baseline if there is none). Use when a recent \
                optimization made output worse and the user wants to undo it. \
                kind is one of: code, email, summary, routine, multistep, \
                general.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "description": "Domain to roll back: code, email, summary, routine, multistep, or general.",
                    ],
                ],
                "required": ["kind"],
            ],
        ],
        [
            "name": "explain_concept",
            "description": """
                Explain a concept the way THIS user learns (code examples, \
                analogies, step-by-step…). Alfred checks the user's mastery \
                level, prerequisites and learned learning style first, so the \
                explanation is personal, not generic. Use for tutoring asks: \
                "explain recursion", "I don't understand integrals", "what \
                does this concept mean". The result ends with a check question \
                — relay it, and when the user answers (yes / still confused / \
                more detail / another angle), call tutor_feedback with their \
                outcome so Alfred learns what worked.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "concept": ["type": "string", "description": "The concept to explain, e.g. \"recursion\" or \"integration by parts\"."],
                    "course": ["type": "string", "description": "Optional course code, e.g. \"CSCI-UA 101\" — used for the default teaching style."],
                ],
                "required": ["concept"],
            ],
        ],
        [
            "name": "socratic_guide",
            "description": """
                Homework help in learning mode: generate guiding questions \
                ("What's the base case?") instead of giving the answer, so the \
                user figures it out themselves. Use when the user says "I'm \
                stuck on this problem" or asks for help with homework. When \
                the user reaches the answer, call tutor_feedback with outcome \
                "understood" so Alfred records that the Socratic method \
                worked for them. Respects the tutor's Socratic depth setting: \
                heavy = questions only, light_hints = question + small hint, \
                just_answer = solve it directly.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "problem": ["type": "string", "description": "The problem the user is stuck on."],
                    "concept": ["type": "string", "description": "Optional concept name (e.g. \"recursion\") so mastery is tracked per concept."],
                ],
                "required": ["problem"],
            ],
        ],
        [
            "name": "track_mastery",
            "description": """
                Record the user's stated knowledge level for a concept (1–5). \
                Use when the user tells you how well they know something \
                ("I'm solid on loops", "I've never touched series") or asks \
                you to note it. Updates the tutor's concept mastery map.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "concept": ["type": "string", "description": "The concept name."],
                    "confidence": ["type": "integer", "description": "1–5 knowledge level."],
                    "course": ["type": "string", "description": "Optional course code."],
                ],
                "required": ["concept", "confidence"],
            ],
        ],
        [
            "name": "tutor_feedback",
            "description": """
                Record how the user reacted to a tutoring explanation or \
                guiding question. This is the learning signal: Alfred adapts \
                future explanations and tracks concept mastery from it. Call \
                it after every tutoring exchange (explain_concept / \
                socratic_guide) once the user replies. outcome: \
                "understood", "confused", "more_detail", "other_angle", or \
                "abandoned".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "concept": ["type": "string", "description": "The concept that was explained."],
                    "outcome": ["type": "string", "description": "understood | confused | more_detail | other_angle | abandoned."],
                    "course": ["type": "string", "description": "Optional course code."],
                ],
                "required": ["concept", "outcome"],
            ],
        ],
        [
            "name": "what_am_i_weak_at",
            "description": """
                List the concepts the user is still struggling with, weakest \
                first — derived from the tutor's mastery tracking (asked about \
                multiple times + still low confidence). Use for "what am I \
                weak at?", "what should I review?".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "exam_prep_routine",
            "description": """
                Generate a focused exam-prep practice session: reviews what \
                the user has learned, drills the weak concepts hardest, and \
                produces practice problems at their difficulty level with \
                immediate answers and explanations. Use for "prepare for my \
                calculus exam", "practice for the test on Thursday".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "exam_date": ["type": "string", "description": "Optional exam date or day, e.g. \"Friday\" or \"2026-12-15\"."],
                    "topics": ["type": "array", "items": ["type": "string"], "description": "Optional topics to focus on, e.g. [\"integration\", \"series\"]. Defaults to the weakest concepts."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "my_learning_style",
            "description": """
                Show how Alfred currently understands the user's learning \
                style: preferred teaching methods (code examples, analogies, \
                step-by-step…), structure, depth, and Socratic vs direct — \
                learned from tutoring feedback over time. Use for "how do \
                you teach me?", "what's my learning style?".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "start_exam_prep",
            "description": """
                Start an automated exam-prep plan: the Daily Exam Prep \
                routine (and the briefing) drill the user's weak concepts \
                daily until the exam, with a full timed practice test in the \
                final week and a final review the day before. Use for \
                "prepare for my calculus exam", "exam Friday". exam_date \
                accepts YYYY-MM-DD, a weekday, or "in 14 days".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "exam_date": ["type": "string", "description": "When the exam is — YYYY-MM-DD, a weekday, or \"in 14 days\"."],
                    "topics": ["type": "array", "items": ["type": "string"], "description": "Optional topics to focus on. Defaults to the user's weakest concepts."],
                    "course": ["type": "string", "description": "Optional course code, e.g. \"MATH-UA 122\"."],
                ],
                "required": [] as [String],
            ],
        ],
        [
            "name": "track_problem_set",
            "description": """
                Track a problem set: order the problems easy → hard and track \
                completion. Re-post the list with `solved` (0-based indices \
                already done) as the user finishes problems. Use when the \
                professor posts a problem set or the user pastes one. source \
                is canvas | manual.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "problems": ["type": "array", "items": ["type": "string"], "description": "The problem statements."],
                    "course": ["type": "string", "description": "Optional course code."],
                    "name": ["type": "string", "description": "Optional set name, e.g. \"HW 4\"."],
                    "source": ["type": "string", "description": "canvas | manual. Default manual."],
                    "solved": ["type": "array", "items": ["type": "integer"], "description": "0-based indices of problems already solved."],
                ],
                "required": ["problems"],
            ],
        ],
        [
            "name": "quiz_on_reading",
            "description": """
                Quiz the user on a reading assignment. Without `result`, \
                generate comprehension questions and store the reading; with \
                `result` (\"passed\", \"4/5\", \"80%\"), record how they did \
                and schedule the next spaced-repetition quiz. Use for \"quiz \
                me on chapter 3\".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "chapter": ["type": "string", "description": "The reading's title or chapter."],
                    "course": ["type": "string", "description": "Optional course code."],
                    "content": ["type": "string", "description": "Optional pasted reading text to quiz on."],
                    "result": ["type": "string", "description": "How the user did: \"passed\", \"failed\", \"4/5\", or \"80%\"."],
                ],
                "required": ["chapter"],
            ],
        ],
        [
            "name": "summarize_lecture",
            "description": """
                Turn lecture notes or a transcript into organized notes: a \
                topic-organized summary, key points, and study questions. \
                Use after class when the user dictates notes or pastes a \
                transcript. Audio transcription is not wired up yet — for a \
                recording path, ask the user to paste the transcript.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recording_or_notes": ["type": "string", "description": "The dictated notes or pasted transcript text."],
                    "course": ["type": "string", "description": "Optional course code."],
                    "title": ["type": "string", "description": "Optional lecture title."],
                ],
                "required": ["recording_or_notes"],
            ],
        ],
        [
            "name": "weekly_review",
            "description": """
                Generate a weekly study progress report: what the user is \
                strong in, what needs practice, and the focus for the week \
                ahead — drawn from tutoring mastery, grades, problem sets, \
                readings and lecture notes. Use for \"how was my week of \
                studying?\", \"what should I focus on?\".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "write_essay",
            "description": """
                Write a complete, submission-ready essay in the user's own \
                voice, with automatic citations. Research sources first, \
                generate an outline, write the essay body, then append the \
                reference list in the requested style. Use when the user says \
                "write an essay on …", "draft a paper about …", or gives a \
                prompt with a length or citation style. citation_style is \
                mla, apa or chicago; tone is academic, analytical, personal, \
                critical, or match_my_style (default: match the user's \
                learned voice).
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "The essay prompt or topic."],
                    "length": ["type": "string", "description": "Optional length, e.g. \"1500 words\" or \"5 pages\"."],
                    "citation_style": ["type": "string", "description": "mla | apa | chicago. Defaults to the user's saved style."],
                    "tone": ["type": "string", "description": "academic | analytical | personal | critical | match_my_style. Default match_my_style."],
                ],
                "required": ["topic"],
            ],
        ],
        [
            "name": "analyze_my_writing_style",
            "description": """
                Show Alfred's understanding of how the user writes essays: \
                paragraph length, sentence variety, quote vs paraphrase \
                preference, common transitions, argument structure and tone. \
                Use for "how do I write?", "what's my essay style?". \
                Instant, no model call.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:],
                "required": [] as [String],
            ],
        ],
        [
            "name": "learn_writing_style",
            "description": """
                Analyze a past essay and fold it into Alfred's learned model \
                of the user's writing voice, so the next generated essay \
                matches it. Use when the user shares a piece of their own \
                writing and asks Alfred to learn their style from it.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "essay": ["type": "string", "description": "The full text of a past essay."],
                ],
                "required": ["essay"],
            ],
        ],
        [
            "name": "research_topic",
            "description": """
                Find credible web sources for a topic (via Crawlee search) and \
                summarize each with quotable lines. Use when the user asks for \
                research on a subject, or as the first step before writing. \
                depth is light | medium | deep.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "The topic to research."],
                    "depth": ["type": "string", "description": "light | medium | deep. Default light."],
                ],
                "required": ["topic"],
            ],
        ],
        [
            "name": "revise_essay",
            "description": """
                Revise an essay according to natural-language feedback, \
                keeping the user's writing voice throughout. Use for \
                "make this section more analytical", "add more evidence", \
                "tighten the intro".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "essay": ["type": "string", "description": "The essay text to revise."],
                    "feedback": ["type": "string", "description": "What to change, in the user's words."],
                    "tone": ["type": "string", "description": "Optional tone override: academic | analytical | personal | critical | match_my_style."],
                ],
                "required": ["essay", "feedback"],
            ],
        ],
        [
            "name": "check_citations",
            "description": """
                Verify an essay's citations are internally consistent: every \
                reference-list entry is cited in the body, and the list has a \
                proper header. Returns a list of problems (empty when clean). \
                Use before the user submits. Deterministic, no model call.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "essay": ["type": "string", "description": "The essay with its reference list appended."],
                    "citation_style": ["type": "string", "description": "mla | apa | chicago. Defaults to the user's saved style."],
                ],
                "required": ["essay"],
            ],
        ],
        [
            "name": "solve_problem",
            "description": """
                Solve a homework problem (code, math or physics — detected \
                automatically). mode="teach" routes to the personal tutor's \
                Socratic guidance (learn the type, hints not answers); \
                mode="submit" (default) produces the complete \
                submission-ready solution in the user's style. Records the \
                problem type to the tracker either way.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "problem": ["type": "string", "description": "The problem statement."],
                    "mode": ["type": "string", "description": "teach | submit. Defaults to the user's setting."],
                ],
                "required": ["problem"],
            ],
        ],
        [
            "name": "explain_problem",
            "description": """
                Walk the user through HOW to approach a homework problem \
                without giving the answer away: the strategy, what to try \
                first, and the pitfalls to avoid.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "problem": ["type": "string", "description": "The problem statement."],
                ],
                "required": ["problem"],
            ],
        ],
        [
            "name": "write_code",
            "description": """
                Write a submission-ready code solution for a homework \
                problem, matched to the user's coding style (naming, error \
                handling, comment structure) when the setting says so, with \
                comments and test cases.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "requirements": ["type": "string", "description": "What the code must do."],
                    "language": ["type": "string", "description": "Preferred language (e.g. python, java, swift). Optional."],
                ],
                "required": ["requirements"],
            ],
        ],
        [
            "name": "solve_math",
            "description": """
                Solve a math problem step by step, with alternative methods \
                when they exist. LaTeX formatting honors the user's setting.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "problem": ["type": "string", "description": "The math problem."],
                ],
                "required": ["problem"],
            ],
        ],
        [
            "name": "solve_physics",
            "description": """
                Solve a physics problem: the concepts that apply, the setup \
                and equations, the solution, and the intuition for why it \
                makes sense.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "problem": ["type": "string", "description": "The physics problem."],
                ],
                "required": ["problem"],
            ],
        ],
        [
            "name": "format_solution",
            "description": """
                Re-format an existing solution: code wraps it in a markdown \
                fence, latex wraps math in display-math delimiters, text \
                returns it plain. Instant, no model call.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "solution": ["type": "string", "description": "The solution text to format."],
                    "format": ["type": "string", "description": "code | latex | text. Defaults to text."],
                ],
                "required": ["solution"],
            ],
        ],
        [
            "name": "what_i_struggle_with",
            "description": """
                The problem types Alfred has watched you struggle with, most-struggled                 first — each with how many times it tripped the user up and how many                 submission solves came out the other end. Instant, no model call.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [],
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

        // Argument helpers shared by the calendar/reminder tools.
        func stringArg(_ key: String, _ args: [String: Any]) -> String? { args[key] as? String }
        func boolArg(_ key: String, _ args: [String: Any], default fallback: Bool) -> Bool {
            if let b = args[key] as? Bool { return b }
            if let s = args[key] as? String { return Bool(s) ?? fallback }
            return fallback
        }
        func dateArg(_ key: String, _ args: [String: Any]) -> Date? {
            (args[key] as? String).flatMap(CalendarCapability.parseISO(_:))
        }

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

        case "terminal_run":
            guard let command = arguments["command"] as? String, !command.isEmpty else {
                throw ToolError.missingArgument("command")
            }
            // The user's explicit "run X" is the permission, so there is no bar prompt.
            // Terminal access is always enabled — the only guard left is the
            // fast-refusal blocklist for obviously destructive commands.
            guard !TerminalCapability.isBlocked(command) else {
                throw ToolError.unavailable("""
                    That command looks destructive (deletes data, alters the system, \
                    or downloads-and-executes code), so Alfred won't run it. Tell the \
                    user you refused, and ask what they actually want to do.
                    """)
            }
            let directory = arguments["directory"] as? String ?? NSHomeDirectory()
            let timeout = TimeInterval(arguments["timeout_seconds"] as? Int ?? 30)
            let result = TerminalCapability.shared.run(command,
                                                       directory: directory,
                                                       timeout: timeout)
            var reply = result.output.isEmpty
                ? "(no output)"
                : result.output
            reply += "\n\nExit code: \(result.exitCode)"
            if result.timedOut {
                reply += " (killed after \(Int(timeout))s)"
            }
            return reply

        case "email_list":
            let mailbox = arguments["mailbox"] as? String ?? "Inbox"
            let limit = arguments["limit"] as? Int ?? 20
            return try EmailCapability.shared.listMessages(
                account: "icloud", mailbox: mailbox, limit: limit)

        case "email_read":
            guard let id = arguments["id"] as? String, !id.isEmpty else {
                throw ToolError.missingArgument("id")
            }
            // Default to Inbox; a mailbox param lets the model open Junk/Archive
            // messages it found via email_scan.
            let mailbox = arguments["mailbox"] as? String ?? "Inbox"
            let message = try EmailCapability.shared.readMessage(
                id: id, account: "icloud", mailbox: mailbox)
            PersonalMemoryStore.shared.recordObservation(
                source: "email",
                text: message,
                app: "Mail")
            return message

        case "email_scan":
            let summary = MailScanService.persistedSummary()
            guard summary.scannedAt > 0 else {
                return "No scan yet. Ask the user to wait a moment while Alfred checks every folder."
            }
            var lines = [summary.oneLine]
            for item in summary.spamMiss {
                let who = item.fromName.isEmpty ? item.fromAddress : item.fromName
                lines.append("Junk → important: \(who) — \(item.subject) (id \(item.uid) in \(item.mailbox), \(Int(item.confidence * 100))%)")
            }
            for item in summary.important.prefix(5) {
                let who = item.fromName.isEmpty ? item.fromAddress : item.fromName
                lines.append("Important: \(who) — \(item.subject)")
            }
            let folder = arguments["folder"] as? String
            if let folder, let stat = summary.folders.first(where: {
                $0.name.caseInsensitiveCompare(folder) == .orderedSame || $0.role == folder.lowercased()
            }) {
                lines.append("\(stat.name): \(stat.unseen) unread of \(stat.total), \(stat.flagged) flagged")
            }
            return lines.joined(separator: "\n")

        case "email_move":
            guard let id = arguments["id"] as? String, !id.isEmpty,
                  let from = arguments["from_mailbox"] as? String,
                  let to = arguments["to_mailbox"] as? String else {
                throw ToolError.missingArgument("id, from_mailbox and to_mailbox")
            }
            let account = arguments["account"] as? String ?? "icloud"
            try EmailCapability.shared.moveMessage(
                account: account, fromMailbox: from, toMailbox: to, messageID: id)
            // Drop it from the cache so the phone's list reflects the move.
            try? MailManager.purgeCachedMessage(account: account, mailbox: from, uid: id)
            return "Moved \(id) from \(from) to \(to)."

        case "email_save_draft":
            guard let to = arguments["to"] as? String, !to.isEmpty,
                  let subject = arguments["subject"] as? String,
                  let body = arguments["body"] as? String else {
                throw ToolError.missingArgument("to, subject and body")
            }
            let account = arguments["account"] as? String ?? "icloud"
            return try EmailCapability.shared.saveDraft(
                to: to, cc: nil, subject: subject, body: body,
                inReplyTo: nil, account: account)

        case "calendar_list":
            let days = min(arguments["days"] as? Int ?? 7, 90)
            let limit = arguments["limit"] as? Int ?? 30
            return try await CalendarCapability().listEvents(days: days, limit: limit)

        case "calendar_add":
            guard let title = stringArg("title", arguments), !title.isEmpty else {
                throw ToolError.missingArgument("title")
            }
            guard let startRaw = stringArg("start", arguments),
                  let start = CalendarCapability.parseISO(startRaw) else {
                throw ToolError.missingArgument("start (ISO-8601, e.g. 2026-09-05T15:00:00)")
            }
            let isAllDay = boolArg("all_day", arguments, default: false)
            let end: Date
            if let raw = stringArg("end", arguments), let parsed = CalendarCapability.parseISO(raw) {
                end = parsed
            } else {
                end = isAllDay ? start.addingTimeInterval(86_400) : start.addingTimeInterval(3_600)
            }
            let draft = CalendarCapability.NewEvent(
                title: title,
                start: start,
                end: end,
                isAllDay: isAllDay,
                location: stringArg("location", arguments),
                notes: stringArg("notes", arguments),
                calendar: stringArg("calendar", arguments)
            )
            // The user's instruction is the permission; only deletes re-bring up
            // the bar (see calendar_delete).
            return try await CalendarCapability().createEvent(draft)

        case "calendar_update":
            guard let id = stringArg("id", arguments), !id.isEmpty else {
                throw ToolError.missingArgument("id")
            }
            // Present-but-empty means "clear the field" for text fields; absent
            // means "leave unchanged".
            let changes = CalendarCapability.EventUpdate(
                title: stringArg("title", arguments),
                start: dateArg("start", arguments),
                end: dateArg("end", arguments),
                isAllDay: arguments.keys.contains("all_day") ? boolArg("all_day", arguments, default: false) : nil,
                location: arguments.keys.contains("location") ? (stringArg("location", arguments) ?? "") : nil,
                notes: arguments.keys.contains("notes") ? (stringArg("notes", arguments) ?? "") : nil,
                calendar: stringArg("calendar", arguments)
            )
            return try await CalendarCapability().updateEvent(id: id, changes: changes)

        case "calendar_delete":
            guard let id = stringArg("id", arguments), !id.isEmpty else {
                throw ToolError.missingArgument("id")
            }
            guard await confirmUserAction(summary: "Delete calendar event \(id) — not reversible") else {
                throw ToolError.denied
            }
            return try await CalendarCapability().deleteEvent(id: id)

        case "reminder_list":
            let includeCompleted = boolArg("include_completed", arguments, default: false)
            let limit = arguments["limit"] as? Int ?? 30
            return try await CalendarCapability().listReminders(includeCompleted: includeCompleted, limit: limit)

        case "reminder_add":
            guard let title = stringArg("title", arguments), !title.isEmpty else {
                throw ToolError.missingArgument("title")
            }
            let due = dateArg("due", arguments)
            let draft = CalendarCapability.NewReminder(
                title: title,
                due: due,
                notes: stringArg("notes", arguments),
                list: stringArg("list", arguments)
            )
            return try await CalendarCapability().createReminder(draft)

        case "reminder_update":
            guard let id = stringArg("id", arguments), !id.isEmpty else {
                throw ToolError.missingArgument("id")
            }
            // An empty "due" string clears the due date; an absent one keeps it.
            let dueUpdate: CalendarCapability.DateUpdate
            if (arguments["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false {
                dueUpdate = .undated
            } else if let due = dateArg("due", arguments) {
                dueUpdate = .set(due)
            } else {
                dueUpdate = .unchanged
            }
            return try await CalendarCapability().updateReminder(
                id: id,
                title: stringArg("title", arguments),
                due: dueUpdate,
                notes: stringArg("notes", arguments)
            )

        case "reminder_complete":
            guard let id = stringArg("id", arguments), !id.isEmpty else {
                throw ToolError.missingArgument("id")
            }
            let completed = boolArg("completed", arguments, default: true)
            return try await CalendarCapability().markReminder(id: id, completed: completed)

        case "reminder_delete":
            guard let id = stringArg("id", arguments), !id.isEmpty else {
                throw ToolError.missingArgument("id")
            }
            guard await confirmUserAction(summary: "Delete reminder \(id) — not reversible") else {
                throw ToolError.denied
            }
            return try await CalendarCapability().deleteReminder(id: id)

        case "email_send":
            guard let to = arguments["to"] as? String, !to.isEmpty,
                  let subject = arguments["subject"] as? String,
                  let body = arguments["body"] as? String
            else {
                throw ToolError.missingArgument("to, subject and body")
            }
            // The user's instruction is the permission; sending goes straight out
            // (only deletes still confirm — see calendar_delete).
            return try EmailCapability.shared.sendMessage(
                to: to,
                cc: arguments["cc"] as? String,
                subject: subject,
                body: body,
                inReplyTo: arguments["in_reply_to"] as? String,
                account: "icloud")

        case "contacts_find":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            return try await ContactsCapability().findContact(query: query)

        case "messages_list":
            return MessagesCapability.shared.listConversations()

        case "messages_thread":
            guard let guid = arguments["guid"] as? String, !guid.isEmpty else {
                throw ToolError.missingArgument("guid")
            }
            let thread = MessagesCapability.shared.threadMessages(guid: guid)
            PersonalMemoryStore.shared.recordObservation(
                source: "messages",
                text: thread,
                app: "Messages")
            return thread

        case "messages_send":
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                throw ToolError.missingArgument("text")
            }
            let guid = arguments["guid"] as? String
            let participant = arguments["participant"] as? String
            if let guid, !guid.isEmpty {
                return MessagesCapability.shared.sendMessage(guid: guid, text: text)
            }
            guard let participant, !participant.isEmpty else {
                throw ToolError.missingArgument("guid or participant")
            }
            // The user's instruction is the permission — a text goes straight out
            // through Messages (only deletes still confirm).
            return MessagesCapability.shared.sendToParticipant(participant: participant, text: text)

        case "spotify_play":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            // Same as a send: the user explicitly asked for it, so it plays
            // straight away — no confirmation prompt.
            return try await SpotifyCapability().play(query)

        case "spotify_control":
            guard let action = arguments["action"] as? String, !action.isEmpty else {
                throw ToolError.missingArgument("action")
            }
            return try await SpotifyCapability().transport(action)

        case "file_organize":
            guard var request = ToolHandlers.decode(FileOrganizeRequest.self, from: arguments) else {
                throw ToolError.missingArgument("valid arguments (action, source_path, destination_path, confirmation)")
            }
            // Deletes are the one class Alfred keeps human-gated — the same bar
            // broker calendar_delete / reminder_delete use. The handler's own
            // keyword check protects direct (non-bar) callers; here the bar is
            // the real gate, and its approval rides through as the confirmation
            // so a legitimately approved delete isn't re-blocked by the keyword
            // check.
            if request.action.lowercased() == "delete" {
                guard await confirmUserAction(summary: "Delete file \(request.sourcePath ?? "this file") — not reversible") else {
                    throw ToolError.denied
                }
                request = FileOrganizeRequest(
                    action: request.action,
                    sourcePath: request.sourcePath,
                    destinationPath: request.destinationPath,
                    recursive: request.recursive,
                    confirmation: "confirmed by the user in the bar")
            }
            // Handlers never throw: failures come back as a readable ToolResult.
            return ToolHandlers.handleFileOrganize(request).text

        case "calendar_plan":
            guard let request = ToolHandlers.decode(CalendarPlanRequest.self, from: arguments) else {
                throw ToolError.missingArgument("valid arguments (action, duration_minutes, start_date, end_date)")
            }
            return await ToolHandlers.handleCalendarPlan(request).text

        case "habit_predict":
            guard let request = ToolHandlers.decode(HabitPredictRequest.self, from: arguments) else {
                throw ToolError.missingArgument("valid arguments (action, current_app)")
            }
            return ToolHandlers.handleHabitPredict(request).text        case "timer_set":
            guard let minutes = arguments["minutes"] as? Double,
                  minutes > 0
            else {
                throw ToolError.missingArgument("minutes (positive number)")
            }
            let label = arguments["label"] as? String
            return await TimerCapability.shared.setTimer(minutes: minutes, label: label)

        case "timer_status":
            return await TimerCapability.shared.status()

        case "timer_cancel":
            return await TimerCapability.shared.cancelAll()

        case "polish_text":
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                throw ToolError.missingArgument("text")
            }
            let style = arguments["style"] as? String
            return await TasteSkillManager.shared.polishForAgent(text, style: style)

        case "evaluate_boringness":
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                throw ToolError.missingArgument("text")
            }
            let verdict = TasteBoringness.evaluate(
                text, aggressiveness: TasteSkillManager.shared.aggressiveness)
            let verdictJSON: [String: Any] = [
                "boringness": verdict.score,
                "needs_polish": verdict.needsPolish,
                "matched_phrases": verdict.matchedPhrases,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: verdictJSON) else {
                throw ToolError.unavailable("could not serialize the verdict")
            }
            return String(data: data, encoding: .utf8) ?? "{}"

        case "suggest_improvements":
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                throw ToolError.missingArgument("text")
            }
            guard let suggestions = await TasteSkillManager.shared.suggestImprovements(text) else {
                return "[]"
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: ["suggestions": suggestions]) else {
                throw ToolError.unavailable("could not serialize suggestions")
            }
            return String(data: data, encoding: .utf8) ?? "[]"

        case "multi_agent_run":
            guard let task = arguments["task"] as? String, !task.isEmpty else {
                throw ToolError.missingArgument("task")
            }
            guard await MultiAgentOrchestrator.shared.enabled else {
                throw ToolError.unavailable(
                    "Multi-agent is off in Alfred Settings — turn it on, or answer the request yourself.")
            }
            // Runs on its own per-role sessions, so it neither waits on nor
            // blocks the shared bar session. The full transcript (headers +
            // every agent's deliverable) comes back as the tool result.
            return await MultiAgentOrchestrator.shared.runCollectingText(task: task)

        case "create_presentation":
            guard let topic = arguments["topic"] as? String, !topic.isEmpty else {
                throw ToolError.missingArgument("topic")
            }
            let numSlides = arguments["num_slides"] as? Int
            let minutes = arguments["minutes"] as? Int
            let tone = PresentationTone(rawValue: arguments["tone"] as? String ?? "") ?? .academic
            let style = arguments["style"] as? String
            let includeNotes = arguments["include_notes"] as? Bool
            // Own Hermes session + own exports: a deck build never blocks the
            // bar session. May take a couple of minutes for a big deck.
            let record = try await PresentationGeneratorSkill.shared.create(
                topic: topic, numSlides: numSlides, minutes: minutes,
                tone: tone, style: style, includeNotes: includeNotes)
            return "id: \(record.id.uuidString)\n" + record.resultText

        case "add_speaker_notes":
            guard let raw = arguments["presentation_id"] as? String,
                  let id = UUID(uuidString: raw) else {
                throw ToolError.missingArgument("presentation_id (a UUID from create_presentation)")
            }
            let path = try await PresentationGeneratorSkill.shared.addSpeakerNotes(id: id)
            return "Speaker notes written to \(path)"

        case "design_presentation":
            guard let raw = arguments["presentation_id"] as? String,
                  let id = UUID(uuidString: raw) else {
                throw ToolError.missingArgument("presentation_id (a UUID from create_presentation)")
            }
            guard let style = arguments["style"] as? String, !style.isEmpty else {
                throw ToolError.missingArgument("style")
            }
            let updated = try await PresentationGeneratorSkill.shared.redesign(id: id, style: style)
            return "Deck re-rendered: \(updated.style) — " + updated.resultText

        case "export_presentation":
            guard let raw = arguments["presentation_id"] as? String,
                  let id = UUID(uuidString: raw) else {
                throw ToolError.missingArgument("presentation_id (a UUID from create_presentation)")
            }
            let format = PresentationExportFormat(
                rawValue: arguments["format"] as? String ?? "") ?? .both
            let updated = try await PresentationGeneratorSkill.shared.export(id: id, format: format)
            return "Re-exported \(format.displayName).\n" + updated.resultText

        case "explain_concept":
            guard let concept = arguments["concept"] as? String, !concept.isEmpty else {
                throw ToolError.missingArgument("concept")
            }
            let course = arguments["course"] as? String
            return await PersonalTutorSkill.shared.explain(concept: concept, course: course)

        case "socratic_guide":
            guard let problem = arguments["problem"] as? String, !problem.isEmpty else {
                throw ToolError.missingArgument("problem")
            }
            let concept = arguments["concept"] as? String
            return await PersonalTutorSkill.shared.socraticGuide(problem: problem, concept: concept)

        case "track_mastery":
            guard let concept = arguments["concept"] as? String, !concept.isEmpty else {
                throw ToolError.missingArgument("concept")
            }
            guard let confidence = arguments["confidence"] as? Int else {
                throw ToolError.missingArgument("confidence (1–5)")
            }
            let course = arguments["course"] as? String
            guard let updated = PersonalTutorSkill.shared.trackMastery(
                concept: concept, confidence: confidence, course: course) else {
                throw ToolError.unavailable("Could not record mastery for '\(concept)'.")
            }
            return "Recorded: \(updated.name) is \(updated.confidence)/5"
                + (updated.sessionCount > 0 ? " across \(updated.sessionCount) sessions." : ".")

        case "tutor_feedback":
            guard let concept = arguments["concept"] as? String, !concept.isEmpty else {
                throw ToolError.missingArgument("concept")
            }
            guard let raw = arguments["outcome"] as? String,
                  let outcome = TutoringOutcome(rawValue: raw) else {
                throw ToolError.missingArgument("outcome (understood | confused | more_detail | other_angle | abandoned)")
            }
            let course = arguments["course"] as? String
            if let updated = PersonalTutorSkill.shared.recordFeedback(
                concept: concept, outcome: outcome, course: course) {
                return "Logged: '\(updated.name)' is now \(updated.confidence)/5 (\(outcome.displayName))."
            }
            return "Logged feedback for '\(concept)' (\(outcome.displayName))."

        case "what_am_i_weak_at":
            return PersonalTutorSkill.shared.whatAmIWeakAt()

        case "exam_prep_routine":
            let examDate = arguments["exam_date"] as? String
            let topics = arguments["topics"] as? [String] ?? []
            return await PersonalTutorSkill.shared.examPrep(examDate: examDate, topics: topics)

        case "my_learning_style":
            return PersonalTutorSkill.shared.myLearningStyle()

        case "start_exam_prep":
            let examDate = arguments["exam_date"] as? String
            let topics = arguments["topics"] as? [String] ?? []
            let course = arguments["course"] as? String
            return StudyRoutineManager.shared.startExamPrep(
                examDate: examDate, topics: topics, course: course)

        case "track_problem_set":
            guard let problems = arguments["problems"] as? [String], !problems.isEmpty else {
                throw ToolError.missingArgument("problems")
            }
            let course = arguments["course"] as? String
            let name = arguments["name"] as? String
            let source = arguments["source"] as? String ?? "manual"
            let solved: [Int]
            if let raw = arguments["solved"] as? [Int] {
                solved = raw
            } else if let raw = arguments["solved"] as? [NSNumber] {
                solved = raw.map { $0.intValue }
            } else {
                solved = []
            }
            return StudyRoutineManager.shared.trackProblemSet(
                problems: problems, course: course, name: name,
                source: source, solvedIndices: solved)

        case "quiz_on_reading":
            guard let chapter = arguments["chapter"] as? String, !chapter.isEmpty else {
                throw ToolError.missingArgument("chapter")
            }
            let course = arguments["course"] as? String
            let content = arguments["content"] as? String
            let result = arguments["result"] as? String
            return await StudyRoutineManager.shared.quizOnReading(
                chapter: chapter, course: course, content: content, result: result)

        case "summarize_lecture":
            guard let notes = arguments["recording_or_notes"] as? String, !notes.isEmpty else {
                throw ToolError.missingArgument("recording_or_notes")
            }
            let course = arguments["course"] as? String
            let title = arguments["title"] as? String
            return await StudyRoutineManager.shared.summarizeLecture(
                recordingOrNotes: notes, course: course, title: title)

        case "weekly_review":
            return await StudyRoutineManager.shared.weeklyReview()

        case "understand_search":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            guard let projectPath = arguments["project_path"] as? String, !projectPath.isEmpty else {
                throw ToolError.missingArgument("project_path")
            }
            let limit = arguments["limit"] as? Int ?? 10
            let hits = await UnderstandAnythingManager.shared.search(
                query: query, projectPath: projectPath, limit: limit)
            guard !hits.isEmpty else {
                return "No matches in the knowledge graph for '\(query)'. The project may not be analyzed yet — check for \(projectPath)/.ua/knowledge-graph.json."
            }
            return hits.map { hit -> String in
                var line = "\(hit.name) [\(hit.type)]"
                if let path = hit.filePath, !path.isEmpty { line += " — \(path)" }
                if let summary = hit.summary, !summary.isEmpty {
                    line += "\n  \(summary)"
                }
                return line + "\n  id: \(hit.id)"
            }.joined(separator: "\n")

        case "understand_impact":
            guard let target = arguments["target"] as? String, !target.isEmpty else {
                throw ToolError.missingArgument("target")
            }
            guard let projectPath = arguments["project_path"] as? String, !projectPath.isEmpty else {
                throw ToolError.missingArgument("project_path")
            }
            let maxDepth = arguments["max_depth"] as? Int ?? 4
            let hits = await UnderstandAnythingManager.shared.impact(
                of: target, projectPath: projectPath, maxDepth: maxDepth)
            guard !hits.isEmpty else {
                return "Nothing in the knowledge graph depends on '\(target)' — changing it looks safe. (If that surprises you, the project may not be analyzed: check for \(projectPath)/.ua/knowledge-graph.json.)"
            }
            let direct = hits.filter { $0.depth == 0 }.count
            let lines = hits.prefix(40).map { hit -> String in
                let pad = String(repeating: "  ", count: min(hit.depth, 3))
                return "\(pad)• \(hit.name) [\(hit.type)] — \(hit.filePath ?? hit.id) (depth \(hit.depth))"
            }
            return "\(hits.count) nodes depend on '\(target)' (\(direct) directly):\n" + lines.joined(separator: "\n")

        case "understand_explain":
            guard let nodeID = arguments["node_id"] as? String, !nodeID.isEmpty else {
                throw ToolError.missingArgument("node_id")
            }
            guard let projectPath = arguments["project_path"] as? String, !projectPath.isEmpty else {
                throw ToolError.missingArgument("project_path")
            }
            guard let explanation = await UnderstandAnythingManager.shared.explain(
                nodeID: nodeID, projectPath: projectPath) else {
                throw ToolError.unavailable("No node '\(nodeID)' in the project's knowledge graph.")
            }
            var lines: [String] = []
            let node = explanation.node
            lines.append("\(node.displayName) [\(node.type)] — \(node.id)")
            if let signature = node.signature, !signature.isEmpty {
                lines.append("Signature: \(signature)")
            }
            if let summary = node.summary, !summary.isEmpty {
                lines.append("\n\(summary)")
            }
            if !explanation.layers.isEmpty {
                lines.append("\nLayers: \(explanation.layers.joined(separator: ", "))")
            }
            let incoming = explanation.neighbors.filter { $0.direction == "in" }
            let outgoing = explanation.neighbors.filter { $0.direction == "out" }
            if !incoming.isEmpty {
                lines.append("\nDepended on by (\(incoming.count)):")
                lines.append(contentsOf: incoming.prefix(15).map {
                    "  • \($0.node.displayName) [\($0.type)] — \($0.node.id)"
                })
            }
            if !outgoing.isEmpty {
                lines.append("\nDepends on (\(outgoing.count)):")
                lines.append(contentsOf: outgoing.prefix(15).map {
                    "  • \($0.node.displayName) [\($0.type)] — \($0.node.id)"
                })
            }
            return lines.joined(separator: "\n")

        case "understand_architecture":
            guard let projectPath = arguments["project_path"] as? String, !projectPath.isEmpty else {
                throw ToolError.missingArgument("project_path")
            }
            let layers = await UnderstandAnythingManager.shared.architecture(projectPath: projectPath)
            guard !layers.isEmpty else {
                return "No knowledge graph for \(projectPath) — analyze it first (check for \(projectPath)/.ua/knowledge-graph.json)."
            }
            let lines = layers.map { layer -> String in
                var line = "\(layer.name) — \(layer.nodeCount) node\(layer.nodeCount == 1 ? "" : "s")"
                if let description = layer.description, !description.isEmpty {
                    line += "\n  \(description)"
                }
                if !layer.sampleNodes.isEmpty {
                    line += "\n  e.g. \(layer.sampleNodes.joined(separator: ", "))"
                }
                return line
            }
            return lines.joined(separator: "\n")

        case "get_assignments":
            let limit = arguments["limit"] as? Int ?? 25
            let rows = await MainActor.run { NYUIntegrationManager.shared.listAssignments() }
            guard !rows.isEmpty else {
                return "No assignments tracked. Enable the NYU integration with a Canvas token in Settings and sync — or there may be nothing due yet."
            }
            let lines = rows.prefix(limit).map { row -> String in
                var line = "\(row.name) [\(row.courseName)] — \(AssignmentStatus(rawValue: row.status)?.displayName ?? row.status)"
                if let due = row.dueAt {
                    let when = Date(timeIntervalSince1970: due).formatted(date: .abbreviated, time: .omitted)
                    line += row.isOverdue ? " (overdue, due \(when))" : " (due \(when))"
                } else {
                    line += " (no due date)"
                }
                if let score = row.score { line += " — scored \(score)" }
                return line + " — id \(row.id)"
            }
            return "\(rows.count) assignment(s):\n" + lines.joined(separator: "\n")

        case "get_current_grades":
            let courses = await MainActor.run { NYUIntegrationManager.shared.listCourses() }
            let graded = courses.filter { $0.currentScore != nil }
            guard !graded.isEmpty else {
                return "No grades yet — the NYU integration is either unconfigured or Canvas hasn't posted scores. Sync to refresh."
            }
            return graded.map { course -> String in
                let score = String(format: "%.1f", course.currentScore ?? 0)
                var line = "\(course.name): \(score) (\(course.trend))"
                if let projected = course.projectedScore {
                    line += " — projected \(String(format: "%.1f", projected))"
                }
                return line + " — course id \(course.id)"
            }.joined(separator: "\n")

        case "get_next_deadline":
            let next = await MainActor.run { NYUIntegrationManager.shared.nextDeadline() }
            guard let next else {
                return "No upcoming deadlines — everything pending is either submitted, graded, or overdue. Sync to be sure."
            }
            let when = next.dueAt.map {
                Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
            } ?? "no due date"
            return "\(next.name) [\(next.courseName)] — due \(when) (id \(next.id))"

        case "mark_submitted":
            guard let assignmentID = arguments["assignment_id"] as? Int else {
                throw ToolError.missingArgument("assignment_id")
            }
            let status = arguments["status"] as? String ?? AssignmentStatus.submitted.rawValue
            let updated = await MainActor.run {
                NYUIntegrationManager.shared.updateAssignmentStatus(id: assignmentID, status: status)
            }
            guard let updated else {
                return "No assignment with id \(assignmentID). Get ids from get_assignments."
            }
            return "Marked '\(updated.name)' as \(AssignmentStatus(rawValue: updated.status)?.displayName ?? updated.status). This is local tracking only — nothing was submitted to Canvas."

        case "get_syllabus_info":
            let courseID = arguments["course_id"] as? Int
            let courses = await MainActor.run {
                courseID.map { NYUIntegrationManager.shared.courseInfo(id: $0).map { [$0] } ?? [] }
                    ?? NYUIntegrationManager.shared.listCourses()
            }
            guard !courses.isEmpty else {
                return "No course info — enable the NYU integration and sync."
            }
            return courses.map { course -> String in
                var lines = ["\(course.name) (\(course.code)) — id \(course.id)"]
                if !course.term.isEmpty { lines.append("  Term: \(course.term)") }
                if !course.professor.isEmpty { lines.append("  Professor: \(course.professor)") }
                if !course.schedule.isEmpty { lines.append("  Schedule: \(course.schedule)") }
                if let finalExam = course.finalExamAt {
                    lines.append("  Final exam: \(Date(timeIntervalSince1970: finalExam).formatted(date: .abbreviated, time: .omitted)) (best-effort from syllabus)")
                }
                if !course.gradingBreakdown.isEmpty {
                    let breakdown = course.gradingBreakdown
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key) \(Int($0.value))%" }
                        .joined(separator: ", ")
                    lines.append("  Grading: \(breakdown)")
                }
                if !course.syllabus.isEmpty {
                    lines.append("  Syllabus: \(course.syllabus.prefix(400))")
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")

        case "learn_preference":
            guard let content = arguments["content"] as? String, !content.isEmpty else {
                throw ToolError.missingArgument("content")
            }
            let category = (arguments["category"] as? String)
                .flatMap(MemoryCategory.init(rawValue:)) ?? .preference
            let id = MemPalaceManager.shared.remember(
                content: content, category: category, source: "manual",
                confidence: 0.75)
            guard !id.isEmpty else {
                throw ToolError.unavailable("could not store the memory")
            }
            return "Stored: \(content) (category \(category.rawValue), id \(id))"

        case "get_learned_context":
            let limit = arguments["limit"] as? Int ?? 6
            let entries = MemPalaceManager.shared.getLearnedContext(limit: limit)
            guard !entries.isEmpty else {
                return "No high-confidence memories yet — nothing above the threshold."
            }
            let lines = entries.map { entry -> String in
                let pct = Int((entry.confidence * 100).rounded())
                return "\(entry.content) (\(entry.category.rawValue), \(pct)%)"
            }
            return lines.joined(separator: "\n")

        case "recall_about_person":
            guard let name = arguments["name"] as? String, !name.isEmpty else {
                throw ToolError.missingArgument("name")
            }
            let entries = MemPalaceManager.shared.recallAboutPerson(name)
            guard !entries.isEmpty else {
                return "Nothing stored about \(name)."
            }
            return entries.map { entry -> String in
                let pct = Int((entry.confidence * 100).rounded())
                return "\(entry.content) (\(pct)%)"
            }.joined(separator: "\n")

        case "search_memory":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            let limit = arguments["limit"] as? Int ?? 12
            let entries = MemPalaceManager.shared.search(query, limit: limit)
            guard !entries.isEmpty else {
                return "No memories match '\(query)'."
            }
            let lines = entries.map { entry -> String in
                let pct = Int((entry.confidence * 100).rounded())
                return "\(entry.content) (\(entry.category.rawValue), \(pct)%, id \(entry.id))"
            }
            return lines.joined(separator: "\n")

        case "correct_memory":
            guard let memoryID = arguments["memory_id"] as? String, !memoryID.isEmpty,
                  let correction = arguments["correction"] as? String, !correction.isEmpty else {
                throw ToolError.missingArgument("memory_id and correction")
            }
            guard let corrected = MemPalaceManager.shared.correctMemory(
                id: memoryID, correction: correction) else {
                throw ToolError.unavailable("no memory with id \(memoryID)")
            }
            return "Corrected: \(corrected.content) (now \(Int((corrected.confidence * 100).rounded()))%)"

        case "update_goal_progress":
            guard let goalID = arguments["goal_id"] as? String, !goalID.isEmpty else {
                throw ToolError.missingArgument("goal_id")
            }
            let completed = arguments["completed"] as? Bool ?? true
            guard let goal = MemPalaceManager.shared.updateGoalProgress(
                id: goalID, completed: completed) else {
                throw ToolError.unavailable("no goal with id \(goalID)")
            }
            return "\(goal.title): streak \(goal.streak)"

        case "get_optimization_report":
            return Self.optimizationReportText()

        case "optimization_compile":
            // The manual trigger: run a compile pass now and report what it
            // learned. Bounded (the DSPy bridge times out at 60s), and the
            // store serializes its own SQLite connections, so this is safe to
            // call from the MCP serving thread.
            let compiled = DSPyOptimizer.shared.compile()
            return Self.optimizationReportText(compiled)

        case "optimization_rollback":
            guard let raw = arguments["kind"] as? String,
                  let kind = OptimizationKind(rawValue: raw) else {
                throw ToolError.missingArgument("kind (code, email, summary, routine, multistep, or general)")
            }
            let rules = DSPyOptimizer.shared.rollback(kind: kind)
            if rules.isEmpty {
                return "\(kind.displayName) rolled back to baseline — no learned rules active."
            }
            let listed = rules.map(\.directive).joined(separator: "\n- ")
            return "\(kind.displayName) rolled back to the previous rule set:\n- \(listed)"

        case "write_essay":
            guard let topic = arguments["topic"] as? String,
                  !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.missingArgument("topic")
            }
            let length = arguments["length"] as? String
            let citationStyle = (arguments["citation_style"] as? String).flatMap(CitationStyle.init(rawValue:))
            let tone = (arguments["tone"] as? String).flatMap(EssayTone.init(rawValue:))
            let result = await EssayWritingSkill.shared.writeEssay(
                topic: topic, length: length, citationStyle: citationStyle, tone: tone)
            return result.essay

        case "analyze_my_writing_style":
            return EssayWritingSkill.shared.styleDescription()

        case "learn_writing_style":
            guard let essay = arguments["essay"] as? String,
                  !essay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.missingArgument("essay")
            }
            let profile = EssayWritingSkill.shared.learnStyle(from: essay)
            let description = profile.summary.isEmpty ? profile.toPromptInjection() : profile.summary
            return "Learned (now \(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")): \(description)"

        case "research_topic":
            guard let topic = arguments["topic"] as? String,
                  !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.missingArgument("topic")
            }
            let depth = (arguments["depth"] as? String).flatMap(ResearchDepth.init(rawValue:))
            let sources = await EssayWritingSkill.shared.research(topic: topic, depth: depth)
            guard !sources.isEmpty else {
                return "No sources found for “\(topic)”. The search bridge may be down or the topic returned nothing."
            }
            var lines: [String] = []
            for (index, source) in sources.enumerated() {
                lines.append("\(index + 1). \(source.title)")
                if !source.url.isEmpty { lines.append("   \(source.url)") }
                if !source.summary.isEmpty { lines.append("   \(source.summary)") }
                for quote in source.keyQuotes { lines.append("   “\(quote)”") }
            }
            return lines.joined(separator: "\n")

        case "revise_essay":
            guard let essay = arguments["essay"] as? String,
                  !essay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.missingArgument("essay")
            }
            guard let feedback = arguments["feedback"] as? String,
                  !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError.missingArgument("feedback")
            }
            let tone = (arguments["tone"] as? String).flatMap(EssayTone.init(rawValue:))
            return await EssayWritingSkill.shared.revise(essay: essay, feedback: feedback, tone: tone)

        case "check_citations":
            guard let essay = arguments["essay"] as? String, !essay.isEmpty else {
                throw ToolError.missingArgument("essay")
            }
            let style = (arguments["citation_style"] as? String).flatMap(CitationStyle.init(rawValue:))
            let issues = EssayWritingSkill.shared.checkCitations(essay: essay, style: style)
            guard !issues.isEmpty else {
                return "Citations look consistent — every listed source is cited and the reference list is present."
            }
            return issues.map { "- \($0)" }.joined(separator: "\n")

        case "solve_problem":
            guard let problem = arguments["problem"] as? String, !problem.isEmpty else {
                throw ToolError.missingArgument("problem")
            }
            return await HomeworkAssistantSkill.shared.solveProblem(
                problem, mode: arguments["mode"] as? String)

        case "explain_problem":
            guard let problem = arguments["problem"] as? String, !problem.isEmpty else {
                throw ToolError.missingArgument("problem")
            }
            return await HomeworkAssistantSkill.shared.explainProblem(problem)

        case "write_code":
            guard let requirements = arguments["requirements"] as? String,
                  !requirements.isEmpty else {
                throw ToolError.missingArgument("requirements")
            }
            return await HomeworkAssistantSkill.shared.writeCode(
                requirements: requirements, language: arguments["language"] as? String)

        case "solve_math":
            guard let problem = arguments["problem"] as? String, !problem.isEmpty else {
                throw ToolError.missingArgument("problem")
            }
            return await HomeworkAssistantSkill.shared.solveMath(problem)

        case "solve_physics":
            guard let problem = arguments["problem"] as? String, !problem.isEmpty else {
                throw ToolError.missingArgument("problem")
            }
            return await HomeworkAssistantSkill.shared.solvePhysics(problem)

        case "format_solution":
            guard let solution = arguments["solution"] as? String else {
                throw ToolError.missingArgument("solution")
            }
            return HomeworkAssistantSkill.shared.formatSolution(
                solution, format: arguments["format"] as? String)

        case "what_i_struggle_with":
            return HomeworkAssistantSkill.shared.struggleSummary()

        default:
            throw ToolError.unknown(tool)
        }
    }

    /// Format the DSPy self-optimization report as plain text the model can
    /// read and relay. Deliberately deterministic and instant — no model turn
    /// is spent reading the agent's own trend.
    private static func optimizationReportText() -> String {
        optimizationReportText(DSPyOptimizer.shared.report())
    }

    private static func optimizationReportText(_ report: OptimizationReport) -> String {
        guard report.totalRatings > 0 || !report.activeOptimizations.isEmpty else {
            return "No optimization data yet. Rate Alfred's outputs and the weekly compile pass will start learning from them."
        }

        var lines: [String] = []
        if report.weekDelta > 0.05 {
            lines.append(String(format: "Average rating: %.1f stars (up %.1f week over week)",
                                report.averageRating, report.weekDelta))
        } else if report.weekDelta < -0.05 {
            lines.append(String(format: "Average rating: %.1f stars (down %.1f week over week)",
                                report.averageRating, abs(report.weekDelta)))
        } else {
            lines.append(String(format: "Average rating: %.1f stars (holding steady)",
                                report.averageRating))
        }

        for score in report.perKind {
            if score.previous > 0 {
                lines.append("- \(score.displayName): \(String(format: "%.1f", score.previous)) → \(String(format: "%.1f", score.current)) (\(score.samples) rated)")
            } else {
                lines.append("- \(score.displayName): \(String(format: "%.1f", score.current)) (\(score.samples) rated)")
            }
        }

        if !report.activeOptimizations.isEmpty {
            lines.append("Active learned rules:")
            for rule in report.activeOptimizations {
                lines.append("- \(rule)")
            }
        }

        if let lastRun = report.lastRun {
            let outcome = lastRun.rolledBack ? "rolled back" : (lastRun.applied ? "applied" : "skipped")
            lines.append("Last compile: \(lastRun.kind) v\(lastRun.version) \(outcome), \(lastRun.examples) example\(lastRun.examples == 1 ? "" : "s")")
        }
        return lines.joined(separator: "\n")
    }

    /// ComputerControlCapability is main-actor isolated (it drives AX and posts
    /// CGEvents), so planning and execution both run there rather than hopping
    /// per call.
    @MainActor
    private static func runComputerControl(script: String) async throws -> String {
        // Computer control is always enabled — the user chose that when they
        // installed Alfred. Real safety lives in `planFromActionScript` below:
        // it throws on destructive requests and on attempts to type secrets.
        //
        // confirmControl below CANNOT be relied on — see the comment there — so
        // the capability's own guards carry the weight here.
        let control = ComputerControlCapability()

        // `planFromActionScript` applies the capability's own guards — it throws
        // on destructive requests and on attempts to type secrets — so asking to
        // click/type runs straight through, like a send. What carries the safety
        // weight now is that settings gate above (defaults OFF) plus these
        // checks; the user's explicit instruction is the permission.
        let plan = try control.planFromActionScript(script)

        let result = try await control.execute(plan)
        return "\(result)\n\nActions run:\n\(plan.summary)"
    }

    /// Human gate for the one class of action the user chose to keep confirming:
    /// deletes. An explicit request to send/message/edit/run is the permission;
    /// erasing something is not reversible, so calendar_delete and reminder_delete
    /// still stop in the bar. The broker fails closed on timeout or missing
    /// delegate by the same deny-by-default design.
    @MainActor
    private static func confirmUserAction(summary: String) async -> Bool {
        await ControlConfirmationBroker.shared.confirm(summary: summary)
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
