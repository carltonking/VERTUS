import Foundation

enum SuggestionType: String, Codable {
    case reminder
    case tip
    case continuation
    case insight
    case action
}

enum SuggestionAction: Equatable {
    case insertText(String)
    case openQuery(String)
    case runWorkflow(String)
    case showMemory(String)
}

extension SuggestionAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case insertText, openQuery, runWorkflow, showMemory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .insertText) {
            self = .insertText(value)
        } else if let value = try? container.decode(String.self, forKey: .openQuery) {
            self = .openQuery(value)
        } else if let value = try? container.decode(String.self, forKey: .runWorkflow) {
            self = .runWorkflow(value)
        } else if let value = try? container.decode(String.self, forKey: .showMemory) {
            self = .showMemory(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unknown SuggestionAction")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .insertText(let value):
            try container.encode(value, forKey: .insertText)
        case .openQuery(let value):
            try container.encode(value, forKey: .openQuery)
        case .runWorkflow(let value):
            try container.encode(value, forKey: .runWorkflow)
        case .showMemory(let value):
            try container.encode(value, forKey: .showMemory)
        }
    }
}

struct MemorySuggestion: Identifiable, Codable, Equatable {
    let id: String
    let type: SuggestionType
    let title: String
    let subtitle: String
    let action: SuggestionAction
    let memoryId: String?
    let confidence: Double
    let createdAt: Date
    var expiresAt: Date
    var dismissed: Bool

    static func make(
        type: SuggestionType,
        title: String,
        subtitle: String,
        action: SuggestionAction,
        memoryId: String? = nil,
        confidence: Double
    ) -> MemorySuggestion {
        MemorySuggestion(
            id: UUID().uuidString,
            type: type,
            title: title,
            subtitle: subtitle,
            action: action,
            memoryId: memoryId,
            confidence: confidence,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            dismissed: false
        )
    }
}

protocol MemorySuggestionStoreProtocol {
    func load() -> [MemorySuggestion]
    func save(_ suggestions: [MemorySuggestion]) throws
}

final class MemorySuggestionStore: MemorySuggestionStoreProtocol {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(fileURL: home.appending(path: ".alfred/proactive_suggestions.json", directoryHint: .notDirectory))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [MemorySuggestion] {
        guard let data = try? Data(contentsOf: fileURL),
              let suggestions = try? decoder.decode([MemorySuggestion].self, from: data)
        else { return [] }
        return suggestions
    }

    func save(_ suggestions: [MemorySuggestion]) throws {
        let data = try encoder.encode(suggestions)
        try data.write(to: fileURL, options: .atomic)
    }
}

protocol SuggestionBlocklistStoreProtocol {
    func load() -> Set<String>
    func save(_ items: Set<String>) throws
}

final class SuggestionBlocklistStore: SuggestionBlocklistStoreProtocol {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(fileURL: home.appending(path: ".alfred/suggestion_blocklist.json", directoryHint: .notDirectory))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? decoder.decode([String].self, from: data)
        else { return [] }
        return Set(items)
    }

    func save(_ items: Set<String>) throws {
        let data = try encoder.encode(Array(items))
        try data.write(to: fileURL, options: .atomic)
    }
}
