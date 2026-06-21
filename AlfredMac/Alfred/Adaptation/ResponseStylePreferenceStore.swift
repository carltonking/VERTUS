import Foundation

// MARK: - ResponseStylePreferenceStore
//
// Captures the user's EXPLICIT response-style feedback ("just give me a list", "that was too long",
// "be more casual") as plain imperative rules, and replays them into every future system prompt so
// Alfred answers the way the user asked — immediately, not after slow statistical drift.
//
// Deliberately tiny and file-based (like ProfileDigest) so it needs zero wiring through AlfredApp:
// AssistantCore reads it in buildSystem and writes it in post-processing. Persisted as a JSON array
// of rules at ~/.alfred/profile/response_style.json, newest last, deduped, capped.

struct ResponseStylePreferenceStore {
    private let fileURL: URL
    private let maxRules = 8

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".alfred/profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("response_style.json")
    }

    func rules() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }

    /// Adds a rule (most-recent-last), deduped case-insensitively, capped. Recency ordering means a
    /// newer preference appears later in the prompt and naturally takes precedence.
    func add(_ rule: String) {
        let clean = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var arr = rules().filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        arr.append(clean)
        if arr.count > maxRules { arr.removeFirst(arr.count - maxRules) }
        if let data = try? JSONEncoder().encode(arr) { try? data.write(to: fileURL) }
    }

    func clear() { try? FileManager.default.removeItem(at: fileURL) }

    /// System-prompt block listing the captured preferences, or "" when none exist.
    func systemPromptBlock(ownerName: String) -> String {
        let r = rules()
        guard !r.isEmpty else { return "" }
        let lines = r.map { "- \($0)" }.joined(separator: "\n")
        return """
            HOW \(ownerName) WANTS YOU TO RESPOND (explicit formatting preferences they taught you — \
            follow these by default; only deviate if this specific request clearly calls for it):
            \(lines)
            """
    }
}
