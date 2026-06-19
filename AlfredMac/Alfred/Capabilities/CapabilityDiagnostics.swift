import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UserNotifications

@MainActor
struct CapabilityDiagnostics {
    static func makeSummary(
        appState: AppState,
        selectedFiles: SelectedFileSnapshot,
        bookmarkStore: SecurityScopedBookmarkStore,
        screenMonitoringActive: Bool,
        focusSessionActive: Bool
    ) async -> String {
        let notificationStatus = await NotificationManager.shared.authorizationStatus()
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        let accessibilityGranted = AXIsProcessTrusted()
        let rememberedFiles = rememberedFilesSummary(bookmarkStore)
        let rememberedFolder = rememberedFolderSummary(bookmarkStore)

        return """
        Alfred Diagnostics

        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App: \(appVersionSummary())

        Permissions
        Notifications: \(notificationStatus.displayName)
        Screen Recording: \(screenRecordingGranted ? "Granted" : "Not granted")
        Accessibility: \(accessibilityGranted ? "Granted" : "Not granted")

        Runtime
        Screen monitoring: \(screenMonitoringActive ? "Active" : "Off")
        Focus session: \(focusSessionActive ? "Active" : "Off")
        Proactive suggestions: \(appState.proactiveSuggestionsEnabled ? "Enabled" : "Off")

        Selected Context
        Selected files: \(selectedFiles.fileURLs.count)
        Selected folder: \(selectedFiles.folderURL == nil ? "None" : "Present")
        Remembered file access: \(rememberedFiles)
        Remembered folder access: \(rememberedFolder)
        """
    }

    private static func appVersionSummary() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String

        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return "Build \(build)"
        default:
            return "Unknown"
        }
    }

    private static func rememberedFilesSummary(_ store: SecurityScopedBookmarkStore) -> String {
        do {
            guard let resolution = try store.resolveFiles() else { return "None" }
            if resolution.isStale {
                return "Stale; reselect files and remember access again"
            }
            return "\(resolution.urls.count)"
        } catch {
            return "Unavailable; reselect files and remember access again"
        }
    }

    private static func rememberedFolderSummary(_ store: SecurityScopedBookmarkStore) -> String {
        do {
            guard let resolution = try store.resolveFolder() else { return "None" }
            if resolution.isStale {
                return "Stale; reselect folder and remember access again"
            }
            return resolution.urls.isEmpty ? "None" : "\(resolution.urls.count)"
        } catch {
            return "Unavailable; reselect folder and remember access again"
        }
    }
}

private extension UNAuthorizationStatus {
    var displayName: String {
        switch self {
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .authorized:
            return "Granted"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }
}
