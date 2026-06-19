import Foundation
import GRDB
import OSLog

final class TimelineStore {
    private let db: DatabaseQueue
    private let summarizer = TimelineSummarizer()
    private let logger = Logger(subsystem: "com.alfred.timeline", category: "store")

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Record event

    func recordEvent(
        type: ActivityEventType,
        applicationName: String,
        windowTitle: String? = nil,
        metadata: [String: String]? = nil
    ) {
        let record = ActivityEventRecord(
            id: nil,
            timestamp: Date().timeIntervalSince1970,
            eventType: type.rawValue,
            applicationName: applicationName,
            windowTitle: windowTitle,
            metadataJSON: metadata.flatMap { try? encodeJSON($0) }
        )

        do {
            try db.write { db in
                try record.insert(db)
            }
        } catch {
            logger.error("Failed to record event: \(error.localizedDescription)")
        }
    }

    // MARK: - Queries

    func recentEvents(limit: Int = 100) -> [ActivityEvent] {
        do {
            let records = try db.read { db in
                try ActivityEventRecord
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.reversed().map(ActivityEvent.init)
        } catch {
            logger.error("Failed to fetch recent events: \(error.localizedDescription)")
            return []
        }
    }

    func eventsBetween(start: Date, end: Date) -> [ActivityEvent] {
        do {
            let records = try db.read { db in
                try ActivityEventRecord
                    .filter(Column("timestamp") >= start.timeIntervalSince1970
                        && Column("timestamp") <= end.timeIntervalSince1970)
                    .order(Column("timestamp").asc)
                    .fetchAll(db)
            }
            return records.map(ActivityEvent.init)
        } catch {
            logger.error("Failed to fetch events between dates: \(error.localizedDescription)")
            return []
        }
    }

    func eventsForApplication(_ name: String, limit: Int = 100) -> [ActivityEvent] {
        do {
            let records = try db.read { db in
                try ActivityEventRecord
                    .filter(Column("applicationName") == name)
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.reversed().map(ActivityEvent.init)
        } catch {
            logger.error("Failed to fetch events for app: \(error.localizedDescription)")
            return []
        }
    }

    func eventCountsByApplication(since: Date? = nil) -> [(application: String, count: Int)] {
        do {
            let events: [ActivityEvent]
            if let since {
                events = eventsBetween(start: since, end: Date())
            } else {
                events = recentEvents(limit: 5000)
            }
            return summarizer.eventCountsByApplication(events)
        }
    }

    // MARK: - Summaries

    func getRecentTimelineSummary() -> String {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let todayEvents = eventsBetween(start: todayStart, end: Date())
        return summarizer.summarize(todayEvents)
    }

    // MARK: - Maintenance

    func pruneEvents(olderThan days: Int) {
        let cutoff = Date().timeIntervalSince1970 - TimeInterval(days * 86_400)
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM activity_timeline WHERE timestamp < ?", arguments: [cutoff])
            }
            logger.info("Pruned events older than \(days) days")
        } catch {
            logger.error("Failed to prune events: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func encodeJSON(_ dict: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
