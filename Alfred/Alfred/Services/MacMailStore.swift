//
//  MacMailStore.swift
//  Alfred
//
//  The state behind the Mac-driven unified inbox: every account Himalaya is
//  configured with on the Mac, the cached inbox from the Mac's SQLite store,
//  search, and the actions the rows can take. Everything travels over the
//  WebSocket as JSON-RPC (`mail.*`), the same way RoutinesView uses the socket.
//
//  The store is deliberately a shared singleton: the tab badge needs the unread
//  count while the tab content needs the rows, and both read the same facts.
//  It starts its update loop when the app's socket connects, so the badge
//  tracks new mail even if the Email tab is never opened.
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
    /// False when Himalaya itself is missing from the Mac — the phone should
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

    /// Reply to a message, keeping the thread. Throws like send.
    func reply(to message: MacMailMessage, body: String) async throws {
        _ = try await socket.sendCommand(
            name: "mail.reply",
            params: [
                "account_id": message.accountID,
                "mailbox": message.mailbox,
                "uid": message.uid,
                "body": body,
            ],
            timeout: 60)
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
