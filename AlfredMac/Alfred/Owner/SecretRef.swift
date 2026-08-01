import Foundation

// MARK: - SecretRef
//
// A POINTER to a secret, never the secret. The owner configuration file must be safe to read aloud,
// screenshot, diff, and hand to a colleague — so nothing in it ever holds an API key, token, app
// password, or private identifier. Resolution is deliberately NOT implemented here: it belongs to the
// capability that actually needs the value, at the moment it needs it (OCS §7).
//
// The type is intentionally inert. It has no `resolve()`, so config loading cannot accidentally pull a
// secret into memory, and a `SecretRef` reaching the prompt builder is a validation failure rather
// than a leak.

/// Where a secret lives. Carries an identifier only.
enum SecretRef: Codable, Equatable, Sendable {
    /// macOS Keychain item, addressed by service + account.
    case keychain(service: String, account: String)
    /// Environment variable, addressed by name (cloud runtime).
    case environment(name: String)
    /// Opaque id for a future secret manager, resolved through a platform adapter.
    case secretId(String)

    // MARK: Validation surface

    /// Keychain services the configuration is allowed to point at. Prevents a hand-edited config from
    /// aiming the resolver at an unrelated application's credentials.
    static let allowedKeychainServices: Set<String> = ["com.alfred.app"]

    /// Strict POSIX-style uppercase identifier, e.g. `CLOUD_BOT_TOKEN`.
    static let environmentNamePattern = "^[A-Z][A-Z0-9_]{0,63}$"

    /// Keychain account: conservative, no whitespace or path separators.
    static let keychainAccountPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

    /// Opaque secret id.
    static let secretIdPattern = "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"

    /// A stable, non-secret label for logs and audit rows. Names the POINTER, never the value.
    var auditLabel: String {
        switch self {
        case let .keychain(service, account): return "keychain:\(service)/\(account)"
        case let .environment(name):          return "env:\(name)"
        case let .secretId(id):               return "secretId:\(id)"
        }
    }

    // MARK: Codable
    //
    // Encoded as a single-key object so the JSON reads unambiguously and a plain string can never be
    // mistaken for a reference:
    //   { "keychainRef": { "service": "...", "account": "..." } }
    //   { "environmentRef": "CLOUD_BOT_TOKEN" }
    //   { "secretId": "..." }

    private enum CodingKeys: String, CodingKey {
        case keychainRef, environmentRef, secretId
    }

    private struct KeychainPayload: Codable, Equatable {
        let service: String
        let account: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let k = try c.decodeIfPresent(KeychainPayload.self, forKey: .keychainRef) {
            self = .keychain(service: k.service, account: k.account)
        } else if let e = try c.decodeIfPresent(String.self, forKey: .environmentRef) {
            self = .environment(name: e)
        } else if let s = try c.decodeIfPresent(String.self, forKey: .secretId) {
            self = .secretId(s)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "SecretRef requires exactly one of keychainRef, environmentRef, secretId."))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .keychain(service, account):
            try c.encode(KeychainPayload(service: service, account: account), forKey: .keychainRef)
        case let .environment(name):
            try c.encode(name, forKey: .environmentRef)
        case let .secretId(id):
            try c.encode(id, forKey: .secretId)
        }
    }
}

// A reference is not sensitive, but printing one next to a resolved value in a log is a trap. Render
// the pointer only — never anything that could be mistaken for a credential.
extension SecretRef: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { auditLabel }
    var debugDescription: String { auditLabel }
}

// MARK: - Secret

/// A resolved secret VALUE. Wrapped so it cannot be interpolated into a prompt or a log line by
/// accident: every textual rendering is `<redacted>`, and the raw value is reachable only through the
/// explicit `reveal()` call, which reads as an obvious intent at the call site.
///
/// Not produced anywhere in this package — the type exists so capabilities can adopt it as they are
/// migrated off raw `String` credentials (OCS §7, deferred work).
struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String
    let origin: SecretRef

    init(_ value: String, origin: SecretRef) {
        self.value = value
        self.origin = origin
    }

    /// The only way to read the value. Deliberately verbose.
    func reveal() -> String { value }

    var isEmpty: Bool { value.isEmpty }

    static let redactedPlaceholder = "<redacted>"
    var description: String { Self.redactedPlaceholder }
    var debugDescription: String { Self.redactedPlaceholder }
}

// A Secret must never round-trip through JSON. Encoding throws rather than silently emitting either
// the value or a placeholder that a later reader might mistake for one.
extension Secret: Encodable {
    func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(Self.redactedPlaceholder, .init(
            codingPath: encoder.codingPath,
            debugDescription: "Secret values are never encoded. Store a SecretRef instead."))
    }
}
