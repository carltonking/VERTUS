import Foundation

struct PersonalContext {
    let identitySummary: String
    let currentFocuses: [String]
    let activeProjects: [String]
    let preferredHelpTypes: [String]
    let communicationPreferences: String
    let recentWorkSummary: String
    let generatedAt: Date
}

final class PersonalContextService {
    private let memory: MemoryStore
    private let learningService: BehavioralLearningService
    private let projectAwareness: ProjectAwarenessService
    private var cachedContext: PersonalContext?
    private var lastGeneration: Date?
    private let cacheLifetime: TimeInterval = 300

    init(
        memory: MemoryStore,
        learningService: BehavioralLearningService,
        projectAwareness: ProjectAwarenessService
    ) {
        self.memory = memory
        self.learningService = learningService
        self.projectAwareness = projectAwareness
    }

    // MARK: - Public

    func personalContext() -> String {
        let context = getOrGenerate()
        return format(context)
    }

    func structuredContext() -> PersonalContext {
        getOrGenerate()
    }

    func refresh() {
        cachedContext = generate()
        lastGeneration = Date()
    }

    // MARK: - Cache

    private func getOrGenerate() -> PersonalContext {
        if let cached = cachedContext, let last = lastGeneration, Date().timeIntervalSince(last) < cacheLifetime {
            return cached
        }
        let fresh = generate()
        cachedContext = fresh
        lastGeneration = Date()
        return fresh
    }

    // MARK: - Generation

    private func generate() -> PersonalContext {
        let profile = learningService.currentProfile
        let categoryRates = learningService.suggestionCategoriesByConfidence()
        let rateMap = Dictionary(uniqueKeysWithValues: categoryRates.map { ($0.category, $0.confidence) })

        let identitySummary = buildIdentity(from: profile, rates: rateMap)
        let focuses = buildFocuses(from: projectAwareness, profile: profile, rates: rateMap)
        let projects = buildProjects(from: projectAwareness, profile: profile)
        let helpTypes = buildHelpTypes(from: profile, rates: rateMap)
        let communicationPrefs = profile.communicationStyle
        let recentSummary = buildRecentWork()

        return PersonalContext(
            identitySummary: identitySummary,
            currentFocuses: focuses,
            activeProjects: projects,
            preferredHelpTypes: helpTypes,
            communicationPreferences: communicationPrefs,
            recentWorkSummary: recentSummary,
            generatedAt: Date()
        )
    }

    // MARK: - Identity

    private func buildIdentity(from profile: UserProfile, rates: [String: Double]) -> String {
        let highConfidenceInterests = profile.interests.filter { rates[$0] ?? 0.0 > 0.4 }
        let topInterests = highConfidenceInterests.prefix(3)

        if topInterests.isEmpty, let best = profile.interests.first {
            return "User has interests in \(best)."
        }

        if topInterests.count == 1 {
            return "User is interested in \(topInterests[0])."
        }

        let joined = topInterests.prefix(2).joined(separator: " and ")
        if topInterests.count > 2 {
            return "User is interested in \(joined) and more."
        }
        return "User is interested in \(joined)."
    }

    // MARK: - Focuses

    private func buildFocuses(
        from projectService: ProjectAwarenessService,
        profile: UserProfile,
        rates: [String: Double]
    ) -> [String] {
        var focuses: [String] = []

        let active = projectService.activeProjects()
        for p in active.prefix(3) where p.confidence >= 0.35 {
            focuses.append(p.displayName)
        }

        let highConfidenceCategories = rates.filter { $0.value > 0.5 }.map(\.key).prefix(2)
        for cat in highConfidenceCategories where !focuses.contains(cat) && focuses.count < 4 {
            focuses.append(cat)
        }

        return focuses
    }

    // MARK: - Projects

    private func buildProjects(
        from projectService: ProjectAwarenessService,
        profile: UserProfile
    ) -> [String] {
        let detected = projectService.activeProjects()
            .filter { $0.confidence >= 0.4 }
            .map { $0.displayName }

        let profileProjects = profile.activeProjects
            .filter { $0.frequencyScore > 0.4 }
            .map { $0.name }

        let merged = Array(Set(detected + profileProjects))
        return merged.sorted().prefix(5).map { $0 }
    }

    // MARK: - Help types

    private func buildHelpTypes(from profile: UserProfile, rates: [String: Double]) -> [String] {
        let preferred = learningService.preferredSuggestionTypes()
        let scored = preferred.filter { rates[$0] ?? 0.0 > 0.4 }
        if scored.isEmpty {
            return preferred.prefix(3).map { $0 }
        }
        return scored.prefix(4).map { $0 }
    }

    // MARK: - Recent work

    private func buildRecentWork() -> String {
        guard let queries = try? memory.recentUserQueries(limit: 30) else { return "" }

        let now = Date()
        let queryPairs = queries.map { ($0, now) }
        let recentQueries = queryPairs.prefix(10).map { $0.0 }

        let compressed = compressQueries(recentQueries)
        guard !compressed.isEmpty else { return "" }

        return compressed.prefix(5).map { "• \($0)" }.joined(separator: "\n")
    }

    private func compressQueries(_ queries: [String]) -> [String] {
        let stopWords = Set([
            "the", "a", "an", "in", "on", "at", "to", "for", "of", "with",
            "and", "or", "but", "is", "are", "was", "were", "can", "could",
            "would", "should", "will", "shall", "do", "does", "did", "have",
            "has", "had", "been", "being", "get", "got", "make", "made",
            "help", "need", "want", "let", "please", "thanks",
        ])

        var seen = Set<String>()
        var compressed: [String] = []

        for query in queries {
            let trimmed = query
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

            if trimmed.count < 10 { continue }

            let words = trimmed.lowercased().split(separator: " ").filter { !stopWords.contains(String($0)) }
            let signature = words.suffix(4).joined(separator: " ")

            if seen.contains(signature) { continue }
            seen.insert(signature)

            let short = words.count > 8
                ? words.prefix(8).joined(separator: " ") + "…"
                : words.joined(separator: " ")

            compressed.append(short)
            if compressed.count >= 5 { break }
        }

        return compressed
    }

    // MARK: - Formatting

    private func format(_ context: PersonalContext) -> String {
        var parts: [String] = []
        parts.append("Identity: \(context.identitySummary)")

        if !context.currentFocuses.isEmpty {
            let focused = context.currentFocuses.map { "• \($0)" }.joined(separator: "\n")
            parts.append("Current Focus:\n\(focused)")
        }

        if !context.activeProjects.isEmpty {
            let projects = context.activeProjects.map { "• \($0)" }.joined(separator: "\n")
            parts.append("Active Projects:\n\(projects)")
        }

        if !context.preferredHelpTypes.isEmpty {
            let help = context.preferredHelpTypes.map { "• \($0)" }.joined(separator: "\n")
            parts.append("Preferred Assistance:\n\(help)")
        }

        if !context.recentWorkSummary.isEmpty {
            parts.append("Recent Activity:\n\(context.recentWorkSummary)")
        }

        let joined = parts.joined(separator: "\n\n")

        // Enforce token budget: rough heuristic ~4 chars per token
        let maxChars = 4000
        if joined.count > maxChars {
            return String(joined.prefix(maxChars))
        }

        return joined
    }
}
