import Foundation
import OSLog

// MARK: - ResponseStyleProfile

struct ResponseStyleProfile {
    enum ResponseTone: String, Codable {
        case formal, neutral, casual
    }
    enum ResponseFormatting: String, Codable {
        case minimal, standard, markdown
    }

    var verbosity: Double
    var tone: ResponseTone
    var structure: Double
    var explanationDepth: Double
    var formatting: ResponseFormatting

    static let neutral = ResponseStyleProfile(
        verbosity: 0.5,
        tone: .neutral,
        structure: 0.5,
        explanationDepth: 0.6,
        formatting: .standard
    )

    var systemPromptBlock: String {
        let verbLabel: String
        switch verbosity {
        case ..<0.33: verbLabel = "low"
        case 0.33...0.66: verbLabel = "medium"
        default: verbLabel = "high"
        }
        let structLabel: String
        switch structure {
        case ..<0.33: structLabel = "none"
        case 0.33...0.66: structLabel = "moderate"
        default: structLabel = "high"
        }
        let depthLabel: String
        switch explanationDepth {
        case ..<0.5: depthLabel = "shallow"
        default: depthLabel = "detailed"
        }
        return """
        RESPONSE STYLE:
        • verbosity: \(verbLabel)
        • tone: \(tone.rawValue)
        • structure: \(structLabel)
        • explanation depth: \(depthLabel)
        • formatting: \(formatting.rawValue)
        """
    }
}

// MARK: - ResponseAdaptationEngine

final class ResponseAdaptationEngine {
    private let writingStyle: WritingStyleStore?
    private let habits: HabitStore
    private let learningLoop: LearningLoopStore
    private let rewardEngine: RewardEngine
    private let logger = Logger(subsystem: "com.alfred.adaptation", category: "engine")

    private(set) var currentProfile: ResponseStyleProfile = .neutral

    private typealias RewardMetrics = (verbosityBias: Double, structureBias: Double, adaptationDrift: Double, dominantAdjustments: [String])
    private typealias LoopMetrics = (acceptanceRate: Double, rejectionRate: Double, editRate: Double)

    struct SignalLog {
        var verbositySignals: [String] = []
        var toneSignals: [String] = []
        var structureSignals: [String] = []
        var depthSignals: [String] = []
        var formattingSignals: [String] = []
    }

    init(
        writingStyle: WritingStyleStore?,
        habits: HabitStore,
        learningLoop: LearningLoopStore,
        rewardEngine: RewardEngine
    ) {
        self.writingStyle = writingStyle
        self.habits = habits
        self.learningLoop = learningLoop
        self.rewardEngine = rewardEngine
    }

    // MARK: - Profile generation

    @discardableResult
    func generateProfile() -> ResponseStyleProfile {
        var log = SignalLog()
        let profile = computeProfile(&log)
        currentProfile = profile
        logSignals(log)
        return profile
    }

    func invalidateProfile() {
        generateProfile()
    }

    func generateResponseStyleProfile() -> ResponseStyleProfile {
        generateProfile()
    }

    // MARK: - Profile computation

    private func computeProfile(_ log: inout SignalLog) -> ResponseStyleProfile {
        // Compute the shared inputs once — previously re-fetched inside multiple determineX helpers
        // (reward metrics 4x, learning-loop metrics 3x, writing profile 3x). No state mutates between
        // reads within one computeProfile, so reuse is behavior-identical.
        let rewardMetrics = computeRewardMetrics()
        let loopMetrics = computeLearningLoopMetrics()
        let writingProfile = writingStyle?.getWritingProfile()

        let verbosity = determineVerbosity(&log, rewardMetrics: rewardMetrics, writingProfile: writingProfile)
        let tone = determineTone(&log, loopMetrics: loopMetrics, rewardMetrics: rewardMetrics, writingProfile: writingProfile)
        let structure = determineStructure(&log, rewardMetrics: rewardMetrics)
        let depth = determineDepth(&log, loopMetrics: loopMetrics)
        let formatting = determineFormatting(&log, loopMetrics: loopMetrics, rewardMetrics: rewardMetrics, writingProfile: writingProfile)

        return ResponseStyleProfile(
            verbosity: verbosity,
            tone: tone,
            structure: structure,
            explanationDepth: depth,
            formatting: formatting
        )
    }

