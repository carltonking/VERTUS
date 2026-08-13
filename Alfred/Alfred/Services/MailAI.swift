//
//  MailAI.swift
//  Alfred
//
//  The iOS half of the mail copilot contract. These mirror the macOS wire
//  shapes in AlfredMac/Alfred/Mail/MailAIService.swift exactly — the phone
//  decodes `mail.classify` / `mail.summarize` / `mail.extract_tasks` /
//  `mail.draft_reply` / `mail.search_ai` results with these. Keep the two in
//  lockstep.
//
//  The payloads are deliberately small: the model does the heavy reading on
//  the Mac, and the phone just renders what came back (plus whatever it cached
//  from the last view of a message).
//

import Foundation

// MARK: - Classification

/// How one message needs the owner's attention. The sweep fields
/// (`importance`, `category`, `confidence`, `reason`) are optional — older
/// cache entries from before the folder scan simply omit them.
struct MailClassificationPayload: Equatable {
    let label: String
    let tone: String
    let summary: String
    let importance: Int?
    let category: String?
    let confidence: Double?
    let reason: String?

    static func fromJSON(_ dict: [String: Any]) -> MailClassificationPayload? {
        guard let label = dict["label"] as? String else { return nil }
        return MailClassificationPayload(
            label: label,
            tone: dict["tone"] as? String ?? "",
            summary: dict["summary"] as? String ?? "",
            importance: dict["importance"] as? Int,
            category: dict["category"] as? String,
            confidence: dict["confidence"] as? Double,
            reason: dict["reason"] as? String)
    }

    /// The list chip derived from the label: "Needs reply" or "Action item",
    /// or none for fyi/low-priority mail.
    var chipKind: MailChipKind {
        switch label {
        case "needs_reply": return .needsReply
        case "action_item": return .actionItem
        default: return .none
        }
    }

    /// 0-100 confidence for the confidence display ("87% important").
    var confidencePercent: Int? {
        confidence.map { Int(($0 * 100).rounded()) }
    }
}

// MARK: - Scan summary

/// One folder's stats inside a scan summary.
struct MailFolderStatPayload: Equatable, Identifiable {
    let accountID: String
    let folderID: String
    let name: String
    let role: String
    let total: Int
    let unseen: Int
    let flagged: Int

    var id: String { accountID + "|" + folderID }

    static func fromJSON(_ dict: [String: Any]) -> MailFolderStatPayload? {
        guard let id = dict["id"] as? String else { return nil }
        return MailFolderStatPayload(
            accountID: dict["account_id"] as? String ?? "",
            folderID: id,
            name: dict["name"] as? String ?? id,
            role: dict["role"] as? String ?? "folder",
            total: dict["total"] as? Int ?? 0,
            unseen: dict["unseen"] as? Int ?? 0,
            flagged: dict["flagged"] as? Int ?? 0)
    }
}

/// One email the sweep flagged as needing attention, with its classification.
struct MailScanItemPayload: Equatable, Identifiable {
    let accountID: String
    let mailbox: String
    let uid: String
    let fromName: String
    let fromAddress: String
    let subject: String
    let date: TimeInterval
    let snippet: String
    let importance: Int
    let category: String
    let confidence: Double
    let reason: String

    var id: String { accountID + "|" + mailbox + "|" + uid }
    var displayName: String { fromName.isEmpty ? fromAddress : fromName }
    var confidencePercent: Int { Int((confidence * 100).rounded()) }

    static func fromJSON(_ dict: [String: Any]) -> MailScanItemPayload? {
        guard let uid = dict["uid"] as? String else { return nil }
        return MailScanItemPayload(
            accountID: dict["account_id"] as? String ?? "",
            mailbox: dict["mailbox"] as? String ?? "",
            uid: uid,
            fromName: dict["from"] as? String ?? "",
            fromAddress: dict["from_address"] as? String ?? "",
            subject: dict["subject"] as? String ?? "",
            date: dict["date"] as? TimeInterval ?? 0,
            snippet: dict["snippet"] as? String ?? "",
            importance: dict["importance"] as? Int ?? 0,
            category: dict["category"] as? String ?? "",
            confidence: dict["confidence"] as? Double ?? 0.5,
            reason: dict["reason"] as? String ?? "")
    }
}

/// The whole-picture result of a folder sweep — the scan header's source.
struct MailScanSummaryPayload: Equatable {
    var folders: [MailFolderStatPayload] = []
    var unreadTotal = 0
    var flaggedTotal = 0
    var important: [MailScanItemPayload] = []
    var spamMiss: [MailScanItemPayload] = []
    var scannedAt: TimeInterval = 0

