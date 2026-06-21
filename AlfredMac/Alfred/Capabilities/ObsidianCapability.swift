import Foundation

// MARK: - ObsidianCapability
//
// Local-first "no-key" connector. Reads the user's Obsidian vault(s) directly off disk —
// NO API, NO token, NO network. Pure Foundation FileManager reads. Mirrors the paste-key
// connector shape (GitHubCapability/NotionCapability) minus all Keychain/URLSession members.
//
// Vault discovery: ~/Library/Application Support/obsidian/obsidian.json (authoritative registry).
// Read-only. summary(query:includeBodies:) never throws — returns a helpful note on any failure.
//
// PRIVACY (must-fix B1): the global Redactor only scrubs credential SHAPES (passwords, SSNs, …),
// NOT free-form note content. An Obsidian vault is the most sensitive local data in the app, so
// when a CLOUD model is active we withhold note bodies entirely and return titles + paths only.
// Full snippets are only included when a LOCAL model (Ollama) is active. The caller passes
// `includeBodies = !router.isActiveProviderCloud`.
//
// SECURITY (must-fix B2): the vault sits in iCloud Drive (user-writable, sync-shared), so a stray
// symlink could point outside it. We skip symlinks AND containment-check every file's resolved
// path against the resolved vault root before reading — the capability can never read ~/.ssh etc.
//
// RELIABILITY (must-fix M3): the vault is in iCloud; an evicted/dataless file's stat or read can
// block. We only read bodies of files whose download status is `.current`, and run the whole scan
// under a hard timeout off the critical path so a single blocking call can't wedge the pipeline.

struct ObsidianCapability {

    private struct Vault { let name: String; let url: URL; let isOpen: Bool }
    private struct Hit {
        let title: String
        let relativePath: String
        let snippet: String?
        let titleMatch: Bool
        let bodyMatch: Bool
        let modDate: Date
    }

    // Bounds — global across all selected vaults (must-fix m8).
    private let maxFilesScanned = 5_000
    private let maxFilesContentRead = 1_500
    private let maxFileSizeBytes = 1_048_576   // 1 MB, mirrors SelectedFileReader
    private let snippetLength = 240
    private let maxResults = 8
    private let maxTotalOutputChars = 4_000
    private let timeBudget: TimeInterval = 2.0

    // MARK: - Entry point

    /// Searches the local Obsidian vault(s). Never throws.
    /// - Parameter includeBodies: false when a cloud model is active → titles + paths only (privacy).
    func summary(query: String, includeBodies: Bool) async -> String {
        let vaults = selectVaults(resolveVaults(), query: query)
        guard !vaults.isEmpty else {
            return "No Obsidian vault found. Open Obsidian once so it registers a vault, then ask again."
        }

        let term = cleanedSearchTerm(from: query)
        let result = await searchWithTimeout(vaults: vaults, term: term, includeBodies: includeBodies)
        guard !result.hits.isEmpty else {
            // Vault exists in the registry but we couldn't enumerate a single file → almost always a
            // macOS permission denial (the vault lives in iCloud Drive). Point the user at the fix.
            if result.scanned == 0 {
                return "I found your Obsidian vault but macOS won't let me read its notes — the vault is in iCloud Drive. Grant Alfred access: System Settings → Privacy & Security → Full Disk Access → turn on Alfred, then ask again."
            }
            return term.isEmpty
                ? "No notes found in your Obsidian vault."
                : "No Obsidian notes found for \"\(term)\"."
        }
        return formatResults(result.hits, term: term, includeBodies: includeBodies)
    }

    // MARK: - Vault discovery (registry-authoritative)

