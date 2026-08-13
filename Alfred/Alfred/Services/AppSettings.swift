//
//  AppSettings.swift
//  Alfred
//
//  Where Alfred lives and how to prove we're allowed to talk to him.
//

import Foundation
import Observation

/// File-scope so the `nonisolated` persistence helper below can reach the keys:
/// a nested enum inside a `@MainActor` class is itself MainActor-isolated, which
/// would break the background discovery path. Must also be explicitly
/// `nonisolated`: the project sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
/// even file-scope types default to MainActor isolation unless told otherwise.
private nonisolated enum SettingsKeys {
    static let host = "alfred.host"
    static let token = "alfred.token"
    static let voiceHost = "alfred.voiceHost"
    static let socketHost = "alfred.socketHost"
    static let socketPort = "alfred.socketPort"
}

@MainActor
@Observable
final class AppSettings {

    /// What the user typed — a hostname or full URL, kept verbatim so the settings field
    /// shows them back what they entered rather than a normalised form they didn't write.
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: SettingsKeys.host) }
    }

    var token: String {
        didSet { Keychain.set(token, for: SettingsKeys.token) }
    }

    /// The Mac's LAN address for voice — reachable directly on this network, unlike the relay
    /// host above. Empty until told where Alfred's voice bridge lives.
    var voiceHost: String {
        didSet { UserDefaults.standard.set(voiceHost, forKey: SettingsKeys.voiceHost) }
    }

    /// The Mac's address for the live socket — auto-discovered over mDNS/Tailscale, or typed
    /// by hand in Settings as the fallback. Host only; the port lives in `socketPort`.
    var socketHost: String {
        didSet { UserDefaults.standard.set(socketHost, forKey: SettingsKeys.socketHost) }
    }

    /// The port the Mac's ACP-over-WebSocket server listens on. Defaults to the shared
    /// constant; a non-default port is kept here so manual entry can point at a custom setup.
    var socketPort: Int {
        didSet { UserDefaults.standard.set(socketPort, forKey: SettingsKeys.socketPort) }
    }

    /// The `ws://host:port` URL for the live socket, or nil when no host is set.
    /// Tolerates what a person might actually paste: a full `ws://host:port` URL,
    /// a `host:port` shorthand, or a bare hostname (which uses `socketPort`).
    ///
    /// Always `ws://`, never `wss://`. The Mac's socket server (BriefingSocketServer)
    /// is plain TCP — `NWParameters(tls: nil)` — so it has no certificate to present,
    /// and a `wss://` URL dies at the TLS handshake no matter what the client's trust
    /// delegate allows. A pasted `wss://` is downgraded here instead. Nothing is
    /// lost: the phone and Mac talk over an encrypted tailnet (or a trusted LAN),
    /// so the plain scheme rides on top of an already-secure link.
    var socketURL: URL? {
        var raw = socketHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("ws://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("wss://") {
            raw = String(raw.dropFirst("wss://".count))
        }
        var port = socketPort
        if let colon = raw.lastIndex(of: ":"), colon > raw.startIndex {
            let digits = raw[raw.index(after: colon)...]
            if let explicit = Int(digits), (1...65535).contains(explicit) {
                port = explicit
                raw = String(raw[..<colon])
            }
        }
        return URL(string: "ws://\(raw):\(port)")
    }

    init() {
        host = UserDefaults.standard.string(forKey: SettingsKeys.host) ?? ""
        var storedToken = Keychain.get(SettingsKeys.token) ?? ""
        #if DEBUG
        // Simulator seeding: the token lives in the Keychain, which simctl can't write
        // directly. A debug-only env var lets CI/automation bootstrap it on first launch.
        if storedToken.isEmpty, let seeded = ProcessInfo.processInfo.environment["ALFRED_SEED_TOKEN"], !seeded.isEmpty {
            storedToken = seeded
        }
        #endif
        token = storedToken
        voiceHost = UserDefaults.standard.string(forKey: SettingsKeys.voiceHost) ?? ""
        socketHost = UserDefaults.standard.string(forKey: SettingsKeys.socketHost) ?? ""
        socketPort = UserDefaults.standard.object(forKey: SettingsKeys.socketPort) as? Int
            ?? AlfredWebSocketClient.defaultPort
    }

    /// Persist a discovered host, so discovery doesn't have to run every launch.
    func saveSocketHost(_ host: String, port: Int) {
        socketHost = host
        socketPort = port
    }

    /// Nonisolated twin for callers off the main actor (TailscaleConnection runs
    /// its discovery on a background task). Writes the same two keys.
    nonisolated static func persistSocketHost(_ host: String, port: Int) {
        UserDefaults.standard.set(host, forKey: SettingsKeys.socketHost)
        UserDefaults.standard.set(port, forKey: SettingsKeys.socketPort)
    }

    var isConfigured: Bool {
        endpoint != nil && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The `/api/app` URL, built from whatever shape the user pasted in.
    var endpoint: URL? { Self.endpoint(forHost: host) }

    /// Normalisation, kept static and free of stored state so it can be tested without constructing
    /// an AppSettings — which would read the Keychain and write the real UserDefaults.
    ///
    /// People paste a bare host, a full deployment URL, one with a trailing slash, or the endpoint
    /// path itself — all four mean the same thing, so normalise rather than making them guess the
    /// format the app wants.
    nonisolated static func endpoint(forHost host: String) -> URL? {
        var raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if !raw.contains("://") { raw = "https://" + raw }
        guard var components = URLComponents(string: raw), let scheme = components.scheme else { return nil }
        guard scheme == "https" || scheme == "http" else { return nil }
        guard let hostName = components.host, hostName.contains(".") || hostName == "localhost" else { return nil }

        // Drop any path they pasted and re-add the canonical one. This is /api/mac,
        // not /api/app: messages are relayed to Alfred on the Mac and answered there
        // by Hermes with the local model, rather than answered in the cloud.
        components.path = "/api/mac"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The host as Alfred will actually reach it — shown in Settings so the normalisation is visible
    /// rather than something the user has to trust silently.
    var resolvedEndpointDescription: String {
        endpoint?.absoluteString ?? "Not set"
    }
}
