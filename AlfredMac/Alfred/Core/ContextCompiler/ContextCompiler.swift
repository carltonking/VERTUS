import Foundation
import OSLog

// MARK: - UnifiedContext

struct UnifiedContext {
    let writingStyleContext: String
    let habitContext: String
    let relationshipContext: String
    let timelineContext: String
    let adaptationContext: String
    let rewardContext: String
    let relevanceScores: [String: Double]
    let activeContextSummary: String

    var systemPromptBlock: String {
        var parts: [String] = []

        if !writingStyleContext.isEmpty {
            parts.append("WRITING STYLE:\n\(writingStyleContext)")
        }
        if !habitContext.isEmpty {
            parts.append(habitContext)
        }
        if !relationshipContext.isEmpty {
            parts.append("RELATIONSHIPS:\n\(relationshipContext)")
        }
        if !timelineContext.isEmpty {
            parts.append("ACTIVITY TIMELINE:\n\(timelineContext)")
        }
        if !adaptationContext.isEmpty {
            parts.append(adaptationContext)
        }
        if !rewardContext.isEmpty {
            parts.append(rewardContext)
        }

        return parts.joined(separator: "\n\n")
    }
}

// MARK: - ContextCompiler

final class ContextCompiler {
    private let writingStyle: WritingStyleStore?
    private let habits: HabitStore?
    private let relationships: RelationshipStore?
    private let timeline: TimelineStore?
    private let adaptation: ResponseAdaptationEngine?
    private let rewards: RewardEngine?
    private let logger = Logger(subsystem: "com.alfred.context", category: "compiler")

    struct BudgetConfig {
        static let maxWritingPct: Double = 0.30
        static let maxHabitsPct: Double = 0.25
        static let maxRelationshipsPct: Double = 0.25
        static let maxTimelinePct: Double = 0.20
        /// Absolute ceiling (chars) for the combined learning context. The percentage budget only
        /// rebalances proportionally, so without this the block grows unbounded as the user's
        /// writing/habits/relationships/timeline accumulate — a prefill tax paid on every query.
        static let maxTotalChars: Int = 4000
    }

    init(
        writingStyle: WritingStyleStore?,
        habits: HabitStore?,
        relationships: RelationshipStore?,
        timeline: TimelineStore?,
        adaptation: ResponseAdaptationEngine?,
        rewards: RewardEngine?
    ) {
        self.writingStyle = writingStyle
        self.habits = habits
        self.relationships = relationships
        self.timeline = timeline
        self.adaptation = adaptation
        self.rewards = rewards
    }

    func generateUnifiedContext(query: String) -> UnifiedContext {
        let lowered = query.lowercased()
        var scores: [String: Double] = [:]
        var logMessages: [String] = []

        // 1. Relevance scoring
        let writingRelevance = computeWritingRelevance(query: lowered)
        let habitRelevance = computeHabitRelevance(query: lowered)
        let relationshipRelevance = computeRelationshipRelevance(query: lowered)
        let timelineRelevance = computeTimelineRelevance(query: lowered)

        scores["writing"] = writingRelevance
        scores["habits"] = habitRelevance
        scores["relationships"] = relationshipRelevance
        scores["timeline"] = timelineRelevance
        scores["rewards"] = 1.0
        scores["adaptation"] = 1.0

        // 2. Fetch raw context strings
        let rawWriting = writingRelevance > 0 ? (writingStyle?.generateStyleContext() ?? "") : ""
        let rawHabits = habitRelevance > 0 ? (habits?.generateHabitContext() ?? "") : ""
        let rawRelationships = relationshipRelevance > 0 ? (relationships?.generateRelationshipContext() ?? "") : ""
        let rawTimeline = timelineRelevance > 0 ? (timeline?.getRecentTimelineSummary() ?? "") : ""
        let adaptationStr = adaptation?.generateResponseStyleProfile().systemPromptBlock ?? ""
        let rewardStr = rewards?.getDailyRewardSummary().systemPromptBlock ?? ""

        // 3. Apply budget to core context blocks (writing, habits, relationships, timeline)
        let budgeted = applyBudget(
            writing: rawWriting,
            habits: rawHabits,
            relationships: rawRelationships,
            timeline: rawTimeline
        )

        // 4. Collect budget exclusions for logging
        if budgeted.writing.count < rawWriting.count {
            logMessages.append("writing truncated from \(rawWriting.count) to \(budgeted.writing.count) chars (budget \(Int(BudgetConfig.maxWritingPct * 100))%)")
        }
        if budgeted.habits.count < rawHabits.count {
            logMessages.append("habits truncated from \(rawHabits.count) to \(budgeted.habits.count) chars")
        }
        if budgeted.relationships.count < rawRelationships.count {
            logMessages.append("relationships truncated from \(rawRelationships.count) to \(budgeted.relationships.count) chars")
        }
        if budgeted.timeline.count < rawTimeline.count {
            logMessages.append("timeline truncated from \(rawTimeline.count) to \(budgeted.timeline.count) chars")
        }

        // 5. Build active context summary
        let summary = buildActiveSummary(
            writingUsed: !budgeted.writing.isEmpty,
            habitsUsed: !budgeted.habits.isEmpty,
            relationshipsUsed: !budgeted.relationships.isEmpty,
            timelineUsed: !budgeted.timeline.isEmpty,
            adaptationUsed: !adaptationStr.isEmpty,
            rewardsUsed: !rewardStr.isEmpty,
            includingQueryInsights: relevanceInsights(
                query: query,
                writingRel: writingRelevance,
                habitRel: habitRelevance,
                relationshipRel: relationshipRelevance,
                timelineRel: timelineRelevance
            )
        )

        // 6. Log
        logger.info("Relevance scores — writing: \(writingRelevance, format: .fixed(precision: 2)), habits: \(habitRelevance, format: .fixed(precision: 2)), relationships: \(relationshipRelevance, format: .fixed(precision: 2)), timeline: \(timelineRelevance, format: .fixed(precision: 2))")
        for msg in logMessages {
            logger.info("Budget: \(msg)")
        }

        return UnifiedContext(
            writingStyleContext: budgeted.writing,
            habitContext: budgeted.habits,
            relationshipContext: budgeted.relationships,
            timelineContext: budgeted.timeline,
            adaptationContext: adaptationStr,
            rewardContext: rewardStr,
            relevanceScores: scores,
            activeContextSummary: summary
        )
    }

