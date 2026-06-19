import Foundation
import GRDB
import OSLog

final class RewardEngine {
    private let db: DatabaseQueue
    private let learningLoop: LearningLoopStore
    private let habits: HabitStore
    private let writingStyle: WritingStyleStore?
    private let timeline: TimelineStore
    private let logger = Logger(subsystem: "com.alfred.reward", category: "engine")

    init(
        db: DatabaseQueue,
        learningLoop: LearningLoopStore,
        habits: HabitStore,
        writingStyle: WritingStyleStore?,
        timeline: TimelineStore
    ) {
        self.db = db
        self.learningLoop = learningLoop
        self.habits = habits
        self.writingStyle = writingStyle
        self.timeline = timeline
    }

    // MARK: - Signal generation

    func generateRewardSignals() {
        let signals = computeWritingSignals()
            + computeWorkflowSignals()
            + computeHabitSignals()
            + computeAdaptationOverrideSignals()

        guard !signals.isEmpty else {
            logger.info("No reward signals generated")
            return
        }

        do {
            try db.write { db in
                for signal in signals {
                    let record = RewardSignalRecord(
                        id: nil,
                        timestamp: signal.timestamp.timeIntervalSince1970,
                        signalType: signal.type.rawValue,
                        strength: signal.strength,
                        sourceContextJSON: encodeContext(signal.sourceContext),
                        explanationTags: signal.explanationTags.joined(separator: ",")
                    )
                    try record.insert(db)
                }
            }
            logger.info("Persisted \(signals.count) reward signals")
        } catch {
            logger.error("Failed to persist reward signals: \(error.localizedDescription)")
        }
    }

    // MARK: - Writing signals

    private func computeWritingSignals() -> [RewardSignal] {
        let suggestions = learningLoop.getAllSuggestions(limit: 100)
        let recent = suggestions.filter { $0.timestamp > Date().addingTimeInterval(-86400 * 7) }
        var signals: [RewardSignal] = []

        for s in recent {
            if s.accepted {
                signals.append(RewardSignal(
                    type: .writingAcceptance,
                    strength: 1.0,
                    sourceContext: ["suggestionId": s.id.map(String.init) ?? "", "promptPrefix": String(s.userPrompt.prefix(100))],
                    explanationTags: ["accepted", "positive"]
                ))
            }

            if s.rejected {
                signals.append(RewardSignal(
                    type: .writingRejection,
                    strength: -1.0,
                    sourceContext: ["suggestionId": s.id.map(String.init) ?? "", "promptPrefix": String(s.userPrompt.prefix(100))],
                    explanationTags: ["rejected", "negative"]
                ))
            }

            if s.edited && !s.finalUserVersion.isEmpty {
                let originalLen = s.alfredResponse.count
                let finalLen = s.finalUserVersion.count
                guard originalLen > 0 else { continue }

                let ratio = Double(finalLen) / Double(originalLen)
                if ratio < 0.8 {
                    signals.append(RewardSignal(
                        type: .writingEditShortened,
                        strength: -0.5,
                        sourceContext: ["suggestionId": s.id.map(String.init) ?? "", "shrinkRatio": String(format: "%.2f", ratio)],
                        explanationTags: ["edited", "shortened", "verbosity-penalty"]
                    ))
                } else if ratio > 1.2 {
                    signals.append(RewardSignal(
                        type: .writingEditExpanded,
                        strength: 0.3,
                        sourceContext: ["suggestionId": s.id.map(String.init) ?? "", "expandRatio": String(format: "%.2f", ratio)],
                        explanationTags: ["edited", "expanded", "depth-preference"]
                    ))
                }
            }
        }

        return signals
    }

    // MARK: - Workflow signals

