import AppKit
import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let replyCategoryID = "ALFRED_INBOUND_REPLY"
    static let respondActionID = "RESPOND"
    static let dismissActionID = "DISMISS"

    private lazy var center: UNUserNotificationCenter = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    func setup() {
        center.delegate = self
        // Actionable category for inbound "want me to respond?" notifications.
        let respond = UNNotificationAction(identifier: Self.respondActionID, title: "Respond", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Self.dismissActionID, title: "Dismiss", options: [])
        let category = UNNotificationCategory(identifier: Self.replyCategoryID,
                                              actions: [respond, dismiss],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    @discardableResult
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    @discardableResult
    func send(title: String, body: String, identifier: String = UUID().uuidString) async throws -> Bool {
        let status = await authorizationStatus()
        let authorized: Bool

        switch status {
        case .notDetermined:
            authorized = try await requestAuthorization()
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .denied:
            authorized = false
        @unknown default:
            authorized = false
        }

        guard authorized else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )

        try await center.add(request)
        return true
    }

    /// Posts an actionable "want me to respond?" notification carrying the message identity in
    /// userInfo, so the Respond tap can route into the drafting brain.
    @discardableResult
    func sendActionable(title: String, body: String, identifier: String = UUID().uuidString,
                        userInfo: [String: String]) async throws -> Bool {
        let status = await authorizationStatus()
        let authorized: Bool
        switch status {
        case .notDetermined: authorized = try await requestAuthorization()
        case .authorized, .provisional, .ephemeral: authorized = true
        case .denied: authorized = false
        @unknown default: authorized = false
        }
        guard authorized else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        content.categoryIdentifier = Self.replyCategoryID

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        try await center.add(request)
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Handles taps on inbound notifications. "Respond" (and a tap on the notification body) routes
    /// the message identity to the AppDelegate, which drafts a reply; "Dismiss" does nothing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.respondActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        var info: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo {
            if let ks = k as? String, let vs = v as? String { info[ks] = vs }
        }
        guard !info.isEmpty else { return }
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.respondToInboundNotification(info)
        }
    }
}
