//
//  TasteSettings.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Models/TasteSettings.swift).
//

import Foundation

/// The persisted anti-slop configuration, as the Mac reports it.
struct TasteSettingsPayload: Codable, Hashable {
    var enabled: Bool
    /// TasteAggressiveness rawValue: conservative | moderate | aggressive.
    var aggressiveness: String
    /// TasteVoice rawValue: matchUser | professional | casual | technical.
    var voice: String
    /// TasteScope rawValues: emails | code | routines | briefing.
    var scopes: [String]

    static let `default` = TasteSettingsPayload(
        enabled: true,
        aggressiveness: "moderate",
        voice: "matchUser",
        scopes: ["emails", "code", "routines", "briefing"])

    static func fromJSON(_ params: [String: Any]) -> TasteSettingsPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let settings = try? JSONDecoder().decode(TasteSettingsPayload.self, from: data)
        else { return nil }
        return settings
    }
}