    static func fromJSON(_ dict: [String: Any]) -> MailScanSummaryPayload? {
        guard let rawFolders = dict["folders"] as? [[String: Any]] else { return nil }
        return MailScanSummaryPayload(
            folders: rawFolders.compactMap(MailFolderStatPayload.fromJSON),
            unreadTotal: dict["unread_total"] as? Int ?? 0,
            flaggedTotal: dict["flagged_total"] as? Int ?? 0,
            important: (dict["important"] as? [[String: Any]] ?? [])
                .compactMap(MailScanItemPayload.fromJSON),
            spamMiss: (dict["spam_miss"] as? [[String: Any]] ?? [])
                .compactMap(MailScanItemPayload.fromJSON),
            scannedAt: dict["scanned_at"] as? TimeInterval ?? 0)
    }
}

// MARK: - Settings

/// The phone's mirror of the Mac's MailSettings. The settings screen edits
/// these locally and pushes them with `mail.set_settings`; the Mac re-arms its
/// sweep timer from the frequency.
struct MailSettingsPayload: Equatable {
    var scanFrequencyMinutes: Int = 15
    var signatures: [String: String] = [:]
    var draftTone: String = "match-context"
    var autoLearnSent: Bool = true
    var excludedFolders: [String] = []
    var notifyOnImportant: Bool = true
    var learnedPhraseCount: Int = 0

    static func fromJSON(_ dict: [String: Any]) -> MailSettingsPayload? {
        guard dict["scan_frequency_minutes"] != nil else { return nil }
        return MailSettingsPayload(
            scanFrequencyMinutes: dict["scan_frequency_minutes"] as? Int ?? 15,
            signatures: dict["signatures"] as? [String: String] ?? [:],
            draftTone: dict["draft_tone"] as? String ?? "match-context",
            autoLearnSent: dict["auto_learn_sent"] as? Bool ?? true,
            excludedFolders: dict["excluded_folders"] as? [String] ?? [],
            notifyOnImportant: dict["notify_on_important"] as? Bool ?? true,
            learnedPhraseCount: dict["learned_phrase_count"] as? Int ?? 0)
    }

    /// The `mail.set_settings` request body (only the fields the caller means
    /// to change ride along).
    func params(editing fields: Set<String>) -> [String: Any] {
        var params: [String: Any] = [:]
        if fields.contains("frequency") { params["scan_frequency_minutes"] = scanFrequencyMinutes }
        if fields.contains("tone") { params["draft_tone"] = draftTone }
        if fields.contains("autoLearn") { params["auto_learn_sent"] = autoLearnSent }
        if fields.contains("notify") { params["notify_on_important"] = notifyOnImportant }
        if fields.contains("excluded") { params["excluded_folders"] = excludedFolders }
        if fields.contains("signature"), let account = signatures.keys.first {
            params["signature_account"] = account
            params["signature"] = signatures[account] ?? ""
        }
        return params
    }
}

/// The chip shown beside a subject in the list. Rendered in the two soft
/// accent colors the spec calls out; `.none` renders nothing.
enum MailChipKind: Equatable {
    case none
    case needsReply
    case actionItem

    var text: String? {
        switch self {
        case .none: return nil
        case .needsReply: return "Needs reply"
        case .actionItem: return "Action item"
        }
    }
}

// MARK: - Summary

/// Bullet-point recap plus the tone to read the message in.
struct MailSummaryPayload: Equatable {
    let bullets: [String]
    let tone: String

    static func fromJSON(_ dict: [String: Any]) -> MailSummaryPayload? {
        guard let bullets = dict["bullets"] as? [String], !bullets.isEmpty else { return nil }
        return MailSummaryPayload(bullets: bullets, tone: dict["tone"] as? String ?? "")
    }
}

// MARK: - Tasks

/// One action item extracted from a message.
struct MailTaskPayload: Equatable, Identifiable {
    let title: String
    let detail: String

    var id: String { title + "|" + detail }

    static func fromJSON(_ dict: [String: Any]) -> MailTaskPayload? {
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        return MailTaskPayload(title: title, detail: dict["detail"] as? String ?? "")
    }
}

// MARK: - Draft

/// A drafted reply the owner can edit before sending.
struct MailDraftPayload: Equatable {
    let subject: String
    let body: String

    static func fromJSON(_ dict: [String: Any]) -> MailDraftPayload? {
        guard let body = dict["body"] as? String, !body.isEmpty else { return nil }
        return MailDraftPayload(
            subject: dict["subject"] as? String ?? "",
            body: body)
    }
}
