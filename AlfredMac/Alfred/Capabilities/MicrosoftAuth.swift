import Foundation

// MARK: - MicrosoftAuth
//
// One-time login for Microsoft / Outlook using the OAuth **device-code flow** — the simplest OAuth
// there is: no local web server, no redirect URI to catch. Alfred shows a short code, the user types
// it into a Microsoft page in their browser, and Alfred polls until Microsoft hands back a token.
//
// Independence: this talks ONLY to login.microsoftonline.com (Microsoft's own server) — no middleman.
//
// One manual setup step (like Spotify's app credentials): the user registers a free app at
// entra.microsoft.com → App registrations → New registration (any account types) → Authentication →
// "Allow public client flows" = Yes, then copies the Application (client) ID and runs:
//     set microsoft token <client-id>
//
// Keychain: client ID under account "microsoft"; the long-lived refresh token under "microsoft_refresh".

enum MicrosoftAuth {

    static let keychainClientID = "microsoft"
    static let keychainRefresh  = "microsoft_refresh"
    private static let service  = "com.alfred.app"

    // "common" = personal Outlook.com accounts AND work/school accounts.
    private static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    // offline_access → we get a refresh token. Mail.Read + User.Read cover reading mail & profile.
    private static let scope = "offline_access User.Read Mail.Read"

    // In-memory access token cache (access tokens last ~1hr; refresh on demand). Guarded by a lock
    // because pollForToken writes it from a detached Task while accessToken() reads/writes it from
    // concurrent query tasks — unsynchronized String/Date statics would be a data race.
    private static var cachedAccessToken: String?
    private static var cachedExpiry: Date = .distantPast
    private static let cacheLock = NSLock()

    private static func cachedToken() -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedAccessToken, Date() < cachedExpiry { return cachedAccessToken }
        return nil
    }
    private static func storeToken(_ token: String, expiresIn: Int) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedAccessToken = token
        cachedExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
    }

    static var hasClientID: Bool {
        guard let c = KeychainHelper.load(service: service, account: keychainClientID) else { return false }
        return !c.trimmingCharacters(in: .whitespaces).isEmpty
    }
    static var isConnected: Bool {
        guard let r = KeychainHelper.load(service: service, account: keychainRefresh) else { return false }
        return !r.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static var clientID: String? {
        KeychainHelper.load(service: service, account: keychainClientID)?
            .trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    // MARK: - Device-code login

    /// Starts the device-code flow. Returns the instruction string to show the user immediately, and
    /// kicks off a background poll that saves the refresh token once they finish in the browser.
    /// Returns a setup message if no client ID is stored yet.
    static func beginLogin() async -> String {
        guard let clientID else { return setupMessage }
        do {
            let code = try await requestDeviceCode(clientID: clientID)
            // Poll in the background until the user authorizes (or it expires). Stores the refresh token.
            Task.detached { await pollForToken(clientID: clientID, deviceCode: code.deviceCode,
                                               interval: code.interval, expiresIn: code.expiresIn) }
            return """
            To connect Microsoft/Outlook:
            1. Open \(code.verificationURI)
            2. Enter this code: \(code.userCode)
            3. Sign in and approve.

            I'll finish connecting automatically once you approve — then ask me to "read my outlook".
            """
        } catch {
            return "Couldn't start Microsoft sign-in: \(error.localizedDescription). Double-check the client ID with: set microsoft token <client-id>"
        }
    }

    private struct DeviceCode {
        let deviceCode: String, userCode: String, verificationURI: String, interval: Int, expiresIn: Int
    }

    private static func requestDeviceCode(clientID: String) async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "\(authority)/devicecode")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["client_id": clientID, "scope": scope])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.networkError("device-code request rejected — is the client ID correct and 'public client flows' enabled?")
        }
        struct Resp: Decodable {
            let device_code: String, user_code: String, verification_uri: String
            let interval: Int, expires_in: Int
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return DeviceCode(deviceCode: r.device_code, userCode: r.user_code,
                          verificationURI: r.verification_uri, interval: r.interval, expiresIn: r.expires_in)
    }

    /// Polls the token endpoint every `interval` seconds until the user authorizes, the code expires,
    /// or a hard error. On success, saves the refresh token to the Keychain.
    private static func pollForToken(clientID: String, deviceCode: String, interval: Int, expiresIn: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var wait = max(interval, 1)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            var req = URLRequest(url: URL(string: "\(authority)/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientID,
                "device_code": deviceCode,
            ])
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse else { continue }

            if (200...299).contains(http.statusCode) {
                struct Tok: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int }
                if let tok = try? JSONDecoder().decode(Tok.self, from: data) {
                    // Only count as "connected" once a refresh token is persisted — without it the
                    // session dies silently after the ~1h access token expires and can't recover.
                    if let refresh = tok.refresh_token, !refresh.isEmpty {
                        _ = KeychainHelper.save(service: service, account: keychainRefresh, value: refresh)
                        storeToken(tok.access_token, expiresIn: tok.expires_in)
                        await CapabilityEventLogger.shared.record("microsoft", "connected")
                    } else {
                        await CapabilityEventLogger.shared.record("microsoft", "no-refresh-token")
                    }
                    return
                }
                // 2xx that didn't decode → transient; keep polling rather than aborting the flow.
                continue
            }
            // Still pending → keep polling. "slow_down" → back off. Anything else → stop.
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            switch err {
            case "authorization_pending": continue
            case "slow_down": wait += 5
            default: return   // expired_token / access_denied / bad request
            }
        }
    }

    // MARK: - Access token (refresh on demand)

    /// A valid access token, refreshing via the stored refresh token when needed. nil if not connected.
    static func accessToken() async -> String? {
        if let token = cachedToken() { return token }
        guard let clientID,
              let refresh = KeychainHelper.load(service: service, account: keychainRefresh)?.nilIfEmpty
        else { return nil }

        var req = URLRequest(url: URL(string: "\(authority)/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh,
            "scope": scope,
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

        struct Tok: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int }
        guard let tok = try? JSONDecoder().decode(Tok.self, from: data) else { return nil }
        storeToken(tok.access_token, expiresIn: tok.expires_in)
        // Microsoft rotates refresh tokens — persist the new one so we don't get logged out.
        if let newRefresh = tok.refresh_token { _ = KeychainHelper.save(service: service, account: keychainRefresh, value: newRefresh) }
        return tok.access_token
    }

    static let setupMessage = """
    To connect Outlook I need a free Microsoft app ID (one-time):
    1. Go to entra.microsoft.com → App registrations → New registration.
    2. Name it "Alfred", pick "Accounts in any organizational directory and personal Microsoft accounts", Register.
    3. Open Authentication → enable "Allow public client flows" → Save.
    4. Copy the "Application (client) ID" and tell me: set microsoft token <client-id>
    Then say "connect outlook".
    """

    // MARK: - Helpers

    private static func form(_ params: [String: String]) -> Data {
        Data(params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension CharacterSet {
    // Percent-encoding set for form values (everything that isn't unreserved gets encoded).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
