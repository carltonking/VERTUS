import Foundation
import GRDB

enum RewardSignalType: String, Codable, CaseIterable {
    case writingAcceptance
    case writingRejection
    case writingEditShortened
    case writingEditExpanded
    case workflowSuccess
    case workflowFailure
    case habitReinforced
    case habitBroken
    case adaptationOverride
}

struct RewardSignalRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reward_signals"

    var id: Int64?
    var timestamp: Double
    var signalType: String
    var strength: Double
    var sourceContextJSON: String
    var explanationTags: String
}

struct RewardSignal {
    let id: Int64?
    let timestamp: Date
    let type: RewardSignalType
    let strength: Double
    let sourceContext: [String: String]
    let explanationTags: [String]

    init(record: RewardSignalRecord) {
        self.id = record.id
        self.timestamp = Date(timeIntervalSince1970: record.timestamp)
        self.type = RewardSignalType(rawValue: record.signalType) ?? .writingAcceptance
        self.strength = record.strength
        self.sourceContext = (try? JSONSerialization.jsonObject(with: Data(record.sourceContextJSON.utf8)) as? [String: String]) ?? [:]
        self.explanationTags = record.explanationTags.split(separator: ",").map(String.init)
    }

    init(
        type: RewardSignalType,
        strength: Double,
        sourceContext: [String: String],
        explanationTags: [String]
    ) {
        self.id = nil
        self.timestamp = Date()
        self.type = type
        self.strength = strength
        self.sourceContext = sourceContext
        self.explanationTags = explanationTags
    }
}

struct DailyRewardSummary {
    let date: Date
    let totalSignals: Int
    let totalPositive: Int
    let totalNegative: Int
    let verbosityBias: Double
    let structureBias: Double
    let adaptationDrift: Double
    let dominantAdjustments: [String]

    var systemPromptBlock: String {
        guard totalSignals > 0 else { return "" }

        var lines: [String] = []
        lines.append("REWARD SIGNALS:")
        lines.append("  • verbosity bias: \(formatBias(verbosityBias))")
        lines.append("  • structure bias: \(formatBias(structureBias))")
        lines.append("  • adaptation drift: \(formatDrift(adaptationDrift))")
        if !dominantAdjustments.isEmpty {
            let adjs = dominantAdjustments.joined(separator: ", ")
            lines.append("  • adjustments: \(adjs)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatBias(_ value: Double) -> String {
        let label: String
        if value > 0.3 { label = "prefer more" }
        else if value < -0.3 { label = "prefer less" }
        else { label = "neutral" }
        return "\(String(format: "%+.2f", value)) (\(label))"
    }

    private func formatDrift(_ value: Double) -> String {
        let label: String
        if value > 0.3 { label = "significant drift" }
        else if value < -0.3 { label = "negative drift" }
        else { label = "minimal" }
        return "\(String(format: "%+.2f", value)) (\(label))"
    }
}
