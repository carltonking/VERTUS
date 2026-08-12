//
//  MacInboxView.swift
//  Alfred
//
//  The unified inbox — the root of the Email tab. Every row is mail the Mac
//  already fetched and cached, so the phone renders a list without its own
//  IMAP connection. The account filter, search and every swipe action travel
//  over the WebSocket as JSON-RPC (`mail.*`), the same way RoutinesView talks
//  to the Mac.
//
//  The cloud client (MailboxesView / MessageListView against /api/mail) stays
//  reachable from the toolbar's "Server mailboxes" menu — both share one tab,
//  but the Mac's inbox is the default because it's the same mail Alfred reads.
//

import SwiftUI

struct MacInboxView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    private var store: MacMailStore { .shared }

    @State private var query = ""
    @State private var showingCompose = false
    @State private var showingCloud = false
    @State private var cloudStore = MailStore()
    @State private var cloudPath = NavigationPath()

    var body: some View {
        ZStack {
            palette.background
            content
        }
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingCompose = true
                    } label: {
                        Label("New message", systemImage: "square.and.pencil")
                    }
                    Button {
                        showingCloud = true
                    } label: {
                        Label("Server mailboxes", systemImage: "server.rack")
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(palette.accentBright)
                }
                .disabled(!settings.isConfigured)
                .accessibilityLabel("New message")
            }
        }
        .navigationDestination(for: MacMailMessage.self) { message in
            MacMessageDetailView(message: message)
        }
        .sheet(isPresented: $showingCompose) {
            MacComposeView()
        }
        .sheet(isPresented: $showingCloud) {
            NavigationStack {
                MailboxesView(store: cloudStore, path: $cloudPath)
                    .navigationDestination(for: MailScope.self) { scope in
                        MessageListView(store: cloudStore, scope: scope)
                    }
            }
        }
        .task { await load() }
        .onChange(of: AlfredWebSocketClient.shared.isConnected) { _, connected in
            // RootView mounts every page up front, so the initial .task can run
            // before the socket connects — and load() politely declines then.
            // The moment the link comes up, load for real.
            if connected { Task { await load() } }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !store.canTalkToMac {
            notConnected
        } else if !store.backendAvailable {
            backendMissing
        } else if store.accounts.isEmpty && !store.isLoading {
            noAccounts
        } else {
            inboxList
        }
    }

    private var notConnected: some View {
        emptyState(
            icon: "wifi.slash",
            title: "Not connected",
            message: "Mail lives on your Mac. Connect Alfred in Settings and your inbox will appear here.")
    }

    private var backendMissing: some View {
        emptyState(
            icon: "envelope.triangle",
            title: "Mail isn't set up",
            message: "Alfred's Mac doesn't have the mail backend (Himalaya) available. Install it or check the config on the Mac.")
    }

    private var noAccounts: some View {
        emptyState(
            icon: "envelope.badge",
            title: "No mail accounts",
            message: "Add an account to the Himalaya config on your Mac and it'll show up here after the next sync.")
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    // MARK: - Inbox

    private var inboxList: some View {
        List {
            if let error = store.lastError {
                errorRow(error)
            }

            if !store.accounts.isEmpty {
                Section {
                    accountFilter
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                if store.messages.isEmpty && !store.isLoading {
                    VStack(spacing: 0) {
                        Spacer().frame(height: 60)
                        Image(systemName: "tray")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(palette.textFaint)
                        Text("No messages")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.textPrimary)
                            .padding(.top, 12)
                        Text(query.isEmpty
                             ? "Pull to refresh, or check back after Alfred's next sync."
                             : "Nothing matches “\(query)”.")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                            .padding(.horizontal, 30)
                        Spacer().frame(height: 60)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(store.messages) { message in
                        NavigationLink(value: message) {
                            messageRow(message)
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await store.markRead(message, read: !message.seen) }
                            } label: {
                                Label(message.seen ? "Unread" : "Read",
                                      systemImage: message.seen ? "envelope.badge" : "checkmark")
                            }
                            .tint(palette.accent)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await store.trash(message) }
                            } label: {
                                Label("Trash", systemImage: "trash.fill")
                            }
                            Button {
                                Task { await store.archive(message) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(palette.accentDeep)
                            Button {
                                Task { await store.setFlag(message, flagged: !message.flagged) }
                            } label: {
                                Label(message.flagged ? "Unflag" : "Flag",
                                      systemImage: message.flagged ? "star.slash" : "star")
                            }
                            .tint(palette.textFaint)
                        }
                    }
                }
            } header: {
                if store.isSyncing {
                    HStack(spacing: 8) {
                        ProgressView().tint(palette.accentBright)
                        Text("Syncing with the Mac…")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .textCase(nil)
                } else if store.lastSyncedAt > 0 {
                    Text("Synced \(timeAgo(store.lastSyncedAt))")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search mail")
        .refreshable { await store.load(forceSync: true) }
        // .task(id:) cancels the in-flight search when the query changes, so a
        // slow earlier response can never overwrite a newer one.
        .task(id: query) { await store.search(query) }
    }

    /// Horizontal filter chips: All + one per account.
    private var accountFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", accountID: nil)
                ForEach(store.accounts) { account in
                    filterChip(label: account.shortLabel, accountID: account.id)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func filterChip(label: String, accountID: String?) -> some View {
        let isSelected = store.selectedAccountID == accountID
        return Button {
            store.selectedAccountID = accountID
            Task { await store.reloadInbox() }
        } label: {
            HStack(spacing: 6) {
                if let accountID {
                    Image(systemName: store.accounts.first { $0.id == accountID }?.icon ?? "at.circle.fill")
                        .font(.system(size: 11))
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isSelected ? palette.backgroundTop : palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? palette.accentBright : palette.surface.opacity(0.7))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.clear : palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private func messageRow(_ message: MacMailMessage) -> some View {
        HStack(spacing: 12) {
            avatar(for: message)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.displayName)
                        .font(.system(size: 15, weight: message.seen ? .regular : .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    if let account = store.account(for: message) {
                        Text(account.shortLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.textFaint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.surfaceBorder.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 4)
                    if message.flagged {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(palette.accent)
                    }
                    Text(timeLabel(message.date))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .lineLimit(1)
                }

                Text(message.subject)
                    .font(.system(size: 14, weight: message.seen ? .regular : .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9))
                            .foregroundStyle(palette.textFaint)
                    }
                    Text(message.snippet.isEmpty ? "No preview" : message.snippet)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.surfaceBorder.opacity(0.6), lineWidth: 1))
    }

    private func avatar(for message: MacMailMessage) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Text(message.initials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accentBright)
                .frame(width: 36, height: 36)
                .background(palette.accent.opacity(0.18))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(palette.surfaceBorder, lineWidth: 1))

            if !message.seen {
                Circle()
                    .fill(palette.accentBright)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(palette.backgroundTop, lineWidth: 1.5))
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(palette.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Formatting

    private func timeLabel(_ timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return "" }
        return MailDate.listLabel(Date(timeIntervalSince1970: timestamp))
    }

    private func timeAgo(_ timestamp: TimeInterval) -> String {
        let minutes = Int(max(0, Date().timeIntervalSince1970 - timestamp) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes)m ago"
        default: return "\(minutes / 60)h ago"
        }
    }

    private func load() async {
        guard store.canTalkToMac else { return }
        // Every call fetches fresh: the .task runs once, but the onChange below
        // fires again on each reconnect, and a fresh load then is exactly right.
        await store.load()
    }
}
