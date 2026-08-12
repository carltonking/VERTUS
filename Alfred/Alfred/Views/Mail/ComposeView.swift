//
//  ComposeView.swift
//  Alfred
//
//  Writing mail — a new message, a reply, a forward, or a reply Alfred drafts for you.
//
//  Alfred's draft lands in the editor rather than in the outbox. That's the same draft-and-confirm
//  rule the Telegram flow follows and the product promise generally: Alfred prepares, the owner
//  sends. Nothing here can put mail on the wire without the Send button being pressed.
//

import SwiftUI

struct ComposeView: View {
    enum Context: Identifiable, Hashable {
        case fresh
        case reply(MailMessage, draftWithAlfred: Bool)
        case forward(MailMessage)

        var id: String {
            switch self {
            case .fresh: return "fresh"
            case .reply(let m, let alfred): return "reply-\(m.id)-\(alfred)"
            case .forward(let m): return "forward-\(m.id)"
            }
        }

        var original: MailMessage? {
            switch self {
            case .fresh: return nil
            case .reply(let m, _): return m
            case .forward(let m): return m
            }
        }

        var wantsAlfredDraft: Bool {
            if case .reply(_, let alfred) = self { return alfred }
            return false
        }

        var title: String {
            switch self {
            case .fresh: return "New Message"
            case .reply: return "Reply"
            case .forward: return "Forward"
            }
        }
    }

    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: MailStore
    let context: Context

    @State private var account = ""
    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var showCc = false

    @State private var instruction = ""
    @State private var isDrafting = false
    @State private var isSending = false
    @State private var error: String?
    @State private var sent = false

    private var canSend: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty
            && !messageBody.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSending
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    if store.accounts.count > 1 {
                        Section {
                            Picker("From", selection: $account) {
                                ForEach(store.accounts) { candidate in
                                    Text(candidate.address).tag(candidate.label)
                                }
                            }
                        }
                    }

                    Section {
                        field("To", text: $to, keyboard: .emailAddress)
                        if showCc {
                            field("Cc", text: $cc, keyboard: .emailAddress)
                        } else {
                            Button("Add Cc") { showCc = true }
                                .font(.system(size: 15))
                        }
                        field("Subject", text: $subject, keyboard: .default)
                    }

                    if context.wantsAlfredDraft || isDrafting {
                        alfredSection
                    }

                    Section {
                        TextEditor(text: $messageBody)
                            .frame(minHeight: 220)
                            .foregroundStyle(palette.textPrimary)
                            .scrollContentBackground(.hidden)
                            .accessibilityIdentifier("compose.body")
                    }

                    if let error {
                        Section { MailErrorRow(text: error) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(context.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(!canSend)
                            .accessibilityIdentifier("compose.send")
                    }
                }
            }
            .task { await prepare() }
        }
    }

    // MARK: - Alfred

    private var alfredSection: some View {
        Section {
            TextField("What should Alfred say?", text: $instruction, axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(palette.textPrimary)
                .accessibilityIdentifier("compose.instruction")

            Button {
                Task { await draft() }
            } label: {
                HStack {
                    Label(messageBody.isEmpty ? "Draft it" : "Redraft", systemImage: "wand.and.stars")
                    Spacer()
                    if isDrafting { ProgressView() }
                }
            }
            .disabled(isDrafting)
        } header: {
            Text("Alfred")
        } footer: {
            Text("Alfred writes it into the editor below. Nothing sends until you press Send.")
        }
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 58, alignment: .leading)

            TextField("", text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .foregroundStyle(palette.textPrimary)
                .accessibilityLabel(label)
        }
    }

    // MARK: - Setup

    private func prepare() async {
        // Reply from the address it was sent to, not from whichever account happens to be first.
        account = context.original?.account ?? store.accounts.first?.label ?? ""

        guard let original = context.original else { return }

        switch context {
        case .reply:
            to = original.fromAddress
            subject = original.subject.lowercased().hasPrefix("re:") ? original.subject : "Re: \(original.subject)"
        case .forward:
            subject = original.subject.lowercased().hasPrefix("fwd:") ? original.subject : "Fwd: \(original.subject)"
        case .fresh:
            break
        }

        // Quote the original. Fetched rather than reusing the list snippet, which is truncated to a
        // preview and would forward a message with most of it missing.
        let quoted = await originalText(original)
        let header = "On \(MailDate.detailLabel(original.date)), \(original.displayName) wrote:"
        messageBody = "\n\n\(header)\n" + quoted.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")

        if context.wantsAlfredDraft { await draft() }
    }

    private func originalText(_ original: MailMessage) async -> String {
        do {
            let payload = try await MailClient().message(
                account: original.account,
                mailbox: original.mailbox,
                uid: original.uid,
                endpoint: MailClient.endpoint(from: settings.endpoint),
                token: settings.token
            )
            return payload.body.text
        } catch {
            return original.snippet
        }
    }

    private func draft() async {
        guard let original = context.original else { return }
        isDrafting = true
        defer { isDrafting = false }

        do {
            let payload = try await MailClient().draftReply(
                account: original.account,
                mailbox: original.mailbox,
                uid: original.uid,
                instruction: instruction,
                endpoint: MailClient.endpoint(from: settings.endpoint),
                token: settings.token
            )
            if to.isEmpty { to = payload.to }
            if subject.isEmpty { subject = payload.subject }
            // Above the quoted original, where a reply belongs.
            messageBody = payload.body + messageBody
            error = nil
        } catch {
            self.error = MailStore.message(for: error)
        }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }

        do {
            try await MailClient().send(
                account: account,
                to: to,
                cc: cc,
                subject: subject,
                body: messageBody,
                inReplyTo: context.original?.messageId,
                endpoint: MailClient.endpoint(from: settings.endpoint),
                token: settings.token
            )
            sent = true
            dismiss()
        } catch {
            self.error = MailStore.message(for: error)
        }
    }
}
