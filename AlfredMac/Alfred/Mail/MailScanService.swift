//
//  MailScanService.swift
//  Alfred
//
//  The whole-folder sweep that makes sure nothing falls through the cracks:
//  every configured account, every folder (Inbox, Junk, Archive, Sent, custom),
//  on a configurable timer (default 15 min). It caches the envelopes beside the
//  inbox, then runs the copilot's cheap envelope classification over the mail
//  that matters — unread inbox, Junk (to catch "important mail mis-filed as
//  spam"), and flagged — and hands the result to the phone (`mail.scan_complete`
//  broadcast + `mail.scan_summary` read), the briefing, and a notification when
//  something important is hiding in a folder the owner never opens.
//
//  Cost discipline: one himalaya subprocess per folder per sweep (bounded to
//  40 envelopes), and at most a dozen model turns per sweep — everything else
//  is served by the 24h classification cache. A busy Hermes session just means
//  fewer classifications this round; the sweep never cuts across a turn.
//

import AppKit
import Foundation
import UserNotifications

// MARK: - Scan models

/// One folder's snapshot inside a scan summary — the row the phone's "By
/// Folder" view and the briefing's inbox summary both draw from.
struct MailFolderStat: Codable, Equatable {
    let account: String
    let id: String
    let name: String
    let role: String
    let total: Int
    let unseen: Int
    let flagged: Int
}

/// An email the sweep flagged as needing attention, with its classification —
/// what the phone shows as an "Important" row or a "Move to Inbox" suggestion.
struct MailScanItem: Codable, Equatable, Identifiable {
    let account: String
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

    var id: String { "\(account)\u{1F}\(mailbox)\u{1F}\(uid)" }
}

/// The whole picture one sweep produces.
struct EmailScanSummary: Codable, Equatable {
    var folders: [MailFolderStat] = []
    /// Unread across the accounts' inboxes (what the badge means).
    var unreadTotal = 0
    /// Flagged across every scanned folder.
    var flaggedTotal = 0
    /// Emails worth surfacing even though they're not at the top of the inbox.
    var important: [MailScanItem] = []
    /// Important emails found sitting in Junk — the "move to inbox" candidates.
    var spamMiss: [MailScanItem] = []
    var scannedAt: TimeInterval = 0

    /// A short human line for notifications and the bar: "3 unread in Inbox,
    /// 2 flagged, 1 from your professor in Junk".
    var oneLine: String {
        var parts: [String] = []
        if unreadTotal > 0 {
            parts.append("\(unreadTotal) unread")
        }
        if flaggedTotal > 0 {
            parts.append("\(flaggedTotal) flagged")
        }
        if let item = spamMiss.first {
            let who = item.fromName.isEmpty ? item.fromAddress : item.fromName
            let count = spamMiss.count > 1 ? "\(spamMiss.count)" : "1"
            parts.append("\(count) important email\(spamMiss.count > 1 ? "s" : "") from \(who) in Junk")
        }
        return parts.isEmpty ? "Nothing needs attention." : parts.joined(separator: ", ")
    }
}

// MARK: - Service

/// The folder sweep. MainActor like the managers it reads; the slow part (the
/// Himalaya fetches) runs detached, and the model turns go through
/// MailAIService's own gate.
@MainActor
final class MailScanService {

    static let shared = MailScanService()

    /// Fired after every completed sweep — wired in AppDelegate to broadcast
    /// `mail.scan_complete` to phones.
    var onScanCompleted: ((EmailScanSummary) -> Void)?

    private var timer: Timer?
    private var isScanning = false

    nonisolated private static let summaryFileURL = URL(
        fileURLWithPath: NSHomeDirectory() + "/.alfred/mail_scan.json")

    private init() {}

    // MARK: - Lifecycle

