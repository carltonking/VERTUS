import Foundation

struct WebSearchCapability {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    // MARK: - Search

    func search(query: String) async throws -> String {
        if let braveKey = KeychainHelper.load(service: "com.alfred.app", account: "brave"),
           !braveKey.isEmpty {
            if let result = try? await braveSearch(query: query, apiKey: braveKey) {
                return result
            }
        }
        return try await duckDuckGoSearch(query: query)
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

    private func braveSearch(query: String, apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "5"),
        ]
        guard let url = components.url else { throw LLMError.networkError("Bad Brave URL") }

        var request = URLRequest(url: url)
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

    private func duckDuckGoSearch(query: String) async throws -> String {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw LLMError.networkError("Bad DDG URL") }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        // Extract result snippets between result__snippet spans
        let snippets = extractDDGSnippets(from: html)
        if snippets.isEmpty {
            return stripHTML(html).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 40 }
                .prefix(5)
                .joined(separator: "\n")
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
