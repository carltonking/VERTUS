import Foundation

// MARK: - Personal memory models

enum PersonalMemoryKind: String, Codable, CaseIterable {
    case person
    case communicationStyle
    case routine
    case classInfo
    case interest
    case passion
    case preference
    case project
    case goal
    case habit
    case lifeContext
}

struct PersonalMemoryEvidence: Codable, Equatable {
    let source: String
    let observedAt: Date
    let excerpt: String
}

struct PersonalMemoryRecord: Codable, Identifiable, Equatable {
    let id: String
    var kind: PersonalMemoryKind
    var title: String
    var summary: String
    var keywords: [String]
    var confidence: Double
    var importance: Int
    var createdAt: Date
    var updatedAt: Date
    var lastObservedAt: Date
    var expiresAt: Date?
    var evidence: [PersonalMemoryEvidence]

    var searchableText: String {
        ([kind.rawValue, title, summary] + keywords + evidence.map(\.excerpt))
            .joined(separator: " ")
    }
}

struct PersonalMemoryObservation: Codable, Identifiable, Equatable {
    let id: String
    let source: String
    let app: String?
    let text: String
    let observedAt: Date
    var processedAt: Date?
}

struct PersonalMemoryCandidate: Codable {
    let kind: PersonalMemoryKind
    let title: String
    let summary: String
    let keywords: [String]
    let confidence: Double
    let importance: Int
    let evidenceSource: String
    let evidenceExcerpt: String
    let observedAt: Date
    let expiresAt: Date?
}

private struct PersonalMemoryFile: Codable {
    var version: Int
    var records: [PersonalMemoryRecord]
    var observations: [PersonalMemoryObservation]
}

// MARK: - Store

/// Local, inspectable profile memory for Alfred.
///
/// Raw signals land as short-lived observations. Reflection turns them into
/// durable records with evidence and confidence, so Alfred can personalize
/// without treating every captured string as a permanent fact.
final class PersonalMemoryStore {

    static let shared = PersonalMemoryStore()

