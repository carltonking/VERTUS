import Foundation
import GRDB
import OSLog

final class HabitStore {
    private let db: DatabaseQueue
    private let timeline: TimelineStore
    private let detector = HabitDetector()
    private let logger = Logger(subsystem: "com.alfred.habits", category: "store")

    init(db: DatabaseQueue, timeline: TimelineStore) {
        self.db = db
        self.timeline = timeline
    }

    // MARK: - Detection (called periodically)

    func detectHabits() {
        let lookbackDays = 30
        let start = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        let events = timeline.eventsBetween(start: start, end: Date())
        guard !events.isEmpty else {
            logger.info("No timeline events for habit detection")
            return
        }

        let detected = detector.detect(from: events)
        logger.info("Detected \(detected.count) habit(s) from \(events.count) events")

        for habit in detected where habit.confidence >= 0.3 {
            saveOrUpdate(habit)
        }

        pruneLowConfidence()
    }

    // MARK: - Query

    func getHabits() -> [Habit] {
        do {
            let records = try db.read { db in
                try HabitRecord
                    .order(Column("confidence").desc)
                    .fetchAll(db)
            }
            return records.map { record in
                Habit(
                    id: record.id,
                    name: record.name,
                    type: HabitType(rawValue: record.habitType) ?? .custom,
                    confidence: record.confidence,
                    firstObserved: Date(timeIntervalSince1970: record.firstObserved),
                    lastObserved: Date(timeIntervalSince1970: record.lastObserved),
                    occurrenceCount: record.occurrenceCount,
                    metadata: record.metadata
                )
            }
        } catch {
            logger.error("Failed to get habits: \(error.localizedDescription)")
            return []
        }
    }

    func getTopHabits(limit: Int = 10) -> [Habit] {
        Array(getHabits().prefix(limit))
    }

    func updateHabit(id: Int64, name: String? = nil, confidence: Double? = nil) {
        do {
            try db.write { db in
                if let name {
                    try db.execute(sql: "UPDATE habit_records SET name = ? WHERE id = ?", arguments: [name, id])
                }
                if let confidence {
                    try db.execute(sql: "UPDATE habit_records SET confidence = ? WHERE id = ?", arguments: [confidence, id])
                }
            }
        } catch {
            logger.error("Failed to update habit: \(error.localizedDescription)")
        }
    }

    // MARK: - Summary

    func getHabitSummary() -> String {
        let habits = getTopHabits(limit: 8)
        guard !habits.isEmpty else { return "Not enough data to detect habits yet." }

        var lines: [String] = []
        lines.append("Observed habits:")

        let safeOpenings = ["Appears to", "Often", "Frequently", "Usually tends to"]
        for (i, habit) in habits.enumerated() {
            let opening = safeOpenings[i % safeOpenings.count]
            let confidenceLabel = confidenceWord(habit.confidence)
            let dayLabel = daysSince(habit.lastObserved)
            lines.append("  • \(opening) \(habit.name.lowercased()) (\(confidenceLabel), \(dayLabel))")
        }

        return lines.joined(separator: "\n")
    }

    func generateHabitContext() -> String {
        let habits = getTopHabits(limit: 6)
        guard !habits.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("HABITS:")

        let safeOpenings = ["appears to", "often", "frequently", "usually"]
        for (i, habit) in habits.enumerated() {
            let opening = safeOpenings[i % safeOpenings.count]
            lines.append("  • \(opening) \(habit.name.lowercased())")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Maintenance

    func pruneLowConfidence(threshold: Double = 0.15) {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM habit_records WHERE confidence < ?", arguments: [threshold])
            }
        } catch {
            logger.error("Failed to prune low-confidence habits: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func saveOrUpdate(_ detected: DetectedHabit) {
        do {
            let lowered = detected.name.lowercased()
            if let existing = try db.read({ db in
                try HabitRecord.filter(sql: "LOWER(name) = ?", arguments: [lowered]).fetchOne(db)
            }) {
                let newConfidence = min(existing.confidence + 0.08, 1.0)
                let now = Date().timeIntervalSince1970
                try db.write { db in
                    try db.execute(
                        sql: """
                            UPDATE habit_records
                            SET confidence = ?, lastObserved = ?, occurrenceCount = occurrenceCount + 1
                            WHERE id = ?
                            """,
                        arguments: [newConfidence, now, existing.id]
                    )
                }
            } else {
                let now = Date().timeIntervalSince1970
                let meta = (try? JSONSerialization.data(withJSONObject: detected.metadata, options: []))
                    .map { String(data: $0, encoding: .utf8) ?? "{}" } ?? "{}"
                let record = HabitRecord(
                    id: nil,
                    name: detected.name,
                    habitType: detected.type.rawValue,
                    confidence: detected.confidence,
                    firstObserved: now,
                    lastObserved: now,
                    occurrenceCount: 1,
                    metadataJSON: meta
                )
                try db.write { db in
                    try record.insert(db)
                }
            }
        } catch {
            logger.error("Failed to save habit: \(error.localizedDescription)")
        }
    }

    private func confidenceWord(_ score: Double) -> String {
        switch score {
        case ..<0.3: return "emerging pattern"
        case ..<0.5: return "possible pattern"
        case ..<0.7: return "moderate pattern"
        default:     return "strong pattern"
        }
    }

    private func daysSince(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days == 0 { return "observed today" }
        return "observed \(days) day\(days == 1 ? "" : "s") ago"
    }
}
