import Foundation

// MARK: - NotionCapability
//
// Second "paste-a-key" integration, same shape as GitHubCapability. Talks directly to the Notion
// API with an internal-integration token stored in the Keychain — no third-party middleman.
// Read-only for now (search + read pages); write (create page) comes later behind a confirm gate.
//
// Token storage: Keychain service "com.alfred.app", account "notion".
// Set it in-app with:  set notion token ntn_xxx   (or secret_xxx)
//
// Notion's response JSON has dynamic, per-page property shapes, so this parses with
// JSONSerialization rather than Codable (cleaner for the freeform `properties` object).

struct NotionCapability {
    static let keychainAccount = "notion"
    private let apiBase = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    static var hasToken: Bool {
        guard let t = KeychainHelper.load(service: "com.alfred.app", account: keychainAccount) else { return false }
        return !t.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var token: String? {
        guard let t = KeychainHelper.load(service: "com.alfred.app", account: Self.keychainAccount),
              !t.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Entry point

    /// Searches the user's Notion workspace for pages matching their query. Never throws — returns
    /// a helpful note when the token is missing or a call fails, so the pipeline can't break.
    func summary(query: String) async -> String {
        guard let token else {
            return "Notion isn't connected yet. Create an internal integration at notion.so/my-integrations, copy its token, share the pages you want Alfred to see with that integration, then tell me: set notion token <your-token>"
        }

        // Strip the trigger word so "search notion for budget" searches "budget".
        let searchTerm = cleanedSearchTerm(from: query)
        do {
            return try await search(token: token, term: searchTerm)
        } catch let LLMError.networkError(msg) {
            return "Notion request failed: \(msg)"
        } catch {
            return "Notion request failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Endpoints

    private func search(token: String, term: String) async throws -> String {
        guard let url = URL(string: "\(apiBase)/search") else {
            throw LLMError.networkError("Bad Notion URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Empty query → Notion returns the most recently edited shared pages.
        var bodyDict: [String: Any] = ["page_size": 10]
        if !term.isEmpty { bodyDict["query"] = term }
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("No response from Notion")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw LLMError.networkError("token rejected (401). Re-run: set notion token <token>")
        case 403:
            throw LLMError.networkError("no access (403) — share the pages with your integration in Notion")
        default:
            throw LLMError.networkError("HTTP \(http.statusCode)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else { throw LLMError.networkError("Unexpected Notion response") }

        guard !results.isEmpty else {
            return term.isEmpty
                ? "No Notion pages are shared with the integration yet. In Notion, open a page → ••• → Connections → add your integration."
                : "No Notion pages found for \"\(term)\"."
        }

        let lines = results.prefix(10).compactMap { formatResult($0) }
        let header = term.isEmpty ? "Recent Notion pages:" : "Notion pages matching \"\(term)\":"
        return header + "\n" + lines.joined(separator: "\n")
    }

    // MARK: - Parsing helpers

    /// Turns one search result into "• Title — url". Notion stores the title under whichever
    /// property has type "title", so scan the properties for it; fall back to the URL.
    private func formatResult(_ result: [String: Any]) -> String? {
        let url = result["url"] as? String ?? ""
        let title = extractTitle(from: result) ?? "(untitled)"
        if url.isEmpty { return "• \(title)" }
        return "• \(title) — \(url)"
    }

    private func extractTitle(from result: [String: Any]) -> String? {
        // Page: title lives in properties.<name> where the property's type == "title".
        if let props = result["properties"] as? [String: Any] {
            for (_, value) in props {
                guard let prop = value as? [String: Any],
                      prop["type"] as? String == "title",
                      let titleArr = prop["title"] as? [[String: Any]]
                else { continue }
                let text = titleArr.compactMap { $0["plain_text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
        }
        // Database object: title is a top-level array of rich-text.
        if let titleArr = result["title"] as? [[String: Any]] {
            let text = titleArr.compactMap { $0["plain_text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Removes trigger words so the remaining text is a usable search term.
    private func cleanedSearchTerm(from query: String) -> String {
        var t = query.lowercased()
        for noise in ["search notion for", "search notion", "in notion", "on notion",
                      "from notion", "my notion", "notion", "find", "search", "look up", "show me"] {
            t = t.replacingOccurrences(of: noise, with: " ")
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
    }
}
