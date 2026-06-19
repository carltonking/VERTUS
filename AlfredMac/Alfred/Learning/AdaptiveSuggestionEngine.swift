import Foundation

struct SuggestionScore {
    let suggestion: ProactiveSuggestion
    let score: Double
    let confidence: Double
    let breakdown: ScoreBreakdown
}

struct ScoreBreakdown {
    let acceptanceRate: Double
    let projectRelevance: Double
    let appRelevance: Double
    let recencyPenalty: Double
    let engagementBonus: Double
}

final class AdaptiveSuggestionEngine {
    private let memory: MemoryStore
    private var cooldowns: [String: Date] = [:]
    private var categoryWeights: [String: Double] = [:]
    private let decayHalfLife: TimeInterval = 7 * 86400

    init(memory: MemoryStore) {
        self.memory = memory
    }

    // MARK: - Public API

    func rankSuggestions(
        _ suggestions: [ProactiveSuggestion],
        context: AppContext?,
        activeProject: String?,
        profileCategoryRates: [(category: String, confidence: Double)],
        recentActivity: [String]
    ) -> [SuggestionScore] {
        let categoryRates = Dictionary(uniqueKeysWithValues: profileCategoryRates.map { ($0.category, $0.confidence) })
        let now = Date()

        return suggestions.map { s in
            let cat = category(for: s)
            let acceptanceRate = categoryRates[cat] ?? 0.0
            let projectRelevance = computeProjectRelevance(suggestion: s, activeProject: activeProject)
            let appRelevance = computeAppRelevance(suggestion: s, context: context)
            let recencyPenalty = computeRecencyPenalty(suggestion: s, now: now)
            let engagementBonus = computeEngagementBonus(suggestion: s, recentActivity: recentActivity)

            let raw = (1.0
                + acceptanceRate * 0.35
                + projectRelevance * 0.25
                + appRelevance * 0.10
                - recencyPenalty * 0.20
                + engagementBonus * 0.10)

            let clamped = max(0.0, min(1.5, raw))

            let confidence = normalizeToConfidence(raw: raw, maxPossible: 1.5)

            return SuggestionScore(
                suggestion: s,
                score: clamped,
                confidence: confidence,
                breakdown: ScoreBreakdown(
                    acceptanceRate: acceptanceRate,
                    projectRelevance: projectRelevance,
                    appRelevance: appRelevance,
                    recencyPenalty: recencyPenalty,
                    engagementBonus: engagementBonus
                )
            )
        }
        .sorted { $0.score > $1.score }
    }

    func generateSuggestions(
        for context: AppContext,
        activeProject: String?,
        profileCategoryRates: [(category: String, confidence: Double)],
        recentActivity: [String]
    ) -> [SuggestionScore] {
        var candidates = SuggestionEngine.suggestions(for: context)

        if let project = activeProject, !project.isEmpty {
            let projectSuggestions = makeProjectSuggestions(project: project, context: context)
            candidates.append(contentsOf: projectSuggestions)
        }

        let ranked = rankSuggestions(
            candidates,
            context: context,
            activeProject: activeProject,
            profileCategoryRates: profileCategoryRates,
            recentActivity: recentActivity
        )

        return ranked
    }

    func explainSuggestion(_ score: SuggestionScore) -> String {
        let s = score.suggestion
        var parts: [String] = []
        let b = score.breakdown

        parts.append("\(s.title): \(String(format: "%.2f", score.confidence))")
        parts.append("  acceptanceRate (\(String(format: "%.2f", b.acceptanceRate))): ×0.35 → \(String(format: "%.2f", b.acceptanceRate * 0.35))")
        parts.append("  projectRelevance (\(String(format: "%.2f", b.projectRelevance))): ×0.25 → \(String(format: "%.2f", b.projectRelevance * 0.25))")
        parts.append("  appRelevance (\(String(format: "%.2f", b.appRelevance))): ×0.10 → \(String(format: "%.2f", b.appRelevance * 0.10))")
        parts.append("  recencyPenalty (\(String(format: "%.2f", b.recencyPenalty))): ×0.20 → \(String(format: "%.2f", -b.recencyPenalty * 0.20))")
        parts.append("  engagementBonus (\(String(format: "%.2f", b.engagementBonus))): ×0.10 → \(String(format: "%.2f", b.engagementBonus * 0.10))")
        parts.append("  raw score: \(String(format: "%.2f", score.score))")

        return parts.joined(separator: "\n")
    }

