import Foundation
import GRDB

enum HabitType: String, Codable, CaseIterable {
    case application_usage
    case work_schedule
    case study_schedule
    case communication_pattern
    case file_organization
    case productivity_pattern
    case custom
}

struct HabitRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "habit_records"

    var id: Int64?
    var name: String
    var habitType: String
    var confidence: Double
    var firstObserved: Double
    var lastObserved: Double
    var occurrenceCount: Int
    var metadataJSON: String

    var metadata: [String: String]? {
        guard let data = metadataJSON.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}

struct Habit {
    let id: Int64?
    let name: String
    let type: HabitType
    let confidence: Double
    let firstObserved: Date
    let lastObserved: Date
    let occurrenceCount: Int
    let metadata: [String: String]?
}
