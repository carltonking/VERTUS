import Foundation

final class BehavioralLearningService {
    private let memory: MemoryStore
    private let profileStore: UserProfileStore
    private var profile: UserProfile
    private var lastShownSuggestions: [SuggestionInteraction] = []

    var currentProfile: UserProfile {
        profile
    }

    init(memory: MemoryStore) {
        self.memory = memory
        self.profileStore = UserProfileStore()
        self.profile = profileStore.load()
    }

    // MARK: - Recording

    func recordSuggestionsShown(_ suggestions: [ProactiveSuggestion], context: AppContext?) {
        let now = Date()
        let activeSuggestionInteractions: [SuggestionInteraction] = suggestions.map { s in
            SuggestionInteraction(
                id: nil,
                suggestionId: s.id,
                category: category(for: s),
                accepted: false,
                dismissed: false,
                timestamp: now,
                contextAppName: context?.appName,
                contextBundleIdentifier: context?.bundleIdentifier,
                contextWindowTitle: context?.windowTitle
            )
        }

        for interaction in activeSuggestionInteractions {
            try? memory.saveSuggestionInteraction(interaction)
        }

        dispatchPreviouslyShown(now: now)
        lastShownSuggestions = activeSuggestionInteractions
    }

    func recordQueryAccepted(_ query: String, context: AppContext?) {
        let now = Date()
        let matchedCategory = inferCategory(from: query, context: context)

        let interaction = SuggestionInteraction(
            id: nil,
            suggestionId: "manual-\(query.prefix(20).hashValue)",
            category: matchedCategory,
            accepted: true,
            dismissed: false,
            timestamp: now,
            contextAppName: context?.appName,
            contextBundleIdentifier: context?.bundleIdentifier,
            contextWindowTitle: context?.windowTitle
        )
        try? memory.saveSuggestionInteraction(interaction)

        updateProfileFromInteraction(category: matchedCategory)
    }

    // MARK: - Profile queries

    func topInterests(limit: Int = 5) -> [String] {
        let scored = profile.acceptedSuggestionCategories
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
        return scored.isEmpty ? profile.interests : scored
    }

    func preferredSuggestionTypes() -> [String] {
        guard let rates = try? memory.suggestionAcceptanceRates(days: 30) else {
            return profile.preferredAssistanceTypes
        }
        return rates
            .filter { $0.rate > 0.3 }
            .sorted { $0.rate > $1.rate }
            .map(\.category)
    }

    func activeProjects() -> [ActiveProject] {
        profile.activeProjects
            .filter { $0.frequencyScore > 0.3 }
            .sorted { $0.frequencyScore > $1.frequencyScore }
    }

    func suggestionCategoriesByConfidence() -> [(category: String, confidence: Double)] {
        guard let rates = try? memory.suggestionAcceptanceRates(days: 60) else {
            return profile.acceptedSuggestionCategories.map { ($0.key, $0.value) }
        }
        return rates.map { ($0.category, $0.rate) }
    }

    func lastInteractionDate(for category: String) -> Date? {
        guard let interactions = try? memory.suggestionInteractions(for: category, days: 365),
              let latest = interactions.first
        else { return nil }
        return latest.timestamp
    }

    // MARK: - Profile maintenance

    func refreshProfile() {
        profile = profileStore.load()
    }

    func saveProfile() {
        try? profileStore.save(profile)
    }

    func generateProfileUpdate() {
        detectInterests()
        detectRecurringWorkflows()
        saveProfile()
    }

    // MARK: - Forget / Reset

    func forgetInterest(_ interest: String) {
        profile.interests.removeAll { $0.lowercased() == interest.lowercased() }
        profile.acceptedSuggestionCategories.removeValue(forKey: interest.lowercased())
        profile.preferredAssistanceTypes.removeAll { $0.lowercased() == interest.lowercased() }
        saveProfile()
    }

    func clearMemory() {
        try? memory.clearSuggestionInteractions()
        saveProfile()
    }

    func resetProfile() {
        profile = UserProfile.defaultProfile
        saveProfile()
    }

    // MARK: - Private

    private func dispatchPreviouslyShown(now: Date) {
        for var interaction in lastShownSuggestions {
            interaction.dismissed = true
            interaction.accepted = false
            try? memory.saveSuggestionInteraction(interaction)
        }
        lastShownSuggestions.removeAll()
    }

    private func category(for suggestion: ProactiveSuggestion) -> String {
        let title = suggestion.title.lowercased()
        if title.contains("summarize video") || title.contains("key takeaways") || title.contains("explain this") { return "youtube" }
        if title.contains("review code") || title.contains("fix visible bug") || title.contains("write tests") { return "coding" }
        if title.contains("improve writing") || title.contains("check grammar") || title.contains("rewrite tone") { return "writing" }
        if title.contains("summarize page") || title.contains("find action items") { return "browser" }
        return "default"
    }

