import Foundation
import GRDB

// MARK: - Writing Source

enum WritingSource: String, Codable, CaseIterable {
    case email
    case notes
    case chat
    case document
    case other
}

// MARK: - WritingSample (raw row)

struct WritingSampleRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "writing_samples"

    var id: Int64?
    var source: String
    var text: String
    var wordCount: Int
    var sentenceCount: Int
    var avgSentenceLength: Double
    var hasGreeting: Bool
    var hasClosing: Bool
    var formalityScore: Double
    var emojiCount: Int
    var timestamp: Double
}

// MARK: - Aggregated profile (single-row table)

struct WritingProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "writing_profile"

    var id: Int64?
    var avgSentenceLength: Double
    var avgParagraphLength: Double
    var commonGreetings: String
    var commonClosings: String
    var commonPhrases: String
    var vocabularyPreferences: String
    var punctuationPatterns: String
    var emojiUsage: Double
    var formalityScore: Double
    var totalSamples: Int
    var lastUpdated: Double
}

// MARK: - Domain models

struct WritingSample {
    let id: Int64?
    let source: WritingSource
    let text: String
    let wordCount: Int
    let sentenceCount: Int
    let avgSentenceLength: Double
    let hasGreeting: Bool
    let hasClosing: Bool
    let formalityScore: Double
    let emojiCount: Int
    let timestamp: Date
}

struct WritingProfile {
    let avgSentenceLength: Double
    let avgParagraphLength: Double
    let commonGreetings: [String]
    let commonClosings: [String]
    let commonPhrases: [String]
    let vocabularyPreferences: [String: Double]
    let punctuationPatterns: [String: Int]
    let emojiUsage: Double
    let formalityScore: Double
    let totalSamples: Int
    let lastUpdated: Date
}
