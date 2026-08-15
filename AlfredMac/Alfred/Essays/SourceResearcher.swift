// MARK: - SourceResearcher
//
// Finds sources for an essay using the Crawlee web-search bridge (the same
// DDG/Bing search the career scanner uses — no API key, no blocked host).
// Returns title/url/snippet hits; the *summaries and key quotes* are added by
// the essay skill's own Hermes turn, so this file stays deterministic and
// model-free.
//
// `parseSearchHits` is static and pure so the result-shape mapping is
// unit-tested without spawning node.

import Foundation

// MARK: - Depth

enum ResearchDepth: String, Codable, CaseIterable, Sendable {
    case light
    case medium
    case deep

    var displayName: String {
        switch self {
        case .light: return "Light (5–10 sources)"
        case .medium: return "Medium (15–20 sources)"
        case .deep: return "Deep (30+ sources)"
        }
    }

    /// How many search hits the researcher keeps.
    var sourceCount: Int {
        switch self {
        case .light: return 6
        case .medium: return 16
        case .deep: return 30
        }
    }
}

// MARK: - Source

struct EssaySource: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var url: String
    var snippet: String
    /// The model-written one-line summary (empty until the skill enriches).
    var summary: String
    /// The model-extracted quotable lines (empty until enriched).
    var keyQuotes: [String]

    init(id: String = UUID().uuidString,
         title: String,
         url: String,
         snippet: String = "",
         summary: String = "",
         keyQuotes: [String] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.summary = summary
        self.keyQuotes = keyQuotes
    }

    /// A citation for this source — web search rarely surfaces an author, so
    /// the entry is title-led in every style.
    var citation: Citation {
        Citation(
            id: id,
            kind: .website,
            authors: [],
            title: title,
            container: nil,
            year: nil,
            url: url,
            accessedAt: CitationManager.accessedToday())
    }
}

// MARK: - Researcher

final class SourceResearcher {

    static let shared = SourceResearcher()

    /// Find sources for a topic. Never throws; a dead bridge yields an empty
    /// array (the essay skill then writes without cited research).
    func searchSources(topic: String, depth: ResearchDepth = .light) async -> [EssaySource] {
        let query = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let result = await CrawleeClient.shared.search(query: query)
        guard result.succeeded,
              let hits = result.payload?["results"] as? [[String: Any]] else {
            NSLog("[essay] source search failed — %@", result.message)
            return []
        }
        return Self.parseSearchHits(hits, limit: depth.sourceCount)
    }

    /// Map Crawlee search hits to sources. Pure and static for tests. The
    /// search payload shape is the same the career scanner reads:
    /// `{results: [{title, url, snippet}]}`.
    static func parseSearchHits(_ hits: [[String: Any]], limit: Int) -> [EssaySource] {
        hits.prefix(max(0, limit)).compactMap { hit in
            guard let url = hit["url"] as? String, !url.isEmpty,
                  let title = hit["title"] as? String, !title.isEmpty else { return nil }
            return EssaySource(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url,
                snippet: (hit["snippet"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
