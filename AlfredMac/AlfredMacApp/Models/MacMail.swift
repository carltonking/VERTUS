//
//  MacMail.swift
//  Alfred
//
//  The Mac mail contract, shared with the iOS app: this app decodes `mail.*`
//  results with these, and encodes nothing back (actions are plain parameter
//  dictionaries). Mirrors the macOS wire shapes in
//  AlfredMac/Alfred/Mail/MailManager.swift exactly.
//
//  Names are prefixed Mac because Models/Mail.swift already owns the cloud
//  /api/mail shapes (MailMessage, MailAttachment…). The Mac-driven unified
//  inbox and the cloud client coexist; the prefix keeps them unambiguous.
//

import Foundation

// MARK: - Account

/// One Himalaya account on the Mac, as `mail.accounts` reports it. `provider`
/// is the raw wire value ("iCloud" / "google" / "nyu" / "other").
struct MacMailAccount: Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
    let provider: String
    let lastSyncedAt: TimeInterval
    let unread: Int

    static func fromJSON(_ dict: [String: Any]) -> MacMailAccount? {
        guard let id = dict["id"] as? String else { return nil }
        return MacMailAccount(
            id: id,
            name: dict["name"] as? String ?? "",
            email: dict["email"] as? String ?? "",
            provider: dict["provider"] as? String ?? "other",
            lastSyncedAt: dict["last_synced_at"] as? TimeInterval ?? 0,
            unread: dict["unread"] as? Int ?? 0)
    }

    /// A short, glanceable label for the filter chips and the From picker.
    var shortLabel: String {
        switch provider.lowercased() {
        case "icloud": return "iCloud"
        case "google": return "Google"
        case "nyu": return "NYU"
        default: return name.isEmpty ? email : name
        }
    }

    /// SF Symbol for the account badge on each row.
    var icon: String {
        switch provider.lowercased() {
        case "icloud": return "icloud.fill"
        case "google": return "g.circle.fill"
        case "nyu": return "graduationcap.fill"
        default: return "at.circle.fill"
        }
    }
}

// MARK: - Folder

/// One mailbox on an account, as `mail.folders` reports it (with counts).
struct MacMailFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let unseen: Int
    let total: Int

    static func fromJSON(_ dict: [String: Any]) -> MacMailFolder? {
        guard let id = dict["id"] as? String else { return nil }
        return MacMailFolder(
            id: id,
            name: dict["name"] as? String ?? id,
            role: dict["role"] as? String ?? "folder",
            unseen: dict["unseen"] as? Int ?? 0,
            total: dict["total"] as? Int ?? 0)
    }
}

// MARK: - Message

/// One message row from the cached inbox (`mail.inbox` / `mail.search`). The
/// wire id is `account \u{1F} mailbox \u{1F} uid` — the exact triple every
/// action addresses, so it's split back out rather than hidden.
struct MacMailMessage: Identifiable, Hashable {
    let id: String
    let accountID: String
    let mailbox: String
    let uid: String
    let from: String
    let fromAddress: String
    let subject: String
    let date: TimeInterval
    let snippet: String
    var seen: Bool
    var flagged: Bool
    let hasAttachments: Bool

    static func fromJSON(_ dict: [String: Any]) -> MacMailMessage? {
        guard let id = dict["id"] as? String,
              let accountID = dict["account_id"] as? String,
              let mailbox = dict["mailbox"] as? String,
              let uid = dict["uid"] as? String
        else { return nil }
        return MacMailMessage(
            id: id,
            accountID: accountID,
            mailbox: mailbox,
            uid: uid,
            from: dict["from"] as? String ?? "",
            fromAddress: dict["from_address"] as? String ?? "",
            subject: dict["subject"] as? String ?? "(no subject)",
            date: dict["date"] as? TimeInterval ?? 0,
            snippet: dict["snippet"] as? String ?? "",
            seen: dict["seen"] as? Bool ?? true,
            flagged: dict["flagged"] as? Bool ?? false,
            hasAttachments: dict["has_attachments"] as? Bool ?? false)
    }

    var displayName: String { from.isEmpty ? fromAddress : from }

    /// The circle of initials Mail shows beside each row. Falls back to the
    /// address when the sender has no display name, so it's never blank.
    var initials: String {
        let source = from.isEmpty ? fromAddress : from
        let words = source
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// The account badge for this row, resolved against the loaded accounts.
    func accountIcon(accounts: [MacMailAccount]) -> String {
        accounts.first { $0.id == accountID }?.icon ?? "at.circle.fill"
    }
}

// MARK: - Attachment

/// One attachment, as `mail.message` reports it. Bodies (and therefore
/// attachment bytes) are fetched on demand; this is just the envelope.
struct MacMailAttachment: Identifiable, Hashable {
    let id: String
    let filename: String
    let mime: String
    let size: Int

    static func fromJSON(_ dict: [String: Any]) -> MacMailAttachment? {
        guard let id = dict["id"] as? String else { return nil }
        return MacMailAttachment(
            id: id,
            filename: dict["filename"] as? String ?? "attachment",
            mime: dict["mime"] as? String ?? "",
            size: dict["size"] as? Int ?? 0)
    }

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

// MARK: - Full message

/// A message with its body and attachments — what the reader screen needs,
/// returned whole by `mail.message` so the app makes one call per open.
struct MacMailMessageDetail {
    let message: MacMailMessage
    let bodyText: String
    let bodyHTML: String
    let attachments: [MacMailAttachment]

    static func fromJSON(_ dict: [String: Any]) -> MacMailMessageDetail? {
        guard let message = MacMailMessage.fromJSON(dict) else { return nil }
        let body = dict["body"] as? [String: Any] ?? [:]
        let attachments = (dict["attachments"] as? [[String: Any]] ?? [])
            .compactMap(MacMailAttachment.fromJSON)
        return MacMailMessageDetail(
            message: message,
            bodyText: body["text"] as? String ?? "",
            bodyHTML: body["html"] as? String ?? "",
            attachments: attachments)
    }

    /// The reader prefers the HTML rendering; plain text is the fallback.
    var hasHTML: Bool { !bodyHTML.isEmpty }
}
