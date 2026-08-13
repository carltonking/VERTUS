//
//  MailSettings.swift
//  Alfred
//
//  The owner's email preferences. Shared by the whole Mac mail stack — the
//  folder sweep (MailScanService), the copilot (MailAIService) and the sent
//  learning loop — and mirrored to the phone over the socket (`mail.settings`
//  / `mail.set_settings`), so one Settings screen on either device drives the
//  same behaviour.
//
//  Plain Codable + UserDefaults, deliberately: the sweep reads it from a
//  detached task, so the store must not be MainActor-bound.
//

import Foundation

/// Scan cadence options the settings UI offers (minutes between sweeps).
enum MailScanFrequency: Int, CaseIterable {
    case five = 5
    case fifteen = 15
    case thirty = 30
    case sixty = 60
}

/// Drafting tone preference for the copilot's replies.
enum MailDraftTone: String, CaseIterable {
    case matchContext = "match-context"
    case formal = "formal"
    case casual = "casual"
}

/// Everything the owner has chosen about their mail.
struct MailSettings: Codable, Equatable {
    /// Minutes between full-folder sweeps. 5 / 15 / 30 / 60.
    var scanFrequencyMinutes: Int = 15
    /// Account id → signature block, appended to drafted replies.
    var signatures: [String: String] = [:]
    /// MailDraftTone raw value.
    var draftTone: String = MailDraftTone.matchContext.rawValue
    /// Learn the writing style from sent messages.
    var autoLearnSent: Bool = true
    /// Folder ids the sweep skips (privacy / noise).
    var excludedFolders: [String] = []
    /// Post a notification when a sweep finds something important.
    var notifyOnImportant: Bool = true
    /// How many sent messages have been folded into the style profile — the
    /// "Revisions available" badge in the settings screen.
    var learnedPhraseCount: Int = 0
}

/// UserDefaults-backed store for `MailSettings`, safe from any thread.
/// Reads are lock-free for the value type; mutations serialize through a lock.
final class MailSettingsStore {

    static let shared = MailSettingsStore()

    private let key = "alfred.mail_settings"
    private let lock = NSLock()
    private var cached: MailSettings

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let settings = try? JSONDecoder().decode(MailSettings.self, from: data) {
            cached = settings
        } else {
            cached = MailSettings()
        }
    }

    /// A snapshot of the current settings.
    var current: MailSettings {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Mutate and persist atomically.
    func update(_ mutate: (inout MailSettings) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&cached)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
