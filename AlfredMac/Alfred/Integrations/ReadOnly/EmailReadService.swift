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

    /// All recent unread inbox messages (no query filter) — backs "summarize my emails".
    /// Unlike `performSearch`, this launches Mail via `tell` if it isn't running, so it works
    /// from a headless routine. Throws on AppleScript/permission failure so the caller can react.
    func fetchRecentUnread(limit: Int = 20, includeBody: Bool = false) async throws -> [IntegrationSearchResult] {
        // Robust script: filter only by read status (the compound `where (date … and …)` whose-clause
        // is buggy/slow and the old version also carried a stray backslash that mangled it). `limit`
        // doubles as the AppleScript cap (callers pass a large value to baseline the whole backlog).
        // When includeBody, each message's content is fetched, truncated, and stripped of
        // tabs/newlines so the tab/linefeed-delimited parse stays deterministic — wrapped in its own
        // `try` so a body-fetch failure degrades to an empty body, never breaking the whole fetch.
        let bodyClause = includeBody ? """
                    set bodyText to ""
                    try
                        set rawBody to content of msg
                        if (count of rawBody) > 600 then set rawBody to text 1 thru 600 of rawBody
                        set AppleScript's text item delimiters to {return, linefeed, tab}
                        set bodyParts to text items of rawBody
                        set AppleScript's text item delimiters to " "
                        set bodyText to bodyParts as text
                        set AppleScript's text item delimiters to ""
                    end try
        """ : "                    set bodyText to \"\""
        let scriptSource = """
        tell application "Mail"
            set out to ""
            set unreadMsgs to (messages of inbox whose read status is false)
            set n to (count of unreadMsgs)
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                try
                    set msg to item i of unreadMsgs
        \(bodyClause)
                    set out to out & (subject of msg) & tab & (sender of msg) & tab & ((date received of msg) as string) & tab & bodyText & linefeed
                end try
            end repeat
            return out
        end tell
        """
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else {
            throw IntegrationError.underlying(NSError(domain: "com.alfred.email", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compile AppleScript"]))
        }
        let output = script.executeAndReturnError(&errorDict)
        if let error = errorDict {
            throw IntegrationError.underlying(NSError(domain: "com.alfred.email", code: -2,
                userInfo: error as? [String: Any]))
        }
        let lines = output.stringValue?.split(separator: "\n").map(String.init) ?? []
        return lines.prefix(limit).map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let subject = parts.count > 0 && !parts[0].isEmpty ? parts[0] : "(no subject)"
            let sender = parts.count > 1 ? parts[1] : "Unknown"
            let dateStr = parts.count > 2 ? parts[2] : ""
            let body = parts.count > 3 ? parts[3] : ""
            var metadata = ["subject": subject, "sender": sender, "date": dateStr]
            if !body.isEmpty { metadata["body"] = body }
            return IntegrationSearchResult(
                title: subject, subtitle: sender, source: "Email", icon: "envelope",
                metadata: metadata
            )
        }
    }
}
