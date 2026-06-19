import Foundation
import GRDB

// MARK: - Relationship type

enum RelationshipType: String, Codable, CaseIterable {
    case family
    case friend
    case professor
    case classmate
    case recruiter
    case coworker
    case manager
    case client
    case teammate
    case unknown
}

// MARK: - Interaction source

enum InteractionSource: String, Codable, CaseIterable {
    case email
    case calendar
    case notes
    case chat
    case document
    case manual
}

// MARK: - PersonRecord (GRDB)

struct PersonRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "person_records"

    var id: Int64?
    var name: String
    var aliases: String
    var firstSeen: Double
    var lastSeen: Double
    var interactionCount: Int
    var notes: String

    var aliasList: [String] {
        aliases.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }
}

// MARK: - RelationshipRecord (GRDB)

struct RelationshipRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "relationship_records"

    var id: Int64?
    var personId: Int64
    var relationshipType: String
    var confidence: Double
    var lastUpdated: Double
    var isManualOverride: Bool
}

// MARK: - InteractionRecord (GRDB)

struct InteractionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "interaction_records"

    var id: Int64?
    var personId: Int64
    var timestamp: Double
    var source: String
    var summary: String
}

// MARK: - Domain models

struct Person {
    let id: Int64?
    let name: String
    let aliases: [String]
    let firstSeen: Date
    let lastSeen: Date
    let interactionCount: Int
    let notes: String

    var primaryRelationship: Relationship?
}

struct Relationship {
    let id: Int64?
    let personId: Int64
    let type: RelationshipType
    let confidence: Double
    let lastUpdated: Date
    let isManualOverride: Bool
}

struct Interaction {
    let id: Int64?
    let personId: Int64
    let timestamp: Date
    let source: InteractionSource
    let summary: String
}
