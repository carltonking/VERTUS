// MARK: - CitationManager
//
// Deterministic citation formatting for the essay skill: full reference-list
// entries and in-text citations in MLA, APA and Chicago (author–date), plus a
// sanity checker that catches the two most common citation mistakes — a listed
// source that is never cited, and a missing works-cited section.
//
// Pure and static so the formats are pinned by tests, not by a model's memory
// of a style guide. The formats here cover the three source kinds the essay
// skill actually produces (books the user names, journal articles, and web
// sources from research); the checker is deliberately conservative — it flags
// only things a human proofreader would also flag.

import Foundation

// MARK: - Style + source kind

enum CitationStyle: String, Codable, CaseIterable, Sendable {
    case mla
    case apa
    case chicago

    var displayName: String {
        switch self {
        case .mla: return "MLA"
        case .apa: return "APA"
        case .chicago: return "Chicago"
        }
    }

    /// The section header that introduces the reference list.
    var listHeader: String {
        switch self {
        case .mla: return "Works Cited"
        case .apa: return "References"
        case .chicago: return "Bibliography"
        }
    }
}

enum SourceKind: String, Codable, CaseIterable, Sendable {
    case book
    case journal
    case website
}

// MARK: - Citation

/// One source, enough to format a reference in all three styles. Fields are
/// optional so a web search hit (which rarely carries an author) still formats
/// into a legal entry.
struct Citation: Codable, Equatable, Sendable {
    var id: String
    var kind: SourceKind
    /// Each author as "Last, First" (or just "Last"). May be empty.
    var authors: [String]
    var title: String
    /// Journal name (journal), site/publisher name (website), publisher (book).
    var container: String?
    var publisher: String?
    var year: String?
    var url: String?
    var accessedAt: String?
    var volume: String?
    var issue: String?
    var pages: String?

    init(id: String = UUID().uuidString,
         kind: SourceKind,
         authors: [String] = [],
         title: String,
         container: String? = nil,
         publisher: String? = nil,
         year: String? = nil,
         url: String? = nil,
         accessedAt: String? = nil,
         volume: String? = nil,
         issue: String? = nil,
         pages: String? = nil) {
        self.id = id
        self.kind = kind
        self.authors = authors
        self.title = title
        self.container = container
        self.publisher = publisher
        self.year = year
        self.url = url
        self.accessedAt = accessedAt
        self.volume = volume
        self.issue = issue
        self.pages = pages
    }

    /// The primary author's last name — the key in-text citations use.
    var primaryLastName: String {
        CitationManager.lastName(of: authors.first ?? "")
    }
}

// MARK: - Manager

enum CitationManager {

    // MARK: In-text citations

    /// `(Last 12)` / `(Last, 2024)` / `(Last 2024, 12)` depending on style.
    static func inText(_ citation: Citation, style: CitationStyle, page: Int? = nil) -> String {
        let last = citation.primaryLastName
        guard !last.isEmpty else {
            // Author-less source: cite by short title, the MLA/APA fallback.
            let short = Self.shortTitle(citation.title)
            return page.map { "(“\(short)” \($0))" } ?? "(“\(short)”)"
        }
        switch style {
        case .mla:
            return page.map { "(\(last) \($0))" } ?? "(\(last))"
        case .apa:
            let year = citation.year ?? "n.d."
            return page.map { "(\(last), \(year), p. \($0))" } ?? "(\(last), \(year))"
        case .chicago:
            let year = citation.year ?? "n.d."
            return page.map { "(\(last) \(year), \($0))" } ?? "(\(last) \(year))"
        }
    }

    /// The full reference-list entry.
    static func entry(_ citation: Citation, style: CitationStyle) -> String {
        switch style {
        case .mla: return mlaEntry(citation)
        case .apa: return apaEntry(citation)
        case .chicago: return chicagoEntry(citation)
        }
    }

    /// The whole reference list, one entry per line, prefixed by the style's
    /// section header.
    static func referenceList(_ citations: [Citation], style: CitationStyle) -> String {
        var lines = [style.listHeader]
        for citation in citations {
            lines.append(entry(citation, style: style))
        }
        return lines.joined(separator: "\n")
    }

