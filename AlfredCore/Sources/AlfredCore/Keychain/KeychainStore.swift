import Foundation
import Security

/// Generic-password Keychain storage shared by the macOS and iOS apps.
///
/// API keys (and the provider key ring) live here — never in UserDefaults.
/// Works on both platforms: `Security`'s generic-password API is identical on
/// macOS and iOS, so this is the one place key material is persisted for
/// AlfredCore's clients.
public enum KeychainStore {

    /// Shared service identifier. The macOS app ships under
    /// `com.alfred.app`; the iOS app uses the same service so a future
    /// shared-login story has one namespace.
    public static let service = "com.alfred.app"

    /// Upsert `data` under `account` (delete-then-add, atomic enough for
    /// single-user key material). Returns false only on a real failure.
    @discardableResult
    public static func save(account: String, data: Data, service: String = service) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Convenience: store a UTF-8 string (e.g. an API key).
    @discardableResult
    public static func save(account: String, string: String, service: String = service) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return save(account: account, data: data, service: service)
    }

    /// The data stored under `account`, or nil when absent.
    public static func load(account: String, service: String = service) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    /// Convenience: load a stored string.
    public static func loadString(account: String, service: String = service) -> String? {
        guard let data = load(account: account, service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(account: String, service: String = service) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
