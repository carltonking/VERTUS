//
//  SettingsView.swift
//  Alfred
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ZStack {
                Theme.background

                Form {
                    Section {
                        TextField("alfredai.vercel.app", text: $settings.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .foregroundStyle(Theme.textPrimary)
                            .onChange(of: settings.host) { testState = .idle }
                    } header: {
                        Text("Address")
                    } footer: {
                        Text("Where Alfred is deployed. Requests go to \(settings.resolvedEndpointDescription).")
                    }

                    Section {
                        SecureField("APP_TOKEN", text: $settings.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(Theme.textPrimary)
                            .onChange(of: settings.token) { testState = .idle }
                    } header: {
                        Text("App token")
                    } footer: {
                        Text("Must match APP_TOKEN in the deployment's environment. Stored in the iPhone's Keychain, never in a backup.")
                    }

                    Section {
                        Button {
                            runTest()
                        } label: {
                            HStack {
                                Text("Test connection")
                                Spacer()
                                if testState == .testing { ProgressView() }
                            }
                        }
                        .disabled(!settings.isConfigured || testState == .testing)

                        switch testState {
                        case .passed(let detail):
                            Label {
                                Text(detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                            }
                        case .failed(let detail):
                            Label {
                                Text(detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.danger)
                            }
                        case .idle, .testing:
                            EmptyView()
                        }
                    } footer: {
                        Text("Asks Alfred which AI backends are up — proves the address, the token, and that he has a brain behind him.")
                    }

                    Section {
                        LabeledContent("What Alfred can do here") {
                            EmptyView()
                        }
                        capability("Answer questions", available: true)
                        capability("Read your calendar", available: true)
                        capability("Add calendar events", available: true)
                        capability("Look up news and the web", available: true)
                        capability("Email, syllabus, routines, video", available: false)
                    } footer: {
                        Text("Greyed-out flows need several messages back and forth, which the app's endpoint can't do yet — they remain on Telegram for now. Anything needing the Mac itself (iMessage, files, screen) is declined honestly rather than guessed at.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accentBright)
        .preferredColorScheme(.dark)
    }

    private func capability(_ name: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Theme.success : Theme.textFaint)
            Text(name)
                .foregroundStyle(available ? Theme.textPrimary : Theme.textFaint)
            Spacer()
        }
    }

    private func runTest() {
        testState = .testing
        Task {
            do {
                let reply = try await AlfredClient().testConnection(
                    endpoint: settings.endpoint,
                    token: settings.token
                )
                testState = .passed(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                testState = .failed(description)
            }
        }
    }
}
