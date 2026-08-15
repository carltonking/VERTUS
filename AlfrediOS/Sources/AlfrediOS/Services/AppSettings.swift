import Foundation
import Combine
import AlfredCore

/// App preferences. Non-secret values persist in UserDefaults; the Hermes API
/// key is stored in the Keychain via `KeychainHelper` and never touches
/// UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Hermes endpoint. Defaults to a local Hermes server on the Mac
    /// (localhost works in the simulator); set a LAN/remote URL on a device.
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }

    /// AlfredCore memory vault path (defaults to AlfredConfig's resolution).
    @Published var vaultPath: String {
        didSet { UserDefaults.standard.set(vaultPath, forKey: "vaultPath") }
    }

    /// Hermes API key — Keychain-backed, blank until the user sets one.
    @Published var apiKey: String {
        didSet {
            if apiKey != oldValue {
                KeychainHelper.save(key: "hermesApiKey", value: apiKey)
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: "baseURL") ?? "http://localhost:8080"
        model = defaults.string(forKey: "model") ?? "hermes"
        vaultPath = defaults.string(forKey: "vaultPath") ?? AlfredConfig.vaultPath()
        apiKey = KeychainHelper.load(key: "hermesApiKey") ?? ""
    }

    var resolvedBaseURL: URL {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://localhost:8080")!
    }
}
