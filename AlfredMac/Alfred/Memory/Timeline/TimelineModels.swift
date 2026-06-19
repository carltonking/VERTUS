import Foundation
import GRDB

// MARK: - Event types

enum ActivityEventType: String, Codable, CaseIterable {
    case appOpened
    case appClosed
    case appFocused
    case documentOpened
    case documentClosed
    case browserNavigation
    case calendarInteraction
    case emailInteraction
    case fileRename
    case fileMove
    case fileCreate
    case fileDelete
    case workflowExecuted
    case custom
}

// MARK: - Database record

struct ActivityEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "activity_timeline"

    var id: Int64?
    var timestamp: Double
    var eventType: String
    var applicationName: String
    var windowTitle: String?
    var metadataJSON: String?

    var decodedMetadata: [String: String]? {
        guard let data = metadataJSON?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}

// MARK: - Domain model

struct ActivityEvent {
    let id: Int64?
    let timestamp: Date
    let eventType: ActivityEventType
    let applicationName: String
    let windowTitle: String?
    let metadata: [String: String]?

    init(record: ActivityEventRecord) {
        self.id = record.id
        self.timestamp = Date(timeIntervalSince1970: record.timestamp)
        self.eventType = ActivityEventType(rawValue: record.eventType) ?? .custom
        self.applicationName = record.applicationName
        self.windowTitle = record.windowTitle
        self.metadata = record.decodedMetadata
    }

    init(
        timestamp: Date = Date(),
        eventType: ActivityEventType,
        applicationName: String,
        windowTitle: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = nil
        self.timestamp = timestamp
        self.eventType = eventType
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.metadata = metadata
    }
}
