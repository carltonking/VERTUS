//
//  Optimization.swift
//  Alfred
//
//  The iOS half of the self-optimization (DSPy) contract. Mirrors the macOS
//  types in AlfredMac/Alfred/Optimization/ and the wire dictionaries in
//  BriefingSocketServer's optimization section exactly — camelCase keys, like
//  the taste and career settings contracts, so both sides encode/decode with
//  the default JSON coders. Keep the two in lockstep.
//

import Foundation

/// One domain's score: current week vs the week before.
struct OptimizationKindScorePayload: Codable, Hashable, Identifiable {
    var kind: String
    var displayName: String
    var current: Double
    var previous: Double
    var samples: Int

    var id: String { kind }
}

/// One compile run, for the report's "last run" line.
struct OptimizationRunPayload: Codable, Hashable {
    var kind: String
    var version: Int
    var before: Double
    var after: Double
    var examples: Int
    var applied: Bool
    var rolledBack: Bool
    var source: String
    var createdAt: TimeInterval
}

/// The full report: the trend, per-domain scores, and active learned rules.
struct OptimizationReportPayload: Codable, Hashable {
    var averageRating: Double
    var weekDelta: Double
    var totalRatings: Int
    var perKind: [OptimizationKindScorePayload]
    var activeOptimizations: [String]
    var lastCompiledAt: TimeInterval?
    var lastRun: OptimizationRunPayload?

    static func fromJSON(_ params: [String: Any]) -> OptimizationReportPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        return try? JSONDecoder().decode(OptimizationReportPayload.self, from: data)
    }
}

/// The optimization loop's persisted configuration.
struct OptimizationSettingsPayload: Codable, Hashable {
    /// OptimizationFrequency rawValue: weekly | monthly | manual.
    var frequency: String
    var minFeedback: Int
    var confidenceThreshold: Double
    var autoRollback: Bool
    var lastCompiledAt: TimeInterval

    static let `default` = OptimizationSettingsPayload(
        frequency: "weekly",
        minFeedback: 10,
        confidenceThreshold: 0.10,
        autoRollback: true,
        lastCompiledAt: 0)

    static func fromJSON(_ params: [String: Any]) -> OptimizationSettingsPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        return try? JSONDecoder().decode(OptimizationSettingsPayload.self, from: data)
    }
}

/// The improvement card carried on a briefing — a headline delta, the
/// per-domain trend, and the active rules.
struct ImprovementCardPayload: Codable, Hashable {
    var averageRating: Double
    var weekDelta: Double
    var totalRatings: Int
    var perKind: [OptimizationKindScorePayload]
    var activeOptimizations: [String]

    static func fromJSON(_ params: [String: Any]) -> ImprovementCardPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        return try? JSONDecoder().decode(ImprovementCardPayload.self, from: data)
    }
}
