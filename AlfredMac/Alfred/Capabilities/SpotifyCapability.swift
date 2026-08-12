import Foundation

/// Plays songs on the user's Spotify desktop app.
///
/// Two layers, chosen for reliability:
///
///   * **Playback** goes through Spotify's own AppleScript dictionary —
///     `play track "spotify:track:…"` — which takes a track *URI*, not a name.
///     Verified live: name-based `play track` fails (the player drops to
///     "stopped" with no current track), while URI-based play works every time.
///   * **Name → URI resolution** uses the Spotify Web API's search endpoint.
///     Credentials live in `~/Library/Application Support/Alfred/spotify.json`
///     as `{ "client_id": …, "client_secret": … }` — the Client Credentials
///     flow, so search works without any user login or OAuth dance. Same plain
///     file convention as `style_samples.jsonl`.
///
/// The Web API is only a lookup table: nothing about the user's account is read,
/// and the actual audio plays through the desktop app they already have.
struct SpotifyCapability {

    enum SpotifyError: LocalizedError {
        case noCredentials
        case tokenFailed(String)
        case searchFailed(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "Spotify isn't configured. Put your app's Client ID and Secret in ~/Library/Application Support/Alfred/spotify.json as {\"client_id\": \"…\", \"client_secret\": \"…\"} (create a free app at developer.spotify.com)."
            case .tokenFailed(let m): return "Spotify auth failed: \(m)"
            case .searchFailed(let m): return "Spotify search failed: \(m)"
            case .notFound(let q): return "No Spotify track found for \"\(q)\". Try artist + title."
            }
        }
    }

    // MARK: - Play

    /// Play a song. `request` is either a full `spotify:track:…` URI or a
    /// human query ("Karma Police", "Karma Police Radiohead") which is resolved
    /// to the top search hit.
    func play(_ request: String) async throws -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let uri: String
        if trimmed.hasPrefix("spotify:") {
            uri = trimmed
        } else {
            uri = try await resolveURI(for: trimmed)
        }
        try runPlayback(uri: uri)
        return "Now playing on Spotify: \(trimmed)"
    }

    /// Pause/resume, skip, or go back — the one-line AppleScript controls.
    func transport(_ action: String) async throws -> String {
        let script: String
        switch action {
        case "play": script = "play"
        case "pause": script = "pause"
        case "toggle": script = "playpause"
        case "next": script = "next track"
        case "previous", "prev": script = "previous track"
        default: throw SpotifyError.searchFailed("unknown transport action '\(action)'")
        }
        try runAppleScript(script)
        return "Spotify: \(script)."
    }

    // MARK: - Name → URI

    /// Turn a song query into a `spotify:track:…` URI via the Web API search.
    private func resolveURI(for query: String) async throws -> String {
        let token = try await accessToken()
        guard let url = URL(string: "https://api.spotify.com/v1/search"
            + "?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            + "&type=track&limit=1") else {
            throw SpotifyError.searchFailed("bad search URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyError.searchFailed(error.localizedDescription)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = root["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]],
              let first = items.first,
              let uri = first["uri"] as? String
        else {
            if let err = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = err["error"] as? [String: Any],
               let text = message["message"] as? String {
                throw SpotifyError.searchFailed(text)
            }
            throw SpotifyError.notFound(query)
        }
        return uri
    }

    /// Client Credentials flow: one token, good for an hour, used only for
    /// catalog search. No user account involved.
    private func accessToken() async throws -> String {
        let (id, secret) = try credentials()
        let pair = "\(id):\(secret)"
            .data(using: .utf8)!
            .base64EncodedString()

        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyError.tokenFailed("bad token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
        request.httpBody = "grant_type=client_credentials".data(using: .utf8)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyError.tokenFailed(error.localizedDescription)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String
        else {
            if let err = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = err["error_description"] as? String {
                throw SpotifyError.tokenFailed(message)
            }
            throw SpotifyError.tokenFailed("unreadable token response")
        }
        return token
    }

    // MARK: - Playback

    /// `play track <uri>` through Spotify's own AppleScript dictionary.
    private func runPlayback(uri: String) throws {
        try runAppleScript("play track \"\(uri)\"")
    }

    private func runAppleScript(_ body: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Spotify\" to \(body)"]
        let err = Pipe()
        task.standardError = err
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw SpotifyError.searchFailed("osascript failed: \(error.localizedDescription)")
        }
        if task.terminationStatus != 0 {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SpotifyError.searchFailed("Spotify rejected the command: \(message)")
        }
    }

    // MARK: - Credentials

    /// Read Client ID + Secret from the support-directory JSON file.
    private func credentials() throws -> (String, String) {
        let url = Self.configURL
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["client_id"] as? String, !id.isEmpty,
              let secret = root["client_secret"] as? String, !secret.isEmpty
        else {
            throw SpotifyError.noCredentials
        }
        return (id, secret)
    }

    static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alfred/spotify.json")
    }
}
