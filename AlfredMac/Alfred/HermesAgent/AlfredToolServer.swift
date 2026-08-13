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
            let message = try EmailCapability.shared.readMessage(
                id: id, account: "icloud", mailbox: "Inbox")
            PersonalMemoryStore.shared.recordObservation(
                source: "email",
                text: message,
                app: "Mail")
            return message

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
            return ToolHandlers.handleHabitPredict(request).text

        case "timer_set":
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

        default:
            throw ToolError.unknown(tool)
        }
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
