import Foundation

// MARK: - SpotifyCapability
//
// Local, zero-auth Spotify control via AppleScript — no API, no token, no OAuth. macOS Spotify
// exposes a scripting interface, so playback control and now-playing work fully on-device.
// Volume goes through SYSTEM output volume (what "turn it up" usually means, and never stuck at
// Spotify's own max). Routed through QuickCommands so it's instant and never depends on the LLM.
//
// Scope (v1): play/resume, pause, next, previous, now-playing, volume. NOT search-by-name
// ("play Faneto") — the AppleScript dictionary has no search; that needs the Web API (OAuth),
// deferred. "play <something>" is caught and answered gracefully so the LLM can't hallucinate.

struct SpotifyCapability {

    static let keychainAccount = "spotify"

    enum Action {
        case nowPlaying, play, pause, next, previous, volumeUp, volumeDown, searchUnsupported
    }

    /// True when Spotify app credentials ("clientId:clientSecret") are stored. Search-by-name needs
    /// them; the basic controls do not.
    static var hasCredentials: Bool {
        guard let c = KeychainHelper.load(service: "com.alfred.app", account: keychainAccount) else { return false }
        return c.contains(":") && c.split(separator: ":").count == 2
    }

    private static func hasAny(_ s: String, _ subs: [String]) -> Bool { subs.contains { s.contains($0) } }

    /// Maps a lowercased query to a Spotify action, or nil if it isn't a music command. Tolerant of
    /// natural phrasing. Order matters — check next/previous BEFORE the generic "play …" fallback so
    /// "play the next song" routes to skip, not to search.
    static func detect(_ lowered: String) -> Action? {
        if hasAny(lowered, ["what's playing", "whats playing", "what is playing", "now playing",
                            "current song", "current track", "what song", "what am i listening",
                            "name of this song", "name of the song", "what's this song", "whats this song"]) {
            return .nowPlaying
        }

        if lowered == "next" || lowered == "skip"
            || hasAny(lowered, ["next song", "next track", "skip song", "skip track", "skip this",
                                "song after", "play the next"]) { return .next }

        if lowered == "previous" || lowered == "back"
            || hasAny(lowered, ["previous song", "previous track", "last song", "go back",
                                "song before", "before this", "play the previous", "previous one",
                                "go back a song", "the one before"]) { return .previous }

        // "pause" almost always means the music.
        if lowered.contains("pause") || lowered == "stop the music" || lowered == "stop music" { return .pause }

        if hasAny(lowered, ["volume up", "turn it up", "turn up", "louder", "raise the volume",
                            "increase the volume", "increase volume", "all the way up", "max volume",
                            "crank it", "pump it up"]) { return .volumeUp }
        if hasAny(lowered, ["volume down", "turn it down", "turn down", "quieter", "lower the volume",
                            "lower volume", "decrease the volume", "decrease volume", "all the way down",
                            "turn it lower"]) { return .volumeDown }

        if lowered == "play" || lowered == "resume" || lowered == "unpause" || lowered == "continue"
            || hasAny(lowered, ["play music", "resume music", "play spotify", "resume spotify",
                                "resume the music", "resume the song", "continue playing", "keep playing"]) {
            return .play
        }

        // Anything else shaped like "play <song>" / "put on <song>" is a search we can't do via
        // AppleScript. Catch it so the LLM doesn't invent a fake result.
        if lowered.hasPrefix("play ") || lowered.contains("put on ") || lowered.contains("play me ")
            || lowered.contains("play the song ") { return .searchUnsupported }

        return nil
    }

