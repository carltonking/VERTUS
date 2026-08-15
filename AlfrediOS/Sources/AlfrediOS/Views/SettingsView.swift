import SwiftUI

/// Server + model + memory configuration. The API key field writes straight
/// to the Keychain (via `AppSettings` → `KeychainHelper`); the rest are
/// UserDefaults-backed preferences.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Hermes Server") {
                    TextField("Base URL", text: $settings.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Defaults to http://localhost:8080 (works in the simulator). On a device, use your Mac's LAN IP or a remote URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Model") {
                    TextField("Model", text: $settings.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("API Key") {
                    SecureField("API Key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Stored in the iOS Keychain — never in UserDefaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Memory") {
                    TextField("Vault Path", text: $settings.vaultPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Markdown vault read by AlfredCore's MemoryStore.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
