import Foundation

// MARK: - GitHubCapability
//
// First "paste-a-key" integration and the template for the others (Notion, Linear, Slack, Jira).
// Talks directly to the GitHub REST API with a personal access token the user stores in the
// macOS Keychain — no third-party integration service. Read-only.
//
// Token storage: Keychain service "com.alfred.app", account "github".
// Set it in-app with:  set github token ghp_xxx   (handled in QuickCommands).
//
// Pattern to copy for a new paste-key app:
//   1. Change `keychainAccount` and the API base URL.
//   2. Swap the request headers for that app's auth scheme.
//   3. Rewrite `summary(query:)` to hit that app's endpoints and format the result.

struct GitHubCapability {
    static let keychainAccount = "github"
    private let apiBase = "https://api.github.com"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    /// True when a token is stored — used to decide whether to attempt a call at all.
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

    /// Routes a natural-language GitHub request to the right endpoint and returns clean text
    /// the model can fold into its answer. Never throws on "no token" — returns a helpful note.
    func summary(query: String) async -> String {
        guard let token else {
            return "GitHub isn't connected yet. Create a personal access token at github.com/settings/tokens, then tell me: set github token <your-token>"
        }

        let q = query.lowercased()
        do {
            if q.contains("issue") {
                return try await searchIssues(token: token, isPR: false)
            }
            // Word-ish match so "profile" doesn't get mistaken for a PR request.
            if q.contains("pull request") || q.contains(" pr") || q.contains("prs") {
                return try await searchIssues(token: token, isPR: true)
            }
            if q.contains("notification") {
                return try await notifications(token: token)
            }
            // Default: who am I + recently updated repos.
            return try await profileAndRepos(token: token)
        } catch let LLMError.networkError(msg) {
            return "GitHub request failed: \(msg)"
        } catch {
            return "GitHub request failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Endpoints

    /// Open PRs you authored, or open issues assigned to you, via the search API.
    private func searchIssues(token: String, isPR: Bool) async throws -> String {
        let qParam = isPR ? "is:open is:pr author:@me" : "is:open is:issue assignee:@me"
        var components = URLComponents(string: "\(apiBase)/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: qParam),
            URLQueryItem(name: "per_page", value: "10"),
            URLQueryItem(name: "sort", value: "updated"),
        ]
        guard let url = components.url else { throw LLMError.networkError("Bad GitHub URL") }

        struct SearchResponse: Decodable {
            struct Item: Decodable {
                let title: String
                let html_url: String
                let repository_url: String
            }
            let total_count: Int
            let items: [Item]
        }

        let decoded: SearchResponse = try await get(url, token: token)
        let label = isPR ? "open pull requests you authored" : "open issues assigned to you"
        guard !decoded.items.isEmpty else { return "No \(label)." }

        let lines = decoded.items.map { item -> String in
            let repo = item.repository_url.components(separatedBy: "/repos/").last ?? ""
            return "• \(item.title) — \(repo)\n  \(item.html_url)"
        }
        return "\(decoded.total_count) \(label):\n" + lines.joined(separator: "\n")
    }

    /// Unread notifications.
    private func notifications(token: String) async throws -> String {
        guard let url = URL(string: "\(apiBase)/notifications") else {
            throw LLMError.networkError("Bad GitHub URL")
        }
        struct Note: Decodable {
            struct Subject: Decodable { let title: String; let type: String }
            struct Repo: Decodable { let full_name: String }
            let subject: Subject
            let repository: Repo
        }
        let notes: [Note] = try await get(url, token: token)
        guard !notes.isEmpty else { return "No unread GitHub notifications." }
        let lines = notes.prefix(15).map { "• [\($0.subject.type)] \($0.subject.title) — \($0.repository.full_name)" }
        return "\(notes.count) unread notifications:\n" + lines.joined(separator: "\n")
    }

    /// Authenticated user + most recently updated repos.
    private func profileAndRepos(token: String) async throws -> String {
        guard let userURL = URL(string: "\(apiBase)/user") else {
            throw LLMError.networkError("Bad GitHub URL")
        }
        struct User: Decodable { let login: String; let name: String? }
        let user: User = try await get(userURL, token: token)

        var components = URLComponents(string: "\(apiBase)/user/repos")!
        components.queryItems = [
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: "5"),
        ]
        struct Repo: Decodable { let full_name: String; let description: String? }
        var repos: [Repo] = []
        if let reposURL = components.url {
            repos = (try? await get(reposURL, token: token)) ?? []
        }

        var out = "Signed in as \(user.name ?? user.login) (@\(user.login))."
        if !repos.isEmpty {
            out += "\nRecently updated repos:\n" + repos.map { "• \($0.full_name)" + ($0.description.map { d in " — \(d)" } ?? "") }.joined(separator: "\n")
        }
        return out
    }

    // MARK: - Writes (confirm-gated upstream by GitHubWriteCapability)
    //
    // These are the only state-changing GitHub calls. They're never reached without the user first
    // seeing a confirmation prompt and replying "yes" (see GitHubWriteCapability). Each returns a
    // short user-facing string and never throws.

    /// The authenticated user's login — used to fill in the owner when the user names only a repo
    /// ("ClubCal" → "carltonking/ClubCal"). Returns nil if there's no token or the call fails.
    func currentLogin() async -> String? {
        guard let token, let url = URL(string: "\(apiBase)/user") else { return nil }
        struct U: Decodable { let login: String }
        let u: U? = try? await get(url, token: token)
        return u?.login
    }

    func createIssue(repo: String, title: String, body: String?) async -> String {
        guard let token else { return notConnectedMessage }
        do {
            guard let url = URL(string: "\(apiBase)/repos/\(repo)/issues") else {
                return "That doesn't look like a valid repo: \(repo)"
            }
            let resp = try await send(url, method: "POST",
                                      json: ["title": title, "body": body ?? ""], token: token)
            let num = resp.number.map { "#\($0)" } ?? ""
            return "Created issue \(num) in \(repo): \(title)" + (resp.html_url.map { "\n\($0)" } ?? "")
        } catch { return writeError(error) }
    }

    func comment(repo: String, number: Int, body: String) async -> String {
        guard let token else { return notConnectedMessage }
        do {
            guard let url = URL(string: "\(apiBase)/repos/\(repo)/issues/\(number)/comments") else {
                return "That doesn't look like a valid repo: \(repo)"
            }
            let resp = try await send(url, method: "POST", json: ["body": body], token: token)
            return "Commented on \(repo) #\(number)." + (resp.html_url.map { "\n\($0)" } ?? "")
        } catch { return writeError(error) }
    }

    func closeIssue(repo: String, number: Int) async -> String {
        guard let token else { return notConnectedMessage }
        do {
            guard let url = URL(string: "\(apiBase)/repos/\(repo)/issues/\(number)") else {
                return "That doesn't look like a valid repo: \(repo)"
            }
            _ = try await send(url, method: "PATCH", json: ["state": "closed"], token: token)
            return "Closed \(repo) #\(number)."
        } catch { return writeError(error) }
    }

    private var notConnectedMessage: String {
        "GitHub isn't connected yet. Create a personal access token at github.com/settings/tokens (with issue write access), then tell me: set github token <your-token>"
    }

    private func writeError(_ error: Error) -> String {
        if case let LLMError.networkError(msg) = error { return "GitHub write failed: \(msg)" }
        return "GitHub write failed: \(error.localizedDescription)"
    }

    private struct WriteResp: Decodable { let number: Int?; let html_url: String? }

    /// Shared authenticated POST/PATCH with a JSON body. Decodes the small bits we surface
    /// (issue number, url). Maps GitHub's error codes to plain-language messages.
    private func send(_ url: URL, method: String, json: [String: Any], token: String) async throws -> WriteResp {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Alfred", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("No response from GitHub")
        }
        switch http.statusCode {
        case 200...299:
            return (try? JSONDecoder().decode(WriteResp.self, from: data)) ?? WriteResp(number: nil, html_url: nil)
        case 401:
            throw LLMError.networkError("token rejected (401). Re-run: set github token <token>")
        case 403:
            throw LLMError.networkError("forbidden (403) — your token may lack issue-write access")
        case 404:
            throw LLMError.networkError("repo or issue not found (404) — check owner/repo and the number")
        case 410:
            throw LLMError.networkError("issues are disabled on that repo (410)")
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw LLMError.networkError("HTTP \(http.statusCode)" + (msg.map { ": \($0)" } ?? ""))
        }
    }

    // MARK: - HTTP

    /// Shared authenticated GET + JSON decode with GitHub's required headers.
    private func get<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Alfred", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("No response from GitHub")
        }
        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(T.self, from: data)
        case 401:
            throw LLMError.networkError("token rejected (401). Re-run: set github token <token>")
        case 403:
            throw LLMError.networkError("forbidden or rate-limited (403)")
        default:
            throw LLMError.networkError("HTTP \(http.statusCode)")
        }
    }
}
