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
    func fetchRecentUnread(limit: Int = 20) async throws -> [IntegrationSearchResult] {
        let scriptSource = """
        tell application "Mail"
            set recentMessages to messages of inbox where \\(date received > ((current date) - 24 * hours) and read status is false)
            set outputLines to {}
            repeat with msg in recentMessages
                set subj to subject of msg
                set sndr to sender of msg
                set msgDate to date received of msg
                set end of outputLines to subj & tab & sndr & tab & (msgDate as text)
            end repeat
            return outputLines
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
            return IntegrationSearchResult(
                title: subject, subtitle: sender, source: "Email", icon: "envelope",
                metadata: ["subject": subject, "sender": sender, "date": dateStr]
            )
        }
    }
}
