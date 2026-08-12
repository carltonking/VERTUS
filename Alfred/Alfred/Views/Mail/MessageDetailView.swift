//
//  MessageDetailView.swift
//  Alfred
//
//  One open message: subject, who it's from, the body, and the things you can do about it.
//
//  Opening a message marks it read the way every other mail client does — the list is updated
//  locally at the same time so going back doesn't need a refetch to look right.
//

import SwiftUI

struct MessageDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: MailStore
    let model: MessageListModel
    let message: MailMessage

    @State private var loaded: MailBody?
    @State private var isLoading = true
    @State private var error: String?
    @State private var allowsRemote = false
    @State private var bodyHeight: CGFloat = 1
    @State private var composing: ComposeView.Context?
    @State private var flagged: Bool
    @State private var isVip = false

    init(store: MailStore, model: MessageListModel, message: MailMessage) {
        self.store = store
        self.model = model
        self.message = message
        _flagged = State(initialValue: message.flagged)
    }

    var body: some View {
        ZStack {
            palette.background

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().overlay(palette.surfaceBorder)
                    content
                    attachments
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { bottomBar }
        .sheet(item: $composing) { context in
            ComposeView(store: store, context: context)
        }
        .task { await open() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.subject)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                Text(message.initials)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.backgroundTop)
                    .frame(width: 38, height: 38)
                    .background(palette.accentGradient)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)

                    if !message.fromAddress.isEmpty {
                        Text(message.fromAddress)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }

                    if !message.to.isEmpty {
                        Text("To: \(message.to.joined(separator: ", "))")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textFaint)
                            .lineLimit(2)
                    }

                    if !message.fromAddress.isEmpty {
                        Button {
                            Task { await toggleVip() }
                        } label: {
                            Label(isVip ? "VIP" : "Add to VIP", systemImage: isVip ? "star.fill" : "star")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isVip ? palette.accentBright : palette.textFaint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mail.vipToggle")
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(MailDate.listLabel(message.date))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)

                    if flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accent)
                    }
                }
            }

            Text(MailDate.detailLabel(message.date))
                .font(.system(size: 12))
                .foregroundStyle(palette.textFaint)

            if message.account != message.displayName {
                Text(message.account)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.surface)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView().padding(.vertical, 50)
                Spacer()
            }
        } else if let error {
            MailErrorRow(text: error)
                .padding(16)
        } else if let loaded {
            if let html = loaded.html, !html.isEmpty {
                MailBodyWebView(
                    html: html,
                    allowsRemoteContent: allowsRemote,
                    palette: palette,
                    height: $bodyHeight
                )
                .frame(height: max(bodyHeight, 1))

                if !allowsRemote {
                    Button {
                        allowsRemote = true
                    } label: {
                        Label("Load Remote Content", systemImage: "photo")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.accentBright)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    Text("Images and other remote content are blocked until you ask for them, so opening a message can't quietly tell the sender you read it.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
            } else {
                Text(loaded.text)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    @ViewBuilder
    private var attachments: some View {
        if let loaded, !loaded.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(palette.surfaceBorder)

                Text("\(loaded.attachments.count) Attachment\(loaded.attachments.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.top, 6)

                ForEach(loaded.attachments) { attachment in
                    HStack(spacing: 10) {
                        Image(systemName: attachment.icon)
                            .font(.system(size: 18))
                            .foregroundStyle(palette.accentBright)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.filename)
                                .font(.system(size: 15))
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(1)
                            Text(attachment.sizeLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textFaint)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(palette.surface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Actions

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            HStack(spacing: 0) {
                Button {
                    Task { await toggleFlag() }
                } label: {
                    Image(systemName: flagged ? "flag.slash" : "flag")
                }
                .accessibilityLabel(flagged ? "Unflag" : "Flag")

                Spacer()

                Button {
                    Task {
                        await model.move([message], to: "trash", settings: settings)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Move to Trash")

                Spacer()

                Button {
                    composing = .reply(message, draftWithAlfred: false)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .accessibilityLabel("Reply")

                Spacer()

                Button {
                    composing = .forward(message)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .accessibilityLabel("Forward")

                Spacer()

                // The reason this is Alfred's mail client and not just a mail client.
                Button {
                    composing = .reply(message, draftWithAlfred: true)
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .accessibilityLabel("Ask Alfred to draft a reply")
                .accessibilityIdentifier("mail.alfredReply")
            }
        }
    }

    private func open() async {
        model.noteOpened(message)

        if !message.fromAddress.isEmpty {
            if let vips = try? await MailClient().vips(
                endpoint: MailClient.endpoint(from: settings.endpoint),
                token: settings.token
            ) {
                isVip = vips.contains(message.fromAddress.lowercased())
            }
        }

        do {
            let payload = try await MailClient().message(
                account: message.account,
                mailbox: message.mailbox,
                uid: message.uid,
                endpoint: MailClient.endpoint(from: settings.endpoint),
                token: settings.token
            )
            loaded = payload.body
            error = nil
        } catch {
            self.error = MailStore.message(for: error)
        }
        isLoading = false

        if !message.seen {
            await model.setSeen(message, true, settings: settings)
        }
    }

    private func toggleFlag() async {
        flagged.toggle()
        await model.setFlagged(message, flagged, settings: settings)
    }

    private func toggleVip() async {
        let target = !isVip
        isVip = target
        do {
            try await MailClient().setVip(
                address: message.fromAddress,
                set: target,
                endpoint: MailClient.endpoint(from: settings.endpoint),
                token: settings.token
            )
        } catch {
            // Put it back and say why — a star that silently disagrees with the server is worse
            // than one that visibly snaps back.
            isVip = !target
            self.error = MailStore.message(for: error)
        }
    }
}
