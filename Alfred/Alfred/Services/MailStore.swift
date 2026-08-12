//
//  MailStore.swift
//  Alfred
//
//  The account and mailbox list — the things that stay true across the whole Email tab.
//
//  Per-mailbox message lists deliberately live elsewhere (MessageListModel): one store holding every
//  message of every mailbox would either refetch constantly or grow without bound, and both show up
//  as the same symptom on a phone — a mail app that gets slower the longer you leave it open.
//

import Foundation
import Observation

@MainActor
@Observable
final class MailStore {
    private(set) var accounts: [MailAccountInfo] = []
    private(set) var providers: [MailProviderInfo] = []
    private(set) var mailboxes: [Mailbox] = []

    /// Unread totals for the smart mailboxes, decoded with defaults when an older deployment omits them.
    private(set) var flaggedUnseen = 0
    private(set) var vipUnseen = 0

    /// Accounts that failed to sync. Shown rather than swallowed — a wrong app password producing an
    /// empty inbox is indistinguishable from having no mail, and only one of those is worth fixing.
    private(set) var failures: [MailAccountFailure] = []

    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Separates "nothing here" from "haven't looked yet", so the empty state doesn't flash on launch.
    private(set) var hasLoaded = false

    private let client = MailClient()

    // MARK: - Derived

    var isConfigured: Bool { !accounts.isEmpty }

    var inboxes: [Mailbox] { mailboxes.filter { $0.role == "inbox" } }

    var totalUnread: Int { inboxes.reduce(0) { $0 + $1.unseen } }

    /// Mailboxes grouped under the account they belong to, in the order the accounts were returned.
    func mailboxes(for account: String) -> [Mailbox] {
        mailboxes.filter { $0.account == account }
    }

    /// Apple Mail's ordering: the standard mailboxes in a fixed sequence, then everything else
    /// alphabetically. Alphabetising the lot would bury Sent under a folder called "Amazon".
    func sortedMailboxes(for account: String) -> [Mailbox] {
        let rank = ["inbox": 0, "drafts": 1, "sent": 2, "junk": 3, "trash": 4, "archive": 5]
        return mailboxes(for: account).sorted { a, b in
            let ra = rank[a.role] ?? 99
            let rb = rank[b.role] ?? 99
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Loading

    func refresh(settings: AppSettings) async {
        guard settings.isConfigured else {
            loadError = MailClient.Failure.notConfigured.errorDescription
            hasLoaded = true
            return
        }

        isLoading = true
        defer { isLoading = false }

        let endpoint = MailClient.endpoint(from: settings.endpoint)
        let token = settings.token

        do {
            let accountsPayload = try await client.accounts(endpoint: endpoint, token: token)
            accounts = accountsPayload.accounts
            providers = accountsPayload.providers

            // No point asking for mailboxes when there's nothing to list them from — and the empty
            // state should read "add an account", not "couldn't reach your mail".
            if accounts.isEmpty {
                mailboxes = []
                failures = []
                loadError = nil
                hasLoaded = true
                return
            }

            let boxes = try await client.mailboxes(endpoint: endpoint, token: token)
            mailboxes = boxes.mailboxes
            failures = boxes.failures
            flaggedUnseen = boxes.smart?.flaggedUnseen ?? 0
            vipUnseen = boxes.smart?.vipUnseen ?? 0
            loadError = nil
        } catch {
            loadError = message(for: error)
        }

        hasLoaded = true
    }

    // MARK: - Accounts

    /// Returns a non-fatal warning when there is one — today, "reading works but sending didn't verify".
    @discardableResult
    func addAccount(
        provider: String,
        address: String,
        password: String,
        label: String?,
        imapHost: String?,
        smtpHost: String?,
        settings: AppSettings
    ) async throws -> String? {
        let result = try await client.addAccount(
            provider: provider,
            address: address,
            password: password,
            label: label,
            imapHost: imapHost,
            smtpHost: smtpHost,
            endpoint: MailClient.endpoint(from: settings.endpoint),
            token: settings.token
        )
        await refresh(settings: settings)
        return result.warning
    }

    /// The Google consent URL to open. The account is added server-side when Google redirects back;
    /// this only fetches the browser address the consent screen starts on.
    func googleLoginURL(settings: AppSettings) async throws -> URL? {
        let raw = try await client.googleLoginURL(endpoint: MailClient.endpoint(from: settings.endpoint), token: settings.token)
        return URL(string: raw)
    }

    func removeAccount(_ account: MailAccountInfo, settings: AppSettings) async throws {
        try await client.removeAccount(
            id: account.id,
            endpoint: MailClient.endpoint(from: settings.endpoint),
            token: settings.token
        )
        await refresh(settings: settings)
    }

    // MARK: - Helpers

    nonisolated static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func message(for error: Error) -> String { Self.message(for: error) }
}