    func structuredExplanation(for score: SuggestionScore) -> SuggestionExplanation {
        let b = score.breakdown

        var source = "context"
        if b.projectRelevance > 0 { source = "project" }
        if b.acceptanceRate > 0.4 { source = "learned" }

        let factors: [FactorContribution] = [
            FactorContribution(
                id: "acceptance",
                name: "Past acceptance rate",
                value: b.acceptanceRate,
                description: b.acceptanceRate > 0.4
                    ? "Accepted \(Int(round(b.acceptanceRate * 100)))% of similar suggestions"
                    : "Low past acceptance"
            ),
            FactorContribution(
                id: "project",
                name: "Active project match",
                value: b.projectRelevance,
                description: b.projectRelevance > 0
                    ? "Matches your current project"
                    : "No project match"
            ),
            FactorContribution(
                id: "app",
                name: "Current app relevance",
                value: b.appRelevance,
                description: b.appRelevance > 0
                    ? "Relevant to your active app"
                    : "Not tied to current app"
            ),
            FactorContribution(
                id: "recency",
                name: "Recency (no-repeat)",
                value: 1.0 - b.recencyPenalty,
                description: b.recencyPenalty > 0
                    ? "Shown recently (cooldown active)"
                    : "Fresh suggestion"
            ),
            FactorContribution(
                id: "engagement",
                name: "Recent engagement",
                value: b.engagementBonus,
                description: b.engagementBonus > 0
                    ? "You were recently engaged in this area"
                    : "No recent engagement"
            ),
        ]

        return SuggestionExplanation(
            id: score.suggestion.id,
            suggestion: score.suggestion,
            confidence: score.confidence,
            source: source,
            factors: factors
        )
    }

    // MARK: - Cooldown

    func markShown(_ suggestion: ProactiveSuggestion) {
        cooldowns[suggestion.id] = Date()
    }

    func lastShown(_ suggestion: ProactiveSuggestion) -> Date? {
        cooldowns[suggestion.id]
    }

    func clearCooldown(for suggestion: ProactiveSuggestion) {
        cooldowns.removeValue(forKey: suggestion.id)
    }

    // MARK: - Feedback loop

    func recordAccepted(category: String) {
        let current = categoryWeights[category] ?? 0.0
        categoryWeights[category] = min(1.0, current + 0.05)
    }

    func recordDismissed(category: String) {
        let current = categoryWeights[category] ?? 0.0
        categoryWeights[category] = max(0.0, current - 0.02)
    }

    func weight(for category: String) -> Double {
        categoryWeights[category] ?? 0.0
    }

    // MARK: - Scoring factors

    private func computeProjectRelevance(suggestion: ProactiveSuggestion, activeProject: String?) -> Double {
        guard let project = activeProject, !project.isEmpty else { return 0.0 }
        let title = suggestion.title.lowercased()
        let projectLower = project.lowercased()

        if title.contains(projectLower) { return 0.5 }
        if title.contains("continue") || title.contains("resume") { return 0.3 }
        return 0.0
    }

