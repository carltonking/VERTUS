import Foundation

// MARK: - GitHubWriteCapability
//
// The confirm-gated front door for GitHub *writes* (create issue, comment, close issue). State-
// changing/outward actions, so they follow Carlton's "confirm before destructive acts" rule:
//
//   1. User: "create an issue in carltonking/ClubCal titled Login is broken"
//   2. Alfred parses it, stashes it as a pending action, and replies with a confirmation prompt.
//   3. User: "yes"  → Alfred runs it. Anything else → the pending action is dropped (default-deny).
//
// All parsing is deterministic and the request bypasses the LLM (like Messages/Spotify) so a slow
// local model can't mangle a repo name or invent a write. The actual HTTP lives in GitHubCapability.

struct GitHubWriteCapability {

    // What the user asked to do, with the repo already resolved to "owner/repo".
    enum Action {
        case createIssue(repo: String, title: String, body: String?)
        case comment(repo: String, number: Int, body: String)
        case closeIssue(repo: String, number: Int)

        /// The exact thing Alfred is about to do — shown to the user before it happens.
        var confirmationPrompt: String {
            switch self {
            case .createIssue(let repo, let title, let body):
                var p = "About to create a GitHub issue in \(repo):\n  “\(title)”"
                if let body, !body.isEmpty { p += "\n  \(body)" }
                return p + "\n\nReply \"yes\" to create it, or \"no\" to cancel."
            case .comment(let repo, let number, let body):
                return "About to comment on \(repo) #\(number):\n  “\(body)”\n\nReply \"yes\" to post it, or \"no\" to cancel."
            case .closeIssue(let repo, let number):
                return "About to close issue \(repo) #\(number).\n\nReply \"yes\" to close it, or \"no\" to cancel."
            }
        }
    }

    // A parsed-but-not-yet-resolved request (repo owner may still be missing).
    private enum Draft {
        case createIssue(repo: String?, title: String, body: String?)
        case comment(repo: String?, number: Int, body: String)
        case closeIssue(repo: String?, number: Int)
    }

    // MARK: - Confirmation words

    static func isAffirmative(_ lowered: String) -> Bool {
        let answer = lowered.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        // Exact short confirmations, including common natural multi-word ones.
        let yes: Set<String> = ["yes", "y", "yeah", "yep", "yup", "confirm", "confirmed", "do it",
                                "go ahead", "sure", "ok", "okay", "send it", "post it", "create it",
                                "please do", "go for it", "yes do it", "yes please", "yes please do",
                                "go ahead and do it", "yeah do it", "yep do it", "do it please"]
        if yes.contains(answer) { return true }
        // Natural sentences that LEAD with an unambiguous yes word ("yes please create it"). Match on
        // the first whole token so "yesterday's meeting" can't be read as a confirmation, and bail if
        // any negation word appears ("yes, actually no — cancel").
        let tokens = answer.split(separator: " ").map(String.init)
        let strongLead: Set<String> = ["yes", "yeah", "yep", "yup", "confirm", "confirmed"]
        if let first = tokens.first, strongLead.contains(first),
           !tokens.contains(where: { ["no", "not", "don't", "dont", "cancel", "stop", "nevermind", "never"].contains($0) }) {
            return true
        }
        return false
    }

    static func isNegative(_ lowered: String) -> Bool {
        let answer = lowered.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        let no: Set<String> = ["no", "nope", "cancel", "stop", "don't", "dont", "nevermind",
                               "never mind", "abort", "no thanks", "no thank you", "cancel it",
                               "no don't", "forget it"]
        if no.contains(answer) { return true }
        let tokens = answer.split(separator: " ").map(String.init)
        let strongLead: Set<String> = ["no", "nope", "cancel", "don't", "dont", "stop", "abort"]
        if let first = tokens.first, strongLead.contains(first) { return true }
        return false
    }

    // MARK: - Resolve + execute

    /// Turns a detected request into either a ready-to-run Action (with the confirmation prompt)
    /// or a plain message to show instead (no repo named, not connected, etc.).
    enum Prepared { case ready(Action), message(String) }

    static func prepare(_ query: String) async -> Prepared? {
        guard let draft = detect(query) else { return nil }

        guard GitHubCapability.hasToken else {
            return .message("GitHub isn't connected yet. Create a token at github.com/settings/tokens (with issue write access), then tell me: set github token <your-token>")
        }

        // Resolve the repo to "owner/repo", filling in the owner from the signed-in account.
        func resolveRepo(_ raw: String?) async -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            if raw.contains("/") { return raw }
            guard let login = await GitHubCapability().currentLogin() else { return nil }
            return "\(login)/\(raw)"
        }