    // MARK: - Learning loop metrics

    private func computeLearningLoopMetrics() -> (acceptanceRate: Double, rejectionRate: Double, editRate: Double) {
        let all = learningLoop.getAllSuggestions(limit: 500)
        let total = max(all.count, 1)
        return (
            acceptanceRate: Double(all.filter(\.accepted).count) / Double(total),
            rejectionRate: Double(all.filter(\.rejected).count) / Double(total),
            editRate: Double(all.filter(\.edited).count) / Double(total)
        )
    }

    private func computeRewardMetrics() -> (verbosityBias: Double, structureBias: Double, adaptationDrift: Double, dominantAdjustments: [String]) {
        let summary = rewardEngine.getDailyRewardSummary()
        return (
            verbosityBias: summary.verbosityBias,
            structureBias: summary.structureBias,
            adaptationDrift: summary.adaptationDrift,
            dominantAdjustments: summary.dominantAdjustments
        )
    }

    // MARK: - Verbosity

    private func determineVerbosity(_ log: inout SignalLog, rewardMetrics: RewardMetrics, writingProfile: WritingProfile?) -> Double {
        var base: Double = 0.5
        if let profile = writingProfile, profile.totalSamples >= 3 {
            switch profile.avgSentenceLength {
            case ..<12:
                base = 0.2
                log.verbositySignals.append("user avg sentence length \(String(format: "%.1f", profile.avgSentenceLength)) → low base")
            case 12...20:
                base = 0.5
                log.verbositySignals.append("user avg sentence length \(String(format: "%.1f", profile.avgSentenceLength)) → medium base")
            default:
                base = 0.8
                log.verbositySignals.append("user avg sentence length \(String(format: "%.1f", profile.avgSentenceLength)) → high base")
            }
        } else {
            let suggestions = learningLoop.getAllSuggestions(limit: 50)
            let accepted = suggestions.filter { $0.accepted }
            if accepted.count >= 3 {
                let avgAcceptedLen = accepted.map { $0.alfredResponse.count }.reduce(0, +) / accepted.count
                if avgAcceptedLen > 2000 {
                    base = 0.8
                } else if avgAcceptedLen < 500 {
                    base = 0.2
                } else {
                    base = 0.5
                }
                log.verbositySignals.append("accepted responses avg \(avgAcceptedLen) chars → base \(String(format: "%.2f", base))")
            }
        }

        let adjusted = base + rewardMetrics.verbosityBias * 0.3
        let clamped = max(0.0, min(1.0, adjusted))
        log.verbositySignals.append("bias: \(String(format: "%+.2f", rewardMetrics.verbosityBias)) → \(String(format: "%.2f", clamped))")
        return clamped
    }

    // MARK: - Tone

    private func determineTone(_ log: inout SignalLog, loopMetrics metrics: LoopMetrics, rewardMetrics: RewardMetrics, writingProfile: WritingProfile?) -> ResponseStyleProfile.ResponseTone {
        let baseFormality = writingProfile?.formalityScore ?? 0.5

        let hasToneAdjustment = rewardMetrics.dominantAdjustments.contains { $0.contains("tone") }
        if metrics.rejectionRate > 0.5 && hasToneAdjustment {
            log.toneSignals.append("rejection rate \(String(format: "%.2f", metrics.rejectionRate)) with tone adjustment → neutral")
            return .neutral
        }

        if baseFormality > 0.6 {
            log.toneSignals.append("formality \(String(format: "%.2f", baseFormality)) → formal")
            return .formal
        } else if baseFormality < 0.3 {
            log.toneSignals.append("formality \(String(format: "%.2f", baseFormality)) → casual")
            return .casual
        }

        log.toneSignals.append("formality \(String(format: "%.2f", baseFormality)) → neutral")
        return .neutral
    }

    // MARK: - Structure

