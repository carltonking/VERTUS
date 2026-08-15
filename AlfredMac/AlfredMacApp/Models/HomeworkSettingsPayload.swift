//
//  HomeworkSettingsPayload.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Models/HomeworkSettingsPayload.swift).
//

import Foundation

/// The persisted homework configuration, as the Mac reports it — the
/// submission-side Homework Assistant skill's knobs.
struct HomeworkSettingsPayload: Codable, Hashable {
    var enabled: Bool
    /// HomeworkMode rawValue: teach | submit.
    var defaultMode: String
    /// HomeworkCodeStyle rawValue: match_mine | generic.
    var codeStyle: String
    /// HomeworkShowSteps rawValue: always | on_request | never.
    var showSteps: String
    /// HomeworkDifficulty rawValue: match_level | challenge | simplify.
    var difficulty: String
    /// HomeworkFormat rawValue: text | latex | code.
    var format: String

    static let `default` = HomeworkSettingsPayload(
        enabled: true,
        defaultMode: "teach",
        codeStyle: "match_mine",
        showSteps: "always",
        difficulty: "match_level",
        format: "text")

    static func fromJSON(_ params: [String: Any]) -> HomeworkSettingsPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let settings = try? JSONDecoder().decode(HomeworkSettingsPayload.self, from: data)
        else { return nil }
        return settings
    }
}
