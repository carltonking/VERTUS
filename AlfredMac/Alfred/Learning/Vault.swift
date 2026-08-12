import Foundation

// MARK: - Vault config

/// Where Alfred's memory lives. Read from `~/.alfred/obsidian.json`
/// (`{"vaultPath": "/path/to/vault"}`); without a config, Alfred keeps an
/// Obsidian-shaped vault at `~/.alfred/vault` so memory always has a home.
enum AlfredConfig {

    static func vaultPath() -> String {
        let configPath = "\(NSHomeDirectory())/.alfred/obsidian.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let vault = json["vaultPath"] as? String, !vault.isEmpty {
            return (vault as NSString).expandingTildeInPath
        }
        return "\(NSHomeDirectory())/.alfred/vault"
    }
}

// MARK: - Vault

/// Thin markdown-file access to an Obsidian vault. Follows the vault's
/// conventions: daily notes nest under `Journal/YYYY/MM/`, concept notes stay
/// flat in `My Life/Projects|Goals|Topics|Key Elements/`, everything links
/// with `[[wikilinks]]`.
struct Vault {

    enum Concept: String, CaseIterable {
        case projects = "Projects"
        case goals = "Goals"
        case habits = "Habits"
        case topics = "Topics"
        case keyElements = "Key Elements"
    }

    let root: URL

    init(path: String) {
        root = URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Paths

    func journalDir(for date: Date = Date()) -> URL {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = String(format: "%02d", cal.component(.month, from: date))
        return root.appendingPathComponent("Journal/\(y)/\(m)", isDirectory: true)
    }

    func conceptDir(_ concept: Concept) -> URL {
        root.appendingPathComponent("My Life/\(concept.rawValue)", isDirectory: true)
    }

    /// The daily note for `date`, creating a skeleton when missing.
    /// Follows the vault's INDEX.md convention: `YYYY/MM/YYYY-MM-DD-<slug>.md`.
    /// If a note for the day already exists (Penn's or ours), we use it —
    /// one file per day, sections appended.
    /// Returns nil when the vault root doesn't exist (not configured yet).
    func dailyNote(for date: Date = Date()) -> URL? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let dir = journalDir(for: date)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Reuse an existing same-day note under any slug (both the ISO-dash
        // convention and the plain yyyyMMdd form).
        let dayDashed = Self.dashedDay(date)
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           let match = existing.first(where: { name in
               name.hasSuffix(".md") && (name.hasPrefix(dayDashed) || name.hasPrefix(yyyyMMdd(date)))
           }) {
            return dir.appendingPathComponent(match)
        }

        let url = dir.appendingPathComponent("\(yyyyMMdd(date))-alfred.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let title = Self.title(for: date)
            try? """
            # \(title)

            > Logged by Alfred.

            """.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Append a bullet to today's journal note (creates it if missing).
    @discardableResult
    mutating func appendJournal(_ text: String, date: Date = Date()) -> URL? {
        guard let url = dailyNote(for: date) else { return nil }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return url }
        if !body.hasPrefix("-") && !body.hasPrefix("##") { body = "- " + body }
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        content = content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n- \(Self.screenTimestamp(date)) \(body)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Create or update a concept note in `My Life/<Concept>/`. Returns the
    /// note URL. Existing notes are updated only when `append` is true.
    @discardableResult
    func writeConceptNote(_ category: Concept, title: String, body: String, append: Bool = false) -> URL? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let dir = conceptDir(category)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: "/", with: " ")
        let url = dir.appendingPathComponent(safeTitle + ".md")
        if FileManager.default.fileExists(atPath: url.path), !append {
            return url  // SSOT: never clobber the user's own note
        }
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(safeTitle)\n\n"
        content = content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- \(Self.timestamp()) — \(body)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Reading

    /// All markdown files under the vault, recursively.
    func allNotes() -> [URL] {
        guard let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }) else { return [] }
        return urls.filter { url in
            url.pathExtension.lowercased() == "md"
                && !url.lastPathComponent.hasPrefix(".")
                && !url.path.contains(".obsidian")
        }
    }

    // MARK: Helpers

    private func yyyyMMdd(_ date: Date) -> String {
        let cal = Calendar.current
        return String(format: "%04d%02d%02d",
                      cal.component(.year, from: date),
                      cal.component(.month, from: date),
                      cal.component(.day, from: date))
    }

    private static func dashedDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func title(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        let df = DateFormatter()
        df.dateFormat = "EEEE"
        return "\(day) \(df.string(from: date))"
    }

    private static func screenTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "(`\(f.string(from: date))`)"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}