import Foundation

// MARK: - Memory note

/// One Alfred memory. First-class citizens of the vault are markdown notes —
/// this is just the in-memory index over them.
public struct MemoryNote: Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let category: String      // journal | activity | projects | goals | habits | topics | keyelements | documents
    public let importance: Int       // 1...5
    public let date: Date
    public let url: URL?

    public var text: String { "\(title)\n\(body)" }

    public init(id: String, title: String, body: String, category: String, importance: Int, date: Date, url: URL?) {
        self.id = id
        self.title = title
        self.body = body
        self.category = category
        self.importance = importance
        self.date = date
        self.url = url
    }
}

// MARK: - Store

/// Markdown-vault-backed memory for Alfred.
///
/// Reads daily notes + My Life concept notes from the configured Obsidian
/// vault, serves keyword search, and hands concepts/journals to the vault
/// writer. The vault is the single source of truth — the index here is only
/// for fast lookups and is rebuilt on refresh.
public final class MemoryStore {

    public static let shared = MemoryStore()

    private var notes: [MemoryNote] = []
    private let queue = DispatchQueue(label: "alfred.memory")

    private lazy var vault: Vault = Vault(path: AlfredConfig.vaultPath())

    public init() {}

    // MARK: Category mapping — vault folders → memory categories

    public static func category(forFolder folder: String) -> String {
        switch folder {
        case "Projects":     return "projects"
        case "Goals":        return "goals"
        case "Habits":       return "habits"
        case "Topics":       return "topics"
        case "Key Elements": return "keyelements"
        default:             return "documents"
        }
    }

    // MARK: - Index

    /// Rebuild the index from the vault. Safe to call repeatedly; used at
    /// launch and on a refresh timer so notes the user adds in Obsidian
    /// become visible without an Alfred restart.
    public func refresh() {
        let urls = vault.allNotes()
        var found: [MemoryNote] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for url in urls {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.path
            let name = url.deletingPathExtension().lastPathComponent

            // Journal filenames encode the date: 2026-08-08.md
            var date = Date()
            if let match = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression),
               let d = formatter.date(from: String(name[match])) {
                date = d
            }

            let category: String
            if path.contains("/Journal/") { category = "journal" }
            else if let folder = path.split(separator: "/").dropLast().last {
                category = Self.category(forFolder: String(folder))
            } else {
                category = "documents"
            }

            found.append(MemoryNote(
                id: "\(date.timeIntervalSince1970)-\(url.lastPathComponent)",
                title: Self.firstHeading(of: content) ?? (name as NSString).lastPathComponent,
                body: content,
                category: category,
                importance: content.contains("## ") ? 4 : 2,
                date: date,
                url: url))
        }
        queue.sync {
            notes = found.sorted { $0.date > $1.date }
        }
        NSLog("[memory] indexed %d vault notes", found.count)
    }

    // MARK: - Query

    /// The full indexed note list, newest first. Read-only snapshot — the
    /// unified layer's vault mirror is rebuilt from this on launch
    /// (MigrationManager).
    public func allNotes() -> [MemoryNote] {
        queue.sync { notes }
    }

    /// Search the vault by keywords. Notes matching the most terms rank first;
    /// importance breaks ties. Pass a category to narrow.
    public func search(_ query: String, category: String? = nil, limit: Int = 6) -> [MemoryNote] {
        let terms = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !terms.isEmpty else { return recent(category: category, limit: limit) }
        return queue.sync {
            notes
                .filter { note in
                    if let category, note.category != category { return false }
                    let text = note.text.lowercased()
                    return terms.contains { text.contains($0) }
                }
                .map { note in
                    let text = note.text.lowercased()
                    let score = terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
                    return (score * 10 + note.importance, note)
                }
                .sorted { $0.0 > $1.0 }
                .prefix(limit)
                .map { $0.1 }
        }
    }

    /// Most recent notes, optionally within one category.
    public func recent(category: String? = nil, limit: Int = 10) -> [MemoryNote] {
        queue.sync {
            let filtered = category.map { c in notes.filter { $0.category == c } } ?? notes
            return Array(filtered.prefix(limit))
        }
    }

    /// A compact single-line rendering of the top matches, ready to drop into
    /// a prompt. Empty string when nothing matched.
    public func groundingText(for query: String, limit: Int = 4) -> String {
        let matches = search(query, limit: limit)
        guard !matches.isEmpty else { return "" }
        return matches.enumerated().map { i, n in
            let snippet = Self.firstHeading(of: n.body) ?? n.title
            return "[vault:\(n.category)/\(snippet)]"
        }.joined(separator: " ")
    }

    // MARK: - Writing

    /// Log a line into today's journal note (activity/inbox) and index it.
    @discardableResult
    public func logActivity(_ text: String, source: String = "screen", importance: Int = 2,
                            date: Date = Date()) -> MemoryNote? {
        guard !text.isEmpty else { return nil }
        var vault = self.vault
        guard let url = vault.appendJournal(text, date: date) else { return nil }
        let note = MemoryNote(
            id: UUID().uuidString,
            title: Self.dayTitle(date),
            body: text,
            category: "journal",
            importance: importance,
            date: date,
            url: url)
        queue.sync { notes.insert(note, at: 0) }
        return note
    }

    /// Upsert a concept note (My Life/Projects, Goals, Topics, ...). Never
    /// clobbers an existing note; when the note exists and `append` is true, a
    /// dated bullet is appended instead.
    @discardableResult
    public func noteConcept(_ concept: Vault.Concept, title: String, body: String,
                            append: Bool = false) -> MemoryNote? {
        guard let url = vault.writeConceptNote(concept, title: title, body: body, append: append) else { return nil }
        let note = MemoryNote(
            id: UUID().uuidString,
            title: title,
            body: body,
            category: MemoryStore.category(forFolder: concept.rawValue),
            importance: 4,
            date: Date(),
            url: url)
        queue.sync { notes.insert(note, at: 0) }
        return note
    }

    // MARK: - Helpers

    private static func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func firstHeading(of content: String) -> String? {
        content.split(separator: "\n").first {
            $0.hasPrefix("# ") && !$0.hasPrefix("## ")
        }.map { String($0.dropFirst(2)) }
    }
}
