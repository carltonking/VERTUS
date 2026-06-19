import Foundation
import GRDB

enum LoopEventType: String, Codable, CaseIterable {
    case suggestionAccepted
    case suggestionEdited
    case suggestionRejected
    case workflowCompleted
    case workflowCancelled
    case fileActionConfirmed
    case fileActionCancelled
}

struct SuggestionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "learning_suggestions"

    var id: Int64?
    var timestamp: Double
    var userPrompt: String
    var alfredResponse: String
    var writingStyleContext: String
    var relationshipContext: String
    var habitContext: String
    var accepted: Bool
    var edited: Bool
    var rejected: Bool
    var finalUserVersion: String
}

struct LoopEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "learning_events"

    var id: Int64?
    var timestamp: Double
    var eventType: String
    var metadataJSON: String
}

struct TrainingSuggestion {
    let id: Int64?
    let timestamp: Date
    let userPrompt: String
    let alfredResponse: String
    let writingStyleContext: String
    let relationshipContext: String
    let habitContext: String
    let accepted: Bool
    let edited: Bool
    let rejected: Bool
    let finalUserVersion: String

    var effectiveResponse: String {
        edited && !finalUserVersion.isEmpty ? finalUserVersion : alfredResponse
    }
}

struct LoopEvent {
    let id: Int64?
    let timestamp: Date
    let type: LoopEventType
    let metadata: [String: String]?
}
