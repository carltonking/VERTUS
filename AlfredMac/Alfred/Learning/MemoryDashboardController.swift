import AppKit
import SwiftUI

@MainActor
final class MemoryDashboardController {
    static let shared = MemoryDashboardController()
    private var window: NSWindow?

    private init() {}

    func showDashboard() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Alfred Memory Dashboard"
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.center()

        let delegate = NSApp.delegate as? AppDelegate
        let view = MemoryDashboardView(
            relationshipService: delegate?.relationshipMemoryService,
            reflectionService: delegate?.memoryReflectionService,
            backupService: delegate?.backupService,
            workflowDetectionService: delegate?.workflowDetectionService,
            memoryLinkService: delegate?.memoryLinkService
        )
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func closeDashboard() {
        window?.close()
        window = nil
    }
}
