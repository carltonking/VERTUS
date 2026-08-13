import Foundation

/// Reads and sends email through Himalaya (IMAP/SMTP backend configured in
/// `~/.config/himalaya/config.toml`, passwords in the login Keychain).
///
/// Alfred chooses Himalaya as its mail backend deliberately:
///
///   * Credentials never leave the machine — the app talks to `himalaya`
///     locally and never sees a password; the Keychain supplies it at connect
///     time and nothing passes through the cloud.
///   * One configuration drives the CLI and the app, so an account added once
///     works in both without turning Alfred into a second email client to
///     maintain.
///
/// Every method here is a discrete `himalaya` subprocess: the app inherits no
/// long-lived connection, and a hung server can't wedge Alfred — the worst case
/// is one timed-out child. Output is emitted as compact text for the model, not
/// himalaya's default header dump.
struct EmailCapability: Sendable {

    static let shared = EmailCapability()

    private static let defaultAccount = "icloud"

    // MARK: - Binary resolution

    /// Locate `himalaya`. A GUI app launched by Finder inherits a minimal PATH,
    /// so known homebrew locations are tried before asking a login shell.
    private let binary: String

    init() {
        let home = NSHomeDirectory()
        let candidates = [                "/opt/homebrew/bin/himalaya",
                "/usr/local/bin/himalaya",
                "\(home)/.local/bin/himalaya",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            binary = path
            return
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v himalaya"]
        let out = Pipe()
        which.standardOutput = out
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                binary = path
                return
            }
        } catch { /* fall through */ }
        binary = "himalaya"
    }

    // MARK: - List

    /// One message as an envelope: enough to list the inbox or watch it without
    /// having to read bodies. `id` is the same id `readMessage` and `sendMessage`
    /// take, so enclosures found here can be read or replied to directly.
    struct MailEnvelope {
        let id: String
        let fromName: String?
        let fromEmail: String
        let subject: String?
        let date: Date?
        let isUnread: Bool
        let isFlagged: Bool
    }

    /// The most recent messages in a mailbox, as structured envelopes. Cheaper
    /// than reading every body, and the shape the mail watcher compares against
    /// to decide what's new.
    func latestEnvelopes(account: String, mailbox: String, limit: Int) throws -> [MailEnvelope] {
        let output = try run([
            "--account", account,
            "envelope", "list",
            "-m", mailbox,
            "-s", "\(min(max(limit, 1), 200))",
            "--json",
        ])
        let data = output.data(using: .utf8) ?? Data()
        let envelopes = try JSONDecoder().decode(EnvelopeList.self, from: data).envelopes
        let date = ISO8601DateFormatter()
        return envelopes.map { env in
            MailEnvelope(
                id: env.id,
                fromName: env.from?.first?.name,
                fromEmail: env.from?.first?.email ?? "?",
                subject: env.subject,
                date: env.date.flatMap { date.date(from: $0) },
                isUnread: !env.flags.contains { $0.raw.lowercased().contains("seen") },
                isFlagged: env.flags.contains { $0.raw.lowercased().contains("flagged") }
            )
        }
    }

    /// The most recent messages in a mailbox, as compact lines the model can
    /// cite a sender from ("respond to alice" → the address in FROM).
    func listMessages(account: String, mailbox: String, limit: Int) throws -> String {
        let envelopes = try latestEnvelopes(account: account, mailbox: mailbox, limit: limit)
        guard !envelopes.isEmpty else {
            return "\(mailbox) is empty (or the mailbox alias doesn't resolve)."
        }

        return envelopes.enumerated().map { index, env in
            let when = env.date.map { Self.twelveHour($0) } ?? "?"
            let flags = env.isUnread ? " [unread]" : ""
            let label = env.fromName.map { "\($0) <\(env.fromEmail)>" } ?? env.fromEmail
            return "\(index + 1). \(env.id) — \(label) → \(when) — \(env.subject ?? "(no subject)")\(flags)"
        }.joined(separator: "\n")
    }

    // MARK: - Read

    /// A full message as text: headers the model actually needs + body text.
    func readMessage(id: String, account: String, mailbox: String) throws -> String {
        let args = [
            "--account", account,
            "message", "read",
            id,
            "-m", mailbox,
            "--json",
        ]
        let output = try run(args)

        guard let root = try? JSONSerialization.jsonObject(with: output.data(using: .utf8) ?? Data()) as? [String: Any] else {
            return output
        }

        let headers = Self.headers(of: root)
        let subject = Self.header(headers, named: "subject") ?? "(no subject)"
        let from = Self.header(headers, named: "from") ?? "?"
        let to = Self.header(headers, named: "to") ?? ""
        let date = Self.header(headers, named: "date") ?? "?"
        let messageID = Self.header(headers, named: "message_id") ?? ""

        let body = Self.textBody(in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentCount = (root["attachments"] as? [[String: Any]])?.count ?? 0

        var lines = ["From: \(from)", "Date: \(date)", "Subject: \(subject)"]
        if !to.isEmpty { lines.append("To: \(to)") }
        if !messageID.isEmpty { lines.append("Message-ID: \(messageID)") }
        if !body.isEmpty { lines.append("") ; lines.append(body) }
        if attachmentCount > 0 { lines.append("") ; lines.append("[\(attachmentCount) attachment(s)]") }

        return lines.joined(separator: "\n")
    }

    // MARK: - Mailboxes

    /// One mailbox as Himalaya lists it — the id/name are the values `envelope
    /// list -m` and `message move --from/--to` address mailboxes by.
    struct MailboxInfo {
        let id: String
        let name: String
        let total: Int
        let unread: Int
    }

    /// Every mailbox on the account, with counts. `--counts` makes IMAP issue
    /// one STATUS per mailbox, so this is the slow call — the MailManager caches
    /// the result rather than re-listing on every inbox refresh.
    func mailboxes(account: String) throws -> [MailboxInfo] {
        let output = try run(["--account", account, "mailbox", "list", "--counts", "--json"])
        guard let root = try? JSONSerialization.jsonObject(with: output.data(using: .utf8) ?? Data()) as? [String: Any],
              let raw = root["mailboxes"] as? [[String: Any]]
        else { return [] }
        return raw.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            return MailboxInfo(
                id: id,
                name: dict["name"] as? String ?? id,
                total: dict["total"] as? Int ?? 0,
                unread: dict["unread"] as? Int ?? 0)
        }
    }

    // MARK: - Flags

    /// Mark a message seen/unseen and flagged/unflagged. Each flag is applied
    /// with the minimal `flag add`/`flag remove` call (setting a flag already
    /// present is a no-op on the server, so computing the delta is pointless
    /// round-trips — just ask for the state you want).
    func setFlags(account: String, mailbox: String, messageID: String,
                  seen: Bool?, flagged: Bool?) throws {
        if let seen {
            _ = try run(["--account", account, "flag", seen ? "add" : "remove",
                         "-m", mailbox, "-f", "seen", messageID])
        }
        if let flagged {
            _ = try run(["--account", account, "flag", flagged ? "add" : "remove",
                         "-m", mailbox, "-f", "flagged", messageID])
        }
    }

    // MARK: - Move

    /// Move a message between mailboxes (IMAP `UID MOVE`). Archive and Trash
    /// are both just moves to the account's archive/trash mailbox.
    func moveMessage(account: String, fromMailbox: String, toMailbox: String,
                     messageID: String) throws {
        _ = try run(["--account", account, "message", "move",
                     "-f", fromMailbox, "-t", toMailbox, messageID])
    }

    // MARK: - Structured read

    /// A full message broken out the way a mail client needs it — header
    /// strings, plain-text and HTML bodies, and the attachment envelope. The
    /// HTML is returned raw for the reader to render; the text is what search
    /// and quoting use.
    struct MessageParts {
        let from: String
        let fromAddress: String
        let to: [String]
        let cc: [String]
        let subject: String
        let date: Date?
        let messageID: String
        let text: String
        let html: String?
        let attachments: [AttachmentInfo]

        struct AttachmentInfo {
            let id: String
            let filename: String
            let mime: String
            let size: Int
        }
    }

    func readMessageParts(id: String, account: String, mailbox: String) throws -> MessageParts {
        let output = try run(["--account", account, "message", "read", id, "-m", mailbox, "--json"])
        let data = output.data(using: .utf8) ?? Data()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Alfred.Email", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't parse the message."])
        }

        let headers = Self.headers(of: root)
        let subject = Self.header(headers, named: "subject") ?? "(no subject)"
        let fromRaw = Self.header(headers, named: "from") ?? "?"
        let from = Self.addressParts(fromRaw).name
        let fromAddress = Self.addressParts(fromRaw).email
        let to = Self.addressList(Self.header(headers, named: "to") ?? "")
        let cc = Self.addressList(Self.header(headers, named: "cc") ?? "")
        // The date is parsed straight from the header value, not through
        // `header(named:)` — that helper formats dates for display, which would
        // hand us "Aug 12, 6:30 PM" instead of something parseable.
        let date = Self.dateHeader(headers) ?? Self.parseDate(Self.header(headers, named: "date") ?? "")
        let messageID = Self.header(headers, named: "message_id") ?? ""

        var plain: [String] = []
        var html: [String] = []
        Self.collectBodies(in: root, plain: &plain, html: &html)

        let attachments = (root["attachments"] as? [[String: Any]] ?? []).enumerated().compactMap { index, dict in
            let filename = (dict["filename"] as? String)
                ?? (dict["name"] as? String)
                ?? (dict["part_id"] as? String)
                ?? "attachment-\(index + 1)"
            return MessageParts.AttachmentInfo(
                id: dict["id"] as? String ?? dict["part_id"] as? String ?? String(index + 1),
                filename: filename,
                mime: dict["mime_type"] as? String ?? dict["mime"] as? String ?? dict["type"] as? String ?? "application/octet-stream",
                size: dict["size"] as? Int ?? 0)
        }

        return MessageParts(
            from: from,
            fromAddress: fromAddress,
            to: to,
            cc: cc,
            subject: subject,
            date: date,
            messageID: messageID,
            text: plain.joined(separator: "\n\n"),
            html: html.first,
            attachments: attachments)
    }

    // MARK: - Address helpers

    /// "Name <email>" (or a bare address) split into display name + address.
    private static func addressParts(_ raw: String) -> (name: String, email: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed.lastIndex(of: ">"),
           open < close {
            let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            let email = String(trimmed[trimmed.index(after: open)..<close])
            return (name, email)
        }
        return ("", trimmed)
    }

    /// "A <a@x>, B <b@y>" → ["A <a@x>", "B <b@y>"].
    private static func addressList(_ raw: String) -> [String] {
        raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private static func parseDate(_ raw: String) -> Date? {
        // mail-parser date fields can arrive as a components dict (handled by
        // dateHeader) or as a plain RFC 2822 string — try both spellings.
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = rfc.date(from: raw) { return date }
        let iso = ISO8601DateFormatter()
        return iso.date(from: raw)
    }

    /// The message date parsed straight from the raw header value, handling the
    /// three shapes mail-parser emits: a plain RFC 2822 string, `{Text: …}`, and
    /// `{DateTime: {components}}`.
    private static func dateHeader(_ headers: [[String: Any]]) -> Date? {
        guard let match = headers.first(where: { (($0["name"] as? String) ?? "").lowercased() == "date" }),
              let value = match["value"] else { return nil }
        if let text = value as? String { return parseDate(text) }
        guard let dict = value as? [String: Any] else { return nil }
        if let text = dict["Text"] as? String { return parseDate(text) }
        if let dt = dict["DateTime"] as? [String: Any] {
            let year = dt["year"] as? Int ?? 0
            guard year > 0 else { return nil }
            var components = DateComponents()
            components.year = year
            components.month = dt["month"] as? Int
            components.day = dt["day"] as? Int
            components.hour = dt["hour"] as? Int
            components.minute = dt["minute"] as? Int
            components.second = dt["second"] as? Int
            components.timeZone = TimeZone(identifier: "GMT")
            return Calendar(identifier: .gregorian).date(from: components)
        }
        return nil
    }

    // MARK: - Send

    /// Send a plain-text message and save a copy to the Sent mailbox.
    func sendMessage(to: String, cc: String?, subject: String, body: String,
                     inReplyTo: String?, account: String) throws -> String {
        let raw = rawMessage(to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo)
        _ = try run(["--account", account, "message", "send", "--save", "sent"], stdin: raw)
        return "Message sent to \(to)."
    }

    /// Save a plain-text message to the account's Drafts mailbox without
    /// sending it (himalaya's `message send --save drafts`). Same RFC 5322
    /// builder as send — the only difference is the save target.
    func saveDraft(to: String, cc: String?, subject: String, body: String,
                   inReplyTo: String?, account: String) throws -> String {
        let raw = rawMessage(to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo)
        _ = try run(["--account", account, "message", "send", "--save", "drafts"], stdin: raw)
        return "Draft saved to the \(account) Drafts mailbox."
    }

    /// Build an RFC 5322 message himalaya's `message send` can forward on
    /// stdin. The body leaves SWIFT as base64 so foreign characters survive any
    /// ASCII-only SMTP hop.
    private func rawMessage(to: String, cc: String?, subject: String, body: String,
                            inReplyTo: String?) -> Data {
        let date = Self.rfc2822Date
        let id = "<\(UUID().uuidString)@alfred.local>"

        let encoded = Data(body.utf8).base64EncodedString()
        let wrapped = stride(from: 0, to: encoded.count, by: 76)
            .map { start in String(encoded.dropFirst(start).prefix(76)) }
            .joined(separator: "\r\n")

        var headers = [
            "From: Carlton King <carltoniking@icloud.com>",
            "To: \(to)",
            "Subject: \(subject)",
            "Date: \(date)",
            "Message-ID: \(id)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "X-Alfred: generated",
        ]
        if let cc, !cc.isEmpty { headers.append("Cc: \(cc)") }
        if let inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            headers.append("References: \(inReplyTo)")
        }

        return (headers.joined(separator: "\r\n") + "\r\n\r\n" + wrapped + "\r\n").data(using: .utf8) ?? Data()
    }

    // MARK: - Process plumbing

    private func run(_ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let input = stdin.map { _ in Pipe() }
        process.standardInput = input as Any?

        // Drain stdout and stderr as the child writes, on background queues that
        // return at EOF. Reading them only AFTER waitUntilExit would deadlock the
        // moment a message's JSON exceeds the 64 KiB pipe buffer: the child blocks
        // on write(), the parent waits forever, and iCloud sits half-open.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let outQueue = DispatchQueue(label: "com.alfred.himalaya.out")
        let errQueue = DispatchQueue(label: "com.alfred.himalaya.err")
        group.enter()
        outQueue.async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQueue.async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Environment is inherited: himalaya reads ~/.config/himalaya/config.toml,
        // which pulls passwords out of the Keychain at runtime.
        try process.run()

        if let input, let stdin {
            input.fileHandleForWriting.write(stdin)
            input.fileHandleForWriting.closeFile()
        }

        // Hard cap on the child. The doc above said "the worst case is one timed-
        // out child" — make that real: a wedged himalaya (half-open IMAP, an
        // unresponsive server) must fail this call, not hang the bar for minutes.
        var didTimeout = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                usleep(200_000)
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                didTimeout = true
                break
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        let outText = String(decoding: outData, as: UTF8.self)
        let errText = String(decoding: errData, as: UTF8.self)

        if didTimeout {
            throw NSError(
                domain: "Alfred.Email", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "himalaya timed out after \(Int(timeout))s and was stopped. iCloud IMAP was unresponsive — try again in a moment."])
        }

        guard process.terminationStatus == 0 else {
            let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? outText.trimmingCharacters(in: .whitespacesAndNewlines)
                : errText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "Alfred.Email", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "himalaya failed: \(detail)"])
        }
        return outText
    }

    // MARK: - JSON parsing

    private struct EnvelopeList: Decodable {
        struct Address: Decodable {
            let name: String?
            let email: String
        }
        struct Flag: Decodable {
            let raw: String
        }
        struct Envelope: Decodable {
            let id: String
            let subject: String?
            let flags: [Flag]
            let from: [Address]?
            let date: String?

            /// "Name <email>" when the sender gave a name, bare email otherwise.
            var fromLabel: String {
                guard let from, let first = from.first else { return "?" }
                if let name = first.name, !name.isEmpty {
                    return "\(name) <\(first.email)>"
                }
                return first.email
            }
        }
        let envelopes: [Envelope]
    }

    /// The message-wide headers from the mail-parser JSON. They live at the top
    /// level when present, otherwise on the first body part.
    private static func headers(of root: [String: Any]) -> [[String: Any]] {
        if let direct = root["headers"] as? [[String: Any]] { return direct }
        if let parts = root["parts"] as? [[String: Any]],
           let first = parts.first,
           let nested = first["headers"] as? [[String: Any]] {
            return nested
        }
        return []
    }

    private static func header(_ headers: [[String: Any]], named target: String) -> String? {
        guard let match = headers.first(where: { (($0["name"] as? String) ?? "").lowercased() == target }) else {
            return nil
        }
        guard let value = match["value"] else { return nil }
        if let text = value as? String { return text }
        guard let dict = value as? [String: Any] else { return nil }

        if let text = dict["Text"] as? String { return text }

        // mail-parser encodes address fields as {"Address": {"List": [...]}}.
        if let address = dict["Address"] as? [String: Any],
           let list = address["List"] as? [[String: Any]] {
            return list.map { a -> String in
                let email = a["address"] as? String ?? ""
                if let name = a["name"] as? String, !name.isEmpty {
                    return "\(name) <\(email)>"
                }
                return email
            }.joined(separator: ", ")
        }

        // Date fields arrive as a components dict rather than a string.
        if let dt = dict["DateTime"] as? [String: Any] {
            let year = dt["year"] as? Int ?? 0
            let month = dt["month"] as? Int ?? 0
            let day = dt["day"] as? Int ?? 0
            let hour = dt["hour"] as? Int ?? 0
            let minute = dt["minute"] as? Int ?? 0
            guard year > 0 else { return nil }
            var components = DateComponents()
            components.year = year; components.month = month; components.day = day
            components.hour = hour; components.minute = minute
            if let date = Calendar(identifier: .gregorian).date(from: components) {
                return Self.twelveHour(date)
            }
            return String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
        }
        return nil
    }

    /// Recurse the mail-parser JSON for any plain-text body part; fall back to
    /// stripping the first HTML body when only that exists.
    private static func textBody(in root: [String: Any]) -> String {
        var plain: [String] = []
        var html: [String] = []
        collectBodies(in: root, plain: &plain, html: &html)

        if !plain.isEmpty { return plain.joined(separator: "\n\n") }
        guard let first = html.first else { return "" }
        // Crude HTML strip — enough that "read this email" isn't a wall of tags.
        let removed = first.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return removed.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func collectBodies(in node: Any, plain: inout [String], html: inout [String]) {
        if let dict = node as? [String: Any] {
            if let body = dict["body"] as? [String: Any] {
                if let text = body["Text"] as? String { plain.append(text) }
                else if let h = body["HTML"] as? String { html.append(h) }
            }
            for (_, value) in dict {
                collectBodies(in: value, plain: &plain, html: &html)
            }
        } else if let arr = node as? [Any] {
            for item in arr { collectBodies(in: item, plain: &plain, html: &html) }
        }
    }

    // MARK: - Formatting

    private static func twelveHour(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    private static var rfc2822Date: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }
}