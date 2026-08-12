//
//  MacMessageDetailView.swift
//  Alfred
//
//  The reader for a message from the Mac's inbox. The body is fetched from
//  Himalaya on demand (`mail.message`) — the cache only holds envelopes — so
//  opening a message is the one moment the phone touches the real mail server.
//
//  HTML bodies render through the same hardened web view the cloud client
//  uses (remote content blocked, JS off); plain text is the fallback. Flagging
//  and the More menu (archive/trash) go straight back to the Mac via JSON-RPC.
//

import SwiftUI

struct MacMessageDetailView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let message: MacMailMessage

    private var store: MacMailStore { .shared }

    /// The row's flag state, owned here. `message` is a let copy — toggling
    /// must update this (and push to the store), not read the stale let.
    @State private var isFlagged: Bool
    @State private var detail: MacMailMessageDetail?
    @State private var loadFailed = false
    @State private var allowsRemote = false
    @State private var bodyHeight: CGFloat = 200
    @State private var showingReply = false

    init(message: MacMailMessage) {
        self.message = message
        _isFlagged = State(initialValue: message.flagged)
    }

    var body: some View {
        ZStack {
            palette.background

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard

                    if let detail {
                        bodyCard(detail)
                        attachmentsCard(detail)
                    } else if loadFailed {
                        failedCard
                    } else {
                        loadingCard
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await toggleFlag() }
                } label: {
                    Image(systemName: isFlagged ? "star.fill" : "star")
                        .foregroundStyle(isFlagged ? palette.accent : palette.textSecondary)
                }
                .accessibilityLabel(isFlagged ? "Unflag" : "Flag")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await archive() }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        Task { await trash() }
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    Button {
                        Task { await store.markRead(message, read: !message.seen) }
                    } label: {
                        Label(message.seen ? "Mark as Unread" : "Mark as Read",
                              systemImage: message.seen ? "envelope.badge" : "checkmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Spacer()
                    Button {
                        showingReply = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.accentBright)
                    }
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showingReply) {
            MacComposeView(replyTo: message)
        }
        .task { await load() }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 3) {
                    Text(message.displayName)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                    if let account = store.account(for: message) {
                        Text(account.email)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textFaint)
                    }
                }
            }

            Divider().overlay(palette.surfaceBorder.opacity(0.6))

            Text(message.subject)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            HStack(spacing: 6) {
                Text("\(message.displayName) <\(message.fromAddress)>")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(dateLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    private var avatar: some View {
        Text(message.initials)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.accentBright)
            .frame(width: 42, height: 42)
            .background(palette.accent.opacity(0.18))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    // MARK: - Body

    @ViewBuilder
    private func bodyCard(_ detail: MacMailMessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if detail.hasHTML {
                if allowsRemote {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.success)
                        Text("Remote content enabled")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                        Spacer()
                    }
                } else {
                    Button {
                        allowsRemote = true
                    } label: {
                        Label("Load remote content", systemImage: "globe")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.accentBright)
                    }
                }
                MailBodyWebView(
                    html: detail.bodyHTML,
                    allowsRemoteContent: allowsRemote,
                    palette: palette,
                    height: $bodyHeight)
                .frame(height: bodyHeight)
            } else {
                Text(detail.bodyText.isEmpty ? "This message has no body." : detail.bodyText)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func attachmentsCard(_ detail: MacMailMessageDetail) -> some View {
        if !detail.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.accentBright)
                    Text("Attachments")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(detail.attachments.enumerated()), id: \.offset) { index, attachment in
                        HStack(spacing: 10) {
                            Image(systemName: attachment.icon)
                                .font(.system(size: 14))
                                .foregroundStyle(palette.accentBright)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.filename)
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(1)
                                Text(attachment.sizeLabel)
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.textFaint)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        if index < detail.attachments.count - 1 {
                            Divider().overlay(palette.surfaceBorder.opacity(0.6))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().tint(palette.accentBright)
            Text("Fetching message from your Mac…")
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var failedCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(palette.danger)
            Text("Couldn't open this message.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Button("Try again") {
                loadFailed = false
                Task { await load() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.accentBright)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Actions

    private func load() async {
        guard detail == nil, !loadFailed else { return }
        if let fetched = await store.messageDetail(for: message) {
            detail = fetched
        } else {
            loadFailed = true
        }
    }

    private func toggleFlag() async {
        isFlagged.toggle()
        await store.setFlag(message, flagged: isFlagged)
    }

    private func archive() async {
        await store.archive(message)
        dismiss()
    }

    private func trash() async {
        await store.trash(message)
        dismiss()
    }

    private var dateLabel: String {
        guard message.date > 0 else { return "" }
        return MailDate.detailLabel(Date(timeIntervalSince1970: message.date))
    }
}