    // MARK: - Suggestion reasoning

    func reasonForSuggesting(task: TaskDefinition) -> String {
        let lowered = (task.name + " " + task.description).lowercased()
        var reasons: [String] = []

        // Check timeline for recent activity matching this task
        if let timeline, !timeline.getRecentTimelineSummary().isEmpty {
            let summary = timeline.getRecentTimelineSummary().lowercased()
            let taskWords = Set(lowered.split(separator: " ").map(String.init))
            let matchCount = taskWords.filter { summary.contains($0) && $0.count > 3 }.count
            if matchCount >= 2 {
                reasons.append("Matches your recent activity")
            }
        }

        // Check habits for task-relevant patterns
        if let habits {
            let ctx = habits.generateHabitContext().lowercased()
            let taskWords = Set(lowered.split(separator: " ").map(String.init))
            let matchCount = taskWords.filter { ctx.contains($0) && $0.count > 3 }.count
            if matchCount >= 1 {
                reasons.append("Aligns with your established habits")
            }
        }

        // Check task action types against relationship/communication patterns
        let hasCommunicationStep = task.steps.contains {
            ActionPolicyRegistry.actionClass(for: $0.actionType) == .externalCommunication
        }
        if hasCommunicationStep, let relationships {
            let ctx = relationships.generateRelationshipContext().lowercased()
            let taskWords = Set(lowered.split(separator: " ").map(String.init))
            let matchCount = taskWords.filter { ctx.contains($0) && $0.count > 3 }.count
            if matchCount >= 1 {
                reasons.append("Involves people you interact with regularly")
            }
        }

        // Check schedule
        switch task.scheduleType {
        case .daily:
            reasons.append("Part of your daily routine")
        case .weekly:
            reasons.append("Weekly recurring task")
        case .custom:
            reasons.append("Custom scheduled task")
        case .manual:
            if task.lastRun == nil {
                reasons.append("You haven't tried this task yet")
            }
        }

        if reasons.isEmpty {
            return "Suggested based on your activity patterns."
        }

        return reasons.joined(separator: "; ") + "."
    }

    // MARK: - Relevance scoring

    private func computeWritingRelevance(query: String) -> Double {
        return 1.0
    }

    private func computeHabitRelevance(query: String) -> Double {
        let keywords = ["time", "routine", "schedule", "habit", "usually", "always", "never", "often",
                        "daily", "weekly", "morning", "afternoon", "evening", "night",
                        "productivity", "focus", "distracted", "break", "pause",
                        "remind", "remember", "forget", "tend to"]
        let matchCount = keywords.filter { query.contains($0) }.count
        return matchCount >= 2 ? 1.0 : matchCount == 1 ? 0.5 : 0.0
    }

