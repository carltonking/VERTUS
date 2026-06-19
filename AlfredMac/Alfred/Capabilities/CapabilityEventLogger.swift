import Foundation
import OSLog

actor CapabilityEventLogger {
    static let shared = CapabilityEventLogger()

    private let logger = Logger(subsystem: "com.alfred.app", category: "capabilities")
    private var events: [String] = []
    private let maxEvents = 100

    func record(_ capability: String, _ event: String, detail: String? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeDetail = detail.map { " - \($0)" } ?? ""
        let line = "\(timestamp) [\(capability)] \(event)\(safeDetail)"
        events.append(line)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        logger.info("\(line, privacy: .public)")
    }

    func recentEvents(limit: Int = 20) -> [String] {
        Array(events.suffix(limit))
    }
}
