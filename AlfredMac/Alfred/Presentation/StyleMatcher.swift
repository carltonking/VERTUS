import Foundation

// MARK: - Style matcher
//
// The "design learning" half of the skill: every deck records which style and
// tone it was made with, and the next request with no explicit style preference
// picks the style the user has actually been using — same tone first, then the
// most recent one. The settings default acts as the user's explicit preference
// and outranks the learned history. Pure and disk-backed, so tests cover the
// ranking without a live run.

struct PresentationHistoryEntry: Codable, Equatable, Sendable {
    var topic: String
    var tone: String
    var style: String
    var createdAt: TimeInterval
}

final class StyleMatcher {

    static let shared = StyleMatcher()

    /// Where the history lives; injectable for tests.
    var storeURL: URL = {
        let home = NSHomeDirectory() as NSString
        return URL(fileURLWithPath: home.appendingPathComponent(".alfred/presentation_history.json"))
    }()

    private(set) var history: [PresentationHistoryEntry] = []

    private init() {
        load()
    }

    /// The style to use for a request. Precedence:
    ///   1. explicit style on the request (the user asked)
    ///   2. the settings default (an explicit preference)
    ///   3. the most recent learned style, preferring one used with this tone
    ///   4. tone-based default (academic → academic, everything else → modern)
    static func suggestedStyle(explicit: String?,
                               settingsDefault: String,
                               history: [PresentationHistoryEntry],
                               tone: PresentationTone) -> PresentationStyle {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PresentationStyle.style(named: explicit)
        }
        if !settingsDefault.isEmpty {
            return PresentationStyle.style(named: settingsDefault)
        }
        let toneMatches = history.filter { $0.tone == tone.rawValue }
        if let latest = toneMatches.max(by: { $0.createdAt < $1.createdAt }) {
            return PresentationStyle.style(named: latest.style)
        }
        if let latest = history.max(by: { $0.createdAt < $1.createdAt }) {
            return PresentationStyle.style(named: latest.style)
        }
        return tone == .academic ? .academic : .modern
    }

    /// Record a finished deck so the next one matches.
    func record(topic: String, tone: PresentationTone, style: PresentationStyle) {
        history.append(PresentationHistoryEntry(
            topic: topic, tone: tone.rawValue, style: style.id,
            createdAt: Date().timeIntervalSince1970))
        // Keep the last 50 so the file stays small and old tastes fade.
        if history.count > 50 { history.removeFirst(history.count - 50) }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([PresentationHistoryEntry].self, from: data)
        else { return }
        history = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}
