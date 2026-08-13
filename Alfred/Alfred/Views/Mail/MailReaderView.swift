//
//  MailReaderView.swift
//  Alfred
//
//  The right pane: one open message, Apple Mail's layout with the copilot
//  riding on top. The body renders through the hardened web view (remote
//  content blocked until asked, JS off); above it the AI layer — the
//  classification row ("Needs reply · Friendly, Urgent"), the collapsible ✨
//  summary, and the Summarize / Draft Reply / Extract Tasks toolbar — loads
//  asynchronously after the body, because the model reads on the Mac.
//
//  Opening a message marks it read the way every other mail client does; the
//  list is updated locally at the same time so going back doesn't refetch.
//

import SwiftUI

struct MailReaderView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let message: MacMailMessage

    private var store: MacMailStore { .shared }

    @State private var isFlagged: Bool
    @State private var detail: MacMailMessageDetail?
    @State private var loadFailed = false
    @State private var allowsRemote = false
    @State private var bodyHeight: CGFloat = 200

    // AI layer
    @State private var classification: MailClassificationPayload?
    @State private var summary: MailSummaryPayload?
    @State private var showSummary = false
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

                    if let classification {
                        classificationCard(classification)
                    }

                    if let summary {
                        MailAISummaryPanel(summary: summary, isExpanded: $showSummary)
                    }

                    if let detail {
                        bodyCard(detail)
                        attachmentsCard(detail)
                    } else if loadFailed {
                        failedCard
                    } else {
                        loadingCard
                    }

                    MailAIActionsToolbar(message: message)
                }
                .padding(16)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) { quickReplyBar }
        .sheet(isPresented: $showingReply) {
            MacComposeView(replyTo: message)
        }
        .task { await open() }
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

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(dateLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                    if isFlagged {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.accent)
                    }
                }
            }

            Divider().overlay(palette.surfaceBorder.opacity(0.6))

            Text(message.subject)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            HStack(spacing: 6) {
                Text(message.fromAddress.isEmpty ? message.displayName : message.fromAddress)
                    .lineLimit(1)
                Spacer(minLength: 8)
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

    // MARK: - AI classification row

    private func classificationCard(_ classification: MailClassificationPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.accentBright)
                if let chip = classification.chipKind.text {
                    Text(chip)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(classification.chipKind == .needsReply ? palette.accentBright : palette.textPrimary)
                }
                if !classification.tone.isEmpty {
                    Text(classification.tone)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(palette.surfaceBorder.opacity(0.6))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }

            if !classification.summary.isEmpty {
                Text(classification.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
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
                Task { await open() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.accentBright)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Quick reply

    private var quickReplyBar: some View {
        HStack(spacing: 10) {
            Text(message.initials)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accentBright)
                .frame(width: 28, height: 28)
                .background(palette.accent.opacity(0.18))
                .clipShape(Circle())

            Button {
                showingReply = true
            } label: {
                Text("Reply…")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.surfaceBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.backgroundTop)
        .overlay(alignment: .top) {
            Divider().overlay(palette.surfaceBorder)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    // MARK: - Loading

    private func open() async {
        do {
            if let fetched = await store.messageDetail(for: message) {
                detail = fetched
                loadFailed = false
            } else {
                loadFailed = true
            }
        }

        // The AI layer loads after the body renders — the model reads on the
        // Mac, so the reader shows the message first and lets the panel fill in.
        await loadAI()

        if !message.seen {
            await store.markRead(message, read: true)
        }
    }

    /// Summary and classification for one message can run in parallel (each is
    /// keyed separately in the store's in-flight set). Both degrade to nil
    /// when the Mac's session is busy — the panel simply doesn't appear.
    private func loadAI() async {
        async let classificationTask = store.classify(message)
        async let summaryTask = store.summarize(message)
        let (classificationResult, summaryResult) = await (classificationTask, summaryTask)
        classification = classificationResult
        summary = summaryResult
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
