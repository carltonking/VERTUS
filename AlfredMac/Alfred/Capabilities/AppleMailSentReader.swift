import AppKit
import Foundation

/// Reads recent SENT messages out of Apple Mail (iCloud + any non-Gmail IMAP accounts) for voice
/// learning. Gmail accounts are skipped here — they're covered by the Gmail API path (Step 3b) — so
/// the two paths don't double-import. Mail's `content of message` is already-decoded plain text, so
/// no MIME parsing is needed. Reuses MailComposeCapability's Automation-for-Mail permission.
///
/// The bulk read can take seconds, so it's run out-of-process via `osascript` (never inline
/// NSAppleScript on the main thread), and only when Mail is already running — we never launch it.
enum AppleMailSentReader {

    /// Output delimiters: unit separator between fields, record separator between messages.
    static let unitSep = "\u{1F}"   // U+001F
    static let recordSep = "\u{1E}" // U+001E

    struct Record: Equatable {
        let accountEmail: String
        let id: String   // RFC Message-ID
        let body: String
    }

    // MARK: - Pure helpers (unit-tested)

    /// Parses the delimited osascript output into records, skipping malformed ones (wrong field
    /// count or empty message id). Body may contain newlines — only the control-char delimiters split.
    static func parse(_ output: String) -> [Record] {
        output.split(separator: recordSep, omittingEmptySubsequences: true)
            .compactMap { rec -> Record? in
                let fields = String(rec).components(separatedBy: unitSep)
                guard fields.count == 3 else { return nil }
                let id = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return nil }
                return Record(accountEmail: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                              id: id, body: fields[2])
            }
    }

    /// Gmail accounts are handled by the Gmail API path — skip them here to avoid double-importing.
    static func isGmailAccount(email: String) -> Bool {
        let e = email.lowercased()
        return e.contains("@gmail.com") || e.contains("@googlemail.com")
    }

    /// Records whose message id hasn't been imported before (the de-dup guarantee).
    static func filterUnseen(_ records: [Record], seen: Set<String>) -> [Record] {
        records.filter { !seen.contains($0.id) }
    }

    // MARK: - Environment

    /// True only when Mail is already running — we never launch it (a `tell application "Mail"` would).
    static func isMailRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
    }

    // MARK: - Live read (not unit-tested)

    /// Runs the sent-mail AppleScript via `osascript` and returns its raw delimited output, or nil on
    /// any failure (Automation denied, Mail not scriptable, timeout). Caller runs this off-main.
    static func readSent(limitPerAccount: Int) -> String? {
        runOsascript(buildScript(limitPerAccount: max(1, limitPerAccount)))
    }

    static func buildScript(limitPerAccount: Int) -> String {
        """
        set recSep to (character id 30)
        set unitSep to (character id 31)
        set out to ""
        tell application "Mail"
            repeat with acct in accounts
                set acctEmail to ""
                set isGmail to false
                try
                    repeat with a in (email addresses of acct)
                        set aStr to (a as text)
                        if acctEmail is "" then set acctEmail to aStr
                        if (aStr contains "@gmail.com") or (aStr contains "@googlemail.com") then set isGmail to true
                    end repeat
                end try
                -- Skip Gmail (covered by the Gmail API path) and accounts with no resolvable address
                -- (can't verify they aren't Gmail → safer to under-import).
                if (acctEmail is not "") and (not isGmail) then
                    try
                        repeat with mb in (mailboxes of acct)
                            set mbName to (name of mb)
                            -- Exact names only (case-insensitive in AppleScript) so "Resent"/"Consent"
                            -- folders aren't harvested. Localized Sent folders would be added here.
                            if (mbName is "Sent") or (mbName is "Sent Messages") or (mbName is "Sent Items") then
                                set msgs to messages of mb
                                set n to (count of msgs)
                                if n > \(limitPerAccount) then set n to \(limitPerAccount)
                                repeat with i from 1 to n
                                    try
                                        set m to item i of msgs
                                        set out to out & acctEmail & unitSep & (message id of m) & unitSep & (content of m) & recSep
                                    end try
                                end repeat
                            end if
                        end repeat
                    end try
                end if
            end repeat
        end tell
        return out
        """
    }

    private static func runOsascript(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-"]   // read the script from stdin
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice   // discard (undrained stderr pipe could deadlock)

        do {
            try proc.run()
        } catch {
            return nil
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        stdin.fileHandleForWriting.closeFile()

        // Watchdog: terminate if Mail hangs faulting bodies; closing the pipe unblocks the read.
        let watchdog = DispatchWorkItem { proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else { return nil }   // non-zero ⇒ Automation denied / error
        return String(data: data, encoding: .utf8)
    }
}