    /// The obvious problems in a draft: a missing reference-list header, and
    /// any listed source whose author/title never appears in the text. Returns
    /// an empty array when the draft looks internally consistent.
    static func check(_ essay: String, citations: [Citation], style: CitationStyle) -> [String] {
        var issues: [String] = []
        let lower = essay.lowercased()

        if !citations.isEmpty, !lower.contains(style.listHeader.lowercased()) {
            issues.append("No “\(style.listHeader)” section — append the reference list.")
        }

        for citation in citations {
            let last = citation.primaryLastName.lowercased()
            let title = Self.shortTitle(citation.title).lowercased()
            if (!last.isEmpty && lower.contains(last)) || (!title.isEmpty && lower.contains(title)) {
                continue
            }
            issues.append("“\(Self.shortTitle(citation.title))” is listed but never cited in the text.")
        }
        return issues
    }

    /// The text-only check (the `check_citations` tool path): parse the
    /// essay's own reference list and verify every entry is cited in the body.
    /// No structured `[Citation]` needed — the essay is the source of truth.
    static func checkReferenceList(_ essay: String, style: CitationStyle) -> [String] {
        let header = style.listHeader
        let lines = essay.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let headerIndex = lines.firstIndex(where: { $0.lowercased() == header.lowercased() }) else {
            return ["No “\(header)” section — append the reference list."]
        }

        let body = lines[..<headerIndex].joined(separator: " ").lowercased()
        let entries = lines[(headerIndex + 1)...].filter { !$0.isEmpty }
        guard !entries.isEmpty else {
            return ["The “\(header)” section is empty."]
        }

        var issues: [String] = []
        for entry in entries {
            let key = referenceKey(entry).lowercased()
            if !key.isEmpty && !body.contains(key) {
                issues.append("“\(Self.shortTitle(entry))” is listed but never cited in the text.")
            }
        }
        return issues
    }

    /// The search key for a reference-list entry: the leading surname (entries
    /// start with the author) or the first title word for author-less sources.
    private static func referenceKey(_ entry: String) -> String {
        guard let token = entry.split(whereSeparator: { $0 == "," || $0 == "." || $0.isWhitespace }).first else { return "" }
        return String(token)
    }

    // MARK: MLA

    private static func mlaEntry(_ c: Citation) -> String {
        switch c.kind {
        case .book:
            return joinNonEmpty([
                Self.mlaAuthors(c.authors),
                Self.italic(c.title),
                c.publisher,
                c.year,
            ])
        case .journal:
            var parts = [Self.mlaAuthors(c.authors), "“\(c.title).”", Self.italic(c.container)]
            if let volume = c.volume { parts.append("vol. \(volume)") }
            if let issue = c.issue { parts.append("no. \(issue)") }
            if let year = c.year { parts.append(year) }
            if let pages = c.pages { parts.append("pp. \(pages)") }
            if let url = c.url { parts.append(url) }
            return joinNonEmpty(parts)
        case .website:
            var parts: [String] = []
            if !c.authors.isEmpty { parts.append(Self.mlaAuthors(c.authors)) }
            parts.append("“\(c.title).”")
            if let container = c.container { parts.append(Self.italic(container)) }
            if let year = c.year { parts.append(year) }
            if let url = c.url { parts.append(url) }
            if let accessed = c.accessedAt { parts.append("Accessed \(accessed).") }
            return joinNonEmpty(parts)
        }
    }

    private static func mlaAuthors(_ authors: [String]) -> String {
        guard !authors.isEmpty else { return "" }
        if authors.count == 1 { return "\(authors[0])." }
        if authors.count == 2 {
            return "\(authors[0]), and \(Self.normalName(authors[1]))."
        }
        return "\(authors[0]), et al."
    }

    // MARK: APA