    private func computeRelationshipRelevance(query: String) -> Double {
        let keywordHits = ["meeting", "call", "email", "message", "contact", "person",
                           "colleague", "client", "boss", "team", "friend",
                           "asked", "said", "told", "spoke", "talked",
                           "send", "reply", "forward"].filter { query.contains($0) }.count
        if keywordHits >= 2 { return 1.0 }
        if keywordHits == 1 { return 0.5 }
        return 0.0
    }

    private func computeTimelineRelevance(query: String) -> Double {
        let keywords = ["today", "yesterday", "tomorrow", "recent", "earlier", "just now",
                        "work", "project", "file", "folder", "document",
                        "app", "application", "browser", "opened", "closed",
                        "what was", "what did", "what happened",
                        "timeline", "activity", "history", "log"]
        let matchCount = keywords.filter { query.contains($0) }.count
        return matchCount >= 2 ? 1.0 : matchCount == 1 ? 0.5 : 0.0
    }

    private func relevanceInsights(
        query: String,
        writingRel: Double,
        habitRel: Double,
        relationshipRel: Double,
        timelineRel: Double
    ) -> [String] {
        var insights: [String] = []
        let lowered = query.lowercased()

        if habitRel > 0 && (lowered.contains("time") || lowered.contains("schedule") || lowered.contains("routine")) {
            insights.append("query references time or routine")
        }
        if relationshipRel > 0 {
            insights.append("query may involve people")
        }
        if timelineRel > 0 {
            insights.append("query references recent activity")
        }
        return insights
    }

    // MARK: - Budget enforcement

    private func applyBudget(
        writing: String,
        habits: String,
        relationships: String,
        timeline: String
    ) -> (writing: String, habits: String, relationships: String, timeline: String) {
        var w = writing
        var h = habits
        var r = relationships
        var t = timeline

        for _ in 0..<3 {
            let total = w.count + h.count + r.count + t.count
            guard total > 0 else { break }

            let maxW = Int(Double(total) * BudgetConfig.maxWritingPct)
            let maxH = Int(Double(total) * BudgetConfig.maxHabitsPct)
            let maxR = Int(Double(total) * BudgetConfig.maxRelationshipsPct)
            let maxT = Int(Double(total) * BudgetConfig.maxTimelinePct)

            var anyTruncated = false

            if w.count > maxW {
                w = truncate(w, to: maxW)
                anyTruncated = true
            }
            if h.count > maxH {
                h = truncate(h, to: maxH)
                anyTruncated = true
            }
            if r.count > maxR {
                r = truncate(r, to: maxR)
                anyTruncated = true
            }
            if t.count > maxT {
                t = truncate(t, to: maxT)
                anyTruncated = true
            }

            if !anyTruncated { break }
        }

        // Hard absolute ceiling after the proportional pass: scale every block down so the combined
        // learning context never exceeds maxTotalChars regardless of how much has accumulated.
        let total = w.count + h.count + r.count + t.count
        if total > BudgetConfig.maxTotalChars {
            let scale = Double(BudgetConfig.maxTotalChars) / Double(total)
            w = truncate(w, to: Int(Double(w.count) * scale))
            h = truncate(h, to: Int(Double(h.count) * scale))
            r = truncate(r, to: Int(Double(r.count) * scale))
            t = truncate(t, to: Int(Double(t.count) * scale))
        }

        return (w, h, r, t)
    }

    private func truncate(_ str: String, to maxChars: Int) -> String {
        guard maxChars > 0, str.count > maxChars else { return str }
        let end = str.index(str.startIndex, offsetBy: max(0, maxChars - 20))
        return String(str[..<end]) + "\n[...truncated due to context budget]"
    }

    private func buildActiveSummary(
        writingUsed: Bool,
        habitsUsed: Bool,
        relationshipsUsed: Bool,
        timelineUsed: Bool,
        adaptationUsed: Bool,
        rewardsUsed: Bool,
        includingQueryInsights: [String]
    ) -> String {
        var active: [String] = []
        if writingUsed { active.append("writing") }
        if habitsUsed { active.append("habits") }
        if relationshipsUsed { active.append("relationships") }
        if timelineUsed { active.append("timeline") }
        if adaptationUsed { active.append("adaptation") }
        if rewardsUsed { active.append("rewards") }

        var summary = "Active context: \(active.joined(separator: ", "))."
        if !includingQueryInsights.isEmpty {
            summary += " " + includingQueryInsights.joined(separator: "; ") + "."
        }
        return summary
    }
}
