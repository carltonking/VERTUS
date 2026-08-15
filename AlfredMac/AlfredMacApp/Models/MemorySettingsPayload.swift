//
//  MemorySettingsPayload.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Models/MemorySettingsPayload.swift).
//

import Foundation

/// The persisted memory configuration, as the Mac reports it.
struct MemorySettingsPayload: Codable, Hashable {
    var enabled: Bool
    /// MemoryLearningMode rawValue: conservative | aggressive.
    var learningMode: String
    /// MemoryDecayRate rawValue: slow | fast.
    var decayRate: String
    /// Only memories at or above this confidence are used for decisions.
    var confidenceThreshold: Double
    /// MemoryCategory rawValues: preference | project_pattern | person |
    /// goal | learning | constraint. The phone echoes these back untouched —
    /// it doesn't edit them, but must not silently reset Mac-side exclusions.
    var excludedCategories: [String]

    static let `default` = MemorySettingsPayload(
        enabled: true,
        learningMode: "conservative",
        decayRate: "slow",
        confidenceThreshold: 0.7,
        excludedCategories: [])

    static func fromJSON(_ params: [String: Any]) -> MemorySettingsPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let settings = try? JSONDecoder().decode(MemorySettingsPayload.self, from: data)
        else { return nil }
        return settings
    }
}
