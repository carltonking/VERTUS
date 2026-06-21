import Foundation

// MARK: - SpotlightCapability
//
// Local, zero-auth file search via Spotlight's `mdfind` — "find my file about X", "where's my
// resume", "find the pdf about taxes". Read-only (returns paths, opens nothing). Routed before the
// LLM so results are real file paths, never invented. Searches filename + content, home dir only.

enum SpotlightCapability {

    static func handle(_ query: String) -> String? {
        guard let term = detectTerm(in: query) else { return nil }
        return search(term: term)
    }

    /// Pulls the search term from "find my file about X", "where is my X", "locate the X document".
    private static func detectTerm(in query: String) -> String? {
        let lowered = query.lowercased()
        let fileWords = ["file", "document", "doc", "pdf", "spreadsheet", "presentation",
                         "folder", "screenshot", "download"]
        let findVerbs = ["find ", "search for ", "locate ", "where is ", "where's ", "where are ",
                         "look for ", "pull up "]
        // Must look like a file search: a find verb AND a file word. Match the file word as a whole
        // token (not a substring) so "doc" doesn't fire on "documentation"/"doctor", nor "download"
        // on "downloaded".
        let hasVerb = findVerbs.contains { lowered.hasPrefix($0) || lowered.contains(" \($0)") }
        let queryTokens = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let hasFileWord = fileWords.contains { queryTokens.contains($0) }
        guard hasVerb, hasFileWord else { return nil }

        var term = query
        // Strip a leading find verb.
        for v in findVerbs where term.lowercased().hasPrefix(v) { term = String(term.dropFirst(v.count)); break }
        // Strip noise words and the file-type words; keep the meaningful remainder.
        let drop: Set<String> = Set(["my", "the", "a", "about", "called", "named", "titled", "for",
                                     "on", "with", "regarding", "re"] + fileWords)
        let words = term.split(separator: " ").map(String.init)
            .filter { !drop.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?.!,"))) }
        let cleaned = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func search(term: String, limit: Int = 8) -> String {
        let home = NSHomeDirectory()
        // Escape backslash first, then the double-quote, so a term containing `"` can't break out of
        // the quoted literal and inject extra mdfind predicates (query-grammar injection).
        let safe = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Match filename OR content, case-insensitive (mdfind's default for these operators).
        let queryStr = "kMDItemDisplayName == \"*\(safe)*\"cd || kMDItemTextContent == \"*\(safe)*\"cd"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["-onlyin", home, queryStr]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do { try proc.run() } catch { return "Couldn't run the file search." }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let paths = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") }   // skip caches/app-support noise
            .prefix(limit)

        guard !paths.isEmpty else { return "No files found matching \"\(term)\"." }
        let lines = paths.map { path -> String in
            let name = (path as NSString).lastPathComponent
            let dir = (path as NSString).deletingLastPathComponent
                .replacingOccurrences(of: home, with: "~")
            return "• \(name)  —  \(dir)"
        }
        return "Files matching \"\(term)\":\n" + lines.joined(separator: "\n")
    }
}
