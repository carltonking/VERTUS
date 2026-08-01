import Foundation
import OSLog

// MARK: - Email read service

final class EmailReadService: ReadOnlyIntegrationProtocol {
    let actionType: ActionType = .queryMemory

    func performSearch(query: String) async throws -> [IntegrationSearchResult] {
        guard query.count >= 2 else { throw IntegrationError.queryTooShort }

        let scriptSource = """
        tell application "System Events"
            set isRunning to (name of processes) contains "Mail"
        end tell
        if not isRunning then
            return ""
        end if
        tell application "Mail"
            set recentMessages to messages of inbox where \\(date received > ((current date) - 24 * hours) and read status is false)
            set outputLines to {}
            repeat with msg in recentMessages
                set subj to subject of msg
                set sndr to sender of msg
                set msgDate to date received of msg
                set acct to (name of account of mailbox of msg)
                set end of outputLines to subj & tab & sndr & tab & (msgDate as text) & tab & acct
            end repeat
            return outputLines
        end tell
        """

        var errorDict: NSDictionary? = nil
        guard let script = NSAppleScript(source: scriptSource) else {
            throw IntegrationError.underlying(NSError(domain: "com.alfred.email", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to compile AppleScript"]))
        }

        let output = script.executeAndReturnError(&errorDict)
        if let error = errorDict {
            throw IntegrationError.underlying(NSError(domain: "com.alfred.email", code: -2, userInfo: error as? [String: Any]))
        }

        guard output.descriptorType != typeNull, output.stringValue != nil else {
            throw IntegrationError.noResults
        }

        let lines = output.stringValue?
            .split(separator: "\n")
            .map(String.init) ?? []

        guard !lines.isEmpty else { throw IntegrationError.noResults }

        let matched = lines.filter { line in
            line.localizedCaseInsensitiveContains(query)
        }

        guard !matched.isEmpty else { throw IntegrationError.noResults }

        return matched.prefix(20).map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let subject = parts.count > 0 ? parts[0] : "Unknown"
            let sender = parts.count > 1 ? parts[1] : "Unknown"
            let dateStr = parts.count > 2 ? parts[2] : ""
            let account = parts.count > 3 ? parts[3] : "Unknown"
            return IntegrationSearchResult(
                title: subject,
                subtitle: sender,
                source: "Email",
                icon: "envelope",
                metadata: [
                    "subject": subject,
                    "sender": sender,
                    "date": dateStr,
                    "account": account
                ]
            )
        }
    }

    /// All recent unread inbox messages (no query filter) — backs "summarize my emails" and the
    /// inbound watcher.
    ///
    /// Reads Mail's local **Envelope Index** SQLite database directly (read-only) instead of scripting
    /// Mail.app. A `tell application "Mail"` AUTO-LAUNCHES Mail; this never does — Alfred reads mail
    /// headlessly whether or not Mail is open. Requires Full Disk Access, which Alfred already relies
    /// on (it reads the Messages `chat.db` the same way). `includeBody` is accepted for source
    /// compatibility but ignored: the Envelope Index carries no message body, and triage/notifications
    /// key off the subject anyway. Never throws for the common cases (DB missing / unreadable → []).
    func fetchRecentUnread(limit: Int = 20, includeBody: Bool = false) async throws -> [IntegrationSearchResult] {
        guard let db = Self.envelopeIndexPath() else { return [] }
        // addresses.comment = display name, addresses.address = email. date_received is Unix epoch
        // seconds (no 2001 offset in V10+). Restrict to INBOX so Sent/Junk/Trash/All-Mail are excluded.
        let sql = """
        SELECT s.subject, a.comment, a.address, m.date_received
        FROM messages m
        JOIN mailboxes mb ON m.mailbox = mb.ROWID
        LEFT JOIN subjects s ON m.subject = s.ROWID
        LEFT JOIN addresses a ON m.sender = a.ROWID
        WHERE m.read = 0 AND m.deleted = 0 AND UPPER(mb.url) LIKE '%INBOX%'
        ORDER BY m.date_received DESC
        LIMIT \(max(1, limit));
        """
        let rows = Self.runSqlite(dbPath: db, sql: sql)
        return rows.compactMap { f in
            guard f.count >= 4 else { return nil }
            let subject = f[0].isEmpty ? "(no subject)" : f[0]
            let name = f[1], address = f[2], date = f[3]
            let sender = name.isEmpty ? address : "\(name) <\(address)>"
            return IntegrationSearchResult(
                title: subject, subtitle: sender, source: "Email", icon: "envelope",
                metadata: ["subject": subject, "sender": sender, "date": date])
        }
    }

    /// Locates the Mail Envelope Index, picking the highest `V<n>` container (V9/V10/V11 vary by
    /// macOS release). Returns nil if Mail data isn't present.
    private static func envelopeIndexPath() -> String? {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mail")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        let versions = entries
            .filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
            .sorted { (Int($0.dropFirst()) ?? 0) > (Int($1.dropFirst()) ?? 0) }
        for v in versions {
            let path = "\(base)/\(v)/MailData/Envelope Index"
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a read-only query against the Envelope Index out-of-process via `/usr/bin/sqlite3` (no
    /// SQLite C linking needed). Fields are split on US (0x1F) and rows on RS (0x1E) so a subject that
    /// contains a newline can't corrupt the row split. `immutable=1` guarantees we never take a lock
    /// or hit SQLITE_BUSY while Mail is actively writing. Returns [] on any failure.
    private static func runSqlite(dbPath: String, sql: String) -> [[String]] {
        let fs = "\u{1F}", rs = "\u{1E}"
        let uri = "file:" + dbPath.replacingOccurrences(of: " ", with: "%20") + "?immutable=1"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = ["-readonly", "-separator", fs, "-newline", rs, uri, sql]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice   // discard (undrained stderr pipe could deadlock)
        do { try proc.run() } catch { return [] }
        // Watchdog: a wedged sqlite3 can't hang the caller; closing the pipe unblocks the read.
        let watchdog = DispatchWorkItem { proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        return text.components(separatedBy: rs)
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: fs) }
    }
}
