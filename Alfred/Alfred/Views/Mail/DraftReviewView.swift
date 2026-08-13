//
//  DraftReviewView.swift
//  Alfred
//
//  The human-review step between the copilot's proposal and the send button —
//  the rule that makes AI drafting safe. It shows the original email, the
//  generated reply (fully editable), the tone alternatives, and the two paths
//  out: Accept & Send, or Save as Draft. A free-text revise field (system
//  dictation via the keyboard mic covers the voice path) re-runs the draft
//  through Hermes with the instruction, in place.
//
//  Never sends automatically: Send is an explicit button, and the draft is
//  always visible and editable right up to the moment it's tapped.
//

import SwiftUI

struct DraftReviewView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let message: MacMailMessage
    /// Pre-generated draft (from the reader's Draft Reply). Nil = generate
    /// on open.
    let initialDraft: MailDraftPayload?

    private var store: MacMailStore { .shared }

    @State private var draft: MailDraftPayload?
    @State private var generating = false
    @State private var subject = ""
    // Named draftBody, not body: `View.body` is the protocol requirement and a
    // @State with the same name would shadow it (invalid redeclaration).
    @State private var draftBody = ""
    @State private var cc = ""
    @State private var accountID = ""
    @State private var detail: MacMailMessageDetail?
    @State private var showOriginal = false
    @State private var showAlternatives = false
    @State private var alternatives: [MailDraftPayload] = []
    @State private var loadingAlternatives = false
    @State private var revisionPrompt = ""
    @State private var revising = false
    @State private var isSending = false
    @State private var isSaving = false
    @State private var toast: String?
    @State private var error: String?
    @State private var toastTask: Task<Void, Never>?

    init(message: MacMailMessage, initialDraft: MailDraftPayload?) {
        self.message = message
        self.initialDraft = initialDraft
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        originalCard
                        toneChips
                        draftEditor
                        reviseBar
                        footer
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Draft Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) { toastOverlay }
        .sheet(isPresented: $showAlternatives) { alternativesSheet }
        .task { await open() }
    }

    // MARK: - Original email

    private var originalCard: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showOriginal.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                    Text("Original")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer(minLength: 0)
                    Text(message.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .lineLimit(1)
                    Image(systemName: showOriginal ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textFaint)
                }
                Text(message.subject)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(showOriginal ? nil : 1)
                if showOriginal {
                    Text(detail?.bodyText ?? message.snippet)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tone chips

    private var toneChips: some View {
        HStack(spacing: 8) {
            ForEach([("match-context", "Match"), ("formal", "Formal"), ("casual", "Casual")], id: \.0) { tone, label in
                Button {
                    Task { await loadTone(tone) }
                } label: {
                    HStack(spacing: 4) {
                        if generating {
                            ProgressView().controlSize(.mini).tint(palette.accentBright)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: .medium))
                        }
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette.accentBright)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(palette.accent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(generating)
            }
            Spacer(minLength: 0)
            Button {
                Task { await loadAlternatives() }
            } label: {
                Text("Show alternatives")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .underline()
            }
            .buttonStyle(.plain)
            .disabled(loadingAlternatives)
        }
    }

    // MARK: - Draft editor

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Subject", text: $subject)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .padding(14)
                .accessibilityIdentifier("draft.subject")

            Divider().overlay(palette.surfaceBorder.opacity(0.6))

            TextField("Cc", text: $cc)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider().overlay(palette.surfaceBorder.opacity(0.6))

            TextEditor(text: $draftBody)
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                .font(.system(size: 15))
                .foregroundStyle(palette.textPrimary)
                .padding(14)
                .accessibilityIdentifier("draft.body")
        }
        .background(palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    // MARK: - Revise

    private var reviseBar: some View {
        HStack(spacing: 8) {
            TextField("Revise… e.g. \"Make it shorter, say we'll meet Tuesday\"", text: $revisionPrompt)
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(palette.surface.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.surfaceBorder, lineWidth: 1))
                .submitLabel(.done)
                .onSubmit { Task { await revise() } }

            Button {
                Task { await revise() }
            } label: {
                Image(systemName: revising ? "ellipsis" : "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 34, height: 34)
                    .background(palette.accent.opacity(0.14))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(revising || revisionPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Revise draft")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Text("\(draftBody.count) characters")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)

                Spacer(minLength: 0)

                Button {
                    Task { await saveDraft() }
                } label: {
                    Text("Save as Draft")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isSaving || isSending)

                Button {
                    Task { await send() }
                } label: {
                    HStack(spacing: 6) {
                        if isSending {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("Send")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(canSend ? palette.accentBright : palette.textFaint)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("draft.send")
            }
        }
    }

    private var canSend: Bool {
        !draftBody.trimmingCharacters(in: .whitespaces).isEmpty && !isSending
    }

    // MARK: - Alternatives sheet

    private var alternativesSheet: some View {
        NavigationStack {
            ZStack {
                palette.background
                if alternatives.isEmpty && !loadingAlternatives {
                    unableState
                } else {
                    List {
                        ForEach(Array(alternatives.enumerated()), id: \.offset) { index, alternative in
                            Button {
                                adopt(alternative)
                                showAlternatives = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(toneLabel(alternative, index: index))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(palette.accentBright)
                                    Text(alternative.subject)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(palette.textPrimary)
                                    Text(alternative.body)
                                        .font(.system(size: 13))
                                        .foregroundStyle(palette.textSecondary)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(palette.surface.opacity(0.55))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Alternatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showAlternatives = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var unableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text("Alfred couldn't draft right now.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Text("He may be busy, or the Mac may be away. Try again in a moment.")
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toneLabel(_ draft: MailDraftPayload, index: Int) -> String {
        // The Mac returns alternatives in the order formal / casual / match.
        switch index {
        case 0: return "Formal"
        case 1: return "Casual"
        default: return "Match context"
        }
    }

    // MARK: - Toast

    private var toastOverlay: some View {
        Group {
            if let toast {
                Text(toast)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(palette.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toast)
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - Logic

    private func open() async {
        accountID = message.accountID
        if let fetched = await store.messageDetail(for: message) {
            detail = fetched
        }
        if let initialDraft {
            adopt(initialDraft)
        } else if draft == nil {
            await loadTone(store.mailSettings.draftTone)
        }
    }

    private func adopt(_ draft: MailDraftPayload) {
        self.draft = draft
        subject = draft.subject
        draftBody = draft.body
    }

    private func loadTone(_ tone: String) async {
        generating = true
        defer { generating = false }
        if let fresh = await store.draftReply(message, tone: tone) {
            adopt(fresh)
        } else {
            error = "Alfred couldn't draft that tone right now."
        }
    }

    private func loadAlternatives() async {
        guard !loadingAlternatives else { return }
        loadingAlternatives = true
        defer { loadingAlternatives = false }
        alternatives = await store.draftAlternatives(message)
        showAlternatives = true
    }

    private func revise() async {
        let instruction = revisionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !revising else { return }
        revising = true
        defer { revising = false }
        if let revised = await store.reviseDraft(
            message, subject: subject, body: draftBody, instruction: instruction) {
            adopt(revised)
            revisionPrompt = ""
            showToast("Revised")
        } else {
            error = "Alfred couldn't revise that right now."
        }
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await store.reply(
                to: message, body: draftBody,
                subject: subject.trimmingCharacters(in: .whitespaces),
                cc: cc.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cc)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveDraft() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.saveDraft(
                to: message.fromAddress,
                cc: cc.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cc,
                subject: subject,
                body: draftBody,
                accountID: message.accountID)
            showToast("Draft saved")
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
