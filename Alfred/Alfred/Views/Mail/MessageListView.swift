//
//  MessageListView.swift
//  Alfred
//
//  One mailbox's messages, with the gestures Mail trained everyone to expect: swipe right to toggle
//  read, swipe left to flag or bin, Edit for multi-select, pull to refresh, search at the top.
//
//  Swipes act immediately and reconcile afterwards (see MessageListModel) — over a phone connection
//  an IMAP round-trip is long enough that a gesture which waits for it reads as a broken gesture.
//

import SwiftUI

struct MessageListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    let store: MailStore

    @State private var model: MessageListModel
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var composing: ComposeView.Context?

    init(store: MailStore, scope: MailScope) {
        self.store = store
        _model = State(initialValue: MessageListModel(scope: scope))
    }

    private var isEditing: Bool { editMode.isEditing }

    private var selectedMessages: [MailMessage] {
        model.messages.filter { selection.contains($0.id) }
    }

    var body: some View {
        @Bindable var model = model

        ZStack {
            palette.background

            if model.hasLoaded && model.visibleMessages.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle(model.scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .onSubmit(of: .search) {
            Task { await model.submitSearch(settings: settings) }
        }
        .environment(\.editMode, $editMode)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .navigationDestination(for: MailMessage.self) { message in
            MessageDetailView(store: store, model: model, message: message)
        }
        .sheet(item: $composing) { context in
            ComposeView(store: store, context: context)
        }
        .task {
            if !model.hasLoaded { await model.load(settings: settings) }
        }
        .refreshable {
            await model.load(settings: settings)
            await store.refresh(settings: settings)
        }
        .alert(
            "Mail",
            isPresented: Binding(get: { model.loadError != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.loadError ?? "")
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            if !model.failures.isEmpty {
                Section {
                    ForEach(model.failures) { failure in
                        MailErrorRow(text: "\(failure.account): \(failure.error)")
                    }
                }
            }

            ForEach(model.visibleMessages) { message in
                row(for: message)
            }

            if model.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .onAppear {
                    Task { await model.loadMore(settings: settings) }
                }
            }

            if !model.updatedLabel.isEmpty {
                Text(model.updatedLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(for message: MailMessage) -> some View {
        NavigationLink(value: message) {
            MessageRow(message: message, showsAccount: model.scope.isUnified)
        }
        .listRowBackground(palette.surface.opacity(selection.contains(message.id) ? 0.9 : 0.35))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await model.setSeen(message, !message.seen, settings: settings) }
            } label: {
                Label(
                    message.seen ? "Unread" : "Read",
                    systemImage: message.seen ? "envelope.badge.fill" : "envelope.open.fill"
                )
            }
            .tint(palette.accentDeep)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await model.move([message], to: "trash", settings: settings) }
            } label: {
                Label("Trash", systemImage: "trash.fill")
            }

            Button {
                Task { await model.setFlagged(message, !message.flagged, settings: settings) }
            } label: {
                Label(message.flagged ? "Unflag" : "Flag", systemImage: "flag.fill")
            }
            .tint(palette.accent)

            Button {
                Task { await model.move([message], to: "archive", settings: settings) }
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(palette.accentDeep)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(isEditing ? "Done" : "Edit") {
                withAnimation {
                    editMode = isEditing ? .inactive : .active
                    if !isEditing { selection.removeAll() }
                }
            }
            .accessibilityIdentifier("mail.edit")
        }
    }

    // MARK: - Bottom bar

    /// The bottom bar renders as a `.safeAreaInset` rather than a `.bottomBar` toolbar item:
    /// with EditMode active, SwiftUI hands the bottom toolbar to a UIKit-backed toolbar that
    /// attaches to the hosting controller and stops accepting hits (buttons exist but are not
    /// tappable). A plain inset view stays above the tab bar and stays hittable in both states.
    @ViewBuilder
    private var bottomBar: some View {
        if isEditing {
            HStack {
                Button("Mark Read") {
                    Task {
                        for message in selectedMessages where !message.seen {
                            await model.setSeen(message, true, settings: settings)
                        }
                        finishEditing()
                    }
                }
                .disabled(selection.isEmpty)

                Spacer()

                Button("Archive") {
                    Task {
                        await model.move(selectedMessages, to: "archive", settings: settings)
                        finishEditing()
                    }
                }
                .disabled(selection.isEmpty)

                Spacer()

                Button("Trash", role: .destructive) {
                    Task {
                        await model.move(selectedMessages, to: "trash", settings: settings)
                        finishEditing()
                    }
                }
                .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(palette.backgroundTop)
            .overlay(alignment: .top) {
                Divider().overlay(palette.surfaceBorder)
            }
        } else {
            HStack {
                Button {
                    model.showUnreadOnly.toggle()
                    Task { await model.load(settings: settings) }
                } label: {
                    Image(systemName: model.showUnreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(model.showUnreadOnly ? "Showing unread only" : "Filter")

                Spacer()

                Text(model.showUnreadOnly ? "Unread" : "\(model.unreadCount) unread")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)

                Spacer()

                Button {
                    composing = .fresh
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
    }

    private func finishEditing() {
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: model.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(palette.textFaint)

            Text(model.searchText.isEmpty ? "No Mail" : "No Results")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textSecondary)

            if !model.searchText.isEmpty && model.searchText != model.serverSearch {
                Text("Press return to search the whole mailbox.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
            Spacer()
        }
    }
}
