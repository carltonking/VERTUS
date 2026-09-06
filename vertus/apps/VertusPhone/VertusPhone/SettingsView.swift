import SwiftUI
import VertusKit

/// Hub URL + token. A phone has no shell to set env vars, so this screen is
/// the ONLY way to point the app at a hub: enter the Mac's address
/// (Tailscale IP or LAN IP) and the token from ~/.vertus/token on the Mac.
/// No address is baked in.
struct SettingsView: View {
    @ObservedObject var model: PhoneAppModel
    @EnvironmentObject private var store: FleetStore
    @State private var baseURL: String
    @State private var token: String
    @State private var status = ""

    init(model: PhoneAppModel) {
        self.model = model
        let config = PhoneConfig.load()
        _baseURL = State(initialValue: config.baseURL)
        _token = State(initialValue: config.token)
    }

    var body: some View {
        Form {
            Section("Hub") {
                TextField("Server URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Bearer token (from ~/.vertus/token on your Mac)", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Test connection") {
                    Task { await test() }
                }
            }
            Section {
                if !status.isEmpty {
                    Text(status).font(.footnote)
                        .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                }
            }
            Section("About") {
                LabeledContent("App", value: "VERTUS")
                if store.hubDegraded {
                    LabeledContent("Hub", value: "degraded: \(store.failingSubsystems.joined(separator: ", "))")
                } else {
                    LabeledContent("Hub", value: store.hubHealth == nil ? "unknown" : "healthy")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
    }

    private func save() {
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
            status = "Enter a full URL, e.g. http://100.64.0.5:8787"
            return
        }
        PhoneConfig.save(
            baseURL: url,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        model.reconfigure()
        status = "Saved — reconnected"
    }

    private func test() async {
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
            status = "Enter a full URL first"
            return
        }
        let config = ServerConfig(
            baseURL: url,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let probe = VertusHTTPClient(config: config)
        do {
            let health = try await probe.hubHealth()
            status = "✓ reachable (\(health.status))"
        } catch {
            status = (error as? VertusError)?.localizedDescription
                ?? "Not reachable: \(error.localizedDescription)"
        }
    }
}