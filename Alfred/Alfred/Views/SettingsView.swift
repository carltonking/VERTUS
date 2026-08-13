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

    private enum SocketTestState: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    @State private var socketTestState: SocketTestState = .idle

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section {
                        // The project's actual production alias. "alfredai.vercel.app" is a
                        // different deployment entirely, so offering it as the example sent people
                        // to a host that 404s every endpoint.
                        TextField("alfredassistant.vercel.app", text: $settings.host)
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

                    Section {
                        TextField("e.g. 192.168.1.40", text: $settings.voiceHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.voiceHost")
                    } header: {
                        Text("Mac address (voice)")
                    } footer: {
                        Text("The Mac's address on this network — where the voice bridge listens on port 8765. Only needed for talking out loud.")
                    }

                    Section {
                        TextField("Auto-discovered", text: $settings.socketHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.socketHost")

                        HStack {
                            Text("Status")
                            Spacer()
                            connectionStatusLabel
                        }

                        Button {
                            runSocketTest()
                        } label: {
                            HStack {
                                Text("Test direct link")
                                Spacer()
                                if socketTestState == .testing { ProgressView() }
                            }
                        }
                        .disabled(socketTestState == .testing)

                        switch socketTestState {
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
                    } header: {
                        Text("Mac address (direct link)")
                    } footer: {
                        Text("The live link to your Mac — streaming chat, briefings and updates without a cloud relay. Left blank, Alfred finds the Mac automatically over mDNS or Tailscale. If you pin an address, prefer the Mac's name (alfred.local, or its Tailscale name) over its IP — iOS blocks plain ws:// connections to IP addresses, and Alfred resolves an IP pin to the Mac's name automatically. The link is plain ws:// (the Mac's server has no TLS), so a pasted wss:// address is downgraded. Leave the port empty for the default (\(AlfredWebSocketClient.defaultPort)).")
                    }

                    connectionSection

                    Section {
                        NavigationLink {
                            EmailSettingsView()
                        } label: {
                            HStack {
                                Label("Email", systemImage: "envelope.fill")
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.textFaint)
                            }
                        }
                    } header: {
                        Text("Mail preferences")
                    } footer: {
                        Text("Scan frequency, drafting tone, signature, and learning — shared with the Mac over the live link.")
                    }

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

    /// The live state of the socket, rendered from the shared client so Settings
    /// and every other tab agree on what they're showing.
    private var connectionStatusLabel: some View {
        let socket = AlfredWebSocketClient.shared
        let (icon, text): (String, String)
        switch socket.state {
        case .idle:
            (icon, text) = ("circle.dashed", "Not connected")
        case .connecting:
            (icon, text) = ("arrow.triangle.2.circlepath", "Connecting…")
        case .connected:
            (icon, text) = ("checkmark.circle.fill", "Connected")
        case .reconnecting(let attempt):
            (icon, text) = ("arrow.triangle.2.circlepath", "Reconnecting… (\(attempt))")
        case .failed(let message):
            (icon, text) = ("exclamationmark.triangle.fill", message)
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(socket.isConnected ? palette.success : palette.textFaint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(socket.isConnected ? palette.textPrimary : palette.textSecondary)
        }
    }

    /// Prove the direct link works end to end: a JSON-RPC ping over the socket.
    private func runSocketTest() {
        socketTestState = .testing
        // Normalise through socketURL so whatever shape was pasted (bare host,
        // host:port, full ws:// URL) resolves to one host+port pair.
        let url = settings.socketURL ?? URL(string: "ws://alfred.local:\(settings.socketPort)")
        let host = url?.host ?? "alfred.local"
        let port = url?.port ?? settings.socketPort
        Task {
            // A pinned IP is ATS-blocked for ws://, so resolve the Mac's Bonjour
            // name first — exactly like the live connection path does.
            let resolved = await TailscaleConnection().resolveSocketEndpoint(manualHost: host, port: port)
            let testHost = resolved?.host ?? host
            let testPort = resolved?.port ?? port
            let ok = await TailscaleConnection().validateConnection(host: testHost, port: testPort)
            socketTestState = ok
                ? .passed("Alfred's Mac answered on ws://\(testHost):\(testPort).")
                : .failed("Nothing answered there. Check the address, make sure the Mac is awake, and that the socket server is running.")
        }
    }
}