        switch draft {
        case .createIssue(let repo, let title, let body):
            guard let full = await resolveRepo(repo) else { return .message(needRepoMessage) }
            return .ready(.createIssue(repo: full, title: title, body: body))
        case .comment(let repo, let number, let body):
            guard let full = await resolveRepo(repo) else { return .message(needRepoMessage) }
            return .ready(.comment(repo: full, number: number, body: body))
        case .closeIssue(let repo, let number):
            guard let full = await resolveRepo(repo) else { return .message(needRepoMessage) }
            return .ready(.closeIssue(repo: full, number: number))
        }
    }

    static func execute(_ action: Action) async -> String {
        let gh = GitHubCapability()
        switch action {
        case .createIssue(let repo, let title, let body): return await gh.createIssue(repo: repo, title: title, body: body)
        case .comment(let repo, let number, let body):    return await gh.comment(repo: repo, number: number, body: body)
        case .closeIssue(let repo, let number):           return await gh.closeIssue(repo: repo, number: number)
        }
    }

    private static let needRepoMessage =
        "Which repository? Tell me like: create an issue in owner/repo titled \"...\" — or just the repo name if it's yours (e.g. ClubCal)."

    // MARK: - Detection (deterministic parse)

    private static func detect(_ query: String) -> Draft? {
        let lowered = query.lowercased()
        let hasIssueWord = lowered.contains("issue")

        // ---- Close: "close issue #5 in owner/repo" ----
        if lowered.contains("close"), hasIssueWord, let number = issueNumber(in: lowered) {
            return .closeIssue(repo: extractRepo(query), number: number)
        }

        // ---- Comment: "comment on issue #5 in repo saying ..." ----
        if lowered.contains("comment"), let number = issueNumber(in: lowered) {
            let body = extractBody(query, markers: [" saying ", " that says ", " with ", " comment "])
                ?? firstQuoted(query)
            if let body, !body.isEmpty {
                return .comment(repo: extractRepo(query), number: number, body: body)
            }
            return nil   // no comment text → let the LLM ask, don't guess
        }

        // ---- Create issue: needs a create verb + "issue" + a title ----
        let createVerb = [" create ", " open ", " file ", " make ", " new ", " add ", " log "]
            .contains { lowered.contains($0) }
            || ["create ", "open ", "file ", "make ", "new ", "add ", "log "].contains { lowered.hasPrefix($0) }
        if createVerb, hasIssueWord, !lowered.contains("my issue"), !lowered.contains("my open") {
            let quoted = allQuoted(query)
            let title = quoted.first
                ?? extractBody(query, markers: [" titled ", " called ", " title ", " about ", " saying "])
            guard let title, !title.isEmpty else { return nil }   // no title → not a confident write
            let body = quoted.count > 1 ? quoted[1]
                : extractBody(query, markers: [" with body ", " description ", " body "])
            return .createIssue(repo: extractRepo(query), title: title, body: body)
        }

        return nil
    }

    // MARK: - Parse helpers

    /// "#5", "issue 5", "number 5" → 5.
    private static func issueNumber(in lowered: String) -> Int? {
        if let r = lowered.range(of: #"#(\d+)"#, options: .regularExpression) {
            return Int(lowered[r].dropFirst())
        }
        for marker in ["issue ", "number ", "#"] {
            if let r = lowered.range(of: marker) {
                let rest = lowered[r.upperBound...].prefix(while: { $0.isNumber || $0 == " " })
                    .trimmingCharacters(in: .whitespaces)
                if let n = Int(rest.split(separator: " ").first.map(String.init) ?? "") { return n }
            }
        }
        return nil
    }

    /// Repo named after " in "/" on "/" to "/" repo ", as "owner/repo" or bare "repo".
    private static func extractRepo(_ original: String) -> String? {
        let lowered = original.lowercased()
        let skip: Set<String> = ["issue", "issues", "the", "my", "a", "github", "repo", "it", "this", "that"]
        for marker in [" in ", " on ", " to ", " repo ", " repository "] {
            var searchStart = lowered.startIndex
            while let r = lowered.range(of: marker, range: searchStart..<lowered.endIndex) {
                // Take the next whitespace-delimited token, in the ORIGINAL casing.
                let after = original[original.index(original.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: r.upperBound))...]
                let token = after.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
                let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.,!?:;"))
                if isRepoShaped(clean), !skip.contains(clean.lowercased()) { return clean }
                searchStart = r.upperBound
            }
        }
        return nil
    }

    private static func isRepoShaped(_ s: String) -> Bool {
        guard !s.isEmpty, s.range(of: #"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil else { return false }
        return s.contains(where: { $0.isLetter })   // exclude bare "#5" / pure numbers
    }

    /// Text after the first matching marker, to end of string (trimmed of quotes/punctuation).
    private static func extractBody(_ original: String, markers: [String]) -> String? {
        let lowered = original.lowercased()
        for marker in markers {
            if let r = lowered.range(of: marker) {
                let startOffset = lowered.distance(from: lowered.startIndex, to: r.upperBound)
                let rest = String(original[original.index(original.startIndex, offsetBy: startOffset)...])
                let cleaned = stripRepoClause(rest).trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”.,!?"))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    /// Drops a trailing " in owner/repo" clause from a captured title/body so it doesn't leak in.
    private static func stripRepoClause(_ s: String) -> String {
        let lowered = s.lowercased()
        if let r = lowered.range(of: " in "), isRepoShaped(String(s[s.index(s.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: r.upperBound))...]).split(separator: " ").first.map(String.init) ?? "") {
            return String(s[..<s.index(s.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: r.lowerBound))])
        }
        return s
    }

    private static func firstQuoted(_ s: String) -> String? { allQuoted(s).first }

    /// All "double" / 'single' / “curly” quoted substrings, in order.
    private static func allQuoted(_ s: String) -> [String] {
        var out: [String] = []
        for pattern in [#""([^"]+)""#, #"“([^”]+)”"#, #"'([^']+)'"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                out.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }
}

// MARK: - GitHubWriteGate
//
// Holds the single pending write between the "do X" turn and the "yes" turn. An actor so it's safe
// regardless of how process() is scheduled.
actor GitHubWriteGate {
    static let shared = GitHubWriteGate()
    private var pending: GitHubWriteCapability.Action?

    var hasPending: Bool { pending != nil }
    func set(_ action: GitHubWriteCapability.Action) { pending = action }
    func take() -> GitHubWriteCapability.Action? { defer { pending = nil }; return pending }
    func clear() { pending = nil }
}
