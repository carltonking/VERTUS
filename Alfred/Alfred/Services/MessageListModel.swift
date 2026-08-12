//
//  MessageListModel.swift
//  Alfred
//
//  One mailbox's worth of messages, and every action the list can take on them.
//
//  Flag and delete apply locally first and reconcile with the server afterwards. IMAP round-trips run
//  to seconds over a phone connection, and a swipe that visibly waits for the network feels broken
//  even when it's working — so the row moves now and rolls back if the server disagrees.
//

import Foundation
import Observation

/// What a message list is showing. "All Inboxes" is a real destination in Mail, not a filter, so it
/// gets to be a scope rather than a special case threaded through every call. Flagged and VIP are the
/// smart mailboxes — searches with a fixed shape, deduplicated into scopes so their lists get the
/// same selection/swipe/paging machinery as any other mailbox.
enum MailScope: Hashable {
    case allInboxes
    case flagged
    case vip
    case mailbox(Mailbox)

    var title: String {
        switch self {
        case .allInboxes: return "All Inboxes"
        case .flagged: return "Flagged"
        case .vip: return "VIP"
        case .mailbox(let box): return box.name
        }
    }

    var account: String? {
        switch self {
        case .allInboxes, .flagged, .vip: return nil
        case .mailbox(let box): return box.account
        }
    }

    var path: String? {
        switch self {
        case .allInboxes, .flagged, .vip: return nil
        case .mailbox(let box): return box.path
        }
    }

    /// A smart mailbox spans every account; a named mailbox belongs to exactly one. Only a real
    /// mailbox can be written to or moved out of.
    var isUnified: Bool {
        switch self {
        case .allInboxes, .flagged, .vip: return true
        case .mailbox: return false
        }
    }

    var isFlaggedFilter: Bool { self == .flagged }
    var isVipFilter: Bool { self == .vip }
}

@MainActor
@Observable
final class MessageListModel {
    let scope: MailScope

    private(set) var messages: [MailMessage] = []
    private(set) var failures: [MailAccountFailure] = []
    private(set) var hasMore = false
    /// Opaque, server-issued. Held rather than derived because only the server knows where each
    /// account's page ended — see MailClient.messages.
    private var cursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadError: String?
    private(set) var hasLoaded = false
    private(set) var lastUpdated: Date?

    /// The live search field. Typing filters what's already loaded; submitting asks the server, which
    /// is the only way to reach mail older than the current page.
    var searchText = "" {
        didSet { if searchText.isEmpty && !serverSearch.isEmpty { serverSearch = "" } }
    }
    private(set) var serverSearch = ""
    var showUnreadOnly = false

    private let client = MailClient()
    private let pageSize = 50

    init(scope: MailScope) {
        self.scope = scope
    }

    // MARK: - Derived

    /// Local narrowing on top of whatever the server returned. Kept separate from `messages` so a
    /// search never destroys the loaded page — clearing the field restores the list instantly.
    var visibleMessages: [MailMessage] {
        var list = messages
        if showUnreadOnly { list = list.filter { !$0.seen } }

        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle != serverSearch else { return list }

        return list.filter {
            $0.subject.localizedCaseInsensitiveContains(needle)
                || $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.fromAddress.localizedCaseInsensitiveContains(needle)
                || $0.snippet.localizedCaseInsensitiveContains(needle)
        }
    }

    var unreadCount: Int { messages.filter { !$0.seen }.count }

