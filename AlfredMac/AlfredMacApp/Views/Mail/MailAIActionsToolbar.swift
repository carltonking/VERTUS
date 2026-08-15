//
//  MailAIActionsToolbar.swift
//  AlfredMacApp
//
//  The three ✨ actions under the message body — the reason this is a copilot,
//  not just a reader:
//
//    Summarize Thread   → a recap of the message and its conversation
//    Draft Reply        → a reply in the owner's learned voice, dropped
//                         straight into the composer where it's still editable
//    Extract Tasks      → the action items the sender is asking for
//
//  Every action runs on the Mac (Hermes) over the socket, shows a spinner on
//  the pill while it works, and lands in its own sheet. Summaries and tasks
//  are cached by the store, so re-opening the message is instant.
//  Ported from the iOS app (Alfred/Alfred/Views/Mail/MailAIActionsToolbar.swift).
//

import SwiftUI

struct MailAIActionsToolbar: View {
    @Environment(\.palette) private var palette

    let message: MacMailMessage

    private var store: MacMailStore { .shared }

    @State private var summarizing = false
    @State private var summary: MailSummaryPayload?
    @State private var showingSummary = false

    @State private var drafting = false
    @State private var draft: MailDraftPayload?
    @State private var showingDraft = false

    @State private var extracting = false
    @State private var tasks: [MailTaskPayload] = []
    @State private var showingTasks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                pill("Summarize", isWorking: summarizing) {
                    runSummarize()
                }
                pill("Draft Reply", isWorking: drafting) {
                    runDraft()
                }
                pill("Extract Tasks", isWorking: extracting) {
                    runTasks()
                }
                Spacer(minLength: 0)
            }
        }
        .sheet(isPresented: $showingSummary) { summarySheet }
        .sheet(isPresented: $showingTasks) { tasksSheet }
        .sheet(isPresented: $showingDraft) {
            // The copilot proposes, the owner disposes: the draft lands in the
            // review screen (Accept & Send / Save as Draft / Revise), never
            // straight in front of a send button.
            if let draft {
                DraftReviewView(message: message, initialDraft: draft)
            }
        }
    }

    // MARK: - Pills

    private func pill(_ label: String, isWorking: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(palette.accentBright)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .medium))
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
        .disabled(isWorking)
    }

    // MARK: - Actions

    private func runSummarize() {
        guard !summarizing else { return }
        summarizing = true
        Task {
            summary = await store.summarize(message)
            summarizing = false
            showingSummary = true
        }
    }

    private func runDraft() {
        guard !drafting else { return }
        drafting = true
        Task {
            draft = await store.draftReply(message)
            drafting = false
            showingDraft = true
        }
    }

    private func runTasks() {
        guard !extracting else { return }
        extracting = true
        Task {
            tasks = await store.extractTasks(message)
            extracting = false
            showingTasks = true
        }
    }

    // MARK: - Sheets

    private var summarySheet: some View {
        NavigationStack {
            ZStack {
                palette.background

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let summary {
                            if !summary.tone.isEmpty {
                                Text(summary.tone)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(palette.textSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(palette.surfaceBorder.opacity(0.6))
                                    .clipShape(Capsule())
                            }
                            ForEach(Array(summary.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "sparkle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(palette.accentBright)
                                        .padding(.top, 4)
                                    Text(bullet)
                                        .font(.system(size: 15))
                                        .foregroundStyle(palette.textPrimary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else {
                            unableState
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
            .navigationTitle("Summary")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSummary = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var tasksSheet: some View {
        NavigationStack {
            ZStack {
                palette.background

                if tasks.isEmpty {
                    unableState
                } else {
                    List {
                        ForEach(tasks) { task in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "square")
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.textFaint)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(palette.textPrimary)
                                    if !task.detail.isEmpty {
                                        Text(task.detail)
                                            .font(.system(size: 13))
                                            .foregroundStyle(palette.textSecondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(palette.surface.opacity(0.55))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Action items")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingTasks = false }
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
            Text("Alfred couldn't do this right now.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Text("He may be busy answering you, or the message may have no body to read. Try again in a moment.")
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
