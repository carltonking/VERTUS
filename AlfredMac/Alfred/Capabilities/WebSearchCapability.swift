import Foundation

struct WebSearchCapability {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        // Ceiling only — each request passes its OWN timeout (see `search(query:timeout:)`): short
        // for interactive queries (bounds time-to-first-token), longer for background routines,
        // which can afford to wait for a slow search instead of failing with no live data.
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config)
    }

    // MARK: - Search

    /// Priority: Tavily (free, no credit card) → Brave (needs a paid/carded key) → keyless
    /// DuckDuckGo (free, best-effort). `timeout` is per request — pass a longer value for routines.
    func search(query: String, timeout: TimeInterval = 8) async throws -> String {
        if let tavilyKey = KeychainHelper.load(service: "com.alfred.app", account: "tavily"),
           !tavilyKey.isEmpty {
            if let result = try? await tavilySearch(query: query, apiKey: tavilyKey, timeout: timeout) {
                return result
            }
        }
        if let braveKey = KeychainHelper.load(service: "com.alfred.app", account: "brave"),
           !braveKey.isEmpty {
            if let result = try? await braveSearch(query: query, apiKey: braveKey, timeout: timeout) {
                return result
            }
        }
        // Keyless & reliable: Google News RSS (recent, sourced articles — great for a briefing),
        // then DuckDuckGo as a general fallback.
        if let news = try? await googleNewsSearch(query: query, timeout: timeout),
           !news.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return news
        }
        return try await duckDuckGoSearch(query: query, timeout: timeout)
    }

    // MARK: - Google News RSS (keyless, free, reliable — not scraper-blocked like DDG)

    private func googleNewsSearch(query: String, timeout: TimeInterval) async throws -> String {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: "en-US"),
            URLQueryItem(name: "gl", value: "US"),
            URLQueryItem(name: "ceid", value: "US:en"),
        ]
        guard let url = components.url else { throw LLMError.networkError("Bad news URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.networkError("Google News HTTP \(http.statusCode)")
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let items = parseRSSItems(xml).prefix(6)
        if items.isEmpty { throw LLMError.networkError("No news results") }
        return items.enumerated().map { i, it in
            var line = "[\(i + 1)] \(it.title)"
            if !it.source.isEmpty { line += " — \(it.source)" }
            if !it.date.isEmpty { line += " (\(it.date))" }
            if !it.link.isEmpty { line += "\n\(it.link)" }
            return line
        }.joined(separator: "\n\n")
    }

    private struct RSSItem { let title: String; let link: String; let source: String; let date: String }

    private func parseRSSItems(_ xml: String) -> [RSSItem] {
        var items: [RSSItem] = []
        var rest = Substring(xml)
        while let start = rest.range(of: "<item>"),
              let end = rest.range(of: "</item>", range: start.upperBound..<rest.endIndex) {
            let block = String(rest[start.upperBound..<end.lowerBound])
            rest = rest[end.upperBound...]
            let title = decodeXML(extractTag("title", block))
            let link = extractTag("link", block)
            let date = String(extractTag("pubDate", block).prefix(16))
            var source = ""
            if let s = block.range(of: "<source"),
               let gt = block.range(of: ">", range: s.upperBound..<block.endIndex),
               let e = block.range(of: "</source>", range: gt.upperBound..<block.endIndex) {
                source = decodeXML(String(block[gt.upperBound..<e.lowerBound]))
            }
            if !title.isEmpty { items.append(RSSItem(title: title, link: link, source: source, date: date)) }
        }
        return items
    }

    private func extractTag(_ tag: String, _ block: String) -> String {
        guard let open = block.range(of: "<\(tag)>") ?? block.range(of: "<\(tag) "),
              let gt = block.range(of: ">", range: open.lowerBound..<block.endIndex),
              let close = block.range(of: "</\(tag)>", range: gt.upperBound..<block.endIndex)
        else { return "" }
        return String(block[gt.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    // MARK: - Tavily Search (free tier, no credit card)

    private func tavilySearch(query: String, apiKey: String, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["api_key": apiKey, "query": query, "max_results": 5, "search_depth": "basic"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.networkError("Tavily API error")
        }
        struct TavilyResponse: Decodable {
            struct Result: Decodable { let title: String?; let url: String?; let content: String? }
            let results: [Result]?
        }
        let decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
        let results = decoded.results?.prefix(4) ?? []
        if results.isEmpty { throw LLMError.networkError("No results") }
        return results.enumerated().map { i, r in
            "[\(i + 1)] \(r.title ?? "")\n\(r.content ?? "")\n\(r.url ?? "")"
        }.joined(separator: "\n\n")
    }

    // MARK: - Page fetch

    func fetchPage(url: String) async throws -> String {
        guard let pageURL = URL(string: url) else {
            throw LLMError.networkError("Invalid URL: \(url)")
        }
        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return stripHTML(html).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Brave Search

    private func braveSearch(query: String, apiKey: String, timeout: TimeInterval) async throws -> String {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "5"),
        ]
        guard let url = components.url else { throw LLMError.networkError("Bad Brave URL") }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.networkError("Brave API error")
        }

        struct BraveResponse: Decodable {
            struct Web: Decodable {
                struct Result: Decodable {
                    let title: String
                    let description: String?
                    let url: String
                }
                let results: [Result]
            }
            let web: Web?
        }

        let decoded = try JSONDecoder().decode(BraveResponse.self, from: data)
        let results = decoded.web?.results.prefix(3) ?? []
        if results.isEmpty { throw LLMError.networkError("No results") }

        return results.enumerated().map { i, r in
            "[\(i + 1)] \(r.title)\n\(r.description ?? "")\n\(r.url)"
        }.joined(separator: "\n\n")
    }

    // MARK: - DuckDuckGo fallback

    private func duckDuckGoSearch(query: String, timeout: TimeInterval) async throws -> String {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw LLMError.networkError("Bad DDG URL") }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.networkError("DuckDuckGo HTTP \(http.statusCode)")
        }
        let html = String(data: data, encoding: .utf8) ?? ""

        // Only DDG's real result markers count as a hit. If they're absent, DDG served a
        // challenge / rate-limit / anomaly page — THROW so the caller treats it as a failed search
        // (webSearchFailed → "answer from general knowledge") instead of feeding the raw error page
        // to the model as if it were results. Dumping that page was the "DuckDuckGo 50x / JSON
        // dump" garbage. A clean failure beats confident nonsense.
        let snippets = extractDDGSnippets(from: html)
        guard !snippets.isEmpty else {
            throw LLMError.networkError("DuckDuckGo returned no parseable results (likely rate-limited or blocked)")
        }
        return snippets.prefix(3).joined(separator: "\n\n")
    }

    private func extractDDGSnippets(from html: String) -> [String] {
        var results: [String] = []
        var remaining = html

        while let titleStart = remaining.range(of: "class=\"result__a\"") {
            remaining = String(remaining[titleStart.upperBound...])
            guard let tagEnd = remaining.range(of: ">"),
                  let titleEnd = remaining.range(of: "</a>",
                                                  range: tagEnd.upperBound..<remaining.endIndex)
            else { break }
            // The anchor's href (a DDG redirect) sits between result__a and the closing '>'.
            let url = Self.extractHref(String(remaining[remaining.startIndex..<tagEnd.lowerBound]))
            let title = stripHTML(String(remaining[tagEnd.upperBound..<titleEnd.lowerBound]))

            guard let snippetStart = remaining.range(of: "result__snippet"),
                  let snippetTagEnd = remaining.range(of: ">",
                                                       range: snippetStart.upperBound..<remaining.endIndex),
                  let snippetEnd = remaining.range(of: "</",
                                                    range: snippetTagEnd.upperBound..<remaining.endIndex)
            else {
                remaining = String(remaining[titleEnd.upperBound...])
                continue
            }
            let snippet = stripHTML(String(remaining[snippetTagEnd.upperBound..<snippetEnd.lowerBound]))

            if !title.isEmpty || !snippet.isEmpty {
                var entry = "\(title)\n\(snippet)".trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty { entry += "\n\(url)" }
                results.append(entry)
            }
            remaining = String(remaining[snippetEnd.upperBound...])
        }
        return results
    }

    /// Pulls the real URL out of a DuckDuckGo anchor tag (decodes the `uddg=` redirect param).
    private static func extractHref(_ tagAttrs: String) -> String {
        guard let r = tagAttrs.range(of: "href=\"") else { return "" }
        let after = tagAttrs[r.upperBound...]
        guard let end = after.range(of: "\"") else { return "" }
        var href = String(after[after.startIndex..<end.lowerBound])
        if let uddg = href.range(of: "uddg=") {
            let encoded = String(href[uddg.upperBound...]).components(separatedBy: "&").first ?? ""
            if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { href = decoded }
        }
        if href.hasPrefix("//") { href = "https:" + href }
        return href
    }

    // MARK: - HTML stripping

    private func stripHTML(_ html: String) -> String {
        // Remove <script>, <style>, <nav>, <header>, <footer> blocks entirely
        var text = html
        for tag in ["script", "style", "nav", "header", "footer", "noscript"] {
            while let open = text.range(of: "<\(tag)", options: .caseInsensitive),
                  let close = text.range(of: "</\(tag)>", options: .caseInsensitive,
                                          range: open.lowerBound..<text.endIndex)
            {
                text.removeSubrange(open.lowerBound...close.upperBound)
            }
        }
        // Strip remaining tags
        var result = ""
        result.reserveCapacity(text.count)
        var inTag = false
        for char in text {
            if char == "<" { inTag = true; continue }
            if char == ">" { inTag = false; continue }
            if !inTag { result.append(char) }
        }
        // Collapse whitespace
        return result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
