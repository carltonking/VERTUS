//
//  MailListView.swift
//  AlfredMacApp
//
//  The center pane: Apple Mail's message list, with the AI layer embedded as
//  the power user feature. One row per message (avatar, sender, subject,
//  snippet, date, unread dot, star), and above it all the natural-language
//  search bar and the subtle classification chips the Mac's copilot produces.
//  Ported from the iOS app (Alfred/Alfred/Views/Mail/MailListView.swift).
//
//  Deviation from iOS: swipe actions don't exist on macOS, so the row actions
//  (read/unread, flag, archive, trash) live on a right-click context menu —
//  same actions, same optimistic-then-reconcile semantics (see MacMailStore).
//

import SwiftUI

struct MailListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    /// Which mailbox view this list is showing. The sidebar drives it; the
    /// account dropdown below writes it back (so the two agree on macOS).
    let scope: MailSidebarItem
    /// The row → reader selection. This view always lives inside the split
    /// view on macOS, so selection is always wired.
    var selection: Binding<MacMailMessage?>?
    /// Lets the account dropdown sync the sidebar's selection back up.
    var onScopeChange: ((MailSidebarItem) -> Void)?

    private var store: MacMailStore { .shared }

    @State private var query = ""
    @State private var aiNote: String?
    @State private var aiSearching = false
    @State private var analyzing = false
    @State private var unreadOnly = false
    @State private var flaggedOnly = false
    @State private var accountFilter: String?
    @State private var showingCompose = false
    @State private var undoToast: UndoToast?
    @State private var undoDismissTask: Task<Void, Never>?
    @State private var pulse = false
    @State private var activeFilter: MailFilter = .all
    @State private var selectedFolderID = ""
    @State private var openedScanItem: MacMailMessage?

    /// The smart filters over the list. `byFolder` switches the row source from
    /// the unified inbox to one folder's cached messages.
    private enum MailFilter: String, CaseIterable, Identifiable {
        case all, unread, flagged, important, needsAction, byFolder
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .unread: return "Unread"
            case .flagged: return "Flagged"
            case .important: return "Important"
            case .needsAction: return "Needs Action"
            case .byFolder: return "By Folder"
            }
        }
    }

    init(scope: MailSidebarItem, selection: Binding<MacMailMessage?>? = nil,
         onScopeChange: ((MailSidebarItem) -> Void)? = nil) {
        self.scope = scope
        self.selection = selection
        self.onScopeChange = onScopeChange
    }

    private var title: String {
        switch scope {
        case .inbox: return "Email"
        case .unread: return "Unread"
        case .flagged: return "Flagged"
        case .account(let id):
            return store.accounts.first { $0.id == id }?.shortLabel ?? "Mailbox"
        }
    }

    /// The smart-folder filters apply over the (account-filtered) cache.
    /// Important / Needs Action need a classification — rows without one drop
    /// out of those filters (the analyze pill invites a sweep to fill them in).
    private var displayedMessages: [MacMailMessage] {
        var result = store.messages
        if unreadOnly { result = result.filter { !$0.seen } }
        if flaggedOnly { result = result.filter { $0.flagged } }
        if activeFilter == .important {
            result = result.filter { message in
                guard let classification = store.classifications[message.id] else { return false }
                return (classification.importance ?? 0) >= 4 || classification.category == "important"
            }
        }
        if activeFilter == .needsAction {
            result = result.filter { message in
                guard let classification = store.classifications[message.id] else { return false }
                return classification.category == "needs_action"
                    || classification.label == "needs_reply"
                    || classification.label == "action_item"
            }
        }
        return result
    }

    var body: some View {
        ZStack {
            palette.background

            if !store.canTalkToMac {
                emptyState(icon: "wifi.slash", title: "Not connected",
                           message: "Mail lives on your Mac. Connect Alfred in Settings and your inbox will appear here.")
            } else if !store.backendAvailable {
                emptyState(icon: "envelope.triangle", title: "Mail isn't set up",
                           message: "Alfred's Mac doesn't have the mail backend (Himalaya) available. Install it or check the config on the Mac.")
            } else if store.accounts.isEmpty && !store.isLoading {
                emptyState(icon: "envelope.badge", title: "No mail accounts",
                           message: "Add an account to the Himalaya config on your Mac and it'll show up here after the next sync.")
            } else if store.isLoading && !store.hasLoaded {
                skeletonRows
            } else {
                list
            }
        }
        .navigationTitle(title)
        .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay(alignment: .bottom) { undoOverlay }
        .sheet(isPresented: $showingCompose) {
            MacComposeView()
        }
        .sheet(item: $openedScanItem) { message in
            NavigationStack {
                MailReaderView(message: message)
            }
        }
        .task {
            apply(scope)
            if !store.hasLoaded { await store.load() }
        }
        .onChange(of: scope) { _, newValue in apply(newValue) }
        .onChange(of: AlfredWebSocketClient.shared.isConnected) { _, connected in
            // RootView mounts every page up front, so the initial .task can run
            // before the socket connects — and load() politely declines then.
            // The moment the link comes up, load for real.
            if connected { Task { await store.load() } }
        }
    }

    // MARK: - Search bar (sticky)

    private var searchBar: some View {
        VStack(spacing: 0) {
            MailSearchView(
                text: $query,
                isSearching: aiSearching,
                note: aiNote,
                onSubmit: runAISearch,
                onClearNote: { aiNote = nil }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().overlay(palette.surfaceBorder)
        }
        .background(palette.backgroundTop)
    }

    private func runAISearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            aiNote = nil
            Task { await store.reloadInbox() }
            return
        }
        aiSearching = true
        Task {
            aiNote = await store.searchAI(trimmed, accountID: store.selectedAccountID)
            aiSearching = false
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if let error = store.lastError {
                errorRow(error)
            }

            filterChipsRow
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if activeFilter == .byFolder {
                folderStripRow
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Section {
                    if store.folderMessages.isEmpty {
                        emptyByFolder
                    } else {
                        ForEach(store.folderMessages) { message in
                            row(for: message)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                } header: { syncHeader }
            } else {
                if activeFilter == .all {
                    MailScanSummaryView(
                        onOpenFolder: openFolder,
                        onOpenItem: openScanItem)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if activeFilter == .all
                    && store.messages.contains(where: { !$0.seen && store.classifications[$0.id] == nil }) {
                    analyzePill
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section {
                    if displayedMessages.isEmpty {
                        emptyInbox
                    } else {
                        ForEach(displayedMessages) { message in
                            row(for: message)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                } header: { syncHeader }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await refresh() }
    }

    /// The "syncing / synced N min ago" list header shared by both modes.
    @ViewBuilder
    private var syncHeader: some View {
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

    private func refresh() async {
        if activeFilter == .byFolder {
            await store.loadFolderMessages(folderID: selectedFolderID)
        } else {
            await store.load(forceSync: true)
            await store.loadScanSummary()
        }
    }

    // MARK: - Filter chips

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MailFilter.allCases) { filter in
                    Button {
                        setFilter(filter)
                    } label: {
                        Text(filter.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(activeFilter == filter ? palette.accentBright : palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(activeFilter == filter ? palette.accent.opacity(0.16) : palette.surface.opacity(0.5))
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(
                                activeFilter == filter ? palette.accent.opacity(0.5) : palette.surfaceBorder,
                                lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 1)
    }

    private func setFilter(_ filter: MailFilter) {
        activeFilter = filter
        unreadOnly = filter == .unread
        flaggedOnly = filter == .flagged
        if filter == .byFolder {
            Task { await store.loadFolderMessages(folderID: selectedFolderID) }
        }
    }

    /// Enter "By Folder" for a folder from the scan header's strip.
    private func openFolder(_ folder: MailFolderStatPayload) {
        selectedFolderID = folder.folderID
        activeFilter = .byFolder
        unreadOnly = false
        flaggedOnly = false
        Task { await store.loadFolderMessages(folderID: folder.folderID) }
    }

    /// Open a scan finding (important / in-junk) in the reader, from the sheet.
    private func openScanItem(_ item: MailScanItemPayload) {
        openedScanItem = MacMailMessage(
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
    }

    /// The folder strip inside By Folder mode, with the current folder marked.
    private var folderStripRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.scanSummary?.folders ?? []) { folder in
                    Button {
                        selectedFolderID = folder.folderID
                        Task { await store.loadFolderMessages(folderID: folder.folderID) }
                    } label: {
                        HStack(spacing: 5) {
                            Text(folder.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selectedFolderID == folder.folderID ? palette.accentBright : palette.textPrimary)
                            if folder.unseen > 0 {
                                Text("\(folder.unseen)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(palette.accentBright)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selectedFolderID == folder.folderID
                                    ? palette.accent.opacity(0.16)
                                    : palette.backgroundTop.opacity(0.6))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(
                            selectedFolderID == folder.folderID ? palette.accent.opacity(0.5) : palette.surfaceBorder,
                            lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 1)
    }

    private var emptyByFolder: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 40)
            Image(systemName: "folder")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text("Nothing in this folder yet")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 10)
            Text("The folder scan hasn't cached it, or it's empty.")
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 5)
                .padding(.horizontal, 30)
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// One-tap, bounded classification of the newest unread mail — the chips
    /// are opt-in, so the inbox never burns model quota without being asked.
    private var analyzePill: some View {
        Button {
            analyzing = true
            Task {
                await store.analyzeTopUnread(5)
                analyzing = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentBright)
                Text(analyzing ? "Analyzing…" : "Analyze inbox")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                if analyzing {
                    ProgressView().controlSize(.small).tint(palette.accentBright)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.accent.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(analyzing)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for message: MacMailMessage) -> some View {
        Group {
            if let selection {
                Button {
                    selection.wrappedValue = message
                } label: {
                    rowContent(message)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: message) {
                    rowContent(message)
                }
            }
        }
        // macOS has no swipe actions; the same actions live here.
        .contextMenu {
            Button {
                Task { await store.markRead(message, read: !message.seen) }
            } label: {
                Label(message.seen ? "Mark as Unread" : "Mark as Read",
                      systemImage: message.seen ? "envelope.badge" : "checkmark")
            }
            Button {
                Task { await store.setFlag(message, flagged: !message.flagged) }
            } label: {
                Label(message.flagged ? "Unflag" : "Flag",
                      systemImage: message.flagged ? "star.slash" : "star")
            }
            Divider()
            Button {
                Task {
                    await store.archive(message)
                    showUndo(message: message, label: "Archived")
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                Task { await store.trash(message) }
            } label: {
                Label("Move to Trash", systemImage: "trash.fill")
            }
        }
    }

    private func rowContent(_ message: MacMailMessage) -> some View {
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

                HStack(spacing: 6) {
                    Text(message.subject)
                        .font(.system(size: 14, weight: message.seen ? .regular : .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9))
                            .foregroundStyle(palette.textFaint)
                    }
                    if let classification = store.classifications[message.id] {
                        chipView(kind: classification.chipKind,
                                 text: classification.chipKind.text ?? "",
                                 confidence: classification.confidencePercent)
                    }
                    Spacer(minLength: 0)
                }

                Text(message.snippet.isEmpty ? "No preview" : message.snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.surfaceBorder.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenDescription(for: message))
    }

    private func chipView(kind: MailChipKind, text: String, confidence: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 8))
            Text(text + (confidence.map { " · \($0)%" } ?? ""))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(kind == .needsReply ? palette.accentBright : palette.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(kind == .needsReply ? palette.accent.opacity(0.2) : palette.surfaceBorder.opacity(0.5))
        .clipShape(Capsule())
        .accessibilityHidden(true)
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

    private func spokenDescription(for message: MacMailMessage) -> String {
        var parts: [String] = []
        if !message.seen { parts.append("Unread") }
        parts.append(message.displayName)
        parts.append(message.subject)
        parts.append(timeLabel(message.date))
        if message.flagged { parts.append("Flagged") }
        if let classification = store.classifications[message.id],
           let chip = classification.chipKind.text {
            parts.append(chip)
        }
        return parts.joined(separator: ". ") + "."
    }

    // MARK: - Skeleton

    private var skeletonRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle()
                        .fill(palette.surfaceBorder.opacity(0.45))
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.surfaceBorder.opacity(0.45))
                            .frame(width: 150, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.surfaceBorder.opacity(0.3))
                            .frame(height: 10)
                            .frame(maxWidth: .infinity)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.surfaceBorder.opacity(0.3))
                            .frame(width: 220, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider().overlay(palette.surfaceBorder.opacity(0.3))
            }
        }
        .opacity(pulse ? 0.45 : 1)
        .onAppear {
            pulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Empty states

    private var emptyInbox: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 50)
            Image(systemName: aiNote != nil || !query.isEmpty ? "magnifyingglass" : "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text(aiNote != nil || !query.isEmpty ? "No Results" : "Inbox zero ✨")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 10)
            Text(aiNote != nil || !query.isEmpty
                 ? "Nothing matched your search."
                 : "Pull to refresh, or check back after Alfred's next sync.")
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 5)
                .padding(.horizontal, 30)
            Spacer().frame(height: 50)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Menu {
                Button {
                    setAccountFilter(nil)
                } label: {
                    if store.selectedAccountID == nil {
                        Label("All Accounts", systemImage: "checkmark")
                    } else {
                        Text("All Accounts")
                    }
                }
                ForEach(store.accounts) { account in
                    Button {
                        setAccountFilter(account.id)
                    } label: {
                        if store.selectedAccountID == account.id {
                            Label(account.shortLabel, systemImage: "checkmark")
                        } else {
                            Text(account.shortLabel)
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Account filter")

            Spacer()

            Text(unreadCountLabel)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)

            Spacer()

            Button {
                showingCompose = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New message")
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(palette.backgroundTop)
        .overlay(alignment: .top) {
            Divider().overlay(palette.surfaceBorder)
        }
    }

    private var unreadCountLabel: String {
        let count = displayedMessages.filter { !$0.seen }.count
        return count == 1 ? "1 unread" : "\(count) unread"
    }

    private func setAccountFilter(_ id: String?) {
        accountFilter = id
        store.selectedAccountID = id
        Task { await store.reloadInbox() }
        let newScope: MailSidebarItem = id.map { .account($0) } ?? .inbox
        onScopeChange?(newScope)
    }

    // MARK: - Undo toast

    private struct UndoToast: Equatable {
        let message: MacMailMessage
        let label: String
    }

    private var undoOverlay: some View {
        Group {
            if let undoToast {
                HStack(spacing: 14) {
                    Text(undoToast.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Button("Undo") {
                        self.undoToast = nil
                        undoDismissTask?.cancel()
                        Task { await store.unarchive(undoToast.message) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accentBright)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 56)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: undoToast)
    }

    private func showUndo(message: MacMailMessage, label: String) {
        undoToast = UndoToast(message: message, label: label)
        undoDismissTask?.cancel()
        undoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            undoToast = nil
        }
    }

    // MARK: - Scope → filters

    private func apply(_ scope: MailSidebarItem) {
        switch scope {
        case .inbox:
            activeFilter = .all
            unreadOnly = false
            flaggedOnly = false
            setFilterAccountSilently(nil)
        case .unread:
            activeFilter = .unread
            unreadOnly = true
            flaggedOnly = false
        case .flagged:
            activeFilter = .flagged
            flaggedOnly = true
            unreadOnly = false
        case .account(let id):
            activeFilter = .all
            unreadOnly = false
            flaggedOnly = false
            setFilterAccountSilently(id)
        }
    }

    /// Same as `setAccountFilter` but without echoing the scope back up — the
    /// sidebar already moved its selection, so writing it again would fight it.
    private func setFilterAccountSilently(_ id: String?) {
        accountFilter = id
        guard store.selectedAccountID != id else { return }
        store.selectedAccountID = id
        Task { await store.reloadInbox() }
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
}
