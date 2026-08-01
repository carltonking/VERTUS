import Foundation

enum LinkType: String, Codable, CaseIterable {
    case keywordOverlap
    case temporalProximity
    case categoryRelationship
    case contradictory
    case causeEffect

    var label: String {
        switch self {
        case .keywordOverlap: return "Keyword Overlap"
        case .temporalProximity: return "Temporal Proximity"
        case .categoryRelationship: return "Category Relationship"
        case .contradictory: return "Contradictory"
        case .causeEffect: return "Cause & Effect"
        }
    }
}

struct MemoryLink: Identifiable, Equatable {
    let id: UUID
    let fromId: UUID
    let toId: UUID
    let type: LinkType
    var strength: Double
    var userConfirmed: Bool
    var userRejected: Bool
    let createdAt: Date
    var lastVerifiedAt: Date
    var lastReferencedAt: Date?

    var isDecayed: Bool {
        strength < 0.1
    }

    static func make(
        from fromId: UUID,
        to toId: UUID,
        type: LinkType,
        strength: Double,
        userConfirmed: Bool = false
    ) -> MemoryLink {
        let now = Date()
        return MemoryLink(
            id: UUID(),
            fromId: fromId,
            toId: toId,
            type: type,
            strength: strength,
            userConfirmed: userConfirmed,
            userRejected: false,
            createdAt: now,
            lastVerifiedAt: now,
            lastReferencedAt: nil
        )
    }
}



extension MemoryLink: Codable {
    enum CodingKeys: String, CodingKey {
        case id, fromId, toId, type, strength, userConfirmed, userRejected, createdAt, lastVerifiedAt, lastReferencedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fromId = try container.decode(UUID.self, forKey: .fromId)
        toId = try container.decode(UUID.self, forKey: .toId)
        type = try container.decode(LinkType.self, forKey: .type)
        strength = try container.decode(Double.self, forKey: .strength)
        userConfirmed = try container.decode(Bool.self, forKey: .userConfirmed)
        userRejected = try container.decode(Bool.self, forKey: .userRejected)
        let dateFormatter = Self.iso8601
        createdAt = try dateFormatter.date(from: container.decode(String.self, forKey: .createdAt)) ?? Date()
        lastVerifiedAt = try dateFormatter.date(from: container.decode(String.self, forKey: .lastVerifiedAt)) ?? Date()
        lastReferencedAt = try container.decodeIfPresent(String.self, forKey: .lastReferencedAt).flatMap { dateFormatter.date(from: $0) }
    }

    // One shared formatter instead of allocating per link on every save/load of the links array.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fromId, forKey: .fromId)
        try container.encode(toId, forKey: .toId)
        try container.encode(type, forKey: .type)
        try container.encode(strength, forKey: .strength)
        try container.encode(userConfirmed, forKey: .userConfirmed)
        try container.encode(userRejected, forKey: .userRejected)
        let dateFormatter = Self.iso8601
        try container.encode(dateFormatter.string(from: createdAt), forKey: .createdAt)
        try container.encode(dateFormatter.string(from: lastVerifiedAt), forKey: .lastVerifiedAt)
        try container.encodeIfPresent(lastReferencedAt.map { dateFormatter.string(from: $0) }, forKey: .lastReferencedAt)
    }
}

protocol MemoryGraphStoreProtocol {
    func load() -> [MemoryLink]
    func save(_ links: [MemoryLink]) throws
}

final class MemoryGraphStore: MemoryGraphStoreProtocol {
    private let fileURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appending(path: ".alfred/memory_links.json", directoryHint: .notDirectory)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [MemoryLink] {
        guard let data = try? Data(contentsOf: fileURL),
              let links = try? JSONDecoder().decode([MemoryLink].self, from: data)
        else { return [] }
        return links
    }

    func save(_ links: [MemoryLink]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(links)
        try data.write(to: fileURL, options: .atomic)
    }
}
