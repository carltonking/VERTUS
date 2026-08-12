//
//  MailboxesView.swift
//  Alfred
//
//  Mail's root screen: All Inboxes at the top, then each account's own mailboxes.
//
//  The unified inbox comes first because it's the one people actually live in; the per-account
//  mailboxes below exist for when you need to know which address something arrived at.
//

import SwiftUI

struct MailboxesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    let store: MailStore

    @Binding var path: NavigationPath
    @State private var showingAccounts = false
    @State private var composing = false

    var body: some View {
        ZStack {
            palette.background

            if !settings.isConfigured {
                NotConnectedNotice()
            } else if store.hasLoaded && !store.isConfigured {
                noAccountsState
            } else {
                mailboxList
            }
        }
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAccounts = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Accounts")
                .accessibilityIdentifier("mail.accounts")
            }

            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Spacer()
                    Text(store.isLoading ? "Checking for Mail…" : "")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    Button {
                        composing = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!store.isConfigured)
                    .accessibilityLabel("New message")
                }
            }
        }
        .sheet(isPresented: $showingAccounts) {
            MailAccountsView(store: store)
        }
        .sheet(isPresented: $composing) {
            ComposeView(store: store, context: .fresh)
        }
        .task {
            if !store.hasLoaded { await store.refresh(settings: settings) }
        }
        .refreshable { await store.refresh(settings: settings) }
    }

    // MARK: - The list

    private var mailboxList: some View {
        List {
            if let error = store.loadError {
                Section { MailErrorRow(text: error) }
            }

            if !store.failures.isEmpty {
                Section {
                    ForEach(store.failures) { failure in
                        MailErrorRow(text: "\(failure.account): \(failure.error)")
                    }
                } header: {
                    Text("Couldn't sync")
                }
            }

            Section {
                mailboxRow(
                    title: "VIP",
                    icon: "star.fill",
                    unseen: store.vipUnseen,
                    scope: .vip
                )

                mailboxRow(
                    title: "Flagged",
                    icon: "flag.fill",
                    unseen: store.flaggedUnseen,
                    scope: .flagged
                )
            } header: {
                Text("Smart Mailboxes")
            }

            Section {
                if store.inboxes.count > 1 {
                    mailboxRow(
                        title: "All Inboxes",
                        icon: "tray.2.fill",
                        unseen: store.totalUnread,
                        scope: .allInboxes
                    )
                }

                ForEach(store.inboxes) { box in
                    mailboxRow(
                        title: store.accounts.count > 1 ? box.account : "Inbox",
                        icon: box.icon,
                        unseen: box.unseen,
                        scope: .mailbox(box),
                        indented: store.inboxes.count > 1
                    )
                }
            } header: {
                Text("Mailboxes")
            }

            ForEach(store.accounts) { account in
                let others = store.sortedMailboxes(for: account.label).filter { $0.role != "inbox" }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { box in
                            mailboxRow(title: box.name, icon: box.icon, unseen: box.unseen, scope: .mailbox(box))
                        }
                    } header: {
                        Text(account.label)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func mailboxRow(
        title: String,
        icon: String,
        unseen: Int,
        scope: MailScope,
        indented: Bool = false
    ) -> some View {
        Button {
            path.append(scope)
        } label: {
            HStack(spacing: 12) {
                if indented { Spacer().frame(width: 16) }

                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 24)

                Text(title)
                    .foregroundStyle(palette.textPrimary)

                Spacer(minLength: 8)

                if unseen > 0 {
                    Text("\(unseen)")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textSecondary)
                        .monospacedDigit()
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty

    private var noAccountsState: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "envelope.badge.person.crop")
                .font(.system(size: 52))
                .foregroundStyle(palette.accent.opacity(0.7))

            Text("No mail accounts")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)

            Text("Add an iCloud or Gmail account and Alfred will keep your mail here — and be able to read and answer it for you.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)

            Button {
                showingAccounts = true
            } label: {
                Text("Add Account")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.backgroundTop)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(palette.accentGradient)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
            .accessibilityIdentifier("mail.addAccount")

            Spacer()
            Spacer()
        }
    }
}

/// One consistent way to show a failure inside a mail list.
struct MailErrorRow: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.danger)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
        }
    }
}
