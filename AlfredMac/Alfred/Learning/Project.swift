import Foundation

enum ProjectStatus: String, Codable, Equatable {
    case active
    case dormant
    case archived
}

struct ProjectActivity: Codable, Equatable, Identifiable {
    var id: String { "\(source)-\(description)-\(timestamp.timeIntervalSince1970)" }
    let description: String
    let timestamp: Date
    let source: String
}

struct Project: Codable, Equatable, Identifiable {
    var id: String { normalizedName }
    var displayName: String
    let normalizedName: String
    var description: String
    var confidence: Double
    var lastSeen: Date
    var relatedApps: [String]
    var relatedKeywords: [String]
    var status: ProjectStatus
    var recentActivity: [ProjectActivity]
}

final class ProjectStore {
    private let fileURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appending(path: ".alfred/projects.json", directoryHint: .notDirectory)
    }

    func load() -> [Project] {
        guard let data = try? Data(contentsOf: fileURL),
              let projects = try? JSONDecoder().decode([Project].self, from: data)
        else {
            return []
        }
        return projects
    }

    func save(_ projects: [Project]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(projects)
        try data.write(to: fileURL, options: .atomic)
    }
}