    /// Mail's footer line. A timestamp people can act on beats a spinner they can't.
    var updatedLabel: String {
        guard let lastUpdated else { return "" }
        if Date().timeIntervalSince(lastUpdated) < 60 { return "Updated Just Now" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return "Updated \(f.string(from: lastUpdated))"
    }

    // MARK: - Loading

    func load(settings: AppSettings) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let payload = try await fetch(cursor: nil, settings: settings)
            messages = payload.messages
            failures = payload.failures
            hasMore = payload.hasMore
            cursor = payload.cursor
            loadError = nil
            lastUpdated = Date()
        } catch {
            loadError = MailStore.message(for: error)
        }
        hasLoaded = true
    }

    /// Paged from where the server said the last page ended. Guarded against re-entry because the
    /// list triggers it from `onAppear` of the last row, which can fire several times in one scroll.
    func loadMore(settings: AppSettings) async {
        guard hasMore, !isLoading, !isLoadingMore, let cursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let payload = try await fetch(cursor: cursor, settings: settings)
            let known = Set(messages.map(\.id))
            let fresh = payload.messages.filter { !known.contains($0.id) }
            messages.append(contentsOf: fresh)
            self.cursor = payload.cursor
            // Stop on a page that added nothing new, even if the server still claims more. Without
            // this a cursor that fails to advance would spin forever against the bottom of the list.
            hasMore = payload.hasMore && !fresh.isEmpty && payload.cursor != nil
        } catch {
            // A failed page is not a failed list — leave what's on screen and let them pull again.
            hasMore = false
        }
    }

    /// Runs the search server-side, reaching mail beyond the loaded page.
    func submitSearch(settings: AppSettings) async {
        serverSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        await load(settings: settings)
    }

    private func fetch(cursor: String?, settings: AppSettings) async throws -> MessagesPayload {
        try await client.messages(
            account: scope.account,
            mailbox: scope.path,
            limit: pageSize,
            cursor: cursor,
            search: serverSearch.isEmpty ? nil : serverSearch,
            unreadOnly: showUnreadOnly,
            flaggedOnly: scope.isFlaggedFilter,
            vipOnly: scope.isVipFilter,
            endpoint: MailClient.endpoint(from: settings.endpoint),
            token: settings.token
        )
    }

    // MARK: - Acting on messages

    func setSeen(_ message: MailMessage, _ seen: Bool, settings: AppSettings) async {
        await applyFlag(message, seen: seen, flagged: nil, settings: settings)
    }

    func setFlagged(_ message: MailMessage, _ flagged: Bool, settings: AppSettings) async {
        await applyFlag(message, seen: nil, flagged: flagged, settings: settings)
    }

    private func applyFlag(_ message: MailMessage, seen: Bool?, flagged: Bool?, settings: AppSettings) async {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previous = messages[index]

        if let seen { messages[index].seen = seen }
        if let flagged { messages[index].flagged = flagged }

        do {
            try await client.setFlags(
                account: message.account,
                mailbox: message.mailbox,
                uids: [message.uid],
                seen: seen,
                flagged: flagged,
                endpoint: MailClient.endpoint(from: settings.endpoint),
                token: settings.token
            )
        } catch {
            // Put it back. A row that silently disagrees with the server is worse than one that
            // visibly snaps back, because only the second tells you to try again.
            if let index = messages.firstIndex(where: { $0.id == previous.id }) {
                messages[index] = previous
            }
            loadError = MailStore.message(for: error)
        }
    }

    /// `role` is "trash", "archive" or "junk". A move, never an expunge — Mail's trash button puts
    /// things in Trash, and an IMAP delete would be genuinely unrecoverable from a swipe.
    func move(_ targets: [MailMessage], to role: String, settings: AppSettings) async {
        guard !targets.isEmpty else { return }
        let removed = messages
        let ids = Set(targets.map(\.id))
        messages.removeAll { ids.contains($0.id) }

        // Grouped because a unified inbox's selection can span accounts, and each account's UIDs are
        // only meaningful against its own mailbox.
        let groups = Dictionary(grouping: targets) { MailboxRef(account: $0.account, mailbox: $0.mailbox) }

        do {
            for (ref, group) in groups {
                try await client.move(
                    account: ref.account,
                    mailbox: ref.mailbox,
                    uids: group.map(\.uid),
                    to: role,
                    endpoint: MailClient.endpoint(from: settings.endpoint),
                    token: settings.token
                )
            }
        } catch {
            messages = removed
            loadError = MailStore.message(for: error)
        }
    }

    func markAllRead(settings: AppSettings) async {
        let unread = messages.filter { !$0.seen }
        guard !unread.isEmpty else { return }

        let previous = messages
        for index in messages.indices { messages[index].seen = true }

        let groups = Dictionary(grouping: unread) { MailboxRef(account: $0.account, mailbox: $0.mailbox) }
        do {
            for (ref, group) in groups {
                try await client.setFlags(
                    account: ref.account,
                    mailbox: ref.mailbox,
                    uids: group.map(\.uid),
                    seen: true,
                    flagged: nil,
                    endpoint: MailClient.endpoint(from: settings.endpoint),
                    token: settings.token
                )
            }
        } catch {
            messages = previous
            loadError = MailStore.message(for: error)
        }
    }

    /// Opening a message marks it read here too, so the list agrees with the detail view without a
    /// full refetch.
    func noteOpened(_ message: MailMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].seen = true
    }

    func dismissError() { loadError = nil }

    private struct MailboxRef: Hashable {
        let account: String
        let mailbox: String
    }
}
