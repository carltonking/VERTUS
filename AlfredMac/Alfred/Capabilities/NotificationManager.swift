import AppKit
import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let replyCategoryID = "ALFRED_INBOUND_REPLY"
    static let respondActionID = "RESPOND"
    static let dismissActionID = "DISMISS"

    /// Category + action for high-risk routine drafts awaiting the owner's one-tap OK.
    static let routineConfirmCategoryID = "ALFRED_ROUTINE_CONFIRM"
    static let runActionID = "RUN_ROUTINE"

    private lazy var center: UNUserNotificationCenter = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    func setup() {
        center.delegate = self
        // Actionable category for inbound "want me to respond?" notifications.
        let respond = UNNotificationAction(identifier: Self.respondActionID, title: "Respond", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Self.dismissActionID, title: "Dismiss", options: [])
        let replyCategory = UNNotificationCategory(identifier: Self.replyCategoryID,
                                                   actions: [respond, dismiss],
                                                   intentIdentifiers: [], options: [])
        // Actionable category for high-risk routine drafts: "Run now" performs the drafted write,
        // "Dismiss" drops it. .foreground brings Alfred forward so any capability UI can present.
        let run = UNNotificationAction(identifier: Self.runActionID, title: "Run now", options: [.foreground])
        let dismissRun = UNNotificationAction(identifier: Self.dismissActionID, title: "Dismiss", options: [])
        let confirmCategory = UNNotificationCategory(identifier: Self.routineConfirmCategoryID,
                                                     actions: [run, dismissRun],
                                                     intentIdentifiers: [], options: [])
        // setNotificationCategories REPLACES the whole set — register both in one call.
        center.setNotificationCategories([replyCategory, confirmCategory])
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
                        userInfo: [String: String],
                        categoryID: String = NotificationManager.replyCategoryID) async throws -> Bool {
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
        content.categoryIdentifier = categoryID

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
        let category = response.notification.request.content.categoryIdentifier

        let info: [String: String] = response.notification.request.content.userInfo.reduce(into: [:]) { acc, pair in
            if let ks = pair.key as? String, let vs = pair.value as? String { acc[ks] = vs }
        }

        // High-risk routine draft: ONLY the explicit "Run now" button performs the write. A plain
        // body tap or Dismiss is a deliberate no-op — a risky action never fires on an accidental tap.
        if category == Self.routineConfirmCategoryID {
            guard response.actionIdentifier == Self.runActionID, !info.isEmpty else { return }
            await MainActor.run { AppDelegate.shared?.confirmRoutineFromNotification(info) }
            return
        }

        // Inbound "want me to respond?": the Respond button or a body tap opens the drafting session.
        guard response.actionIdentifier == Self.respondActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        guard !info.isEmpty else { return }
        await MainActor.run {
            // NOT NSApp.delegate — SwiftUI's @NSApplicationDelegateAdaptor keeps its own object there;
            // the real AppDelegate is reachable only via its static handle.
            AppDelegate.shared?.respondToInboundNotification(info)
        }
    }
}
