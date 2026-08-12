import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro, invisible to Swift; the destructor type is.
// -1 tells SQLite to copy the string before the statement is finalized.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Reads and sends iMessage and SMS through the system Messages database.
///
/// iMessage lives in `~/Library/Messages/chat.db`, which only a macOS app with
/// Full Disk Access can read — the reason the cloud can't do this, and the phone
/// can't. Every method here is a short SQLite read, plus one osascript for
/// sending. No long-lived connection: the database is Apple's, so each call
/// re-opens and reads fresh rather than caching.
///
/// Output is JSON, because the relay that carries these answers to the phone is
/// a dumb string pipe — structured data has to survive the trip as text.
struct MessagesCapability {

    static let shared = MessagesCapability()

    private let databasePath = "\(NSHomeDirectory())/Library/Messages/chat.db"

    // MARK: - Commands (all return JSON strings)

    /// `alfred:messages:list` — every conversation, newest first.
    func listConversations() -> String {
        guard let db = openReadOnly() else {
            return jsonError("Alfred can't read your messages. Grant it Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then reopen Alfred.")
        }

        let sql = """
            SELECT c.guid, c.chat_identifier, c.display_name,
                   (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) > 1 AS is_group,
                   (SELECT COUNT(*) FROM message m2
                     JOIN chat_message_join cmj2 ON cmj2.message_id = m2.ROWID
                    WHERE cmj2.chat_id = c.ROWID AND m2.is_from_me = 0 AND m2.is_read = 0) AS unread,
                   m.text, m.date, m.is_from_me
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.message_date = (SELECT MAX(message_date) FROM chat_message_join WHERE chat_id = c.ROWID)
            ORDER BY m.date DESC
        """

        var rows: [[String: Any]] = []
        let ok = query(db, sql: sql) { stmt in
            let guid = textColumn(stmt, 0)
            let identifier = textColumn(stmt, 1)
            let displayName = textColumn(stmt, 2)
            let isGroup = intColumn(stmt, 3) != 0
            let unread = intColumn(stmt, 4)
            let lastText = textColumn(stmt, 5)
            let dateNs = doubleColumn(stmt, 6)
            let lastFromMe = intColumn(stmt, 7) != 0

            var json: [String: Any] = [
                "guid": guid,
                "identifier": identifier,
                "isGroup": isGroup,
                "unread": unread,
                "lastText": lastText,
                "lastDateMs": dateMs(fromNs: dateNs),
                "lastFromMe": lastFromMe,
            ]
            if isGroup, !displayName.isEmpty {
                json["name"] = displayName
            }
            rows.append(json)
        }
        sqlite3_close(db)

        guard ok else {
            return jsonError("Couldn't read the Messages database. Try again in a moment.")
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["ok": true, "conversations": rows]),
              let string = String(data: payload, encoding: .utf8)
        else {
            return jsonError("Couldn't package your conversations.")
        }
        return string
    }

