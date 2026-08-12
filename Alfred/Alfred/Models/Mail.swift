//
//  Mail.swift
//  Alfred
//
//  The shapes /api/mail speaks in, and the date formatting a message list needs.
//
//  These mirror the server's IMAP view of a mailbox rather than inventing an Alfred-specific model,
//  because every operation the UI offers — mark read, flag, move to trash — is ultimately (account,
//  mailbox, uid). Flattening that triple into one opaque id would make those calls unaddressable.
//

import Foundation

// MARK: - Accounts

struct MailAccountInfo: Identifiable, Decodable, Hashable {
    let id: String
    let label: String
    let address: String
    let provider: String
    /// "env" — deployed in the server's environment; "stored" — added from this app.
    let source: String
    /// Only accounts added from the app can be removed by it. The server's own configuration
    /// isn't the app's to unpick.
    let removable: Bool
}

/// A provider the app offers when adding an account, with the hostnames already filled in.
struct MailProviderInfo: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    /// Every supported provider needs an app-specific password rather than the account password,
    /// and getting that wrong is the single most common reason adding an account fails — so the
    /// server sends the explanation along with the option.
    let passwordHint: String
    let helpUrl: String?
    let imapHost: String
    let smtpHost: String
    /// OAuth providers aren't added with an address + password — the app signs in via Google and
    /// the server stores whatever account Google approved. Absent on older deployments, so decoded
    /// with a default.
    let oauth: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, passwordHint, helpUrl, imapHost, smtpHost, oauth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        passwordHint = try c.decodeIfPresent(String.self, forKey: .passwordHint) ?? ""
        helpUrl = try c.decodeIfPresent(String.self, forKey: .helpUrl)
        imapHost = try c.decodeIfPresent(String.self, forKey: .imapHost) ?? ""
        smtpHost = try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? ""
        oauth = try c.decodeIfPresent(Bool.self, forKey: .oauth) ?? false
    }

    /// "Other (IMAP)" arrives with empty hostnames, which is what makes it custom.
    var needsHostnames: Bool { imapHost.isEmpty }

    var icon: String {
        switch id {
        case "icloud": return "icloud.fill"
        case "gmail", "yahoo": return "envelope.fill"
        case "outlook": return "envelope.badge.fill"
        case "fastmail": return "bolt.fill"
        case "google": return "globe"
        default: return "at"
        }
    }
}

// MARK: - Mailboxes

struct Mailbox: Identifiable, Decodable, Hashable {
    let account: String
    /// The IMAP path, e.g. "INBOX" or "[Gmail]/All Mail". What the server addresses it by.
    let path: String
    /// The leaf name, for display.
    let name: String
    /// inbox · sent · drafts · trash · junk · archive · folder
    let role: String
    let unseen: Int
    let total: Int

    var id: String { "\(account)\u{1F}\(path)" }

    /// Apple Mail's iconography, so a Sent folder reads as one at a glance.
    var icon: String {
        switch role {
        case "inbox": return "tray.fill"
        case "sent": return "paperplane.fill"
        case "drafts": return "doc.fill"
        case "trash": return "trash.fill"
        case "junk": return "xmark.bin.fill"
        case "archive": return "archivebox.fill"
        case "flagged": return "flag.fill"
        default: return "folder.fill"
        }
    }
}

// MARK: - Messages

struct MailMessage: Identifiable, Decodable, Hashable {
    let account: String
    let mailbox: String
    let uid: Int
    let from: String
    let fromAddress: String
    let to: [String]
    let subject: String
    let date: Date
    let messageId: String?
    let snippet: String
    var seen: Bool
    var flagged: Bool
    let hasAttachments: Bool

    var id: String { "\(account)\u{1F}\(mailbox)\u{1F}\(uid)" }

    /// Declared explicitly because writing `init(from:)` by hand suppresses the synthesised version.
    private enum CodingKeys: String, CodingKey {
        case account, mailbox, uid, from, fromAddress, to, subject, date, messageId, snippet, seen, flagged, hasAttachments
    }

