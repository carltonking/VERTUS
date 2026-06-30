import GRDB
import XCTest
@testable import Alfred

/// Covers the few-shot real-writing exemplars: the WritingStyleStore selector and the testable
/// drafting-prompt assembly (DraftingService.buildSystemPrompt).
final class VoiceExemplarsTests: XCTestCase {

    // MARK: - Setup

    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.create(table: "writing_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source", .text).notNull()
                t.column("text", .text).notNull()
                t.column("wordCount", .integer).notNull()
                t.column("sentenceCount", .integer).notNull()
                t.column("avgSentenceLength", .double).notNull()
                t.column("hasGreeting", .boolean).notNull()
                t.column("hasClosing", .boolean).notNull()
                t.column("formalityScore", .double).notNull()
                t.column("emojiCount", .integer).notNull()
                t.column("timestamp", .double).notNull()
            }
        }
        return db
    }

    private var ts = 1000.0
    /// Inserts a raw sample (bypassing recordWritingSample's 20-char guard so we can seed trivial
    /// samples like "ok"). Increasing timestamps make recency order deterministic.
    private func insert(_ db: DatabaseQueue, _ text: String, _ source: WritingSource) throws {
        ts += 1
        let words = text.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
        try db.write { db in
            try WritingSampleRecord(
                id: nil, source: source.rawValue, text: text, wordCount: words,
                sentenceCount: 1, avgSentenceLength: Double(words), hasGreeting: false,
                hasClosing: false, formalityScore: 0.5, emojiCount: 0, timestamp: ts
            ).insert(db)
        }
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
    }

    // MARK: - voiceExemplars selector

    func testFiltersTrivialDedupesCapsAndRespectsLimit() throws {
        let db = try makeDB()
        let store = try WritingStyleStore(db: db)

        // Trivial — must never appear.
        try insert(db, "ok", .email)
        try insert(db, "yes", .email)
        try insert(db, "do it", .chat)
        // Substantive email.
        try insert(db, "Thanks so much for sending that over — I'll review it tonight and reply tomorrow.", .email)
        // Near-duplicate (only trailing punctuation differs) — must dedupe.
        try insert(db, "Thanks so much for sending that over — I'll review it tonight and reply tomorrow!!", .email)
        // Another substantive email.
        try insert(db, "Sounds good, let's lock in Thursday at 2pm and I'll send a calendar invite shortly.", .email)
        // Very long sample — must be length-capped.
        try insert(db, "Just circling back on the roadmap " + String(repeating: "and the next milestone ", count: 20), .email)

        let ex = store.voiceExemplars(preferredSources: [.email], limit: 3, minWords: 8, maxChars: 220)

        XCTAssertEqual(ex.count, 3, "respects the limit")
        XCTAssertFalse(ex.contains("ok"))
        XCTAssertFalse(ex.contains("yes"))
        XCTAssertFalse(ex.contains("do it"))
        XCTAssertTrue(ex.allSatisfy { wordCount($0) >= 8 }, "only substantive (≥ 8 words) samples")
        XCTAssertTrue(ex.allSatisfy { $0.count <= 220 }, "each capped to maxChars")
        let thanks = ex.filter { $0.lowercased().hasPrefix("thanks so much") }
        XCTAssertLessThanOrEqual(thanks.count, 1, "near-identical samples deduped")
    }

    func testFallsBackWhenPreferredSourceScarce() throws {
        let db = try makeDB()
        let store = try WritingStyleStore(db: db)
        // No .notes samples exist; substantive chat ones should still come back.
        try insert(db, "Hey, are we still on for lunch on Friday or should we push it to next week?", .chat)
        try insert(db, "I pushed the fix to the branch — can you take a look when you get a sec?", .chat)

        let ex = store.voiceExemplars(preferredSources: [.notes], limit: 3, minWords: 8)
        XCTAssertEqual(ex.count, 2, "falls back to any substantive sample when the preferred source is scarce")
    }

    func testPrefersIMessageOverChatForTextChannel() throws {
        let db = try makeDB()
        let store = try WritingStyleStore(db: db)
        // Insert the chat (Alfred-command-style) sample FIRST (older) and the real iMessage AFTER
        // (newer), so a pure-recency order would put chat... no — newer wins recency. Force the test
        // to depend on SOURCE preference, not recency: make the chat one NEWER.
        try insert(db, "open mail and summarize my unread messages from this morning please", .imessage)
        try insert(db, "hey sounds good, let's grab coffee thursday before the standup meeting", .chat)

        // The .text channel maps to [.imessage, .chat]; the iMessage sample must rank first even
        // though the chat sample is more recent.
        let ex = store.voiceExemplars(preferredSources: [.imessage, .chat], limit: 2, minWords: 8)
        XCTAssertEqual(ex.count, 2)
        XCTAssertEqual(ex.first, "open mail and summarize my unread messages from this morning please",
                       "the .imessage sample should rank above the more-recent .chat sample")
    }

    func testEmptyWhenAllTrivial() throws {
        let db = try makeDB()
        let store = try WritingStyleStore(db: db)
        try insert(db, "ok", .chat)
        try insert(db, "sure thing", .chat)
        XCTAssertTrue(store.voiceExemplars(limit: 3, minWords: 8).isEmpty)
    }

    // MARK: - Drafting prompt assembly (pure helper)

    func testExemplarsBlockAppearsWhenSamplesExist() {
        let prompt = DraftingService.buildSystemPrompt(
            owner: "Carlton", channel: .email, recipientDisplay: "Sarah",
            styleContext: "casual, concise",
            exemplars: ["Thanks for the update — will circle back tomorrow."],
            relationshipContext: nil)

        XCTAssertTrue(prompt.contains("EXAMPLES OF CARLTON'S ACTUAL WRITING"))
        XCTAssertTrue(prompt.contains("match the phrasing/voice, NOT the content"))
        XCTAssertTrue(prompt.contains("Thanks for the update"))
        XCTAssertTrue(prompt.contains("HOW CARLTON WRITES"), "statistical block still present")
    }

    func testExemplarsBlockAbsentWhenNoSamples() {
        let prompt = DraftingService.buildSystemPrompt(
            owner: "Carlton", channel: .text, recipientDisplay: "Sarah",
            styleContext: "casual, concise", exemplars: [], relationshipContext: nil)

        XCTAssertFalse(prompt.contains("EXAMPLES OF"))
    }
}
