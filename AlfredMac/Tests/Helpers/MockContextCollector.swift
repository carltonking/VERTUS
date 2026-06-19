import Foundation
@testable import Alfred

final class MockContextCollector: ContextCollectorProtocol {
    var activeAppName: String?
    var currentHour: Int = 12
    var currentDayOfWeek: Int = 3
    var recentQueryHistory: [String] = []
    var activeProjectFromMemory: String?
    var windowTitle: String?
    var activeBundleIdentifier: String?

    func getActiveAppName() -> String? { activeAppName }
    func getCurrentHour() -> Int { currentHour }
    func getCurrentDayOfWeek() -> Int { currentDayOfWeek }
    func getRecentQueryHistory(limit: Int) -> [String] { Array(recentQueryHistory.prefix(limit)) }
    func getActiveProjectFromMemory() -> String? { activeProjectFromMemory }
    func getWindowTitle() -> String? { windowTitle }
    func getActiveBundleIdentifier() -> String? { activeBundleIdentifier }
}
