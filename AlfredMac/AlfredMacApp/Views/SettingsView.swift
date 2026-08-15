//
//  SettingsView.swift
//  AlfredMacApp
//
//  The macOS companion's settings. Where the iOS SettingsView mirrors every
//  Mac-backed feature, this one focuses on what the companion itself needs to
//  reach Alfred, plus the Mac's own model world:
//
//    * Relay — the cloud address + app token (the "relay endpoint/token").
//    * Direct link — the Mac's socket host/port, with live status.
//    * Model mode — cloud vs local (ProviderKeyRing).
//    * API keys — the provider key ring (ProviderKeyRing).
//
//  The feature settings (Routines, Code, NYU, Taste, Memory, Homework,
//  Optimization…) arrive with Session 3's feature views.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    /// The Mac's provider key ring and model mode — shared singletons, observed
    /// so key adds/removals and the active-key star reflow immediately.
    @ObservedObject private var keyRing = ProviderKeyRing.shared

    @State private var testState: TestState = .idle
    @State private var socketTestState: SocketTestState = .idle

    /// Cloud vs local, seeded from the Mac's persisted choice.
    @State private var modelMode = ProviderKeyRing.persistedModelMode()

    /// The add-key editor.
    @State private var newProvider: LLMProvider = .gemini
    @State private var newKey = ""

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

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section {
                        TextField("alfredassistant.vercel.app", text: $settings.host)
                            .autocorrectionDisabled()
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.host")
                            .onChange(of: settings.host) { testState = .idle }
                    } header: {
                        Text("Address")
                    } footer: {
                        Text("Where Alfred is deployed. Requests go to \\(settings.resolvedEndpointDescription).")
                    }

                    Section {
                        SecureField("APP_TOKEN", text: $settings.token)
                            .autocorrectionDisabled()
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.token")
                            .onChange(of: settings.token) { testState = .idle }
                    } header: {
                        Text("App token")
                    } footer: {
                        Text("Must match APP_TOKEN in the deployment's environment. Stored in the Keychain, never in a backup.")
                    }

                    connectionSection

                    Section {
                        TextField("Auto-discovered", text: $settings.socketHost)
                            .autocorrectionDisabled()
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
                        Text("The live link to your Mac — streaming chat, briefings and updates without a cloud relay. Left blank, Alfred finds the Mac automatically over mDNS or Tailscale. The link is plain ws:// (the Mac's server has no TLS), so a pasted wss:// address is downgraded. Leave the port empty for the default (\\(AlfredWebSocketClient.defaultPort)).")
                    }

                    Section {
                        Picker("Model mode", selection: $modelMode) {
                            ForEach(ModelMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .onChange(of: modelMode) { _, mode in
                            ProviderKeyRing.persistModelMode(mode)
                        }
                    } header: {
                        Text("Model")
                    } footer: {
                        Text("Cloud uses the provider keys below (with Hermes' fallback chain); Local drives Alfred with the Ollama models on this Mac. The menu-bar app applies the choice to Hermes' config — it takes effect on the next turn.")
                    }

                    Section {
                        if keyRing.keys.isEmpty {
                            Text("No API keys yet. Add a free-tier key to give Alfred more room to answer.")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.textSecondary)
                        } else {
                            ForEach(keyRing.keys) { key in
                                HStack(spacing: 8) {
                                    Button {
                                        keyRing.setActive(id: key.id)
                                    } label: {
                                        Image(systemName: keyRing.activeKeyID == key.id ? "star.fill" : "star")
                                            .font(.system(size: 13))
                                            .foregroundStyle(keyRing.activeKeyID == key.id ? palette.accentBright : palette.textFaint)
                                    }
                                    .buttonStyle(.plain)
                                    .help(keyRing.activeKeyID == key.id ? "Active key" : "Make active")

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(key.label)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(palette.textPrimary)
                                        Text("\\(key.provider.displayName) — \\(key.redacted)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(palette.textFaint)
                                    }

                                    Spacer()

                                    Button {
                                        keyRing.remove(id: key.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                            .foregroundStyle(palette.textFaint)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove key")
                                }
                            }
                        }

                        Divider()

                        Picker("Provider", selection: $newProvider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }

                        SecureField("API key", text: $newKey)
                            .autocorrectionDisabled()
                            .foregroundStyle(palette.textPrimary)

                        Button {
                            addKey()
                        } label: {
                            HStack {
                                Text("Add key")
                                Spacer()
                            }
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("API keys")
                    } footer: {
                        Text("Free-tier keys across several LLM companies multiply quota. Alfred rotates to the next key when one hits a limit, and mirrors every stored provider into Hermes' fallback chain.")
                    }
                }
                .formStyle(.grouped)
            }
            .navigationTitle("Settings")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
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
            (icon, text) = ("arrow.triangle.2.circlepath", "Reconnecting… (\\(attempt))")
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

    /// Prove the direct link works end to end: a JSON-RPC ping over the socket.
    private func runSocketTest() {
        socketTestState = .testing
        // Normalise through socketURL so whatever shape was pasted (bare host,
        // host:port, full ws:// URL) resolves to one host+port pair.
        let url = settings.socketURL ?? URL(string: "ws://alfred.local:\\(settings.socketPort)")
        let host = url?.host ?? "alfred.local"
        let port = url?.port ?? settings.socketPort
        Task {
            // A pinned IP resolves to the Mac's Bonjour name first — exactly
            // like the live connection path does.
            let resolved = await TailscaleConnection().resolveSocketEndpoint(manualHost: host, port: port)
            let testHost = resolved?.host ?? host
            let testPort = resolved?.port ?? port
            let ok = await TailscaleConnection().validateConnection(host: testHost, port: testPort)
            socketTestState = ok
                ? .passed("Alfred's Mac answered on ws://\\(testHost):\\(testPort).")
                : .failed("Nothing answered there. Check the address, make sure the Mac is awake, and that the socket server is running.")
        }
    }

    // MARK: - Provider keys

    private func addKey() {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = keyRing.add(provider: newProvider, key: trimmed)
        newKey = ""
    }
}
