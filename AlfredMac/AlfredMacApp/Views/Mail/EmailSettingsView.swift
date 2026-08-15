//
//  EmailSettingsView.swift
//  AlfredMacApp
//
//  The email preferences screen — identical settings to what the Mac would
//  offer, edited here and pushed to the Mac over the socket (`mail.set_settings`)
//  so one screen drives the sweep timer, the drafter and the learning loop on
//  the machine that actually does the work.
//  Ported from the iOS app (Alfred/Alfred/Views/Mail/EmailSettingsView.swift).
//

import SwiftUI

struct EmailSettingsView: View {
    @Environment(\.palette) private var palette

    private var store: MacMailStore { .shared }

    /// Local editable copy; pushed to the Mac on change. Loaded on appear.
    @State private var settings = MailSettingsPayload()
    @State private var loaded = false
    @State private var signatureText = ""

    var body: some View {
        ZStack {
            palette.background

            Form {
                Section {
                    Picker("Scan every", selection: $settings.scanFrequencyMinutes) {
                        ForEach([5, 15, 30, 60], id: \.self) { minutes in
                            Text(minutes == 5 ? "5 minutes" : "\(minutes) minutes")
                                .tag(minutes)
                        }
                    }
                    .onChange(of: settings.scanFrequencyMinutes) { push(fields: ["frequency"]) }
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("Alfred checks every folder — Inbox, Junk, Archive, Sent — for mail that matters.")
                }

                Section {
                    Picker("Drafting tone", selection: $settings.draftTone) {
                        Text("Match context").tag("match-context")
                        Text("Formal").tag("formal")
                        Text("Casual").tag("casual")
                    }
                    .onChange(of: settings.draftTone) { push(fields: ["tone"]) }

                    TextField("Email signature", text: $signatureText, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textPrimary)
                        .onChange(of: signatureText) { push(fields: ["signature"]) }
                } header: {
                    Text("Drafting")
                } footer: {
                    Text("Drafted replies are reviewed before sending — the signature is appended automatically.")
                }

                Section {
                    Toggle("Learn from sent email", isOn: $settings.autoLearnSent)
                        .onChange(of: settings.autoLearnSent) { push(fields: ["autoLearn"]) }
                    Toggle("Notify about important finds", isOn: $settings.notifyOnImportant)
                        .onChange(of: settings.notifyOnImportant) { push(fields: ["notify"]) }
                } header: {
                    Text("Learning & alerts")
                }

                Section {
                    HStack {
                        Text("Revisions learned")
                        Spacer()
                        Text("\(settings.learnedPhraseCount)")
                            .foregroundStyle(palette.textSecondary)
                    }
                    if settings.learnedPhraseCount >= 5 {
                        Label("Revisions available", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.accentBright)
                    }
                } header: {
                    Text("Style profile")
                } footer: {
                    Text("Every message you actually send folds into your writing voice, so drafts keep matching how you really write.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Email")
        .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
        .task { await load() }
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        await store.loadMailSettings()
        settings = store.mailSettings
        signatureText = settings.signatures.values.first ?? ""
    }

    /// Persist locally (so re-opening the screen is instant) and push to the Mac.
    private func push(fields: Set<String>) {
        // Signature edits are pushed with their account key.
        if fields.contains("signature") {
            if let account = settings.signatures.keys.first {
                settings.signatures[account] = signatureText
            } else if let account = store.accounts.first?.id {
                settings.signatures[account] = signatureText
            }
        }
        store.mailSettings = settings
        Task { await store.pushMailSettings(editing: fields) }
    }
}