    /// Decoded field-by-field with defaults rather than by the synthesised initialiser. The phone and
    /// the deployment version independently, so a server that gains or drops a field shouldn't blank
    /// the entire inbox — a message missing `flagged` should render unflagged, not fail to decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(String.self, forKey: .account)
        mailbox = try c.decodeIfPresent(String.self, forKey: .mailbox) ?? "INBOX"
        uid = try c.decode(Int.self, forKey: .uid)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        fromAddress = try c.decodeIfPresent(String.self, forKey: .fromAddress) ?? ""
        to = try c.decodeIfPresent([String].self, forKey: .to) ?? []
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? "(no subject)"
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        messageId = try c.decodeIfPresent(String.self, forKey: .messageId)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? false
        flagged = try c.decodeIfPresent(Bool.self, forKey: .flagged) ?? false
        hasAttachments = try c.decodeIfPresent(Bool.self, forKey: .hasAttachments) ?? false
    }

    /// The circle of initials Mail shows beside each row. Falls back to the address when the sender
    /// has no display name, so it's never blank.
    var initials: String {
        let source = from.isEmpty ? fromAddress : from
        let words = source
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    var displayName: String { from.isEmpty ? fromAddress : from }
}

/// The readable body, fetched only when a message is opened — pulling full bodies for a whole
/// inbox would be slow and almost entirely wasted, since the list only ever shows the snippet.
struct MailBody: Decodable, Hashable {
    let html: String?
    let text: String
    let attachments: [MailAttachment]
}

struct MailAttachment: Identifiable, Decodable, Hashable {
    let part: String
    let filename: String
    let size: Int
    let mime: String

    var id: String { part }

    var icon: String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        return "paperclip"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// One account failing shouldn't blank the whole inbox — but it must not be silent either. A wrong
/// app password contributing zero messages looks exactly like a quiet mailbox from a phone.
struct MailAccountFailure: Decodable, Hashable, Identifiable {
    let account: String
    let error: String
    var id: String { account }
}

// MARK: - Responses

struct AccountsPayload: Decodable {
    let accounts: [MailAccountInfo]
    let providers: [MailProviderInfo]
}

struct MailboxesPayload: Decodable {
    let mailboxes: [Mailbox]
    let failures: [MailAccountFailure]
    /// Unread totals for the smart mailboxes. Absent on older deployments, so decoded with defaults.
    let smart: SmartCounts?

    struct SmartCounts: Decodable {
        let flaggedUnseen: Int
        let vipUnseen: Int
    }
}

struct MessagesPayload: Decodable {
    let messages: [MailMessage]
    let failures: [MailAccountFailure]
    let hasMore: Bool
    /// Opaque position to hand back for the next page. Absent once the mailbox is exhausted.
    let cursor: String?
}

struct MessagePayload: Decodable {
    let message: MailMessage
    let body: MailBody
}

struct DraftPayload: Decodable {
    let to: String
    let subject: String
    let body: String
}

struct AddAccountPayload: Decodable {
    let account: MailAccountInfo
    /// Set when reading works but sending couldn't be verified — worth showing, not worth refusing.
    let warning: String?
}

// MARK: - Dates

enum MailDate {
    /// The server sends `new Date().toISOString()`, which carries milliseconds. `.withInternetDateTime`
    /// alone rejects those, so both spellings are tried rather than silently failing to decode every
    /// message in the inbox.
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        withFraction.date(from: raw) ?? plain.date(from: raw)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    /// Mail's list column: a time today, "Yesterday", a weekday inside the last week, then a date.
    static func listLabel(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }

        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), date >= week {
            return weekday.string(from: date)
        }
        return shortDate.string(from: date)
    }

    /// The header inside an open message, where there's room to be unambiguous.
    static func detailLabel(_ date: Date) -> String {
        full.string(from: date)
    }
}
