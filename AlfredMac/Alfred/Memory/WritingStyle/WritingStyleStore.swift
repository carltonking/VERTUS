import Foundation
import GRDB
import OSLog

final class WritingStyleStore {
    private let db: DatabaseQueue
    private let analyzer = WritingStyleAnalyzer()
    private let writeQueue = DispatchQueue(label: "com.alfred.writing-style", qos: .utility)

    init(db: DatabaseQueue) throws {
        self.db = db
    }

    // MARK: - Record a sample

    func recordWritingSample(
        text: String,
        source: WritingSource = .chat
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return }
        let capped = String(trimmed.prefix(2000))

        let result = analyzer.analyze(capped)
        let now = Date().timeIntervalSince1970

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let record = WritingSampleRecord(
                    id: nil,
                    source: source.rawValue,
                    text: capped,
                    wordCount: result.wordCount,
                    sentenceCount: result.sentenceCount,
                    avgSentenceLength: result.avgSentenceLength,
                    hasGreeting: result.greeting != nil,
                    hasClosing: result.closing != nil,
                    formalityScore: result.formalityScore,
                    emojiCount: result.emojiCount,
                    timestamp: now
                )
                try self.db.write { db in
                    try record.insert(db)
                }
                try self.rebuildProfile()
            } catch {
                Logger(subsystem: "com.alfred.writing-style", category: "store").error("Failed to record sample: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Profile

    private func rebuildProfile() throws {
        let samples: [WritingSampleRecord] = try db.read { db in
            try WritingSampleRecord.order(Column("timestamp").desc).fetchAll(db)
        }
        guard !samples.isEmpty else { return }

        let avgSentenceLen = samples.map(\.avgSentenceLength).reduce(0, +) / Double(samples.count)
        let avgFormality = samples.map(\.formalityScore).reduce(0, +) / Double(samples.count)
        let totalEmoji = samples.map(\.emojiCount).reduce(0, +)
        let emojiRate = Double(totalEmoji) / Double(samples.count)

        var greetingSet: [String: Int] = [:]
        var closingSet: [String: Int] = [:]
        var phraseCounts: [String: Int] = [:]
        var punctCounts: [String: Int] = [:]

        for s in samples {
            let result = analyzer.analyze(s.text)
            if let g = result.greeting { greetingSet[g, default: 0] += 1 }
            if let c = result.closing { closingSet[c, default: 0] += 1 }
            for (p, cnt) in result.commonPhrases {
                phraseCounts[p, default: 0] += cnt
            }
            for (k, v) in result.punctuationPatterns {
                punctCounts[k, default: 0] += v
            }
        }

        let topGreetings = greetingSet.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let topClosings = closingSet.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let topPhrases = phraseCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)

        let paraLen: Double = {
            var total = 0.0
            var count = 0
            for s in samples {
                let paras = analyzer.splitParagraphs(s.text)
                total += Double(paras.count)
                count += 1
            }
            return count > 0 ? total / Double(count) : 1.0
        }()

        let now = Date().timeIntervalSince1970

        let profile = WritingProfileRecord(
            id: 1,
            avgSentenceLength: avgSentenceLen,
            avgParagraphLength: paraLen,
            commonGreetings: topGreetings.joined(separator: "|"),
            commonClosings: topClosings.joined(separator: "|"),
            commonPhrases: topPhrases.joined(separator: "|"),
            vocabularyPreferences: "{}",
            punctuationPatterns: punctCounts.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ","),
            emojiUsage: emojiRate,
            formalityScore: avgFormality,
            totalSamples: samples.count,
            lastUpdated: now
        )

        try db.write { db in
            try profile.save(db)
        }
    }

    // MARK: - Read profile

    func getWritingProfile() -> WritingProfile? {
        guard let record = try? db.read({ db in
            try WritingProfileRecord.fetchOne(db)
        }) else { return nil }

        return WritingProfile(
            avgSentenceLength: record.avgSentenceLength,
            avgParagraphLength: record.avgParagraphLength,
            commonGreetings: record.commonGreetings.split(separator: "|").map(String.init),
            commonClosings: record.commonClosings.split(separator: "|").map(String.init),
            commonPhrases: record.commonPhrases.split(separator: "|").map(String.init),
            vocabularyPreferences: [:],
            punctuationPatterns: [:],
            emojiUsage: record.emojiUsage,
            formalityScore: record.formalityScore,
            totalSamples: record.totalSamples,
            lastUpdated: Date(timeIntervalSince1970: record.lastUpdated)
        )
    }

    // MARK: - Context injection

    func generateStyleContext() -> String {
        guard let p = getWritingProfile(), p.totalSamples > 0 else {
            return ""
        }

        var lines: [String] = []
        lines.append("Writing style profile (based on \(p.totalSamples) sample(s)):")

        if !p.commonGreetings.isEmpty {
            lines.append("  • often opens with: \(p.commonGreetings.joined(separator: ", "))")
        }
        if !p.commonClosings.isEmpty {
            lines.append("  • often closes with: \(p.commonClosings.joined(separator: ", "))")
        }

        let sentenceDesc: String
        switch p.avgSentenceLength {
        case ..<10: sentenceDesc = "very concise"
        case ..<15: sentenceDesc = "concise"
        case ..<22: sentenceDesc = "moderate"
        default:    sentenceDesc = "verbose"
        }
        lines.append("  • \(sentenceDesc) sentences (avg \(Int(p.avgSentenceLength.rounded())) words)")

        let paraDesc: String
        switch p.avgParagraphLength {
        case ..<2:  paraDesc = "short"
        case ..<4:  paraDesc = "moderate"
        default:    paraDesc = "long"
        }
        lines.append("  • \(paraDesc) paragraphs (avg \(String(format: "%.1f", p.avgParagraphLength)) sentences)")

        let formalityDesc: String
        switch p.formalityScore {
        case ..<0.33: formalityDesc = "casual"
        case ..<0.66: formalityDesc = "neutral"
        default:      formalityDesc = "formal"
        }
        lines.append("  • \(formalityDesc) tone (formality: \(String(format: "%.2f", p.formalityScore)))")

        if p.emojiUsage > 0.5 {
            lines.append("  • frequently uses emoji")
        } else if p.emojiUsage > 0.1 {
            lines.append("  • occasionally uses emoji")
        } else {
            lines.append("  • rarely uses emoji")
        }

        if !p.commonPhrases.isEmpty {
            let phrases = p.commonPhrases.prefix(3).joined(separator: ", ")
            lines.append("  • common phrases: \(phrases)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Voice exemplars (few-shot real samples for the drafting path)

    /// Up to `limit` representative REAL writing samples — substantive (≥ `minWords`),
    /// de-duplicated, each whitespace-normalized and capped to `maxChars`. Soft-prefers
    /// `preferredSource`, falling back to any substantive sample (samples are mostly `.chat`).
    /// LLMs imitate concrete examples far better than the statistics in `generateStyleContext()`,
    /// which this leaves untouched — it's purely additive and used only by the drafting path.
    func voiceExemplars(preferredSource: WritingSource? = nil,
                        limit: Int = 3,
                        minWords: Int = 8,
                        maxChars: Int = 220) -> [String] {
        guard limit > 0 else { return [] }

        // Pull a recent pool; filtering/dedup/ranking happens in Swift (the table is small).
        let pool: [WritingSampleRecord] = (try? db.read { db in
            try WritingSampleRecord.order(Column("timestamp").desc).limit(80).fetchAll(db)
        }) ?? []
        guard !pool.isEmpty else { return [] }

        // Substantive only — count words from the actual text (don't trust the stored stat) so
        // "ok" / "yes" / "do it" never appear as exemplars.
        let substantive = pool.filter { Self.wordCount($0.text) >= minWords }
        guard !substantive.isEmpty else { return [] }

        // Soft-prefer the requested source: same-source first, then everything else (recency kept).
        let ordered: [WritingSampleRecord]
        if let src = preferredSource?.rawValue {
            ordered = substantive.filter { $0.source == src } + substantive.filter { $0.source != src }
        } else {
            ordered = substantive
        }

        var out: [String] = []
        var seen = Set<String>()
        for rec in ordered {
            if out.count >= limit { break }
            let cleaned = Self.cleanSample(rec.text, maxChars: maxChars)
            guard !cleaned.isEmpty else { continue }
            let key = Self.dedupKey(cleaned)
            if seen.insert(key).inserted { out.append(cleaned) }
        }
        return out
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
    }

    /// Collapses internal whitespace and caps length at a word boundary (adds "…" when truncated).
    /// The ellipsis is accounted for so the result never exceeds `maxChars`.
    private static func cleanSample(_ text: String, maxChars: Int) -> String {
        let collapsed = text.split { $0.isWhitespace }.joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        let cut = collapsed.prefix(max(0, maxChars - 1))   // leave room for the "…"
        if let space = cut.lastIndex(of: " ") {
            return cut[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Near-duplicate key: lowercased, whitespace-collapsed, first 80 chars — collapses re-saved
    /// samples that differ only by trailing punctuation/length.
    private static func dedupKey(_ text: String) -> String {
        let normalized = text.lowercased().split { $0.isWhitespace }.joined(separator: " ")
        return String(normalized.prefix(80))
    }
}
