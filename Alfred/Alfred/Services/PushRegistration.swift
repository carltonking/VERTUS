//
//  PushRegistration.swift
//  Alfred
//
//  One install, one APNs token, handed to the cloud so the departure watcher
//  (api/cron-departure) can nudge the owner when it's time to leave for the
//  next class. The token is registered through the same front door the app
//  already trusts:
//
//      POST /api/device
//      Authorization: Bearer <APP_TOKEN>
//      { "token": "<apns device token hex>" }
//
//  The flow is started from RootView once the app is configured, and is
//  idempotent: permission is requested once, the token is re-registered on
//  every launch (the server refreshes its key TTL), and failures are silent —
//  push is best-effort on top of the existing chat/Telegram channels.
//

import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Ask for notification permission once, then let the OS hand us the token.
    /// Safe to call every launch — the OS remembers the answer.
    func request() async {
        let settings = AppSettings()
        guard settings.isConfigured else { return }
        registeredEndpoint = endpoint(from: settings.host)
        guard registeredEndpoint != nil else { return }

        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            break // Leave the Settings toggle as the way back in.
        @unknown default:
            break
        }
    }

    /// AppDelegate hands the raw APNs token here once the OS delivers it.
    func tokenDidArrive(_ token: String) async {
        self.registeredToken = token
        if registeredEndpoint == nil {
            let settings = AppSettings()
            guard settings.isConfigured else { return }
            registeredEndpoint = endpoint(from: settings.host)
        }
        await upload(token: token)
    }

    // MARK: - Internals

    private var registeredEndpoint: URL?
    private var registeredToken: String?

    private func endpoint(from host: String) -> URL? {
        var raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        components.path = "/api/device"
        return components.url
    }

    private func upload(token: String) async {
        guard let url = registeredEndpoint else { return }
        let settings = AppSettings()
        guard !settings.token.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": token])

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            registered = http.statusCode == 200
            if !registered { print("[push] registration rejected: HTTP \(http.statusCode)") }
        } catch {
            // Keep it quiet and retry next launch.
            print("[push] registration failed: \(error.localizedDescription)")
        }
    }

    /// Has this install successfully registered a token with its current server?
    private(set) var registered: Bool = false
}