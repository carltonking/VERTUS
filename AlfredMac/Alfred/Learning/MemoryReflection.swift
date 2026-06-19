import Foundation

enum ReflectionType: String, Codable, CaseIterable {
    case pattern
    case contradiction
    case milestone
    case timeAssociation
    case toolPreference

    var label: String {
        switch self {
        case .pattern: return "Pattern"
        case .contradiction: return "Contradiction"
        case .milestone: return "Milestone"
        case .timeAssociation: return "Time Association"
        case .toolPreference: return "Tool Preference"
        }
    }
}

struct Reflection: Codable, Identifiable {
    let id: UUID
    let type: ReflectionType
    let content: String
    var supportingMemoryIds: [UUID]
    var confidence: Double
    let createdAt: Date
    var lastPresented: Date?
    var dismissed: Bool

    static func make(
        type: ReflectionType,
        content: String,
        supportingMemoryIds: [UUID],
        confidence: Double
    ) -> Reflection {
        Reflection(
            id: UUID(),
            type: type,
            content: content,
            supportingMemoryIds: supportingMemoryIds,
            confidence: confidence,
            createdAt: Date(),
            lastPresented: nil,
            dismissed: false
        )
    }
}

protocol ReflectionStoreProtocol {
    func load() -> [Reflection]
    func save(_ reflections: [Reflection]) throws
}

final class ReflectionStore: ReflectionStoreProtocol {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(fileURL: home.appending(path: ".alfred/reflections.json", directoryHint: .notDirectory))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [Reflection] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([Reflection].self, from: data)) ?? []
    }

    func save(_ reflections: [Reflection]) throws {
        let data = try encoder.encode(reflections)
        try data.write(to: fileURL, options: .atomic)
    }
}