    private static func apaEntry(_ c: Citation) -> String {
        switch c.kind {
        case .book:
            return joinNonEmpty([
                Self.apaAuthors(c.authors, year: c.year),
                Self.italic(c.title) + ".",
                c.publisher,
            ])
        case .journal:
            var core = "\(Self.apaAuthors(c.authors, year: c.year)) \(c.title)."
            if let container = c.container { core += " \(Self.italic(container))" }
            var volIssue = ""
            if let volume = c.volume {
                volIssue = volume
                if let issue = c.issue { volIssue += "(\(issue))" }
            }
            if !volIssue.isEmpty { core += ", \(Self.italic(volIssue))" }
            if let pages = c.pages { core += ", \(pages)" }
            if let url = c.url { core += ". \(url)" }
            return core
        case .website:
            var parts: [String] = []
            if c.authors.isEmpty {
                parts.append("\(c.title).")
                if let container = c.container { parts.append(Self.italic(container) + ".") }
            } else {
                parts.append("\(Self.apaAuthors(c.authors, year: c.year)) \(c.title).")
                if let container = c.container { parts.append(Self.italic(container) + ".") }
            }
            if let url = c.url { parts.append(url) }
            if let accessed = c.accessedAt { parts.append("Accessed \(accessed).") }
            return joinNonEmpty(parts)
        }
    }

    private static func apaAuthors(_ authors: [String], year: String?) -> String {
        let yearText = year ?? "n.d."
        if authors.isEmpty { return "(\(yearText))." }
        let names = authors.map { Self.apaName($0) }.joined(separator: ", ")
        return "\(names) (\(yearText))."
    }

    /// "Last, First Middle" → "Last, F. M." (approximate initials).
    private static func apaName(_ author: String) -> String {
        let last = lastName(of: author)
        let rest = author.contains(",")
            ? author.split(separator: ",").dropFirst().joined(separator: " ")
            : author
        let initials = rest.split(whereSeparator: { $0.isWhitespace })
            .compactMap { $0.first.map { "\($0)." } }
            .joined(separator: " ")
        guard !last.isEmpty else { return rest.trimmingCharacters(in: .whitespaces) }
        return initials.isEmpty ? last : "\(last), \(initials)"
    }

    // MARK: Chicago (notes-bibliography, bibliography form)

    private static func chicagoEntry(_ c: Citation) -> String {
        switch c.kind {
        case .book:
            return joinNonEmpty([
                Self.chicagoAuthors(c.authors),
                Self.italic(c.title) + ".",
                c.publisher,
                c.year,
            ])
        case .journal:
            var core = "\(Self.chicagoAuthors(c.authors)) “\(c.title).”"
            if let container = c.container { core += " \(Self.italic(container))" }
            if let volume = c.volume { core += " \(volume)" }
            if let issue = c.issue { core += ", no. \(issue)" }
            if let year = c.year { core += " (\(year))" }
            if let pages = c.pages { core += ": \(pages)" }
            if let url = c.url { core += ". \(url)" }
            return core
        case .website:
            var parts: [String] = []
            if c.authors.isEmpty {
                parts.append("“\(c.title).”")
            } else {
                parts.append("\(Self.chicagoAuthors(c.authors)) “\(c.title).”")
            }
            if let container = c.container { parts.append(Self.italic(container) + ".") }
            if let year = c.year { parts.append(year + ".") }
            if let url = c.url { parts.append(url) }
            if let accessed = c.accessedAt { parts.append("Accessed \(accessed).") }
            return joinNonEmpty(parts)
        }
    }

    private static func chicagoAuthors(_ authors: [String]) -> String {
        guard !authors.isEmpty else { return "" }
        if authors.count == 1 { return "\(authors[0])." }
        if authors.count == 2 { return "\(authors[0]), and \(normalName(authors[1]))." }
        return "\(authors[0]), et al."
    }

    // MARK: Shared helpers

    /// "Last, First" (or a bare name) → "Last".
    static func lastName(of author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ",") else {
            // No comma: treat the final word as the surname.
            return trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? trimmed
        }
        return String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
    }

    /// "Last, First" → "First Last" (for the second MLA author position).
    static func normalName(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ",") else { return trimmed }
        let last = String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
        let first = String(trimmed[trimmed.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? last : "\(first) \(last)"
    }

    /// A short title for in-text citations and check messages.
    static func shortTitle(_ title: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        guard words.count > 4 else { return cleaned }
        return words.prefix(4).joined(separator: " ") + "…"
    }

    /// Markdown italics (the generated essays are plain text/Markdown).
    private static func italic(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return "*\(text)*"
    }

    /// Join the non-empty parts with the style's separator.
    private static func joinNonEmpty(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Today's date in "1 Mar 2026" form, for `accessedAt`.
    static func accessedToday() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: Date())
    }
}
