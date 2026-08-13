//
//  MacComposeView.swift
//  Alfred
//
//  Writing a message to send from the Mac's mail setup. Works for both new
//  messages and replies: replies come in with the recipient and subject
//  pre-filled, and send via `mail.reply` so the thread stays intact. The From
//  picker is the account list the Mac reported — the default account first.
//

import SwiftUI

struct MacComposeView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Nil = new message; set = reply to this message.
    private let replyTo: MacMailMessage?
    /// An AI-drafted reply to pre-fill (subject + body), still fully editable
    /// — the copilot proposes, the owner disposes.
    private let draft: MailDraftPayload?

    private var store: MacMailStore { .shared }

    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    // Named messageBody, not body: `View.body` is the protocol requirement and
    // a @State with the same name would shadow it (invalid redeclaration).
    @State private var messageBody = ""
    @State private var accountID = ""
    @State private var isSending = false
    @State private var isSaving = false
    @State private var error: String?

    init(replyTo: MacMailMessage? = nil, draft: MailDraftPayload? = nil) {
        self.replyTo = replyTo
        self.draft = draft
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section {
                        Picker("From", selection: $accountID) {
                            ForEach(store.accounts) { account in
                                Text(account.email).tag(account.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .foregroundStyle(palette.textPrimary)

                        TextField("To", text: $to)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("compose.to")

                        if !cc.isEmpty || replyTo != nil {
                            TextField("Cc", text: $cc)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(palette.textPrimary)
                        }

                        TextField("Subject", text: $subject)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("compose.subject")
                    }
                    .listRowBackground(palette.surface.opacity(0.6))

                    Section {
                        TextEditor(text: $messageBody)
                            .frame(minHeight: 180)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("compose.body")
                    }
                    .listRowBackground(palette.surface.opacity(0.6))

                    if let error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.danger)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(replyTo == nil ? "New Message" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(palette.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await saveDraft() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save Draft")
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    .disabled(isSaving || isSending
                              || to.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(!canSend)
                            .foregroundStyle(canSend ? palette.accentBright : palette.textFaint)
                            .accessibilityIdentifier("compose.send")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { prefill() }
    }

    // MARK: - Logic

    private var canSend: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty
            && !accountID.isEmpty
            && !isSending
    }

    /// Pre-fill a reply's recipient, subject and account. Only runs once per
    /// presentation — repeated appearance (e.g. after dismissing) must not
    /// clobber what the user has already typed.
    @State private var didPrefill = false

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true

        if let replyTo {
            to = replyTo.fromAddress
            let base = replyTo.subject
            subject = base.hasPrefix("Re:") ? base : "Re: " + base
            accountID = replyTo.accountID
        } else {
            accountID = store.accounts.first?.id ?? ""
        }

        // An AI draft wins over the mechanical Re: subject and empty body —
        // still editable, just pre-filled by the copilot.
        if let draft {
            if !draft.subject.isEmpty { subject = draft.subject }
            messageBody = draft.body
        }
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        defer { isSending = false }

        do {
            if let replyTo {
                try await store.reply(to: replyTo, body: messageBody)
            } else {
                try await store.send(
                    to: to.trimmingCharacters(in: .whitespaces),
                    cc: cc.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cc,
                    subject: subject,
                    body: messageBody,
                    accountID: accountID)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Save to the account's Drafts mailbox instead of sending.
    private func saveDraft() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.saveDraft(
                to: to.trimmingCharacters(in: .whitespaces),
                cc: cc.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cc,
                subject: subject,
                body: messageBody,
                accountID: accountID)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
