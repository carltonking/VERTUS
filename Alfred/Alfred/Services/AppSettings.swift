//
//  AppSettings.swift
//  Alfred
//
//  Where Alfred lives and how to prove we're allowed to talk to him.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let host = "alfred.host"
        static let token = "alfred.token"
        static let theme = "alfred.theme"
    }

    /// Which of the three palettes the app draws with. Persisted so it survives a relaunch.
    var theme: ThemeChoice {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// What the user typed — a hostname or full URL, kept verbatim so the settings field
    /// shows them back what they entered rather than a normalised form they didn't write.
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Keys.host) }
    }

    var token: String {
        didSet { Keychain.set(token, for: Keys.token) }
    }

    init() {
        host = UserDefaults.standard.string(forKey: Keys.host) ?? ""
        token = Keychain.get(Keys.token) ?? ""
        theme = UserDefaults.standard.string(forKey: Keys.theme)
            .flatMap(ThemeChoice.init(rawValue:)) ?? .eclipse
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

        // Drop any path they pasted (…/api/app, or a stray trailing slash) and re-add the canonical one.
        components.path = "/api/app"
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
