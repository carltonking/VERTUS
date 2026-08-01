import Foundation
import OSLog

// MARK: - Risk level

enum ActionRiskLevel: String, Codable {
    case low, medium, high
}

// MARK: - ActionCandidate

struct ActionCandidate: Comparable {
    let actionType: String
    let confidenceScore: Double
    let requiredTools: [String]
    let reasoningTags: [String]
    let contextDependencies: [String]
    let riskLevel: ActionRiskLevel

    static func < (lhs: ActionCandidate, rhs: ActionCandidate) -> Bool {
        lhs.confidenceScore < rhs.confidenceScore
    }

    static func == (lhs: ActionCandidate, rhs: ActionCandidate) -> Bool {
        lhs.actionType == rhs.actionType && lhs.confidenceScore == rhs.confidenceScore
    }
}

// MARK: - ActionSelectionEngine

final class ActionSelectionEngine {
    private let habits: HabitStore?
    private let rewards: RewardEngine?
    private let adaptation: ResponseAdaptationEngine?
    private let logger = Logger(subsystem: "com.alfred.action-selection", category: "engine")

    init(
        habits: HabitStore?,
        rewards: RewardEngine?,
        adaptation: ResponseAdaptationEngine?
    ) {
        self.habits = habits
        self.rewards = rewards
        self.adaptation = adaptation
    }

    // MARK: - Public API

    struct SelectionResult {
        let top: ActionCandidate
        let fallbacks: [ActionCandidate]
        let explanation: [String]
    }

    func selectBestAction(query: String, context: UnifiedContext) -> SelectionResult {
        let lowered = query.lowercased()
        var explanation: [String] = []

        // Compute the DB-backed inputs ONCE up front instead of re-fetching them inside scoreAction
        // for every action type. Previously getTopHabits / getDailyRewardSummary /
        // generateResponseStyleProfile each ran once PER action type (~9x); the last also mutates
        // currentProfile + calls logSignals, so that side effect now fires once. Scores are identical.
        let topHabits = habits?.getTopHabits(limit: 10) ?? []
        let rewardSummary = context.rewardContext.isEmpty ? nil : rewards?.getDailyRewardSummary()
        let styleProfile = adaptation?.generateResponseStyleProfile()

        // 1. Compute scores for all action types
        var candidates: [ActionCandidate] = []
        for actionType in allActionTypes {
            let candidate = scoreAction(actionType: actionType, query: query, lowered: lowered, context: context, topHabits: topHabits, rewardSummary: rewardSummary, styleProfile: styleProfile, explanation: &explanation)
            candidates.append(candidate)
        }

        // 2. Sort descending by confidence
        candidates.sort { $0.confidenceScore > $1.confidenceScore }

        // 3. Separate top from fallbacks
        let top = candidates.first ?? defaultRespondAction()
        let fallbacks = Array(candidates.dropFirst().prefix(3))

        // 4. Log
        logger.info("Selected: \(top.actionType) (\(String(format: "%.2f", top.confidenceScore)))")
        for fb in fallbacks {
            logger.info("Fallback: \(fb.actionType) (\(String(format: "%.2f", fb.confidenceScore)))")
        }

        return SelectionResult(top: top, fallbacks: fallbacks, explanation: explanation)
    }

    // MARK: - Action scoring

    private func scoreAction(
        actionType: String,
        query: String,
        lowered: String,
        context: UnifiedContext,
        topHabits: [Habit],
        rewardSummary: DailyRewardSummary?,
        styleProfile: ResponseStyleProfile?,
        explanation: inout [String]
    ) -> ActionCandidate {
        let base = computeBaseScore(actionType: actionType, lowered: lowered, context: context)
        let habitMod = computeHabitModifier(actionType: actionType, topHabits: topHabits)
        let rewardMod = computeRewardModifier(actionType: actionType, rewardSummary: rewardSummary)
        let adaptationMod = computeAdaptationModifier(actionType: actionType, styleProfile: styleProfile)
        let adjustedScore = max(0, min(1.0, base + habitMod + rewardMod + adaptationMod))

        var reasoning: [String] = []
        if base >= 0.4 {
            reasoning.append("keyword_match")
        }
        if habitMod > 0 {
            reasoning.append("habit_aligned")
        }
        if rewardMod > 0 {
            reasoning.append("reward_aligned")
        }
        if adaptationMod > 0 {
            reasoning.append("adaptation_aligned")
        }
        if adjustedScore > 0.8 {
            reasoning.append("high_confidence")
        }
        if adjustedScore > base + 0.05 {
            reasoning.append("boosted_by_context")
        }

        var deps: [String] = []
        if context.relevanceScores["writing"] ?? 0 > 0 { deps.append("writing_style") }
        if context.relevanceScores["habits"] ?? 0 > 0 { deps.append("habits") }
        if context.relevanceScores["relationships"] ?? 0 > 0 { deps.append("relationships") }
        if context.relevanceScores["timeline"] ?? 0 > 0 { deps.append("timeline") }

        return ActionCandidate(
            actionType: actionType,
            confidenceScore: adjustedScore,
            requiredTools: requiredTools(for: actionType),
            reasoningTags: reasoning,
            contextDependencies: deps,
            riskLevel: ActionPolicyRegistry.riskLevel(for: actionType)
        )
    }

