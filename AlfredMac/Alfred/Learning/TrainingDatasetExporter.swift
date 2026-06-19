import Foundation
import OSLog

// MARK: - Writing style snapshot

struct WritingStyleSnapshot: Codable {
    let verbosity: Double
    let tone: Double
    let structure: Double
    let explanationDepth: Double
    let lastUpdated: String
}

// MARK: - Training record

struct TrainingRecord: Codable {
    let timestamp: String
    let query: String
    let context: String
    let suggestedAction: String
    let suggestedParameters: [String: String]
    let outcome: String
    let finalParameters: [String: String]?
    let writingStyleSnapshot: WritingStyleSnapshot
    let rewardSignals: [String: Double]
    let explanation: String
}

// MARK: - Exporter

final class TrainingDatasetExporter {
    private let learningLoopStore: LearningLoopStore
    private let writingStyleStore: WritingStyleStore
    private let rewardEngine: RewardEngine
    private let logger = Logger(subsystem: "com.alfred.training", category: "exporter")
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(
        learningLoopStore: LearningLoopStore,
        writingStyleStore: WritingStyleStore,
        rewardEngine: RewardEngine
    ) {
        self.learningLoopStore = learningLoopStore
        self.writingStyleStore = writingStyleStore
        self.rewardEngine = rewardEngine
    }

    // MARK: - Export all

    func exportToJSONL() throws -> URL {
        let suggestions = learningLoopStore.getAllSuggestions(limit: 10000)
        let records = buildRecords(from: suggestions)
        return try writeJSONL(records, filename: "training_data.jsonl")
    }

    // MARK: - Export since date

    func exportBatch(since: Date) throws -> URL {
        let all = learningLoopStore.getAllSuggestions(limit: 10000)
        let filtered = all.filter { $0.timestamp >= since }
        let records = buildRecords(from: filtered)

        let sinceStr = dateFormatter.string(from: since)
        let nowStr = dateFormatter.string(from: Date())
        let safeSince = sinceStr.replacingOccurrences(of: ":", with: "-")
        let safeNow = nowStr.replacingOccurrences(of: ":", with: "-")
        return try writeJSONL(records, filename: "training_data_\(safeSince)_\(safeNow).jsonl")
    }

    // MARK: - Validation

    func validateRecord(_ record: TrainingRecord) -> Bool {
        guard !record.query.isEmpty else { return false }
        guard ["accepted", "rejected", "edited_shortened", "edited_expanded"].contains(record.outcome) else { return false }
        guard ActionType(rawValue: record.suggestedAction) != nil else { return false }
        return true
    }

    // MARK: - Private

    private func buildRecords(from suggestions: [TrainingSuggestion]) -> [TrainingRecord] {
        let snapshot = buildSnapshot()
        let signals = rewardEngine.getDailyRewardSummary()

        return suggestions.compactMap { s in
            let outcome = classifyOutcome(s)
            guard let outcome else { return nil }

            let context = [
                "writingStyle": s.writingStyleContext,
                "relationships": s.relationshipContext,
                "habits": s.habitContext
            ].filter { !$0.value.isEmpty }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")

            let explanationParts: [String] = [
                outcome == "accepted" ? "User accepted the suggestion as-is." : nil,
                outcome == "rejected" ? "User rejected the suggestion." : nil,
                outcome == "edited_shortened" ? "User edited the suggestion to a shorter version." : nil,
                outcome == "edited_expanded" ? "User edited the suggestion to a longer version." : nil,
                s.edited && !s.finalUserVersion.isEmpty ? "Original: \(s.alfredResponse) → Final: \(s.finalUserVersion)" : nil
            ].compactMap { $0 }

            let record = TrainingRecord(
                timestamp: dateFormatter.string(from: s.timestamp),
                query: s.userPrompt,
                context: context,
                suggestedAction: "respond_text",
                suggestedParameters: [:],
                outcome: outcome,
                finalParameters: s.edited ? ["userVersion": s.finalUserVersion] : nil,
                writingStyleSnapshot: snapshot,
                rewardSignals: [
                    "verbosityBias": signals.verbosityBias,
                    "structureBias": signals.structureBias,
                    "adaptationDrift": signals.adaptationDrift
                ],
                explanation: explanationParts.joined(separator: " ")
            )

            return record
        }
    }

    private func classifyOutcome(_ s: TrainingSuggestion) -> String? {
        if s.accepted && !s.edited { return "accepted" }
        if s.rejected { return "rejected" }
        if s.edited {
            let origLen = s.alfredResponse.count
            let finalLen = s.finalUserVersion.count
            return finalLen < origLen ? "edited_shortened" : "edited_expanded"
        }
        return nil
    }

    private func buildSnapshot() -> WritingStyleSnapshot {
        if let profile = writingStyleStore.getWritingProfile() {
            WritingStyleSnapshot(
                verbosity: profile.avgSentenceLength / 50.0,
                tone: profile.formalityScore,
                structure: profile.avgParagraphLength / 10.0,
                explanationDepth: profile.totalSamples > 50 ? 0.8 : 0.3,
                lastUpdated: dateFormatter.string(from: profile.lastUpdated)
            )
        } else {
            WritingStyleSnapshot(
                verbosity: 0.5,
                tone: 0.5,
                structure: 0.5,
                explanationDepth: 0.3,
                lastUpdated: dateFormatter.string(from: Date())
            )
        }
    }

    private func writeJSONL(_ records: [TrainingRecord], filename: String) throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw TrainingError.documentDirectoryUnavailable
        }

        let dir = docs.appendingPathComponent("Alfred", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var lines: [String] = []
        for record in records {
            guard validateRecord(record) else { continue }
            let data = try encoder.encode(record)
            if let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }

        let output = lines.joined(separator: "\n") + "\n"
        try output.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Exported \(records.count) records to \(url.path)")
        return url
    }
}

// MARK: - Errors

enum TrainingError: LocalizedError {
    case documentDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .documentDirectoryUnavailable: return "Documents directory is not available"
        }
    }
}
