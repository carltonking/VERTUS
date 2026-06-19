import AppKit
import Foundation
import OSLog

final class AppActivityMonitor {
    private let store: TimelineStore
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.alfred.timeline", category: "monitor")
    private var lastFrontApp: (name: String, bundleID: String?)?

    init(store: TimelineStore) {
        self.store = store
    }

    deinit {
        stop()
    }

    func start() {
        guard observers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleLaunch(note)
        }
        observers.append(launchObs)

        let terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleTerminate(note)
        }
        observers.append(terminateObs)

        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleActivate(note)
        }
        observers.append(activateObs)

        // Record current frontmost app as focused on start
        if let app = NSWorkspace.shared.frontmostApplication,
           let name = app.localizedName {
            let bundleID = app.bundleIdentifier
            lastFrontApp = (name, bundleID)
            store.recordEvent(
                type: .appFocused,
                applicationName: name,
                windowTitle: focusedWindowTitle(for: app),
                metadata: bundleID.map { ["bundleIdentifier": $0] }
            )
        }

        logger.info("App activity monitoring started")
    }

    func stop() {
        for obs in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        observers.removeAll()
        lastFrontApp = nil
        logger.info("App activity monitoring stopped")
    }

    // MARK: - Handlers

    private func handleLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName
        else { return }

        store.recordEvent(
            type: .appOpened,
            applicationName: name,
            metadata: app.bundleIdentifier.map { ["bundleIdentifier": $0] }
        )
    }

    private func handleTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName
        else { return }

        store.recordEvent(
            type: .appClosed,
            applicationName: name,
            metadata: app.bundleIdentifier.map { ["bundleIdentifier": $0] }
        )
    }

    private func handleActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName
        else { return }

        let bundleID = app.bundleIdentifier
        let title = focusedWindowTitle(for: app)

        // Deduplicate — don't record if same app as last
        if lastFrontApp?.name == name, lastFrontApp?.bundleID == bundleID {
            lastFrontApp = (name, bundleID)
            lastFrontWindowTitle = title
            return
        }

        lastFrontApp = (name, bundleID)
        lastFrontWindowTitle = title

        store.recordEvent(
            type: .appFocused,
            applicationName: name,
            windowTitle: title,
            metadata: bundleID.map { ["bundleIdentifier": $0] }
        )
    }

    // MARK: - Window title

    private var lastFrontWindowTitle: String?

    private func focusedWindowTitle(for app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted(),
              let pid = app.processIdentifier as pid_t?
        else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef
        else { return nil }

        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success
        else { return nil }

        return titleRef as? String
    }
}