    private let queue = DispatchQueue(label: "alfred.personal-memory")
    private let url: URL
    private var records: [PersonalMemoryRecord] = []
    private var observations: [PersonalMemoryObservation] = []

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            self.url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".alfred", isDirectory: true)
                .appendingPathComponent("personal-memory.json")
        }
        load()
    }

    // MARK: Persistence

    func refresh() {
        queue.sync { loadUnlocked() }
    }

    private func load() {
        queue.sync { loadUnlocked() }
    }

    private func loadUnlocked() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.personalMemory.decode(PersonalMemoryFile.self, from: data)
        else {
            records = []
            observations = []
            return
        }
        records = decoded.records.sorted { $0.updatedAt > $1.updatedAt }
        observations = decoded.observations.sorted { $0.observedAt > $1.observedAt }
    }

    private func persistUnlocked() {
        let file = PersonalMemoryFile(version: 1, records: records, observations: observations)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder.personalMemory.encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("[personal-memory] persist failed: %@", error.localizedDescription)
        }
    }

    // MARK: Observations

    @discardableResult
    func recordObservation(source: String, text: String, app: String? = nil, date: Date = Date()) -> PersonalMemoryObservation? {
        let cleaned = Self.clean(text)
        guard cleaned.count >= 12 else { return nil }
        return queue.sync {
            if observations.contains(where: { $0.source == source && $0.text == cleaned }) {
                return nil
            }
            let observation = PersonalMemoryObservation(
                id: UUID().uuidString,
                source: source,
                app: app,
                text: cleaned,
                observedAt: date,
                processedAt: nil)
            observations.insert(observation, at: 0)
            observations = Array(observations.prefix(500))
            persistUnlocked()
            return observation
        }
    }

    func unprocessedObservations(limit: Int = 80) -> [PersonalMemoryObservation] {
        queue.sync {
            Array(observations
                .filter { $0.processedAt == nil }
                .sorted { $0.observedAt > $1.observedAt }
                .prefix(limit))
        }
    }

    func markObservationsProcessed(_ ids: [String], at date: Date = Date()) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        queue.sync {
            for index in observations.indices where set.contains(observations[index].id) {
                observations[index].processedAt = date
            }
            persistUnlocked()
        }
    }

    // MARK: Durable records

    @discardableResult
    func upsert(_ candidate: PersonalMemoryCandidate) -> PersonalMemoryRecord {
        queue.sync {
            let now = Date()
            let normalizedTitle = Self.normalized(candidate.title)
            let existingIndex = records.firstIndex { record in
                record.kind == candidate.kind && Self.normalized(record.title) == normalizedTitle
            }
            let evidence = PersonalMemoryEvidence(
                source: candidate.evidenceSource,
                observedAt: candidate.observedAt,
                excerpt: Self.clean(candidate.evidenceExcerpt))

            if let existingIndex {
                var record = records[existingIndex]
                record.summary = candidate.summary
                record.keywords = Self.mergedKeywords(record.keywords, candidate.keywords)
                record.confidence = min(1.0, max(record.confidence, candidate.confidence))
                record.importance = max(record.importance, min(5, max(1, candidate.importance)))
                record.updatedAt = now
                record.lastObservedAt = max(record.lastObservedAt, candidate.observedAt)
                record.expiresAt = candidate.expiresAt
                record.evidence = Self.appendEvidence(evidence, to: record.evidence)
                records[existingIndex] = record
                records.sort { $0.updatedAt > $1.updatedAt }
                persistUnlocked()
                return record
            }

            let record = PersonalMemoryRecord(
                id: UUID().uuidString,
                kind: candidate.kind,
                title: candidate.title,
                summary: candidate.summary,
                keywords: Self.mergedKeywords([], candidate.keywords),
                confidence: min(1.0, max(0.0, candidate.confidence)),
                importance: min(5, max(1, candidate.importance)),
                createdAt: now,
                updatedAt: now,
                lastObservedAt: candidate.observedAt,
                expiresAt: candidate.expiresAt,
                evidence: [evidence])
            records.insert(record, at: 0)
            persistUnlocked()
            return record
        }
    }

    func allRecords() -> [PersonalMemoryRecord] {
        queue.sync { records }
    }

    func search(_ query: String, kinds: Set<PersonalMemoryKind>? = nil, limit: Int = 8) -> [PersonalMemoryRecord] {
        let terms = Self.terms(query)
        return queue.sync {
            let now = Date()
            return records
                .filter { record in
                    if let kinds, !kinds.contains(record.kind) { return false }
                    if let expiresAt = record.expiresAt, expiresAt < now { return false }
                    guard !terms.isEmpty else { return true }
                    let text = record.searchableText.lowercased()
                    return terms.contains { text.contains($0) }
                }
                .map { record in
                    let text = record.searchableText.lowercased()
                    let hitScore = terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
                    let recency = max(0, 30 - Int(Date().timeIntervalSince(record.lastObservedAt) / 86_400))
                    let score = hitScore * 20 + record.importance * 4 + Int(record.confidence * 10) + recency
                    return (score, record)
                }
                .sorted { $0.0 > $1.0 }
                .prefix(limit)
                .map { $0.1 }
        }
    }

    func groundingText(for query: String, limit: Int = 6) -> String {
        let matches = search(query, limit: limit)
        guard !matches.isEmpty else { return "" }
        return matches.map { record in
            let confidence = String(format: "%.2f", record.confidence)
            return "[personal:\(record.kind.rawValue)/\(record.title) conf=\(confidence): \(record.summary)]"
        }.joined(separator: " ")
    }

    /// Grounding that merges the local personal-memory file with the unified
    /// memory graph.
    ///
    /// The local store knows the records reflection has written so far; the
    /// unified layer knows more — entities, relations, conversations and
    /// screen observations accumulated across every memory system. So besides
    /// the local `groundingText` we fold the unified layer's ranked hits into
    /// the same `[graph: ...]` shape. Best-effort: an empty graph degrades to
    /// local only, never to an error.
    func agentMemoryGroundingText(for query: String, limit: Int = 6) async -> String {
        let local = groundingText(for: query, limit: limit)
        let graphHits = UnifiedMemoryLayer.shared.search(query: query, limit: limit)
        let graph = graphHits.isEmpty ? "" : graphHits.prefix(limit).map { "[graph: \($0.title)]" }.joined(separator: " ")
        return [local, graph].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Helpers

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func terms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    private static func normalized(_ text: String) -> String {
        clean(text).lowercased()
    }

    private static func mergedKeywords(_ existing: [String], _ incoming: [String]) -> [String] {
        var seen = Set<String>()
        // Pin the chain into Array: under newer Swift toolchains the trailing
        // `.prefix(20).map(String.init)` trips an ambiguous-prefix overload
        // error on the filter's element type.
        return Array((existing + incoming)
            .map { clean($0).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(20))
    }

    private static func appendEvidence(_ evidence: PersonalMemoryEvidence, to existing: [PersonalMemoryEvidence]) -> [PersonalMemoryEvidence] {
        var items = existing.filter { $0.excerpt != evidence.excerpt || $0.source != evidence.source }
        items.insert(evidence, at: 0)
        return Array(items.prefix(8))
    }
}

private extension JSONEncoder {
    static var personalMemory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var personalMemory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
