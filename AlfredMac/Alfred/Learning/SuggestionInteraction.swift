import Foundation
import GRDB

struct SuggestionInteraction: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "suggestion_interactions"

    var id: Int64?
    var suggestionId: String
    var category: String
    var accepted: Bool
    var dismissed: Bool
    var timestamp: Date
    var contextAppName: String?
    var contextBundleIdentifier: String?
    var contextWindowTitle: String?
}