    /// Runs the action and returns a short user-facing confirmation. Never throws.
    static func handle(_ action: Action) -> String {
        switch action {
        case .nowPlaying:
            return runScript(spotify("""
                if player state is stopped then
                    return "Nothing's playing on Spotify right now."
                else
                    return "♪ " & (name of current track) & " — " & (artist of current track)
                end if
                """), fallback: "Couldn't reach Spotify.")
        case .play:
            return runScript(#"tell application "Spotify" to play"#, ok: "Playing.", fallback: "Couldn't start Spotify.")
        case .pause:
            return runScript(spotify("pause"), ok: "Paused.", fallback: "Couldn't reach Spotify.")
        case .next:
            return runScript(spotify("next track\nreturn \"Skipped ahead.\""), fallback: "Couldn't reach Spotify.")
        case .previous:
            // Spotify restarts the current track on the first `previous track`; call it twice so the
            // user actually lands on the prior song.
            return runScript(spotify("previous track\nprevious track\nreturn \"Back a track.\""), fallback: "Couldn't reach Spotify.")
        case .volumeUp:
            return runScript(systemVolumeDelta(15), ok: "Turned it up.", fallback: "Couldn't change volume.")
        case .volumeDown:
            return runScript(systemVolumeDelta(-15), ok: "Turned it down.", fallback: "Couldn't change volume.")
        case .searchUnsupported:
            return setupMessage
        }
    }

    static let setupMessage = "To play songs by name, I need free Spotify app credentials. Go to developer.spotify.com/dashboard → Create app (redirect URI can be anything, e.g. http://localhost), copy the Client ID and Client Secret, then tell me: set spotify token <clientID>:<clientSecret>"

    // MARK: - Search by name (Web API search → AppleScript play)

    /// Pulls the song query out of "play <song>" / "put on <song>" / "play me <song>".
    static func songQuery(from query: String) -> String? {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["play the song ", "play me ", "put on ", "play "] {
            if q.lowercased().hasPrefix(prefix) {
                q = String(q.dropFirst(prefix.count))
                break
            }
        }
        // Drop a trailing "on spotify".
        if q.lowercased().hasSuffix(" on spotify") { q = String(q.dropLast(" on spotify".count)) }
        q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    /// Searches Spotify for the song and plays it on the desktop app. Uses the Client Credentials
    /// flow (app token, no user login) for search; playback is the local AppleScript `play track`.
    /// Never throws — returns a user-facing string.
    static func searchAndPlay(query: String) async -> String {
        guard let song = songQuery(from: query) else { return setupMessage }
        guard let creds = KeychainHelper.load(service: "com.alfred.app", account: keychainAccount),
              let sep = creds.firstIndex(of: ":") else { return setupMessage }
        let clientId = String(creds[..<sep])
        let clientSecret = String(creds[creds.index(after: sep)...])

        do {
            let token = try await appToken(clientId: clientId, clientSecret: clientSecret)
            guard let track = try await searchTrack(song, token: token) else {
                return "Couldn't find \"\(song)\" on Spotify."
            }
            let played = runScript(#"tell application "Spotify" to play track "\#(track.uri)""#,
                                   ok: "", fallback: "Found it but couldn't reach Spotify to play.")
            if !played.isEmpty { return played } // fallback message
            return "▶ Playing \(track.name) — \(track.artist)"
        } catch {
            return "Spotify search failed: \(error.localizedDescription). Re-check your credentials with: set spotify token <id>:<secret>"
        }
    }

    private struct Track { let uri: String; let name: String; let artist: String }

    private static func appToken(clientId: String, clientSecret: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.networkError("credentials rejected")
        }
        struct TokenResp: Decodable { let access_token: String }
        return try JSONDecoder().decode(TokenResp.self, from: data).access_token
    }

    private static func searchTrack(_ song: String, token: String) async throws -> Track? {
        var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: song),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.networkError("search HTTP error")
        }
        struct SearchResp: Decodable {
            struct Tracks: Decodable {
                struct Item: Decodable {
                    struct Artist: Decodable { let name: String }
                    let uri: String; let name: String; let artists: [Artist]
                }
                let items: [Item]
            }
            let tracks: Tracks
        }
        guard let item = try JSONDecoder().decode(SearchResp.self, from: data).tracks.items.first else { return nil }
        return Track(uri: item.uri, name: item.name, artist: item.artists.first?.name ?? "Unknown")
    }

    // MARK: - AppleScript

    /// Wraps a Spotify command body in an is-running guard (so pause/skip don't auto-launch) and the
    /// `tell application "Spotify"` block.
    private static func spotify(_ body: String) -> String {
        """
        if application "Spotify" is running then
            tell application "Spotify"
                \(body)
            end tell
        else
            return "Spotify isn't open."
        end if
        """
    }

    /// Adjusts macOS system output volume by `delta` (clamped 0–100) — what "turn it up" usually
    /// means, and never stuck at Spotify's own max.
    private static func systemVolumeDelta(_ delta: Int) -> String {
        """
        set cur to output volume of (get volume settings)
        set newVol to cur + (\(delta))
        if newVol > 100 then set newVol to 100
        if newVol < 0 then set newVol to 0
        set volume output volume newVol
        """
    }

    private static func runScript(_ source: String, ok: String = "", fallback: String) -> String {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return fallback }
        let output = script.executeAndReturnError(&errorDict)
        if errorDict != nil { return fallback }
        let text = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? ok : text
    }
}
