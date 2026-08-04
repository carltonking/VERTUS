//
//  Keychain.swift
//  Alfred
//
//  The APP_TOKEN is the only credential the phone holds, and it authorises calendar writes and
//  LLM spend on the owner's account. That puts it in the Keychain rather than UserDefaults, which
//  is plain-text inside the app container and rides along in unencrypted backups.
//

import Foundation
import Security

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "Carlton.Alfred"

    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ value: String, for key: String) {
        guard !value.isEmpty else {
            remove(key)
            return
        }
        let data = Data(value.utf8)
        SecItemDelete(query(key) as CFDictionary)

        var attributes = query(key)
        attributes[kSecValueData as String] = data
        // The token is only ever needed while the user is driving the app, so it doesn't need to
        // survive into a locked device — and this attribute keeps it out of iCloud backups.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var attributes = query(key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func remove(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