    private func computeAppRelevance(suggestion: ProactiveSuggestion, context: AppContext?) -> Double {
        guard let context else { return 0.0 }
        let cat = category(for: suggestion)
        let app = context.appName.lowercased()

        let codingApps = ["xcode", "visual studio code", "cursor", "zed", "sublime text", "terminal", "iterm", "warp", "pycharm", "intellij", "webstorm", "android studio"]
        let writingApps = ["notes", "pages", "microsoft word", "textedit", "ulysses", "obsidian", "notion", "bear", "slack", "mail", "messages"]
        let browserBundles = ["com.apple.safari", "com.google.chrome", "com.google.chrome.canary", "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser"]
        let bundle = context.bundleIdentifier?.lowercased() ?? ""

        let isCodingApp = !codingApps.filter { app.contains($0) || bundle.contains($0.replacingOccurrences(of: " ", with: "")) }.isEmpty
        let isWritingApp = !writingApps.filter { app.contains($0) || bundle.contains($0.replacingOccurrences(of: " ", with: "")) }.isEmpty
        let isBrowserApp = browserBundles.contains(bundle)

        if cat == "coding" && isCodingApp { return 0.15 }
        if cat == "writing" && isWritingApp { return 0.15 }
        if cat == "browser" && isBrowserApp { return 0.10 }
        if cat == "youtube" && isBrowserApp && (context.browserURL?.contains("youtube") ?? false) { return 0.20 }
        if cat == "default" && !isCodingApp && !isWritingApp && !isBrowserApp { return 0.05 }

        return 0.0
    }

    private func computeRecencyPenalty(suggestion: ProactiveSuggestion, now: Date) -> Double {
        guard let last = cooldowns[suggestion.id] else { return 0.0 }
        let elapsed = now.timeIntervalSince(last)
        switch elapsed {
        case ..<300:   return 0.5
        case ..<900:   return 0.3
        case ..<3600:  return 0.15
        case ..<14400: return 0.05
        default:       return 0.0
        }
    }

    private func computeEngagementBonus(suggestion: ProactiveSuggestion, recentActivity: [String]) -> Double {
        let cat = category(for: suggestion)
        let recent = recentActivity.filter { $0.lowercased().contains(cat) }.count
        guard recent > 0 else { return 0.0 }
        return min(0.20, Double(recent) * 0.04)
    }

    private func normalizeToConfidence(raw: Double, maxPossible: Double) -> Double {
        let normalized = raw / maxPossible
        return max(0.0, min(1.0, normalized))
    }

    // MARK: - Project-specific suggestions

    private func makeProjectSuggestions(project: String, context: AppContext) -> [ProactiveSuggestion] {
        [
            ProactiveSuggestion(
                id: "continue-\(project)",
                title: "Continue \(project)",
                prompt: "I was working on \(project). Based on what is visible in \(context.appName), suggest what to continue with. Active window: \(context.windowTitle ?? "unknown").",
                icon: ""
            ),
            ProactiveSuggestion(
                id: "review-\(project)",
                title: "Review \(project)",
                prompt: "Review the current state of \(project) visible in \(context.appName). Point out issues and suggest next steps. Active window: \(context.windowTitle ?? "unknown").",
                icon: ""
            ),
        ]
    }

    // MARK: - Category helper

    func category(for suggestion: ProactiveSuggestion) -> String {
        let title = suggestion.title.lowercased()
        if title.contains("summarize video") || title.contains("key takeaways") || title.contains("explain this") { return "youtube" }
        if title.contains("review code") || title.contains("fix visible bug") || title.contains("write tests") || title.contains("debug") || title.contains("review") { return "coding" }
        if title.contains("improve writing") || title.contains("check grammar") || title.contains("rewrite tone") { return "writing" }
        if title.contains("summarize page") || title.contains("find action items") || title.contains("summarize screen") || title.contains("suggest next steps") { return "browser" }
        if title.contains("continue") || title.contains("review ") { return "project" }
        return "default"
    }

    func categoryConfidence(for cat: String, profileCategoryRates: [(category: String, confidence: Double)]) -> Double {
        let fromProfile = profileCategoryRates.first { $0.category == cat }?.confidence ?? 0.0
        let fromWeights = categoryWeights[cat] ?? 0.0
        return max(fromProfile, fromWeights)
    }
}