    private func computeWorkflowSignals() -> [RewardSignal] {
        let events = learningLoop.getEvents(limit: 100)
        let recent = events.filter { $0.timestamp > Date().addingTimeInterval(-86400 * 7) }
        var signals: [RewardSignal] = []

        for e in recent {
            switch e.type {
            case .workflowCompleted:
                signals.append(RewardSignal(
                    type: .workflowSuccess,
                    strength: 0.7,
                    sourceContext: ["eventId": e.id.map(String.init) ?? ""],
                    explanationTags: ["workflow", "success", "positive"]
                ))
            case .workflowCancelled:
                signals.append(RewardSignal(
                    type: .workflowFailure,
                    strength: -0.7,
                    sourceContext: ["eventId": e.id.map(String.init) ?? ""],
                    explanationTags: ["workflow", "cancelled", "negative"]
                ))
            default:
                break
            }
        }

        return signals
    }

    // MARK: - Habit signals

    private func computeHabitSignals() -> [RewardSignal] {
        let habitList = habits.getHabits()
        var signals: [RewardSignal] = []

        for h in habitList {
            if h.occurrenceCount >= 7 {
                signals.append(RewardSignal(
                    type: .habitReinforced,
                    strength: 0.5,
                    sourceContext: ["habitName": h.name, "occurrenceCount": "\(h.occurrenceCount)"],
                    explanationTags: ["habit", "reinforced", "positive"]
                ))
            }

            let daysSinceLastSeen = Calendar.current.dateComponents([.day], from: h.lastObserved, to: Date()).day ?? 0
            if h.confidence > 0.5 && daysSinceLastSeen > 14 {
                signals.append(RewardSignal(
                    type: .habitBroken,
                    strength: -0.3,
                    sourceContext: ["habitName": h.name, "daysSinceLastSeen": "\(daysSinceLastSeen)"],
                    explanationTags: ["habit", "broken", "negative"]
                ))
            }
        }

        return signals
    }

    // MARK: - Adaptation override signals

    private func computeAdaptationOverrideSignals() -> [RewardSignal] {
        guard let profile = writingStyle?.getWritingProfile(), profile.totalSamples >= 5 else {
            return []
        }

        let suggestions = learningLoop.getAllSuggestions(limit: 20)
        let recentAccepted = suggestions.filter { $0.accepted }.prefix(5)
        guard recentAccepted.count >= 3 else { return [] }

        let avgAcceptedLen = recentAccepted.map { $0.alfredResponse.count }.reduce(0, +) / recentAccepted.count
        let predictedVerbosity: String
        switch profile.avgSentenceLength {
        case ..<12: predictedVerbosity = "low"
        case 12...20: predictedVerbosity = "medium"
        default: predictedVerbosity = "high"
        }

        var drift: Double = 0.0
        if predictedVerbosity == "low" && avgAcceptedLen > 1000 {
            drift = 0.3
        } else if predictedVerbosity == "high" && avgAcceptedLen < 500 {
            drift = -0.3
        } else if predictedVerbosity == "medium" && avgAcceptedLen > 2000 {
            drift = 0.2
        } else if predictedVerbosity == "medium" && avgAcceptedLen < 300 {
            drift = -0.2
        }

        guard abs(drift) > 0.0 else { return [] }

        return [RewardSignal(
            type: .adaptationOverride,
            strength: drift,
            sourceContext: [
                "predictedVerbosity": predictedVerbosity,
                "avgAcceptedLength": "\(avgAcceptedLen)",
                "userSentenceLength": String(format: "%.1f", profile.avgSentenceLength),
            ],
            explanationTags: ["adaptation", "override", drift > 0 ? "wants-more" : "wants-less"]
        )]
    }

    // MARK: - Daily summary

