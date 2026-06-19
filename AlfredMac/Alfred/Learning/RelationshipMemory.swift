import Foundation

enum MemoryCategory: String, Codable, CaseIterable, Equatable {
    case goals
    case projects
    case preferences
    case skills
    case workflows
    case recurringProblems
    case longTermInterests

    var label: String {
        switch self {
        case .goals: return "Goals"
        case .projects: return "Projects"
        case .preferences: return "Preferences"
        case .skills: return "Skills"
        case .workflows: return "Workflows"
        case .recurringProblems: return "Recurring Problems"
        case .longTermInterests: return "Long-Term Interests"
        }
    }
}

struct RelationshipMemory: Identifiable, Codable, Equatable {
    var id: UUID
    var category: MemoryCategory
    var content: String
    var source: String
    var importance: Double
    var createdAt: Date
    var lastReferenced: Date
    var mentionCount: Int
    var correctedAt: Date?
    var archivedAt: Date?
    var reasonSaved: String
    var manualOverride: Bool
    var manualImportance: Double?

    var isArchived: Bool { archivedAt != nil }

    var ageDays: Double {
        -createdAt.timeIntervalSinceNow / 86400
    }

    var daysSinceLastReferenced: Double {
        -lastReferenced.timeIntervalSinceNow / 86400
    }

    var effectiveImportance: Double {
        if manualOverride, let mi = manualImportance {
            return mi
        }
        return importance
    }

    static func make(
        category: MemoryCategory,
        content: String,
        source: String,
        importance: Double,
        reasonSaved: String
    ) -> RelationshipMemory {
        let now = Date()
        return RelationshipMemory(
            id: UUID(),
            category: category,
            content: content,
            source: source,
            importance: importance,
            createdAt: now,
            lastReferenced: now,
            mentionCount: 1,
            correctedAt: nil,
            archivedAt: nil,
            reasonSaved: reasonSaved,
            manualOverride: false,
            manualImportance: nil
        )
    }
}

protocol RelationshipMemoryStoreProtocol {
    func load() -> [RelationshipMemory]
    func save(_ memories: [RelationshipMemory]) throws
}

final class RelationshipMemoryStore: RelationshipMemoryStoreProtocol {
    private let fileURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appending(path: ".alfred/relationship_memories.json", directoryHint: .notDirectory)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [RelationshipMemory] {
        guard let data = try? Data(contentsOf: fileURL),
              let memories = try? JSONDecoder().decode([RelationshipMemory].self, from: data)
        else { return [] }
        return memories
    }

    func save(_ memories: [RelationshipMemory]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(memories)
        try data.write(to: fileURL, options: .atomic)
    }
}
