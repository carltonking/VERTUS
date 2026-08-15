//
//  MacMailStore.swift
//  Alfred
//
//  The state behind the Mac-driven unified inbox: every account Himalaya is
//  configured with on the Mac, the cached inbox from the Mac's SQLite store,
//  search, and the actions the rows can take. Everything travels over the
//  WebSocket as JSON-RPC (`mail.*`).
//
//  The store is deliberately a shared singleton: the tab badge needs the unread
//  count while the tab content needs the rows, and both read the same facts.
//

import Foundation
import Observation

@MainActor
@Observable
final class MacMailStore {

    static let shared = MacMailStore()

    // MARK: State

    /// Every Himalaya account on the Mac, in the Mac's order (default first).
    private(set) var accounts: [MacMailAccount] = []
    /// The cached inbox — unified, or filtered to `selectedAccountID`.
    private(set) var messages: [MacMailMessage] = []
    /// The unified unread total, from the Mac's folder counts. Feeds the badge.
    private(set) var totalUnread = 0
    /// False when Himalaya itself is missing from the Mac — the app should
    /// say so instead of showing a mysteriously empty inbox.
    private(set) var backendAvailable = true
    private(set) var isLoading = false
    private(set) var isSyncing = false
    /// The most recent failure, surfaced above the list so it's not silent.
    private(set) var lastError: String?
    /// Set once the first load succeeded — separates "empty" from "not loaded".
    private(set) var hasLoaded = false
    /// When the last completed sync happened (for the "synced Xs ago" line).
    private(set) var lastSyncedAt: TimeInterval = 0

    /// Which account the inbox is filtered to. Nil = the unified inbox.
    var selectedAccountID: String?

    private var socket: AlfredWebSocketClient { .shared }
    private var updatesTask: Task<Void, Never>?
    private var didStartUpdates = false

    // MARK: AI copilot caches

    /// Classifications by message id — the source for the list chips and the
    /// reader's tone line.
    private(set) var classifications: [String: MailClassificationPayload] = [:]
    /// Summaries by message id for the reader's AI panel.
    private(set) var summaries: [String: MailSummaryPayload] = [:]
    /// Extracted tasks by message id for the reader's Tasks popover.
    private(set) var tasksByMessage: [String: [MailTaskPayload]] = [:]
    /// Message ids with a model call in flight (keyed per method so classify
    /// and summarize for the same message can run in parallel without stacking
    /// duplicate turns).
    private(set) var analysisInFlight = Set<String>()

    // MARK: Folder sweep state

    /// The last folder-sweep summary from the Mac — the scan header's source.
    private(set) var scanSummary: MailScanSummaryPayload?
    /// Email settings mirrored from the Mac (signature, tone, frequency…).
    /// Writable so the settings screen can edit a local copy before pushing.
    var mailSettings: MailSettingsPayload = MailSettingsPayload()
    /// Rows for the currently browsed folder (the "By Folder" filter).
    private(set) var folderMessages: [MacMailMessage] = []
    /// Which folder `folderMessages` belongs to ("" = the unified inbox list).
    private(set) var browsingFolder = ""

    // MARK: - Derived

    /// The account badge info for a message row, resolved against loaded accounts.
    func account(for message: MacMailMessage) -> MacMailAccount? {
        accounts.first { $0.id == message.accountID }
    }

    /// True when there's a live socket to talk over. The views gate their
    /// empty states on this; a dead link means "connect first", not "no mail".
    var canTalkToMac: Bool {
        AlfredWebSocketClient.shared.isConnected
    }

    // MARK: - Lifecycle

