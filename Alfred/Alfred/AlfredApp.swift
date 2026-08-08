//
//  AlfredApp.swift
//  Alfred
//
//  Created by Carlton King on 8/4/26.
//
//  Alfred on the phone. The brain is the same one Telegram talks to — the always-on cloud app in
//  `api/` — reached over its plain-HTTP front door (api/app.ts) instead of Telegram's protocol.
//

import SwiftUI
import UserNotifications

@main
struct AlfredApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var chat = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(chat)
        }
    }
}

/// Registers for remote notifications so the cloud's "time to leave" watcher
/// (api/cron-departure) can nudge this phone. Permissions are requested lazily
/// from PushRegistration.request() — not here, so first launch isn't interrupted.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await PushRegistration.shared.tokenDidArrive(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[push] failed to register: \(error.localizedDescription)")
    }
}
