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

    /// Bulk-record samples, rebuilding the aggregate profile ONCE (instead of once per sample). Used
    /// by the sent-iMessage / Gmail backfills so a few-hundred-row import is O(n), not O(n²).
    func recordWritingSamples(_ samples: [(text: String, source: WritingSource)]) {
        let now = Date().timeIntervalSince1970
        let prepared: [WritingSampleRecord] = samples.compactMap { item in
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 20 else { return nil }
            let capped = String(trimmed.prefix(2000))
            let r = analyzer.analyze(capped)
            return WritingSampleRecord(
                id: nil, source: item.source.rawValue, text: capped,
                wordCount: r.wordCount, sentenceCount: r.sentenceCount,
                avgSentenceLength: r.avgSentenceLength, hasGreeting: r.greeting != nil,
                hasClosing: r.closing != nil, formalityScore: r.formalityScore,
                emojiCount: r.emojiCount, timestamp: now
            )
        }
        guard !prepared.isEmpty else { return }

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.db.write { db in
                    for rec in prepared { try rec.insert(db) }
                }
                try self.rebuildProfile()   // ONCE for the whole batch
            } catch {
                Logger(subsystem: "com.alfred.writing-style", category: "store").error("Failed to record samples: \(error.localizedDescription)")
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
    /// `preferredSources` in priority order (e.g. [.imessage, .chat] for texts), falling back to any
    /// substantive sample. LLMs imitate concrete examples far better than the statistics in
    /// `generateStyleContext()`, which this leaves untouched — additive, drafting-path only.
    func voiceExemplars(preferredSources: [WritingSource] = [],
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

        // Soft-prefer the requested sources in priority order, then everything else (recency kept).
        let ordered: [WritingSampleRecord]
        if preferredSources.isEmpty {
            ordered = substantive
        } else {
            let prefRaw = preferredSources.map(\.rawValue)
            let prefSet = Set(prefRaw)
            var result: [WritingSampleRecord] = []
            for raw in prefRaw {
                result += substantive.filter { $0.source == raw }
            }
            result += substantive.filter { !prefSet.contains($0.source) }
            ordered = result
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

    // MARK: - Voice learning from sent iMessages

    private static let sentWatermarkKey = "voiceLearning.lastImportedMessageRowID"
    private static let sentBackfillFlag = "voiceLearning.imessageBackfillDone"
    private static let messagesHintLock = NSLock()
    private static var didLogMessagesHint = false

    /// Imports the user's REAL sent iMessages as `.imessage` writing samples (feeding both the style
    /// stats and the exemplar pool). One-time backfill of up to 500 recent sent texts (gated by a
    /// flag), then incremental imports of anything with ROWID greater than the stored watermark — so
    /// samples never duplicate. Reads chat.db read-only and bounded; the CALLER runs this off the
    /// main thread (recordWritingSample also enqueues its own writes on a background queue).
    func importSentMessages() {
        let defaults = UserDefaults.standard
        let isBackfill = !defaults.bool(forKey: Self.sentBackfillFlag)
        let watermark = Int64(defaults.integer(forKey: Self.sentWatermarkKey))
        let limit = isBackfill ? 500 : 200

        let sent = MessagesReadCapability.recentSentMessages(afterRowID: watermark, limit: limit)
        guard !sent.isEmpty else {
            // Nothing imported — most often Full Disk Access isn't granted. Hint once, non-fatally.
            if isBackfill { Self.logMessagesHintOnce() }
            return
        }

        recordWritingSamples(sent.map { ($0.text, .imessage) })   // batch: rebuild the profile once
        let newWatermark = sent.map(\.rowid).max() ?? watermark
        defaults.set(Int(newWatermark), forKey: Self.sentWatermarkKey)
        if isBackfill { defaults.set(true, forKey: Self.sentBackfillFlag) }
    }

    // MARK: - Voice learning from sent Gmail

    private static let gmailWatermarkKey = "voiceLearning.gmailLastInternalDate"
    private static let gmailBackfillFlag = "voiceLearning.gmailBackfillDone"
    private static var didLogGmailHint = false

    /// Imports the user's REAL sent Gmail as `.email` writing samples. One-time backfill of up to 200
    /// recent sent emails (gated flag) then incremental imports past the latest-imported internalDate
    /// watermark. Quoted text + signatures are stripped before recording. Gated on Google being
    /// connected (no-op + one-time hint otherwise). The caller runs this off the main thread.
    func importSentEmails() async {
        guard GoogleAuth.isConnected else {
            Self.logGmailHintOnce()
            return
        }
        let defaults = UserDefaults.standard
        let isBackfill = !defaults.bool(forKey: Self.gmailBackfillFlag)
        let watermark = Int64(defaults.integer(forKey: Self.gmailWatermarkKey))
        let limit = isBackfill ? 200 : 50

        let fetched = await GmailCapability.recentSentEmails(afterInternalDate: watermark, limit: limit)
        let fresh = GmailCapability.emailsNewerThan(fetched, watermark)
        guard !fresh.isEmpty else { return }

        recordWritingSamples(fresh.map { ($0.body, .email) })
        defaults.set(Int(GmailCapability.newWatermark(fresh, current: watermark)), forKey: Self.gmailWatermarkKey)
        if isBackfill { defaults.set(true, forKey: Self.gmailBackfillFlag) }
    }

    private static func logGmailHintOnce() {
        messagesHintLock.lock(); defer { messagesHintLock.unlock() }
        guard !didLogGmailHint else { return }
        didLogGmailHint = true
        Logger(subsystem: "com.alfred.writing-style", category: "store").notice(
            "Voice learning from Gmail needs Google connected — say \"connect gmail\" to enable it.")
    }

    // MARK: - Voice learning from sent Apple Mail (iCloud + IMAP)

    private static let appleMailSeenKey = "voiceLearning.appleMailSeenIds"
    private static let appleMailBackfillFlag = "voiceLearning.appleMailBackfillDone"
    private static var didLogAppleMailHint = false

    /// Imports recent SENT messages from Apple Mail (iCloud + non-Gmail IMAP accounts) as `.email`
    /// writing samples. Gmail accounts are skipped (covered by the Gmail API path). De-dupes by RFC
    /// message id (bounded UserDefaults seen-set). One-time backfill of ~200, then ~50 incrementally.
    /// Runs only when Mail is already running; no-op + one-time hint if it isn't, or Automation is
    /// denied. Bodies are stripped of quotes/signatures before recording. The caller runs this
    /// off the main thread.
    func importSentAppleMail() {
        guard AppleMailSentReader.isMailRunning() else { Self.logAppleMailHintOnce(); return }

        let defaults = UserDefaults.standard
        let isBackfill = !defaults.bool(forKey: Self.appleMailBackfillFlag)
        let overallLimit = isBackfill ? 200 : 50

        guard let output = AppleMailSentReader.readSent(limitPerAccount: 50) else {
            Self.logAppleMailHintOnce()   // Mail not scriptable / Automation denied / timed out
            return
        }

        // Parse → drop Gmail accounts → drop already-seen ids.
        let records = AppleMailSentReader.parse(output)
            .filter { !AppleMailSentReader.isGmailAccount(email: $0.accountEmail) }
        let seenArray = defaults.stringArray(forKey: Self.appleMailSeenKey) ?? []
        let seen = Set(seenArray)
        let unseen = AppleMailSentReader.filterUnseen(records, seen: seen)

        var newSamples: [(text: String, source: WritingSource)] = []
        var newlySeen: [String] = []
        for rec in unseen {
            guard newSamples.count < overallLimit else { break }
            newlySeen.append(rec.id)
            let cleaned = EmailBodyCleaner.ownTextOnly(rec.body)
            if !cleaned.isEmpty { newSamples.append((cleaned, .email)) }
        }

        if !newSamples.isEmpty { recordWritingSamples(newSamples) }   // batch: one profile rebuild

        // Persist the seen-set. Refresh the recency of EVERY id read this run (newest-last), not just
        // the newly-imported ones, so the always-re-read newest window is never evicted by the 2000
        // cap — a stable mailbox then truly imports nothing on re-run. Over-budget unseen ids are
        // intentionally left out so they're picked up next time.
        let decided = records.map(\.id).filter { seen.contains($0) } + newlySeen
        if !decided.isEmpty {
            let decidedSet = Set(decided)
            let prior = seenArray.filter { !decidedSet.contains($0) }
            defaults.set(Array((prior + decided).suffix(2000)), forKey: Self.appleMailSeenKey)
        }

        // Mark the one-time backfill done only once it actually produced samples (mirrors the
        // iMessage path) — otherwise stay in backfill mode with the larger limit.
        if isBackfill && !newSamples.isEmpty { defaults.set(true, forKey: Self.appleMailBackfillFlag) }
    }

    private static func logAppleMailHintOnce() {
        messagesHintLock.lock(); defer { messagesHintLock.unlock() }
        guard !didLogAppleMailHint else { return }
        didLogAppleMailHint = true
        Logger(subsystem: "com.alfred.writing-style", category: "store").notice(
            "Voice learning from Apple Mail needs Mail running and Automation permission for Mail (System Settings → Privacy & Security → Automation).")
    }

    private static func logMessagesHintOnce() {
        messagesHintLock.lock(); defer { messagesHintLock.unlock() }
        guard !didLogMessagesHint else { return }
        didLogMessagesHint = true
        Logger(subsystem: "com.alfred.writing-style", category: "store").notice(
            "Voice learning from Messages needs Full Disk Access — grant it in System Settings → Privacy & Security → Full Disk Access.")
    }
}