    /// `alfred:messages:thread {"guid": "..."}` — every message in one conversation.
    func threadMessages(guid: String) -> String {
        guard let db = openReadOnly() else {
            return jsonError("Alfred can't read your messages. Grant it Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then reopen Alfred.")
        }

        let sql = """
            SELECT m.guid, m.text, m.date, m.is_from_me,
                   (SELECT a.transfer_name
                      FROM message_attachment_join maj
                      JOIN attachment a ON a.ROWID = maj.attachment_id
                     WHERE maj.message_id = m.ROWID
                     ORDER BY a.ROWID LIMIT 1) AS attachment
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = (SELECT ROWID FROM chat WHERE guid = ?)
            ORDER BY m.date ASC
        """

        var rows: [[String: Any]] = []
        let ok = query(db, sql: sql, args: [guid]) { stmt in
            let text = textColumn(stmt, 0)
            let body = textColumn(stmt, 1)
            let dateNs = doubleColumn(stmt, 2)
            let fromMe = intColumn(stmt, 3) != 0
            let attachment = textColumn(stmt, 4)

            var json: [String: Any] = [
                "guid": text,
                "text": body,
                "dateMs": dateMs(fromNs: dateNs),
                "fromMe": fromMe,
            ]
            if !attachment.isEmpty {
                json["attachment"] = attachment
            }
            rows.append(json)
        }
        sqlite3_close(db)

        guard ok else {
            return jsonError("Couldn't read that conversation. Try again in a moment.")
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": rows]),
              let string = String(data: payload, encoding: .utf8)
        else {
            return jsonError("Couldn't package that conversation.")
        }
        return string
    }

    /// `alfred:messages:send {"guid": "...", "text": "..."}` — send through the
    /// Messages app, which carries iMessage and SMS routing.
    func sendMessage(guid: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return jsonError("Nothing to send.") }

        let script = """
        tell application "Messages"
            send "\(escapedForAppleScript(trimmed))" to chat id "\(escapedForAppleScript(guid))"
        end tell
        """
        do {
            try runAppleScript(script)
            return "{\"ok\":true}"
        } catch let error as ScriptError {
            return jsonError(error.message)
        } catch {
            return jsonError("Couldn't send. Check that Messages is signed in and that Alfred can control it (System Settings → Privacy & Security → Automation).")
        }
    }

    /// `alfred:messages:sendTo {"participant": "...", "text": "..."}` — send to a
    /// phone number or Apple ID that isn't necessarily in an existing thread.
    /// Messages creates a new conversation. Notes the Numbers of rules: the
    /// recipient value must be a plain handle — either a phone number (`+1555…`)
    /// or an Apple ID email — as a bare `text` argument resolves to list/thread
    /// not send. Since AppleScript's `buddy` form takes a bare handle, the
    /// participant argument is passed straight through after escaping.
    func sendToParticipant(participant: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return jsonError("Nothing to send.") }
        let who = participant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { return jsonError("No recipient given.") }

        let script = """
        tell application "Messages"
            send "\(escapedForAppleScript(trimmed))" to buddy "\(escapedForAppleScript(who))"
        end tell
        """
        do {
            try runAppleScript(script)
            return "{\"ok\":true}"
        } catch let error as ScriptError {
            return jsonError(error.message)
        } catch {
            return jsonError("Couldn't send. Check that Messages is signed in and that Alfred can control it (System Settings → Privacy & Security → Automation).")
        }
    }

    // MARK: - SQLite plumbing

    private func openReadOnly() -> OpaquePointer? {
        var db: OpaquePointer?
        // SQLITE_OPEN_READONLY — this capability must never write to Apple's
        // database. Readonly opens fail cleanly instead of scribbling.
        let rc = sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else { return nil }
        return db
    }

    private func query(
        _ db: OpaquePointer,
        sql: String,
        args: [String] = [],
        row: (OpaquePointer) -> Void
    ) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        for (index, arg) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), arg, -1, SQLITE_TRANSIENT)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
        }
        return true
    }

    private func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    private func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    /// iMessage stores timestamps in nanoseconds since 2001-01-01.
    private func dateMs(fromNs ns: Double) -> Int64 {
        guard ns > 0 else { return 0 }
        return Int64((ns / 1_000_000_000 + 978_307_200) * 1_000)
    }

    // MARK: - AppleScript

    private enum ScriptError: LocalizedError {
        case failed(String)
        var message: String {
            switch self {
            case .failed(let m): return m
            }
        }
    }

    /// Run osascript. Automation permission lives with the script host: if Alfred
    /// has not been approved to control Messages, osascript exits non-zero with
    /// "not authorized" and the user needs System Settings → Automation.
    private func runAppleScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ScriptError.failed("Couldn't launch osascript: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScriptError.failed(message.isEmpty ? "osascript exited \(process.terminationStatus)" : message)
        }
    }

    private func escapedForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func jsonError(_ message: String) -> String {
        // JSONSerialization would do this, but an error string is also the one
        // place where quoting can't be skipped — keep it minimal and correct.
        let quoted = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"ok\":false,\"error\":\"\(quoted)\"}"
    }
}