    private func resolveVaults() -> [Vault] {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: registry),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]]
        else { return [] }

        let fm = FileManager.default
        var out: [Vault] = []
        for (_, entry) in vaults {
            guard let path = entry["path"] as? String else { continue }
            let isOpen = entry["open"] as? Bool ?? false
            // Drop stale registry entries that no longer exist or aren't real vaults.
            guard fm.fileExists(atPath: path), fm.fileExists(atPath: path + "/.obsidian") else { continue }
            out.append(Vault(name: URL(fileURLWithPath: path).lastPathComponent,
                             url: URL(fileURLWithPath: path),
                             isOpen: isOpen))
        }
        return out
    }

    /// Name in query → that vault; else the open vault(s); else all registered.
    private func selectVaults(_ vaults: [Vault], query: String) -> [Vault] {
        let q = query.lowercased()
        if let named = vaults.first(where: { q.contains($0.name.lowercased()) }) { return [named] }
        let open = vaults.filter { $0.isOpen }
        return open.isEmpty ? vaults : open
    }

    // MARK: - Search term extraction (word-boundary, must-fix M4)

    /// Strips command-phrase noise as whole words/phrases so a term like "findings" isn't gutted
    /// by the noise word "find". Uses `\b` anchors rather than blind substring replacement.
    private func cleanedSearchTerm(from query: String) -> String {
        var t = query.lowercased()
        let noise = ["search obsidian for", "search my obsidian", "search obsidian",
                     "in my obsidian vault", "my obsidian vault", "obsidian vault",
                     "in obsidian", "on obsidian", "from obsidian", "my obsidian", "obsidian",
                     "in my notes", "my notes", "my vault", "notes about", "note about",
                     "look up", "show me", "find", "search"]
        for phrase in noise {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
    }

    // MARK: - Search (timed, off critical path)

    private struct SearchResult { let hits: [Hit]; let scanned: Int }

    private func searchWithTimeout(vaults: [Vault], term: String, includeBodies: Bool) async -> SearchResult {
        await withTaskGroup(of: SearchResult?.self) { group -> SearchResult in
            group.addTask { self.searchSync(vaults: vaults, term: term, includeBodies: includeBodies) }
            group.addTask {
                // Hard ceiling slightly above searchSync's own self-limit, so a blocking iCloud
                // stat can't wedge the assistant pipeline.
                try? await Task.sleep(nanoseconds: UInt64((self.timeBudget + 1.0) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? SearchResult(hits: [], scanned: 0)
        }
    }

    private func searchSync(vaults: [Vault], term: String, includeBodies: Bool) -> SearchResult {
        let fm = FileManager.default
        let start = Date()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
            .contentModificationDateKey, .fileSizeKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        let tokens = term.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        var hits: [Hit] = []
        var scanned = 0
        var bodyReads = 0

        outer: for vault in vaults {
            let vaultRootResolved = vault.url.resolvingSymlinksInPath().path
            guard let en = fm.enumerator(
                at: vault.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }   // skip unreadable, keep going
            ) else { continue }

            for case let url as URL in en {
                if scanned >= maxFilesScanned { break outer }
                if Date().timeIntervalSince(start) > timeBudget { break outer }

                let name = url.lastPathComponent
                if [".obsidian", ".trash", ".git", "node_modules"].contains(name) {
                    en.skipDescendants(); continue
                }

                guard let rv = try? url.resourceValues(forKeys: keys) else { continue }

                // must-fix B2: never follow symlinks (escape vector out of the vault).
                if rv.isSymbolicLink == true { en.skipDescendants(); continue }
                guard rv.isRegularFile == true, isMarkdown(url) else { continue }

                // must-fix B2: containment — the resolved file must live under the resolved vault root.
                guard url.resolvingSymlinksInPath().path.hasPrefix(vaultRootResolved + "/") else { continue }

                scanned += 1
                let modDate = rv.contentModificationDate ?? .distantPast
                let size = rv.fileSize ?? 0
                let title = url.deletingPathExtension().lastPathComponent
                let titleMatch = !tokens.isEmpty && tokens.allSatisfy { title.localizedCaseInsensitiveContains($0) }

                var bodyMatch = false
                var snippet: String? = nil

                // must-fix M3: only read bodies of fully-downloaded files; skip evicted iCloud items.
                let downloaded = (rv.isUbiquitousItem != true)
                    || (rv.ubiquitousItemDownloadingStatus == .current)
                let canReadBody = includeBodies && downloaded
                    && size <= maxFileSizeBytes && bodyReads < maxFilesContentRead

                if !term.isEmpty && canReadBody {
                    bodyReads += 1
                    // Markdown is effectively always UTF-8; a non-UTF-8 file just stays title-only.
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        if content.range(of: term, options: .caseInsensitive) != nil {
                            bodyMatch = true
                            snippet = makeSnippet(content: content, term: term)
                        } else if titleMatch {
                            snippet = firstNonEmptyLine(of: content)
                        }
                    }
                }

                // Empty term = "recent notes" mode: every note is a candidate, ranked by recency.
                if term.isEmpty || titleMatch || bodyMatch {
                    hits.append(Hit(title: title,
                                    relativePath: relativePath(of: url, vaultRoot: vault.url),
                                    snippet: snippet,
                                    titleMatch: titleMatch,
                                    bodyMatch: bodyMatch,
                                    modDate: modDate))
                }
            }
        }

        // Tuple sort (must-fix m6/m9): title hits, then body hits, then most recent.
        hits.sort { a, b in
            if a.titleMatch != b.titleMatch { return a.titleMatch }
            if a.bodyMatch != b.bodyMatch { return a.bodyMatch }
            return a.modDate > b.modDate
        }
        return SearchResult(hits: Array(hits.prefix(maxResults)), scanned: scanned)
    }

    // MARK: - Helpers

    private func isMarkdown(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return e == "md" || e == "markdown"
    }

    /// Obsidian-style location (folder path inside the vault), never an absolute /Users path.
    private func relativePath(of url: URL, vaultRoot: URL) -> String {
        let full = url.deletingLastPathComponent().path
        let root = vaultRoot.path
        guard full.hasPrefix(root) else { return url.deletingLastPathComponent().lastPathComponent }
        let rel = String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? vaultRoot.lastPathComponent : rel
    }

    private func makeSnippet(content: String, term: String) -> String? {
        guard let r = content.range(of: term, options: .caseInsensitive) else {
            return firstNonEmptyLine(of: content)
        }
        let pre = content.index(r.lowerBound, offsetBy: -100, limitedBy: content.startIndex) ?? content.startIndex
        let post = content.index(r.upperBound, offsetBy: 140, limitedBy: content.endIndex) ?? content.endIndex
        var s = String(content[pre..<post])
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if s.count > snippetLength { s = String(s.prefix(snippetLength)) }
        let lead = pre > content.startIndex ? "…" : ""
        let trail = post < content.endIndex ? "…" : ""
        return lead + s + trail
    }

    private func firstNonEmptyLine(of content: String) -> String? {
        for line in content.split(separator: "\n") {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#>-*"))
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty && cleaned != "---" { return String(cleaned.prefix(snippetLength)) }
        }
        return nil
    }

    private func formatResults(_ hits: [Hit], term: String, includeBodies: Bool) -> String {
        var header = term.isEmpty ? "Recent Obsidian notes:" : "Obsidian notes matching \"\(term)\":"
        if !includeBodies {
            header += "\n(cloud model active — showing titles only; note contents withheld for privacy. Switch Alfred to a local model to read note bodies.)"
        }
        var lines: [String] = [header]
        for h in hits {
            var line = "• \(h.title) — \(h.relativePath)"
            if includeBodies, let s = h.snippet, !s.isEmpty { line += "\n  \(s)" }
            lines.append(line)
        }
        var out = lines.joined(separator: "\n")
        if out.count > maxTotalOutputChars { out = String(out.prefix(maxTotalOutputChars)) + "…" }
        return out
    }
}