    // MARK: - Base score (keyword matching)

    private func computeBaseScore(actionType: String, lowered: String, context: UnifiedContext) -> Double {
        switch actionType {

        case "respond_text":
            return 0.3

        case "open_application":
            let triggers = ["open ", "launch ", "start ", "run app "]
            let hits = triggers.filter { lowered.contains($0) }.count
            return hits > 0 ? 0.8 : 0.0

        case "search_files":
            let triggers = ["find ", "search ", "locate ", "where is ", "look for ", "show me "]
            let hits = triggers.filter { lowered.contains($0) }.count
            return hits > 0 ? 0.7 : 0.0

        case "create_file":
            let triggers = ["create ", "write ", "make ", "new file", "new document", "save as"]
            let hits = triggers.filter { lowered.contains($0) }.count
            return hits > 0 ? 0.8 : 0.0

        case "edit_file":
            let triggers = ["edit ", "change ", "update ", "modify ", "rewrite ", "append "]
            let hits = triggers.filter { lowered.contains($0) }.count
            return hits > 0 ? 0.7 : 0.0

        case "schedule_calendar_event":
            let triggers = ["schedule", "calendar", "appointment", "meeting on", "event on", "remind me"]
            let hits = triggers.filter { lowered.contains($0) }.count
            return hits > 0 ? 0.8 : 0.0

        case "send_message":
            let triggers = ["send ", "message ", "email ", "text ", "tell ", "slack ", "forward "]
            let hits = triggers.filter { lowered.contains($0) }.count
            var score = hits > 0 ? 0.7 : 0.0
            if context.relevanceScores["relationships"] ?? 0 > 0.5 {
                score += 0.15
            }
            return min(score, 1.0)

        case "query_memory":
            let triggers = ["remember", "recall", "what about", "earlier", "what did", "story", "tell me about"]
            let hits = triggers.filter { lowered.contains($0) }.count
            return hits > 0 ? 0.7 : 0.0

        case "system_command":
            let triggers = ["run command", "execute command", "terminal ", "bash ", "shell ", "run script"]
            let hits = triggers.filter { lowered.contains($0) }.count
            return hits > 0 ? 0.6 : 0.0

        default:
            return 0.0
        }
    }

    // MARK: - Modifiers

    private func computeHabitModifier(actionType: String, topHabits: [Habit]) -> Double {
        // topHabits is [] when habits is nil, so productivityCount stays 0 (same as the old guard).
        let productivityCount = topHabits.filter { $0.type == .productivity_pattern }.count

        guard productivityCount > 0 else { return 0.0 }

        switch actionType {
        case "open_application":
            return productivityCount >= 2 ? 0.12 : 0.06
        case "search_files":
            return 0.04
        default:
            return 0.0
        }
    }

    private func computeRewardModifier(actionType: String, rewardSummary: DailyRewardSummary?) -> Double {
        // rewardSummary is nil when context.rewardContext was empty (gate preserved by the caller).
        guard let s = rewardSummary, s.totalSignals > 0 else { return 0.0 }

        switch actionType {
        case "respond_text":
            if s.verbosityBias > 0.3 { return 0.08 }
            if s.verbosityBias < -0.3 { return -0.05 }
            return 0.0
        default:
            return 0.0
        }
    }

    private func computeAdaptationModifier(actionType: String, styleProfile: ResponseStyleProfile?) -> Double {
        // styleProfile is nil when adaptation is nil (same as the old guard).
        guard let profile = styleProfile else { return 0.0 }

        switch actionType {
        case "respond_text":
            if profile.tone == .formal { return 0.05 }
            return 0.03
        default:
            return 0.0
        }
    }

    // MARK: - Metadata helpers

    private func requiredTools(for actionType: String) -> [String] {
        switch actionType {
        case "open_application":        return ["app_control"]
        case "search_files":            return ["file_system"]
        case "create_file":             return ["file_write"]
        case "edit_file":               return ["file_write"]
        case "schedule_calendar_event": return ["calendar"]
        case "send_message":            return ["messaging"]
        case "query_memory":            return ["memory_store"]
        case "system_command":          return ["shell"]
        case "respond_text":            return ["llm"]
        default:                        return []
        }
    }

    private func defaultRespondAction() -> ActionCandidate {
        ActionCandidate(
            actionType: "respond_text",
            confidenceScore: 0.3,
            requiredTools: ["llm"],
            reasoningTags: ["default"],
            contextDependencies: [],
            riskLevel: .low
        )
    }

    // MARK: - Types

    private let allActionTypes: [String] = ActionType.allCases.map(\.rawValue)
}
