import Foundation

/// Phase 3 — relationship map.
/// Extracts the people the user communicates with from screen memory, builds a
/// graph of interactions (topic, sentiment, direction), and summarizes relationships.
/// This is the most sensitive data in Alfred — profiles of OTHER people — so it is
/// local-only and never leaves the device (see threat-model.md T4).
struct People {
    let store: Store
    let ollama: OllamaClient

    private struct Extracted: Decodable {
        let name: String
        let direction: String?
        let topic: String?
        let sentiment: String?
        let snippet: String?
    }
    private struct Envelope: Decodable { let people: [Extracted] }

    /// Scan recent memory; extract real people + interactions into the graph.
    /// Returns (scannedBlocks, peopleTouched, interactionsAdded).
    func scan(maxBlocks: Int = 40) async throws -> (scanned: Int, people: Int, interactions: Int) {
        let blocks = try store.recentMemoryTexts(limit: 300)
            .filter { $0.count >= 30 }              // skip tiny UI fragments
            .prefix(maxBlocks)

        let system = """
        From the screen text, extract ONLY real human INDIVIDUALS the USER appears to be
        communicating with (messages, emails, chats, calls). A real person has a personal name.
        Do NOT include: organizations, companies, schools, teams, products, app/UI labels, menu
        items, code identifiers, role titles (e.g. "Startup Coach", "Institute"), phone numbers,
        the user themselves, or public figures merely mentioned in articles.
        For each, return: name, direction ('to' = user wrote to them, 'from' = they wrote to the
        user, 'mention'), topic (short), sentiment ('positive'|'neutral'|'negative'), and a short
        snippet. If there are none, return an empty list.
        Respond as JSON: {"people":[{"name","direction","topic","sentiment","snippet"}]}
        """

        var touched = Set<String>(), interactions = 0
        for block in blocks {
            let raw = try await ollama.chatJSON(system: system, user: block)
            guard let data = raw.data(using: .utf8),
                  let env = try? JSONDecoder().decode(Envelope.self, from: data) else { continue }
            for p in env.people {
                let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isLikelyPerson(name) else { continue }
                let pid = try store.upsertPerson(name: name, ts: now())
                let added = try store.addInteraction(
                    personID: pid, ts: now(),
                    direction: p.direction, topic: p.topic, sentiment: p.sentiment,
                    snippet: (p.snippet?.isEmpty == false ? p.snippet! : block).prefix(400).description)
                touched.insert(name.lowercased())
                if added { interactions += 1 }
            }
        }
        return (blocks.count, touched.count, interactions)
    }

    // Words that signal an organization / role / product rather than an individual.
    static let orgWords: Set<String> = [
        "coaching", "coach", "institute", "startup", "lab", "elab", "university", "college",
        "inc", "llc", "ltd", "team", "support", "nyu", "dept", "department", "office", "group",
        "services", "service", "company", "co", "corp", "foundation", "center", "centre",
        "school", "club", "society", "association", "bot", "ai", "notifications", "notification"
    ]

    /// Names that are really the user themselves — derived from the macOS account.
    static var selfTokens: Set<String> {
        let full = NSFullUserName().lowercased()
        return Set(full.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 1 })
    }

    static func tokens(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
    }

    /// Strict check: is this plausibly an individual human's name (not org/self/junk/phone)?
    static func isLikelyPerson(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return false }
        if trimmed.contains(where: { $0.isNumber }) { return false }                 // phone fragments etc.
        if trimmed.contains(where: { "{}[]()<>/\\|@#".contains($0) }) { return false }
        let toks = tokens(trimmed)
        guard (1...4).contains(toks.count) else { return false }
        if toks.contains(where: { orgWords.contains($0) }) { return false }           // org / role
        let selfT = selfTokens
        // drop if it's the user themselves (full overlap or single self-name)
        if !selfT.isEmpty, Set(toks).isSubset(of: selfT) { return false }
        // each token should look like a name word (starts with a letter)
        return toks.allSatisfy { $0.first?.isLetter == true }
    }

    /// Two people are the same if one's token set is contained in the other's
    /// (e.g. "Leslie" ⊂ "Leslie Carter") — used for duplicate merging.
    static func sameEntity(_ a: String, _ b: String) -> Bool {
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        return ta.isSubset(of: tb) || tb.isSubset(of: ta)
    }

    /// Clean the existing graph: drop orgs/self/junk, then merge duplicate variants.
    /// Returns (removed, merged).
    func clean() throws -> (removed: Int, merged: Int) {
        var removed = 0, merged = 0
        // 1) remove non-people
        for p in try store.people() where !Self.isLikelyPerson(p.name) {
            try store.deletePerson(id: p.id); removed += 1
        }
        // 2) merge duplicates — keep the one with more interactions as canonical
        var survivors = try store.people()   // already sorted by count desc
        var i = 0
        while i < survivors.count {
            let canonical = survivors[i]
            var j = i + 1
            while j < survivors.count {
                if Self.sameEntity(canonical.name, survivors[j].name) {
                    try store.mergePerson(from: survivors[j].id, into: canonical.id)
                    merged += 1
                    survivors.remove(at: j)
                } else { j += 1 }
            }
            i += 1
        }
        return (removed, merged)
    }

    /// Summarize the relationship with a named person from their interactions.
    func summarize(name: String) async throws -> (summary: String, interactions: [Store.Interaction])? {
        guard let pid = try store.personID(name: name) else { return nil }
        let ix = try store.interactions(personID: pid, limit: 50)
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
        let log = ix.map { i in
            let dir = i.direction.map { "(\($0))" } ?? ""
            let topic = i.topic.map { " [\($0)]" } ?? ""
            return "\(fmt.string(from: i.ts)) \(dir)\(topic): \(i.snippet)"
        }.joined(separator: "\n")
        let system = """
        You are Alfred. Summarize the user's relationship with this person based on the
        interaction log: who they seem to be to the user, main topics, overall tone, and what's
        recent/open. Be concise. This is private data — never invent details not in the log.
        """
        let summary = try await ollama.chat(system: system, user: "Person: \(name)\n\nInteractions:\n\(log.isEmpty ? "(none)" : log)")
        return (summary, ix)
    }

    /// Find any known person named in free text (for draft context injection).
    func knownPersonMentioned(in text: String) throws -> (name: String, context: String)? {
        let all = try store.people()
        let lowerText = text.lowercased()
        for p in all where lowerText.contains(p.name.lowercased()) {
            let ix = try store.interactions(personID: p.id, limit: 8)
            let ctx = ix.map { ($0.topic.map { t in "[\(t)] " } ?? "") + $0.snippet }.joined(separator: "\n")
            return (p.name, ctx)
        }
        return nil
    }
}