    /// Start the sweep timer and fire one immediately. Idempotent.
    func start() {
        guard timer == nil else { return }
        schedule()
        Task { @MainActor in
            _ = await scanNow()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-arm the timer after settings changed the interval.
    func reschedule() {
        stop()
        schedule()
    }

    private func schedule() {
        let interval = TimeInterval(MailSettingsStore.shared.current.scanFrequencyMinutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in _ = await self?.scanNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSLog("[mailscan] sweep scheduled (every \(Int(interval))s)")
    }

    // MARK: - Sweep

    /// Run one full sweep. Never throws; a failing account/folder degrades to a
    /// logged skip. Returns the summary (nil only while another sweep runs).
    @discardableResult
    func scanNow() async -> EmailScanSummary? {
        guard !isScanning else { return Self.persistedSummary() }
        isScanning = true
        defer { isScanning = false }

        let accounts = MailManager.shared.accounts
        let settings = MailSettingsStore.shared.current

        // Fetch + cache every folder off the main actor: himalaya subprocesses
        // block, and the cache writes are per-call FULLMUTEX connections.
        let fetched = await Task.detached(priority: .utility) {
            MailScanService.fetchFolders(accounts: accounts, settings: settings)
        }.value

        // Classify the mail that matters, on the main actor (the copilot is
        // MainActor and gates its own model turns). A busy session just yields
        // fewer classifications this round.
        var classifications: [String: MailClassification] = [:]
        let candidates = Self.classificationCandidates(from: fetched.messages)
        for message in candidates.prefix(12) {
            if let classification = await MailAIService.shared.classifyEnvelope(
                account: message.account, mailbox: message.mailbox, uid: message.uid,
                fromName: message.fromName, fromAddress: message.fromAddress,
                subject: message.subject, snippet: message.snippet) {
                classifications[message.id] = classification
            }
        }

        let previous = Self.persistedSummary()
        let summary = Self.assembleSummary(
            folders: fetched.folders,
            messages: fetched.messages,
            classifications: classifications,
            now: Date().timeIntervalSince1970)

        Self.persist(summary)
        onScanCompleted?(summary)
        maybeNotify(summary, previous: previous)
        NSLog("[mailscan] sweep done — \(summary.folders.count) folders, "
              + "\(summary.unreadTotal) unread, \(summary.spamMiss.count) in junk")
        return summary
    }

    /// The folder-fetch half of the sweep, runnable detached (static).
    nonisolated private static func fetchFolders(accounts: [EmailAccount], settings: MailSettings)
        -> (folders: [MailFolderStat], messages: [MailMessage]) {
        let cap = EmailCapability.shared
        var folders: [MailFolderStat] = []
        var messages: [MailMessage] = []

        for account in accounts {
            let mailboxes: [EmailCapability.MailboxInfo]
            do {
                mailboxes = try cap.mailboxes(account: account.id)
            } catch {
                NSLog("[mailscan] mailbox list failed for \(account.id): \(error.localizedDescription)")
                continue
            }
            for mailbox in mailboxes {
                guard !settings.excludedFolders.contains(mailbox.id) else { continue }
                let envelopes: [EmailCapability.MailEnvelope]
                do {
                    envelopes = try cap.latestEnvelopes(
                        account: account.id, mailbox: mailbox.id, limit: 40)
                } catch {
                    NSLog("[mailscan] envelope list failed for \(account.id)/\(mailbox.id): \(error.localizedDescription)")
                    continue
                }
                let mapped = envelopes.map { envelope in
                    MailMessage(
                        account: account.id,
                        mailbox: mailbox.id,
                        uid: envelope.id,
                        fromName: envelope.fromName ?? "",
                        fromAddress: envelope.fromEmail,
                        subject: envelope.subject ?? "(no subject)",
                        date: envelope.date?.timeIntervalSince1970,
                        snippet: String((envelope.subject ?? "").prefix(120)),
                        isUnread: envelope.isUnread,
                        isFlagged: envelope.isFlagged,
                        hasAttachments: false)
                }
                // Feed the same cache the inbox/search read from, so "By Folder"
                // and cross-folder search work on the phone too.
                MailManager.cacheFolderEnvelopes(
                    account: account.id, mailbox: mailbox.id, envelopes: envelopes)
                folders.append(MailFolderStat(
                    account: account.id, id: mailbox.id, name: mailbox.name,
                    role: MailManager.role(for: mailbox.name),
                    total: mailbox.total, unseen: mailbox.unread,
                    flagged: mapped.filter(\.isFlagged).count))
                messages.append(contentsOf: mapped)
            }
        }
        return (folders, messages)
    }

    /// Which scanned messages are worth a model turn: unread inbox, anything in
    /// Junk (the spam_miss hunt), and anything flagged. Folder exclusions are
    /// already applied upstream in `fetchFolders`. Internal (not private) so
    /// the pure candidate logic is directly testable, like `assembleSummary`.
    nonisolated static func classificationCandidates(from messages: [MailMessage])
        -> [MailMessage] {
        messages.filter { message in
            if message.isFlagged { return true }
            if message.isUnread && message.mailbox.lowercased() == "inbox" { return true }
            let role = MailManager.role(for: message.mailbox)
            return role == "junk"
        }
    }

    /// Assemble the summary from the fetch + the classifications. Pure and
    /// deterministic (given the same inputs), so it's directly testable.
    /// "Don't re-offer the same junk twice" lives in `maybeNotify` (it diffs
    /// against the previous sweep before posting), not here.
    nonisolated static func assembleSummary(folders: [MailFolderStat],
                                            messages: [MailMessage],
                                            classifications: [String: MailClassification],
                                            now: TimeInterval) -> EmailScanSummary {
        let unreadTotal = folders
            .filter { $0.role == "inbox" }
            .reduce(0) { $0 + $1.unseen }
        let flaggedTotal = folders.reduce(0) { $0 + $1.flagged }

        func scanItem(_ message: MailMessage, _ classification: MailClassification) -> MailScanItem? {
            MailScanItem(
                account: message.account,
                mailbox: message.mailbox,
                uid: message.uid,
                fromName: message.fromName,
                fromAddress: message.fromAddress,
                subject: message.subject,
                date: message.date ?? 0,
                snippet: message.snippet,
                importance: classification.importance ?? 0,
                category: classification.category ?? classification.label,
                confidence: classification.confidence ?? 0.5,
                reason: classification.reason ?? "")
        }

        let importanceCategories: Set<String> = ["important", "needs_action", "academic"]
        var important: [MailScanItem] = []
        var spamMiss: [MailScanItem] = []
        for message in messages {
            guard let classification = classifications[message.id] else { continue }
            let isImportant = (classification.importance ?? 0) >= 4
                || importanceCategories.contains(classification.category ?? "")
            guard isImportant else { continue }
            guard let item = scanItem(message, classification) else { continue }
            if MailManager.role(for: message.mailbox) == "junk" {
                spamMiss.append(item)
            } else {
                important.append(item)
            }
        }

        // Highest confidence first, bounded — the phone shows the top of the
        // list, and repeating offers for the same junk mail would nag.
        important.sort { $0.confidence > $1.confidence }
        spamMiss.sort { $0.confidence > $1.confidence }
        spamMiss = Array(spamMiss.prefix(5))

        return EmailScanSummary(
            folders: folders,
            unreadTotal: unreadTotal,
            flaggedTotal: flaggedTotal,
            important: Array(important.prefix(8)),
            spamMiss: spamMiss,
            scannedAt: now)
    }

    // MARK: - Notification

    /// One notification per sweep, only for the finding worth interrupting
    /// for: important mail sitting in Junk that wasn't offered last time.
    private func maybeNotify(_ summary: EmailScanSummary, previous: EmailScanSummary) {
        guard MailSettingsStore.shared.current.notifyOnImportant else { return }
        let newMisses = summary.spamMiss.filter { item in
            !previous.spamMiss.contains { $0.id == item.id }
        }
        guard let first = newMisses.first else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Important email in Junk"
        let who = first.fromName.isEmpty ? first.fromAddress : first.fromName
        content.body = "\(who): \(first.subject). Move it to Inbox?"
        content.userInfo = [
            "mailAccount": first.account, "mailMailbox": first.mailbox, "mailUID": first.uid,
        ]
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "mail-scan-\(first.id)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[mailscan] notification failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Persistence

    /// The last completed sweep, readable from any thread (the briefing reads
    /// it synchronously). Nil until the first sweep finishes.
    nonisolated static func persistedSummary() -> EmailScanSummary {
        guard let data = try? Data(contentsOf: summaryFileURL),
              let summary = try? JSONDecoder().decode(EmailScanSummary.self, from: data)
        else { return EmailScanSummary() }
        return summary
    }

    nonisolated private static func persist(_ summary: EmailScanSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: summaryFileURL, options: .atomic)
    }
}
