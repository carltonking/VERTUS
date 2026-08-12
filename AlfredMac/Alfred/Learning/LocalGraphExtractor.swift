import Foundation

// MARK: - Extracted graph facts

/// One entity the local extractor pulled out of a conversation turn.
struct GraphEntity: Equatable, Sendable {
    enum Kind: String, Sendable {
        case person
        case organization
        case communicationPreference

        /// Human label folded into the stored memory's content.
        var displayName: String {
            switch self {
            case .person: return "Person"
            case .organization: return "Organization"
            case .communicationPreference: return "Communication preference"
            }
        }
    }

    let name: String
    let kind: Kind
    /// Extra context the model gave (the preference channel, a qualifier…),
    /// folded into the memory content when present.
    let detail: String?
}

/// An edge between two extracted entities, keyed by their (normalized) names.
struct GraphRelation: Equatable, Sendable {
    let sourceName: String
    let targetName: String
    let type: String
}

/// Everything one extraction pass found, plus the edges between the entities.
struct GraphFactSet: Equatable, Sendable {
    var entities: [GraphEntity] = []
    var relations: [GraphRelation] = []

    var isEmpty: Bool { entities.isEmpty && relations.isEmpty }
}

// MARK: - The local extractor

/// Runs Alfred's local extractor model (`alfred-coder` on Ollama) over a
/// finished conversation turn and returns the people, organizations and
/// communication preferences it names, plus the edges between them.
///
/// This is the on-device replacement for agentmemory's background graph
/// pipeline: that pipeline calls an external LLM with a strict structured
/// output schema, which the free relay rejects. Here the model is local
/// (Ollama, no API key, no schema) and the output is plain text key-value
/// pairs parsed defensively — nothing for the server to reject.
///
/// Everything is best-effort and non-throwing: Ollama down, or a message with
/// nothing to extract, is a miss, not an error.
final class LocalGraphExtractor: @unchecked Sendable {
    static let shared = LocalGraphExtractor()

    /// The model built from Modelfile.alfred (qwen2.5-coder base). Override
    /// with ALFRED_EXTRACTOR_MODEL to test against another local model.
    let model = ProcessInfo.processInfo.environment["ALFRED_EXTRACTOR_MODEL"] ?? "alfred-coder"
    let baseURL = URL(string: "http://localhost:11434")!

    private init() {}

    /// How long one extraction may take. The 3B model on a 4K window answers in
    /// a couple of seconds; the cap is for the cold-start load and the broken
    /// server case.
    private static let extractionTimeout: TimeInterval = 30

    /// The extract prompt, verbatim, plus a tight output contract so the
    /// tolerant parser below can rely on the shape.
    private static let systemPrompt = """
    Extract all people, organizations, and communication preferences from this message as simple comma-separated key-value pairs.
    Output only key-value lines, one fact per line:
    person: <name>
    organization: <name>
    communication_preference: <channel>
    Use "person" for individual people, "organization" for companies, teams and groups, and \
    "communication_preference" for how someone prefers to be reached (email, phone, Slack, and so on).
    If a category has nothing in it, omit it. If nothing is relevant at all, output nothing.
    """

    /// Run one extraction. Empty set on any failure — never throws.
    func extract(from text: String) async -> GraphFactSet {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing worth an Ollama round trip for a fragment or a bare prompt.
        guard trimmed.count >= 20, trimmed.count <= 12_000 else { return GraphFactSet() }
        let raw = await chat(text: trimmed)
        guard !raw.isEmpty else { return GraphFactSet() }
        return Self.parse(raw)
    }

    // MARK: - Ollama

