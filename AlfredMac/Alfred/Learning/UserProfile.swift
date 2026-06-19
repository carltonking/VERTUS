import Foundation

struct ActiveProject: Codable, Equatable {
    var name: String
    var lastActive: Date
    var frequencyScore: Double
}

struct UserProfile: Codable {
    var interests: [String]
    var expertiseAreas: [String]
    var preferredAssistanceTypes: [String]
    var communicationStyle: String
    var activeProjects: [ActiveProject]
    var ignoredSuggestionCategories: [String]
    var acceptedSuggestionCategories: [String: Double]
    var lastUpdated: Date

    static let defaultProfile = UserProfile(
        interests: [],
        expertiseAreas: [],
        preferredAssistanceTypes: [],
        communicationStyle: "concise",
        activeProjects: [],
        ignoredSuggestionCategories: [],
        acceptedSuggestionCategories: [:],
        lastUpdated: Date()
    )
}

final class UserProfileStore {
    private let fileURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appending(path: ".alfred/profile.json", directoryHint: .notDirectory)
    }

    func load() -> UserProfile {
        guard let data = try? Data(contentsOf: fileURL),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data)
        else {
            return .defaultProfile
        }
        return profile
    }

    func save(_ profile: UserProfile) throws {
        var mutable = profile
        mutable.lastUpdated = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(mutable)
        try data.write(to: fileURL, options: .atomic)
    }
}
