import Foundation

// MARK: - Behavior profile

/// Aggregate, privacy-safe usage patterns learned passively from screen
/// observations: which apps are used when, and when the user is active.
///
/// Deliberately contains nothing content-shaped — no URLs, no file paths, no
/// text. Only bundle identifiers, day-of-week/hour buckets and file
/// extensions (when a file-access source exists). Counts are aggregated, never
/// individual events, so the profile describes *patterns*, not a transcript.
struct BehaviorProfile: Codable, Equatable {

    // MARK: Nested types

    /// One row of `topApps` — a tuple can't be Codable, so this is the
    /// persisted form of (bundleID, count).
    struct AppUsage: Codable, Equatable {
        let bundleID: String
        let count: Int
    }

    /// A work window like 9–18. A tuple can't be Codable either.
    struct WorkHours: Codable, Equatable {
        let start: Int
        let end: Int
    }

    // MARK: Fields

    /// Bundle ID → [count for each hour 0–23].
    var appUsageByHour: [String: [Int]]
    /// Bundle ID → [count for each day of week 0–6 (0 = Sunday)].
    var appUsageByDay: [String: [Int]]
    /// Most-used apps, ranked descending, capped at 20.
    var topApps: [AppUsage]
    /// File extension → access count. Empty until a file-access source exists
    /// (screen observations carry no paths — see ActivityObserver).
    var fileTypesAccessed: [String: Int]
    /// Hour 0–23 → activity level normalized to a 0–100 scale.
    var timeOfDayActivity: [Int: Int]
    /// Inferred primary work window, e.g. (9, 18). (0, 0) when unknown.
    var primaryWorkHours: WorkHours

    // MARK: - Prompt injection

    /// Two or three plain sentences describing the learned routine, ready for
    /// the system prompt. Returns "" until the profile has real signal.
    func toPromptInjection() -> String {
        guard !topApps.isEmpty else { return "" }

        var sentences: [String] = []

        let top = topApps.prefix(3)
            .map { Self.friendlyName(for: $0.bundleID) }
            .joined(separator: ", ")
        sentences.append("The user is most active in \(top).")

        if primaryWorkHours.start != 0 || primaryWorkHours.end != 0 {
            sentences.append("Their typical active window is \(Self.describe(primaryWorkHours)).")
        }

        sentences.append("Use these patterns to time proactive suggestions and anticipate when they'll want you — without reading anything they type or view.")

        return sentences.joined(separator: " ")
    }

    /// A short human name for an app bundle ID, when we know one; otherwise
    /// the last dotted component (com.apple.Safari → Safari).
    static func friendlyName(for bundleID: String) -> String {
        switch bundleID {
        case "com.apple.dt.Xcode": return "Xcode"
        case "com.tinyspeck.slackmacgap": return "Slack"
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Chrome"
        case "com.microsoft.VSCode": return "VS Code"
        case "com.apple.Finder": return "Finder"
        case "com.apple.mail": return "Mail"
        case "com.apple.Terminal": return "Terminal"
        case "com.jetbrains.intellij": return "IntelliJ"
        case "com.spotify.client": return "Spotify"
        default:
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
    }

    /// "9am to 6pm" for (9, 18); handles midnight-crossing windows like
    /// (22, 2) → "10pm to 2am".
    static func describe(_ hours: WorkHours) -> String {
        func hourLabel(_ h: Int) -> String {
            let h12 = h % 12 == 0 ? 12 : h % 12
            return "\(h12)\(h < 12 ? "am" : "pm")"
        }
        return "\(hourLabel(hours.start)) to \(hourLabel(hours.end))"
    }
}