    /// One non-streaming chat completion against `/api/chat`. Returns the
    /// model's text, or "" on any failure.
    private func chat(text: String) async -> String {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text],
            ],
            // Deterministic extraction: no temperature, no creativity budget.
            "options": ["temperature": 0],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body),
              let url = baseURL.appendingPathComponent("api/chat") as URL?
        else { return "" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = Self.extractionTimeout

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = json?["message"] as? [String: Any]
            return (message?["content"] as? String) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Parsing

    /// Keys the model is told to emit, longest first so the alternation
    /// matches "communication_preference" before it can match "preference".
    /// Optional trailing "s" accepts stray plurals (organizations, orgs, …)
    /// without letting "personal:" slip through — the `\s*:` guard still
    /// rejects anything that isn't directly followed by a colon.
    private static let keyPattern =
        "communication_preferences?|communication preferences?|people|persons?|organizations?|organisations?|orgs?|companies|company|preferences?|prefers"

    /// Pull `key: value` pairs out of the raw reply. Tolerant by design: the
    /// model may separate pairs with commas or newlines, may capitalise, and
    /// may drift from the letter of the contract — the regex only needs a key
    /// it knows and a value that stops at the next key or the end of line.
    static func parse(_ raw: String) -> GraphFactSet {
        var entities: [GraphEntity] = []
        var seen = Set<String>()
        var relationInputs: [GraphEntity] = []

        let pattern = #"(?i)\b("# + keyPattern + #")\s*:\s*([^,\n]+?)(?=(?:,\s*(?:"# + keyPattern + #")\s*:|\r?\n\s*(?:"# + keyPattern + #")\s*:|$))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return GraphFactSet() }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))

        for match in matches.prefix(24) {
            guard match.numberOfRanges == 3 else { continue }
            let key = ns.substring(with: match.range(at: 1))
            let value = Self.cleanValue(ns.substring(with: match.range(at: 2)))
            guard !value.isEmpty, let kind = Self.kind(for: key) else { continue }

            // Fold a trailing qualifier like "Carlton — prefers email" into
            // the detail field; the memory content keeps the full sentence.
            var name = value
            var detail: String?
            if let dash = name.range(of: "—") ?? name.range(of: " - ") {
                // upperBound, not index(after: lowerBound): for the three-char
                // " - " separator it lands past the closing space, so the
                // qualifier keeps no stray hyphen.
                let after = name[dash.upperBound...]
                name = String(name[..<dash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let qualifier = String(after).trimmingCharacters(in: .whitespacesAndNewlines)
                if !qualifier.isEmpty { detail = qualifier }
            }

            // Names are title-cased so "carlton"/"Carlton" merge on write;
            // preference channels stay lowercase (email, slack, phone).
            let normalized = kind == .communicationPreference
                ? name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                : Self.normalize(name)
            guard Self.isPlausible(normalized), !seen.contains("\(kind.rawValue):\(normalized)") else { continue }
            seen.insert("\(kind.rawValue):\(normalized)")
            let entity = GraphEntity(name: normalized, kind: kind, detail: detail)
            entities.append(entity)
            relationInputs.append(entity)
        }

        guard !entities.isEmpty else { return GraphFactSet() }
        return GraphFactSet(entities: entities, relations: Self.relations(from: relationInputs))
    }

    private static func cleanValue(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func kind(for key: String) -> GraphEntity.Kind? {
        // Mirrors the regex's plural tolerance: the pattern matches
        // "organizations" / "communication_preferences" / "orgs" …, so the
        // mapping has to accept those same forms or every plural is dropped.
        let k = key.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        switch k {
        case "person", "people", "persons": return .person
        case "organization", "organizations", "organisation", "organisations",
             "org", "orgs", "company", "companies": return .organization
        case "communicationpreference", "communicationpreferences",
             "preference", "preferences", "prefers": return .communicationPreference
        default: return nil
        }
    }

    /// Names are stored title-cased so "carlton" and "Carlton" merge on write.
    private static func normalize(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" })
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return parts.joined(separator: " ")
    }

    /// Values the model writes when it found nothing for a category. A live
    /// run emits `organization: None` when a message names no company — storing
    /// that would litter the graph with "Organization: None" nodes.
    private static let placeholderValues: Set<String> = [
        "none", "nothing", "no one", "nobody", "null", "nil", "n/a", "na",
        "unknown", "not specified", "not available", "unavailable", "-",
    ]

    /// Cheap plausibility gate: long enough to be a name, short enough to be
    /// one, no control characters, not a bare number, not a placeholder, not
    /// an obvious label.
    private static func isPlausible(_ name: String) -> Bool {
        let count = name.count
        guard count >= 2, count <= 60 else { return false }
        if placeholderValues.contains(name.lowercased()) { return false }
        if name.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) { return false }
        if name.allSatisfy({ $0.isNumber || $0 == "." || $0 == " " }) { return false }
        return true
    }

    /// Build edges between the extracted entities:
    ///   person – person                     → "knows"
    ///   person – organization               → "affiliated_with"
    ///   person – communication_preference   → "prefers" (only when unambiguous)
    static func relations(from entities: [GraphEntity]) -> [GraphRelation] {
        var out: [GraphRelation] = []
        let people = entities.filter { $0.kind == .person }.map(\.name)
        let orgs = entities.filter { $0.kind == .organization }.map(\.name)
        let prefs = entities.filter { $0.kind == .communicationPreference }.map(\.name)

        for (i, a) in people.enumerated() {
            for b in people.dropFirst(i + 1) {
                out.append(GraphRelation(sourceName: a, targetName: b, type: "knows"))
            }
        }
        for person in people {
            for org in orgs {
                out.append(GraphRelation(sourceName: person, targetName: org, type: "affiliated_with"))
            }
        }
        // A preference with no person in the same turn (e.g. "always email me")
        // gets no edge — its entity is still stored and searchable.
        if people.count == 1, let person = people.first {
            for pref in prefs {
                out.append(GraphRelation(sourceName: person, targetName: pref, type: "prefers"))
            }
        }
        return out
    }
}