    private func inferCategory(from query: String, context: AppContext?) -> String {
        let lowered = query.lowercased()
        let app = context?.appName.lowercased() ?? ""
        let bundle = context?.bundleIdentifier?.lowercased() ?? ""
        let url = context?.browserURL?.lowercased() ?? ""

        if url.contains("youtube") || lowered.contains("youtube") || lowered.contains("video") { return "youtube" }
        if isCodingApp(app: app, bundle: bundle) || lowered.contains("code") || lowered.contains("debug") || lowered.contains("fix") || lowered.contains("review") || lowered.contains("test") || lowered.contains("implement") || lowered.contains("refactor") { return "coding" }
        if isWritingApp(app: app, bundle: bundle, url: url) || lowered.contains("write") || lowered.contains("draft") || lowered.contains("edit") || lowered.contains("grammar") || lowered.contains("rewrite") { return "writing" }
        if isBrowser(bundle: bundle) || lowered.contains("search") || lowered.contains("look up") || lowered.contains("find") { return "browser" }
        return "default"
    }

    private func isCodingApp(app: String, bundle: String) -> Bool {
        let codingApps = ["xcode", "visual studio code", "cursor", "zed", "sublime text", "terminal", "iterm", "warp", "pycharm", "intellij", "webstorm", "android studio"]
        return codingApps.contains(where: { app.contains($0) || bundle.contains($0.replacingOccurrences(of: " ", with: "")) })
    }

    private func isWritingApp(app: String, bundle: String, url: String) -> Bool {
        if url.contains("docs.google.com") || url.contains("notion.so") || url.contains("overleaf.com") { return true }
        let writingApps = ["notes", "pages", "microsoft word", "textedit", "ulysses", "obsidian", "notion", "bear", "slack", "mail", "messages"]
        return writingApps.contains(where: { app.contains($0) || bundle.contains($0.replacingOccurrences(of: " ", with: "")) })
    }

    private func isBrowser(bundle: String) -> Bool {
        let browsers = ["com.apple.safari", "com.google.chrome", "com.google.chrome.canary", "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser"]
        return browsers.contains(bundle)
    }

    private func updateProfileFromInteraction(category: String) {
        var accepted = profile.acceptedSuggestionCategories
        let currentConfidence = accepted[category] ?? 0.0
        accepted[category] = min(1.0, currentConfidence + 0.05)
        profile.acceptedSuggestionCategories = accepted

        if !profile.preferredAssistanceTypes.contains(category) {
            let allRates = (try? memory.suggestionAcceptanceRates(days: 30)) ?? []
            let isPreferred = allRates.contains { $0.category == category && $0.rate > 0.3 }
            if isPreferred || currentConfidence + 0.05 > 0.3 {
                profile.preferredAssistanceTypes.append(category)
            }
        }

        if accepted[category] ?? 0.0 > 0.4 {
            if !profile.interests.contains(category) {
                profile.interests.append(category)
            }
        }
    }

    private func detectInterests() {
        guard let rates = try? memory.suggestionAcceptanceRates(days: 60) else { return }

        let highConfidence = rates.filter { $0.rate > 0.4 }.map(\.category)
        if !highConfidence.isEmpty {
            profile.interests = Array(Set(profile.interests + highConfidence))
        }

        let ignored = rates.filter { $0.shown > 3 && $0.rate < 0.1 }.map(\.category)
        for category in ignored {
            if !profile.ignoredSuggestionCategories.contains(category) {
                profile.ignoredSuggestionCategories.append(category)
            }
            profile.acceptedSuggestionCategories[category] = max(0.0, (profile.acceptedSuggestionCategories[category] ?? 0.0) - 0.1)
        }
    }

    private func detectRecurringWorkflows() {
        guard let queries = try? memory.recentUserQueries(limit: 100) else { return }

        let loweredQueries = queries.map { $0.lowercased() }
        var workflowCounts: [String: Int] = [:]

        let patterns: [(keyword: String, project: String)] = [
            ("review", "code review"),
            ("debug", "debugging"),
            ("implement", "implementation"),
            ("refactor", "refactoring"),
            ("test", "testing"),
            ("write", "writing"),
            ("design", "design"),
            ("architect", "architecture"),
            ("deploy", "deployment"),
            ("migrate", "migration"),
        ]

        for query in loweredQueries {
            for (keyword, project) in patterns {
                if query.contains(keyword) {
                    workflowCounts[project, default: 0] += 1
                }
            }
        }

        for (name, count) in workflowCounts where count >= 3 {
            if let existing = profile.activeProjects.firstIndex(where: { $0.name == name }) {
                var project = profile.activeProjects[existing]
                project.lastActive = Date()
                project.frequencyScore = min(1.0, project.frequencyScore + 0.1)
                profile.activeProjects[existing] = project
            } else {
                let project = ActiveProject(name: name, lastActive: Date(), frequencyScore: 0.3)
                profile.activeProjects.append(project)
            }
        }

        profile.activeProjects.sort { $0.frequencyScore > $1.frequencyScore }
        if profile.activeProjects.count > 10 {
            profile.activeProjects = Array(profile.activeProjects.prefix(10))
        }
    }
}
