//
//  SettingsView.swift
//  Alfred
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

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
                palette.background

                Form {
                    themeSection

                    Section {
                        TextField("alfredai.vercel.app", text: $settings.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.host")
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
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.token")
                            .onChange(of: settings.token) { testState = .idle }
                    } header: {
                        Text("App token")
                    } footer: {
                        Text("Must match APP_TOKEN in the deployment's environment. Stored in the iPhone's Keychain, never in a backup.")
                    }

                    connectionSection

                    Section {
                        capability("Answer questions", available: true)
                        capability("Read your calendar", available: true)
                        capability("Add calendar events", available: true)
                        capability("Look up news and the web", available: true)
                        capability("Email, syllabus, routines, video", available: false)
                        capability("Texts, files, screen (needs the Mac)", available: false)
                    } header: {
                        Text("What Alfred can do here")
                    } footer: {
                        Text("Greyed-out flows need several messages back and forth, which this app's endpoint can't do yet — they remain on Telegram. Anything needing the Mac itself is declined honestly rather than guessed at.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        // Tint and colour scheme come from RootView, so every tab agrees on them.
    }

    // MARK: - Theme

    /// AppSettings is a reference type, so this mutates the shared object directly — no Binding
    /// needs threading through.
    private var themeSection: some View {
        Section {
            ForEach(ThemeChoice.allCases) { choice in
                Button {
                    settings.theme = choice
                } label: {
                    HStack(spacing: 12) {
                        swatch(for: choice)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.displayName)
                                .font(.system(size: 16))
                                .foregroundStyle(palette.textPrimary)
                            Text(choice.blurb)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.textSecondary)
                        }

                        Spacer(minLength: 0)

                        if settings.theme == choice {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(palette.accentBright)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("theme.\(choice.rawValue)")
            }
        } header: {
            Text("Theme")
        }
    }

    /// Three stacked circles — ground, surface, accent — so the choice is legible without
    /// applying it first.
    private func swatch(for choice: ThemeChoice) -> some View {
        HStack(spacing: -8) {
            ForEach(Array(choice.swatch.enumerated()), id: \.offset) { _, colour in
                Circle()
                    .fill(colour)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
        }
        .frame(width: 56, alignment: .leading)
    }

    // MARK: - Connection

    private var connectionSection: some View {
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
                        .foregroundStyle(palette.textSecondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.success)
                }
            case .failed(let detail):
                Label {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.danger)
                }
            case .idle, .testing:
                EmptyView()
            }
        } footer: {
            Text("Asks Alfred which AI backends are up — proves the address, the token, and that he has a brain behind him.")
        }
    }

    private func capability(_ name: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? palette.success : palette.textFaint)
            Text(name)
                .foregroundStyle(available ? palette.textPrimary : palette.textFaint)
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