    /// Begin consuming the Mac's mail pushes. Runs once; safe to call from the
    /// app's socket-connect hook.
    func start() {
        guard !didStartUpdates else { return }
        didStartUpdates = true
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.socket.updates() {
                switch update {
                case .mailSyncComplete(let synced, let unread, let failed):
                    self.lastSyncedAt = Date().timeIntervalSince1970
                    self.totalUnread = unread
                    if synced > 0 {
                        await self.reloadInbox()
                    } else if !failed.isEmpty {
                        self.lastError = "Some accounts couldn't sync on the Mac."
                    }
                case .mailUnreadChanged(let unread):
                    self.totalUnread = unread
                case .mailScanComplete(let scan):
                    // A sweep finished on the Mac — refresh the scan header and
                    // its folder rows if we're browsing one.
                    self.scanSummary = scan
                    if !self.browsingFolder.isEmpty {
                        await self.loadFolderMessages(folderID: self.browsingFolder)
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Loading

    /// Fetch accounts and the inbox. `force: true` (pull-to-refresh) also tells
    /// the Mac to re-sync from IMAP first; otherwise it answers from its cache.
    func load(forceSync: Bool = false) async {
        guard canTalkToMac else {
            lastError = "Alfred isn't connected yet."
            hasLoaded = true
            return
        }
        if forceSync {
            isSyncing = true
        } else if isLoading {
            return
        }
        isLoading = true
        defer { isLoading = false; isSyncing = false }

        do {
            if forceSync {
                _ = try await socket.sendCommand(name: "mail.sync", timeout: 60)
            }
            let result = try await socket.sendCommand(name: "mail.accounts", timeout: 20)
            let rawAccounts = result["accounts"] as? [[String: Any]] ?? []
            accounts = rawAccounts.compactMap(MacMailAccount.fromJSON)
            totalUnread = result["total_unread"] as? Int ?? 0
            backendAvailable = result["backend_available"] as? Bool ?? true

            await reloadInbox()
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
        hasLoaded = true
    }

    /// Re-fetch just the inbox (and unread total) under the current filter.
    /// Used after actions, sync completions, and account-filter changes.
    func reloadInbox() async {
        var params: [String: Any] = [:]
        if let accountID = selectedAccountID {
            params["account_id"] = accountID
        }
        do {
            let result = try await socket.sendCommand(name: "mail.inbox", params: params, timeout: 20)
            let rawMessages = result["messages"] as? [[String: Any]] ?? []
            messages = rawMessages.compactMap(MacMailMessage.fromJSON)
            totalUnread = result["total_unread"] as? Int ?? totalUnread
            lastError = nil
        } catch {
            // A failed inbox refresh after an action shouldn't clobber what we
            // already have — keep the rows, surface the failure.
            lastError = Self.message(for: error)
        }
    }

    /// Subject/sender/snippet search over the Mac's cached inbox. Empty query
    /// = the plain inbox again.
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await reloadInbox()
            return
        }
        var params: [String: Any] = ["query": trimmed]
        if let accountID = selectedAccountID {
            params["account_id"] = accountID
        }
        do {
            let result = try await socket.sendCommand(name: "mail.search", params: params, timeout: 20)
            let rawMessages = result["messages"] as? [[String: Any]] ?? []
            messages = rawMessages.compactMap(MacMailMessage.fromJSON)
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    // MARK: - Full message

    /// A message with its body and attachments, fresh from Himalaya on the Mac.
    func messageDetail(for message: MacMailMessage) async -> MacMailMessageDetail? {
        do {
            let result = try await socket.sendCommand(
                name: "mail.message",
                params: [
                    "account_id": message.accountID,
                    "mailbox": message.mailbox,
                    "uid": message.uid,
                ],
                timeout: 30)
            guard let raw = result["message"] as? [String: Any] else { return nil }
            return MacMailMessageDetail.fromJSON(raw)
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    // MARK: - Actions

    /// Mark read/unread. Optimistic: the row flips immediately, and a failed
    /// round trip reverts it (the failure also surfaces above the list).
    func markRead(_ message: MacMailMessage, read: Bool) async {
        applyLocally(to: message) { $0.seen = read }
        let ok = await mailAck(
            "mail.mark_read",
            message: message,
            extra: ["read": read])
        if !ok { await reloadInbox() }
    }

    /// Flag/unflag.
    func setFlag(_ message: MacMailMessage, flagged: Bool) async {
        applyLocally(to: message) { $0.flagged = flagged }
        let ok = await mailAck(
            "mail.flag",
            message: message,
            extra: ["flagged": flagged])
        if !ok { await reloadInbox() }
    }

    /// Move to the account's trash.
    func trash(_ message: MacMailMessage) async {
        await mailAck("mail.trash", message: message)
        await reloadInbox()
    }

    /// Move to the account's archive.
    func archive(_ message: MacMailMessage) async {
        await mailAck("mail.archive", message: message)
        await reloadInbox()
    }

    /// Send a new message. Throws so the compose sheet can show the reason.
    func send(to: String, cc: String?, subject: String, body: String, accountID: String) async throws {
        var params: [String: Any] = [
            "to": to,
            "subject": subject,
            "body": body,
            "account_id": accountID,
        ]
        if let cc, !cc.isEmpty { params["cc"] = cc }
        _ = try await socket.sendCommand(name: "mail.send", params: params, timeout: 60)
    }

    /// Reply to a message, keeping the thread. `subject`/`cc` override the
    /// defaults (the review screen edits them); nil keeps the standard Re: and
    /// no cc. Throws like send.
    func reply(to message: MacMailMessage, body: String,
               subject: String? = nil, cc: String? = nil) async throws {
        var params: [String: Any] = [
            "account_id": message.accountID,
            "mailbox": message.mailbox,
            "uid": message.uid,
            "body": body,
        ]
        if let subject { params["subject"] = subject }
        if let cc { params["cc"] = cc }
        _ = try await socket.sendCommand(name: "mail.reply", params: params, timeout: 60)
    }

    // MARK: - Helpers

    /// Fire an ack-style mail action and report whether it succeeded.
    private func mailAck(_ method: String, message: MacMailMessage, extra: [String: Any] = [:]) async -> Bool {
        var params: [String: Any] = [
            "account_id": message.accountID,
            "mailbox": message.mailbox,
            "uid": message.uid,
        ]
        for (key, value) in extra { params[key] = value }
        do {
            _ = try await socket.sendCommand(name: method, params: params, timeout: 30)
            lastError = nil
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    /// Mutate the matching cached row in place (by wire id) without a re-fetch.
    private func applyLocally(to message: MacMailMessage, _ mutate: (inout MacMailMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        var copy = messages[index]
        mutate(&copy)
        messages[index] = copy
    }

    nonisolated private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - AI copilot
//
// The smart layer over the same inbox: classification chips, summaries, task
// extraction, draft replies and natural-language search — all served by the
// Mac's MailAIService over the socket (`mail.classify` / `mail.summarize` /
// `mail.extract_tasks` / `mail.draft_reply` / `mail.search_ai`).
//
// Everything model-backed is cached here for the session so re-opening a
// message is instant, and the Mac keeps its own 24h SQLite cache on top. A
// busy session (someone talking to Alfred) degrades to nil/empty rather than
// erroring — the chips just don't appear until the Mac has a free turn.

extension MacMailStore {

    /// Classify a message. Cached in memory; a live call re-uses the Mac's
    /// 24h SQLite cache so repeat views are instant.
    @discardableResult
    func classify(_ message: MacMailMessage) async -> MailClassificationPayload? {
        if let cached = classifications[message.id] { return cached }
        guard !analysisInFlight.contains("classify|\(message.id)") else { return nil }
        analysisInFlight.insert("classify|\(message.id)")
        defer { analysisInFlight.remove("classify|\(message.id)") }
        do {
            let result = try await socket.sendCommand(
                name: "mail.classify", params: triple(message), timeout: 90)
            guard let raw = result["classification"] as? [String: Any],
                  let classification = MailClassificationPayload.fromJSON(raw)
            else { return nil }
            classifications[message.id] = classification
            return classification
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Summarize a message (and its conversation) for the reader's AI panel.
    @discardableResult
    func summarize(_ message: MacMailMessage) async -> MailSummaryPayload? {
        if let cached = summaries[message.id] { return cached }
        guard !analysisInFlight.contains("summarize|\(message.id)") else { return nil }
        analysisInFlight.insert("summarize|\(message.id)")
        defer { analysisInFlight.remove("summarize|\(message.id)") }
        do {
            let result = try await socket.sendCommand(
                name: "mail.summarize", params: triple(message), timeout: 90)
            guard let raw = result["summary"] as? [String: Any],
                  let summary = MailSummaryPayload.fromJSON(raw)
            else { return nil }
            summaries[message.id] = summary
            return summary
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Extract action items. Empty when nothing is asked of the owner.
    func extractTasks(_ message: MacMailMessage) async -> [MailTaskPayload] {
        if let cached = tasksByMessage[message.id] { return cached }
        guard !analysisInFlight.contains("tasks|\(message.id)") else { return [] }
        analysisInFlight.insert("tasks|\(message.id)")
        defer { analysisInFlight.remove("tasks|\(message.id)") }
        do {
            let result = try await socket.sendCommand(
                name: "mail.extract_tasks", params: triple(message), timeout: 90)
            let raw = result["tasks"] as? [[String: Any]] ?? []
            let tasks = raw.compactMap(MailTaskPayload.fromJSON)
            tasksByMessage[message.id] = tasks
            return tasks
        } catch {
            lastError = Self.message(for: error)
            return []
        }
    }

    /// A reply draft in the owner's learned voice. `tone` overrides the Mac's
    /// settings default ("formal" / "casual" / "match-context"). Never
    /// cached — it answers a fresh ask, and the Mac doesn't cache it either.
    func draftReply(_ message: MacMailMessage, tone: String? = nil) async -> MailDraftPayload? {
        var params = triple(message)
        if let tone { params["tone"] = tone }
        do {
            let result = try await socket.sendCommand(name: "mail.draft_reply", params: params, timeout: 90)
            guard let raw = result["draft"] as? [String: Any] else { return nil }
            return MailDraftPayload.fromJSON(raw)
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Natural-language search. The Mac compiles the query into a structured
    /// filter over its cached inbox (falling back to plain LIKE search when
    /// Alfred is busy); this store's `messages` becomes the result set, and
    /// the returned note is the one-line description shown above the list.
    func searchAI(_ query: String, accountID: String? = nil) async -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await reloadInbox()
            return nil
        }
        var params: [String: Any] = ["query": trimmed]
        if let accountID { params["account_id"] = accountID }
        do {
            let result = try await socket.sendCommand(name: "mail.search_ai", params: params, timeout: 60)
            let rawMessages = result["messages"] as? [[String: Any]] ?? []
            messages = rawMessages.compactMap(MacMailMessage.fromJSON)
            lastError = nil
            return result["note"] as? String
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Classify a handful of unread messages for the list chips, oldest of the
    /// newest first. Sequential (one model turn at a time) and bounded — this
    /// is opt-in from the list, never automatic, so it can't quietly burn
    /// quota every time the inbox loads.
    func analyzeTopUnread(_ limit: Int = 5) async {
        let candidates = messages
            .filter { !$0.seen && classifications[$0.id] == nil }
            .prefix(limit)
        for message in candidates {
            await classify(message)
        }
    }

    /// Move a message back to the inbox (the Undo side of Archive). The Mac
    /// resolves the account's real inbox folder, same as trash/archive do.
    func unarchive(_ message: MacMailMessage) async {
        await mailAck("mail.unarchive", message: message)
        await reloadInbox()
    }

    /// One account's mailboxes with counts (for the sidebar's folder list).
    func folders(accountID: String) async -> [MacMailFolder] {
        do {
            let result = try await socket.sendCommand(
                name: "mail.folders", params: ["account_id": accountID], timeout: 20)
            let raw = result["folders"] as? [[String: Any]] ?? []
            return raw.compactMap(MacMailFolder.fromJSON)
        } catch {
            lastError = Self.message(for: error)
            return []
        }
    }

    /// The (account_id, mailbox, uid) params every message-addressed mail.*
    /// call shares.
    private func triple(_ message: MacMailMessage) -> [String: Any] {
        [
            "account_id": message.accountID,
            "mailbox": message.mailbox,
            "uid": message.uid,
        ]
    }
}

// MARK: - Folder sweep, drafts & settings
//
// The rest of the email-management surface: the folder-sweep summary, the
// "By Folder" drill-down, multi-tone drafts + revision, save-as-draft, and the
// settings mirror that drives the Mac's sweep timer and drafter.

extension MacMailStore {

    // MARK: Scan summary

    /// Load the latest sweep summary from the Mac (the scan header on appear;
    /// pull-to-refresh calls `refreshScan` instead).
    func loadScanSummary() async {
        do {
            let result = try await socket.sendCommand(name: "mail.scan_summary", timeout: 20)
            if let raw = result["scan"] as? [String: Any] {
                scanSummary = MailScanSummaryPayload.fromJSON(raw)
            }
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Ask the Mac to run a full sweep now and hand back the fresh summary.
    func refreshScan() async {
        do {
            let result = try await socket.sendCommand(name: "mail.scan", timeout: 120)
            if let raw = result["scan"] as? [String: Any] {
                scanSummary = MailScanSummaryPayload.fromJSON(raw)
            }
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Remove a finding from the scan header after the owner acted on it
    /// (the one-tap "Move to Inbox" rescue), so it doesn't keep re-offering.
    func dismissScanItem(id: String) {
        guard var scan = scanSummary else { return }
        scan.spamMiss.removeAll { $0.id == id }
        scan.important.removeAll { $0.id == id }
        scanSummary = scan
    }

    // MARK: By-folder drill-down

    /// Load one folder's cached messages ("" = every scanned folder).
    func loadFolderMessages(folderID: String) async {
        browsingFolder = folderID
        var params: [String: Any] = [:]
        if !folderID.isEmpty { params["folder_id"] = folderID }
        if let accountID = selectedAccountID { params["account_id"] = accountID }
        do {
            let result = try await socket.sendCommand(name: "mail.folder_messages", params: params, timeout: 20)
            let rawMessages = result["messages"] as? [[String: Any]] ?? []
            folderMessages = rawMessages.compactMap(MacMailMessage.fromJSON)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Move a message to an explicit folder (the "Move to Inbox" rescue and
    /// general re-organization).
    func moveToFolder(_ message: MacMailMessage, destination: String) async {
        var params = triple(message)
        params["destination"] = destination
        _ = await mailAck("mail.move_folder", message: message, extra: ["destination": destination])
        if browsingFolder == message.mailbox {
            await loadFolderMessages(folderID: browsingFolder)
        } else {
            await reloadInbox()
        }
    }

    /// One-tap rescue for a sweep finding: move it back to the account's inbox.
    /// Reuses the existing unarchive path (role "inbox"), which resolves the
    /// real inbox mailbox on the Mac.
    func moveToInbox(item: MailScanItemPayload) async {
        let message = MacMailMessage(
            id: "\(item.accountID)\u{1F}\(item.mailbox)\u{1F}\(item.uid)",
            accountID: item.accountID,
            mailbox: item.mailbox,
            uid: item.uid,
            from: item.fromName,
            fromAddress: item.fromAddress,
            subject: item.subject,
            date: item.date,
            snippet: item.snippet,
            seen: false,
            flagged: false,
            hasAttachments: false)
        await unarchive(message)
    }

    // MARK: Drafts

    /// Three tone alternatives for the review screen's "Show alternatives".
    func draftAlternatives(_ message: MacMailMessage) async -> [MailDraftPayload] {
        do {
            let result = try await socket.sendCommand(
                name: "mail.draft_alternatives", params: triple(message), timeout: 120)
            let raw = result["alternatives"] as? [[String: Any]] ?? []
            return raw.compactMap(MailDraftPayload.fromJSON)
        } catch {
            lastError = Self.message(for: error)
            return []
        }
    }

    /// Revise a draft in place from a natural-language instruction.
    func reviseDraft(_ message: MacMailMessage, subject: String, body: String,
                     instruction: String) async -> MailDraftPayload? {
        var params = triple(message)
        params["subject"] = subject
        params["body"] = body
        params["instruction"] = instruction
        do {
            let result = try await socket.sendCommand(name: "mail.draft_revise", params: params, timeout: 120)
            guard let raw = result["draft"] as? [String: Any] else { return nil }
            return MailDraftPayload.fromJSON(raw)
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Save a message as a draft on the Mac without sending.
    func saveDraft(to: String, cc: String?, subject: String, body: String, accountID: String) async throws {
        var params: [String: Any] = [
            "to": to, "subject": subject, "body": body, "account_id": accountID,
        ]
        if let cc, !cc.isEmpty { params["cc"] = cc }
        _ = try await socket.sendCommand(name: "mail.save_draft", params: params, timeout: 60)
    }

    // MARK: Settings

    /// Load the Mac's email settings so the settings screen reflects reality.
    func loadMailSettings() async {
        do {
            let result = try await socket.sendCommand(name: "mail.settings", timeout: 20)
            if let raw = result["settings"] as? [String: Any],
               let settings = MailSettingsPayload.fromJSON(raw) {
                mailSettings = settings
            }
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Push the locally edited settings to the Mac (and re-arm its sweep timer).
    func pushMailSettings(editing fields: Set<String>) async {
        do {
            let result = try await socket.sendCommand(
                name: "mail.set_settings",
                params: mailSettings.params(editing: fields),
                timeout: 30)
            if let raw = result["settings"] as? [String: Any],
               let settings = MailSettingsPayload.fromJSON(raw) {
                mailSettings = settings
            }
        } catch {
            lastError = Self.message(for: error)
        }
    }
}
