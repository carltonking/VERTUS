//
//  TasteSettings.swift
//  Alfred
//
//  The iOS half of the taste (anti-slop) settings contract. Mirrors the
//  macOS TasteSettings in AlfredMac/Alfred/Services/TasteSkillManager.swift
//  and the wire dictionaries in BriefingSocketServer's taste section exactly —
//  the phone decodes `taste.settings` results with this and encodes
//  `taste.set_settings` back with it. Keep the two in lockstep.
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
