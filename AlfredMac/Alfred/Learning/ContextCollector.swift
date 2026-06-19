import AppKit
import Foundation

protocol ContextCollectorProtocol: AnyObject {
    func getActiveAppName() -> String?
    func getCurrentHour() -> Int
    func getCurrentDayOfWeek() -> Int
    func getRecentQueryHistory(limit: Int) -> [String]
    func getActiveProjectFromMemory() -> String?
    func getWindowTitle() -> String?
    func getActiveBundleIdentifier() -> String?
}

final class ContextCollector: ContextCollectorProtocol {
    private weak var memoryStore: MemoryStore?
    private weak var relationshipMemory: RelationshipMemoryService?
    private let calendar = Calendar.current

    private var cachedAppName: (value: String?, timestamp: Date)?
    private var cachedWindowTitle: (value: String?, timestamp: Date)?
    private let cacheDuration: TimeInterval = 60

    init(memoryStore: MemoryStore? = nil, relationshipMemory: RelationshipMemoryService? = nil) {
        self.memoryStore = memoryStore
        self.relationshipMemory = relationshipMemory
    }

    func setMemoryStore(_ store: MemoryStore) {
        memoryStore = store
    }

    func getActiveAppName() -> String? {
        if let cached = cachedAppName, Date().timeIntervalSince(cached.timestamp) < cacheDuration {
            return cached.value
        }
        let name = NSWorkspace.shared.frontmostApplication?.localizedName
        cachedAppName = (name, Date())
        return name
    }

    func getCurrentHour() -> Int {
        calendar.component(.hour, from: Date())
    }

    func getCurrentDayOfWeek() -> Int {
        calendar.component(.weekday, from: Date())
    }

    func getRecentQueryHistory(limit: Int = 5) -> [String] {
        guard let store = memoryStore else { return [] }
        do {
            return try store.recentUserQueries(limit: limit)
        } catch {
            return []
        }
    }

    func getActiveProjectFromMemory() -> String? {
        relationshipMemory?.topProjects(limit: 1).first?.content
    }

    func getWindowTitle() -> String? {
        if let cached = cachedWindowTitle, Date().timeIntervalSince(cached.timestamp) < cacheDuration {
            return cached.value
        }
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let pid = app.processIdentifier as pid_t?
        else {
            cachedWindowTitle = (nil, Date())
            return nil
        }

        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef
        else {
            cachedWindowTitle = (nil, Date())
            return nil
        }

        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success
        else {
            cachedWindowTitle = (nil, Date())
            return nil
        }

        let title = titleRef as? String
        cachedWindowTitle = (title, Date())
        return title
    }

    func getActiveBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func invalidateCache() {
        cachedAppName = nil
        cachedWindowTitle = nil
    }
}