    private func determineStructure(_ log: inout SignalLog, rewardMetrics: RewardMetrics) -> Double {
        let habitList = habits.getTopHabits(limit: 10)
        let productivityHabits = habitList.filter { $0.type == .productivity_pattern }

        var base: Double = 0.5
        if productivityHabits.count >= 2 {
            base = 0.8
            log.structureSignals.append("\(productivityHabits.count) productivity habits → high base")
        } else if productivityHabits.count == 1 {
            base = 0.6
            log.structureSignals.append("1 productivity habit → moderate-high base")
        } else {
            let events = learningLoop.getEvents(limit: 50)
            let workflowCompletions = events.filter { $0.type == .workflowCompleted }.count
            if workflowCompletions > 5 {
                base = 0.8
                log.structureSignals.append("\(workflowCompletions) workflow completions → high base")
            } else if workflowCompletions > 0 {
                base = 0.6
                log.structureSignals.append("\(workflowCompletions) workflow completions → moderate-high base")
            }
        }

        let adjusted = base + rewardMetrics.structureBias * 0.3
        let clamped = max(0.0, min(1.0, adjusted))
        log.structureSignals.append("bias: \(String(format: "%+.2f", rewardMetrics.structureBias)) → \(String(format: "%.2f", clamped))")
        return clamped
    }

    // MARK: - Explanation depth

    private func determineDepth(_ log: inout SignalLog, loopMetrics metrics: LoopMetrics) -> Double {
        var base: Double = 0.6
        if metrics.acceptanceRate > 0.8 {
            base -= 0.1
            log.depthSignals.append("high acceptance (\(String(format: "%.2f", metrics.acceptanceRate))) → reduce to \(String(format: "%.2f", base))")
        }
        if metrics.rejectionRate > 0.5 {
            base += 0.1
            log.depthSignals.append("high rejection (\(String(format: "%.2f", metrics.rejectionRate))) → increase to \(String(format: "%.2f", base))")
        }

        let clamped = max(0.0, min(1.0, base))
        log.depthSignals.append("final: \(String(format: "%.2f", clamped))")
        return clamped
    }

    // MARK: - Formatting

    private func determineFormatting(_ log: inout SignalLog, loopMetrics metrics: LoopMetrics, rewardMetrics: RewardMetrics, writingProfile: WritingProfile?) -> ResponseStyleProfile.ResponseFormatting {
        guard let profile = writingProfile, profile.totalSamples >= 3 else {
            log.formattingSignals.append("insufficient writing data → standard")
            return .standard
        }

        let dashCount = profile.punctuationPatterns["—"] ?? 0
        let quoteCount = profile.punctuationPatterns["\""] ?? 0

        var result: ResponseStyleProfile.ResponseFormatting
        if dashCount > 5 || quoteCount > 5 {
            result = .markdown
            log.formattingSignals.append("\(dashCount) dashes, \(quoteCount) quotes → markdown")
        } else if profile.emojiUsage > 0.3 {
            result = .standard
            log.formattingSignals.append("emoji usage \(String(format: "%.2f", profile.emojiUsage)) → standard")
        } else if dashCount == 0 && quoteCount == 0 && profile.emojiUsage < 0.1 {
            result = .minimal
            log.formattingSignals.append("no markdown signals → minimal")
        } else {
            result = .standard
            log.formattingSignals.append("mixed signals → standard")
        }

        if metrics.editRate > 0.3 && rewardMetrics.dominantAdjustments.contains(where: { $0.contains("format") }) {
            log.formattingSignals.append("edit rate \(String(format: "%.2f", metrics.editRate)) with format adjustment → standard")
            result = .standard
        }

        log.formattingSignals.append("final: \(result.rawValue)")
        return result
    }

    // MARK: - Logging

    private func logSignals(_ log: SignalLog) {
        logger.info("VERBOSITY: \(log.verbositySignals.joined(separator: "; "))")
        logger.info("TONE: \(log.toneSignals.joined(separator: "; "))")
        logger.info("STRUCTURE: \(log.structureSignals.joined(separator: "; "))")
        logger.info("DEPTH: \(log.depthSignals.joined(separator: "; "))")
        logger.info("FORMATTING: \(log.formattingSignals.joined(separator: "; "))")
    }
}
