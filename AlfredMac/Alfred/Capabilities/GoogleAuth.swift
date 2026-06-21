import Foundation
import Network
import AppKit

// MARK: - GoogleAuth
//
// One-time login for Google (Gmail, Drive, Google Calendar) using the OAuth **loopback flow** — the
// method Google requires for desktop apps. Alfred opens Google's sign-in in the browser, runs a tiny
// local web server on 127.0.0.1 for a few seconds to catch the redirect, exchanges the code for
// tokens, and stores the long-lived refresh token in the Keychain. Talks only to Google's servers.
//
// One-time setup (the user does this once, like Spotify/Microsoft):
//   1. console.cloud.google.com → create a project.
//   2. Enable the "Gmail API" (APIs & Services → Library).
//   3. APIs & Services → Credentials → Create credentials → OAuth client ID → type "Desktop app".
//   4. On the OAuth consent screen, add your own email under "Test users".
//   5. Copy the Client ID and Client secret, then run:
//        set google token <clientID>:<clientSecret>
//   6. Say "connect gmail".
//
// Keychain: "clientId:clientSecret" under account "google"; refresh token under "google_refresh".

enum GoogleAuth {

    static let keychainCreds   = "google"          // "clientId:clientSecret"
    static let keychainRefresh = "google_refresh"
    private static let service = "com.alfred.app"
    // Read-only Gmail. Add more scopes (drive.readonly, calendar.readonly) here as connectors grow.
    private static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    // Token cache + the active listener are touched from a detached connection handler (on a global
    // queue) and from concurrent query tasks, so both need a lock — unsynchronized statics race.
    private static var cachedAccessToken: String?
    private static var cachedExpiry = Date.distantPast
    private static let cacheLock = NSLock()
    private static var listener: NWListener?
    private static let listenerLock = NSLock()

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

    // Synchronous so the lock is never held across an await (keeps it out of the async startListener).
    private static func installListener(_ l: NWListener) {
        listenerLock.lock(); defer { listenerLock.unlock() }
        listener?.cancel()
        listener = l
    }
    private static func clearListener(ifCurrent l: NWListener) {
        listenerLock.lock(); defer { listenerLock.unlock() }
        if listener === l { listener = nil }
    }

    static var hasCredentials: Bool { creds() != nil }
    static var isConnected: Bool {
        (KeychainHelper.load(service: service, account: keychainRefresh)?.trimmingCharacters(in: .whitespaces).isEmpty == false)
    }

    private static func creds() -> (id: String, secret: String)? {
        guard let c = KeychainHelper.load(service: service, account: keychainCreds),
              let sep = c.firstIndex(of: ":") else { return nil }
        let id = String(c[..<sep]).trimmingCharacters(in: .whitespaces)
        let secret = String(c[c.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : (id, secret)
    }

    // MARK: - Login (loopback)

    /// Opens Google sign-in and starts the local redirect-catcher. The token exchange + save happen in
    /// the background once the user approves. Returns the message to show immediately.
    static func beginLogin() async -> String {
        guard let creds = creds() else { return setupMessage }
        do {
            let port = try await startListener(clientID: creds.id, clientSecret: creds.secret)
            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                URLQueryItem(name: "client_id", value: creds.id),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            guard let url = comps.url else { return "Couldn't build the Google sign-in URL." }
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            return "Opening Google sign-in in your browser — approve access, then ask me to \"read my gmail\". (If the browser didn't open, paste this:\n\(url.absoluteString))"
        } catch {
            return "Couldn't start Google sign-in: \(error.localizedDescription)"
        }
    }

    /// Starts a one-shot loopback HTTP server, returns the port it bound to. The connection handler
    /// captures the auth code, replies in the browser, and kicks off the token exchange.
    private static func startListener(clientID: String, clientSecret: String) async throws -> UInt16 {
        let params = NWParameters.tcp
        let newListener = try NWListener(using: params, on: .any)   // .any → an ephemeral free port
        installListener(newListener)

        newListener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let code = parseCode(from: request)
                let bodyText = code != nil
                    ? "Alfred is connected to Google. You can close this tab."
                    : "Sign-in failed or was cancelled. You can close this tab."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyText.utf8.count)\r\nConnection: close\r\n\r\n\(bodyText)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

                if let code {
                    let redirect = "http://127.0.0.1:\(newListener.port?.rawValue ?? 0)"
                    Task { await exchangeCode(code, clientID: clientID, clientSecret: clientSecret, redirectURI: redirect) }
                }
                // Cancel the listener WE captured, and only clear the shared static if it still points
                // at us — so a second concurrent login isn't killed by this handler.
                newListener.cancel()
                clearListener(ifCurrent: newListener)
            }
        }

        let lock = NSLock()
        var resumed = false
        return try await withCheckedThrowingContinuation { continuation in
            // Resume exactly once for any terminal state. Missing .cancelled here would hang the
            // login task forever if a second login cancels this listener before it reaches .ready.
            func finish(_ result: Result<UInt16, Error>) {
                lock.lock(); let already = resumed; resumed = true; lock.unlock()
                if !already { continuation.resume(with: result) }
            }
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(newListener.port?.rawValue ?? 0))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            newListener.start(queue: .global())
        }
    }

    /// Pulls the `code` query parameter out of the raw HTTP request's first line.
    private static func parseCode(from request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(pathPart)") else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private static func exchangeCode(_ code: String, clientID: String, clientSecret: String, redirectURI: String) async {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
        struct Tok: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int }
        guard let tok = try? JSONDecoder().decode(Tok.self, from: data) else { return }
        storeToken(tok.access_token, expiresIn: tok.expires_in)
        if let refresh = tok.refresh_token, !refresh.isEmpty {
            _ = KeychainHelper.save(service: service, account: keychainRefresh, value: refresh)
            await CapabilityEventLogger.shared.record("google", "connected")
        } else {
            await CapabilityEventLogger.shared.record("google", "no-refresh-token")
        }
    }

    // MARK: - Access token (refresh on demand)

    static func accessToken() async -> String? {
        if let token = cachedToken() { return token }
        guard let creds = creds(),
              let refresh = KeychainHelper.load(service: service, account: keychainRefresh)?.trimmingCharacters(in: .whitespaces),
              !refresh.isEmpty else { return nil }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "client_id": creds.id,
            "client_secret": creds.secret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        struct Tok: Decodable { let access_token: String; let expires_in: Int }
        guard let tok = try? JSONDecoder().decode(Tok.self, from: data) else { return nil }
        storeToken(tok.access_token, expiresIn: tok.expires_in)
        return tok.access_token
    }

    static let setupMessage = """
    To connect Gmail I need free Google app credentials (one-time):
    1. console.cloud.google.com → create a project.
    2. APIs & Services → Library → enable "Gmail API".
    3. Credentials → Create credentials → OAuth client ID → type "Desktop app".
    4. On the OAuth consent screen, add your email under "Test users".
    5. Copy the Client ID and Client secret, then tell me: set google token <clientID>:<clientSecret>
    Then say "connect gmail".
    """

    // MARK: - Helpers

    private static func form(_ params: [String: String]) -> Data {
        Data(params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowedG) ?? $0.value)" }
            .joined(separator: "&").utf8)
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowedG: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