    func getDailyRewardSummary() -> DailyRewardSummary {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let signals = getSignals(since: todayStart)

        let totalSignals = signals.count
        let totalPositive = signals.filter { $0.strength > 0 }.count
        let totalNegative = signals.filter { $0.strength < 0 }.count

        let verbosityBias = computeVerbosityBias(from: signals)
        let structureBias = computeStructureBias(from: signals)
        let adaptationDrift = computeAdaptationDrift(from: signals)
        let dominantAdjustments = computeDominantAdjustments(from: signals)

        return DailyRewardSummary(
            date: Date(),
            totalSignals: totalSignals,
            totalPositive: totalPositive,
            totalNegative: totalNegative,
            verbosityBias: verbosityBias,
            structureBias: structureBias,
            adaptationDrift: adaptationDrift,
            dominantAdjustments: dominantAdjustments
        )
    }

    // MARK: - Queries

    func getSignals(since: Date? = nil, limit: Int = 200) -> [RewardSignal] {
        do {
            let records: [RewardSignalRecord] = try db.read { db in
                var request = RewardSignalRecord.order(Column("timestamp").desc).limit(limit)
                if let since {
                    request = request.filter(Column("timestamp") >= since.timeIntervalSince1970)
                }
                return try request.fetchAll(db)
            }
            return records.map(RewardSignal.init)
        } catch {
            logger.error("Failed to fetch reward signals: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private

    private func computeVerbosityBias(from signals: [RewardSignal]) -> Double {
        let verbosityTypes: Set<RewardSignalType> = [.writingAcceptance, .writingRejection, .writingEditShortened, .writingEditExpanded]
        let relevant = signals.filter { verbosityTypes.contains($0.type) }
        guard !relevant.isEmpty else { return 0.0 }

        let total = relevant.map(\.strength).reduce(0, +)
        let weights: [RewardSignalType: Double] = [
            .writingAcceptance: 1.0,
            .writingRejection: 1.0,
            .writingEditShortened: 1.5,
            .writingEditExpanded: 1.5,
        ]
        let weightedSum = relevant.reduce(0.0) { sum, s in
            sum + s.strength * (weights[s.type] ?? 1.0)
        }
        let weightTotal = relevant.reduce(0.0) { $0 + (weights[$1.type] ?? 1.0) }
        let result = weightTotal > 0 ? weightedSum / weightTotal : total / Double(relevant.count)
        return max(-1.0, min(1.0, result))
    }

    private func computeStructureBias(from signals: [RewardSignal]) -> Double {
        let structureTypes: Set<RewardSignalType> = [.workflowSuccess, .workflowFailure]
        let relevant = signals.filter { structureTypes.contains($0.type) }
        guard !relevant.isEmpty else { return 0.0 }

        let total = relevant.map(\.strength).reduce(0, +)
        return max(-1.0, min(1.0, total / Double(relevant.count)))
    }

    private func computeAdaptationDrift(from signals: [RewardSignal]) -> Double {
        let drifts = signals.filter { $0.type == .adaptationOverride }
        guard !drifts.isEmpty else { return 0.0 }
        let avg = drifts.map(\.strength).reduce(0, +) / Double(drifts.count)
        return max(-1.0, min(1.0, avg))
    }

    private func computeDominantAdjustments(from signals: [RewardSignal]) -> [String] {
        var adjustments: [String] = []

        let verbositySignals = signals.filter { $0.type == .writingEditShortened || $0.type == .writingEditExpanded }
        if !verbositySignals.isEmpty {
            let shortenCount = verbositySignals.filter { $0.type == .writingEditShortened }.count
            let expandCount = verbositySignals.filter { $0.type == .writingEditExpanded }.count
            if shortenCount > expandCount {
                adjustments.append("user prefers shorter responses")
            } else if expandCount > shortenCount {
                adjustments.append("user prefers more detailed responses")
            }
        }

        let workflowSignals = signals.filter { $0.type == .workflowSuccess || $0.type == .workflowFailure }
        if !workflowSignals.isEmpty {
            let failCount = workflowSignals.filter { $0.type == .workflowFailure }.count
            if failCount > 2 {
                adjustments.append("frequent workflow cancellations")
            }
        }

        return adjustments
    }

    private func encodeContext(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
