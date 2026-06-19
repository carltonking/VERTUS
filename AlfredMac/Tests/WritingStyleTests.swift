import XCTest
import GRDB
@testable import Alfred

final class WritingStyleTests: XCTestCase {

    // MARK: - Analyzer (pure)

    func testAnalyzerDistinguishesFormality() {
        let a = WritingStyleAnalyzer()
        let formal = a.analyze("Dear Mr. Smith, I am writing to inform you of the quarterly results. Please find the report attached. Sincerely, John")
        let casual = a.analyze("hey lol idk it's gonna be fine 😂 ttyl")
        XCTAssertGreaterThan(formal.formalityScore, casual.formalityScore)
    }

    func testAnalyzerDetectsGreetingAndClosing() {
        let r = WritingStyleAnalyzer().analyze("Hi there, thanks for the update. Talk soon")
        XCTAssertNotNil(r.greeting)
        XCTAssertNotNil(r.closing)
    }

    func testAnalyzerCountsEmoji() {
        let a = WritingStyleAnalyzer()
        XCTAssertGreaterThan(a.analyze("great work 🎉🔥").emojiCount, 0)
        XCTAssertEqual(a.analyze("great work everyone").emojiCount, 0)
    }

    // MARK: - Store (record → profile → style context)

    func testStoreRecordsSampleAndBuildsProfile() throws {
        let store = try WritingStyleStore(db: makeDB())
        XCTAssertTrue(store.generateStyleContext().isEmpty)   // nothing recorded yet

        store.recordWritingSample(text: "Hi team, just a quick note to confirm the meeting tomorrow. Thanks!", source: .chat)
        let ctx = waitForContext(store)
        XCTAssertFalse(ctx.isEmpty, "profile should build after a sample")
        XCTAssertTrue(ctx.localizedCaseInsensitiveContains("writing style"))
    }

    func testStoreIgnoresTooShortSamples() throws {
        let store = try WritingStyleStore(db: makeDB())
        store.recordWritingSample(text: "hi", source: .chat)   // < 20 chars → dropped
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(store.generateStyleContext().isEmpty)
    }

    // MARK: - Helpers

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
            try db.create(table: "writing_profile") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("avgSentenceLength", .double).notNull()
                t.column("avgParagraphLength", .double).notNull()
                t.column("commonGreetings", .text).notNull().defaults(to: "")
                t.column("commonClosings", .text).notNull().defaults(to: "")
                t.column("commonPhrases", .text).notNull().defaults(to: "")
                t.column("vocabularyPreferences", .text).notNull().defaults(to: "{}")
                t.column("punctuationPatterns", .text).notNull().defaults(to: "")
                t.column("emojiUsage", .double).notNull()
                t.column("formalityScore", .double).notNull()
                t.column("totalSamples", .integer).notNull()
                t.column("lastUpdated", .double).notNull()
            }
        }
        return db
    }

    /// `recordWritingSample` persists + rebuilds the profile asynchronously on a private queue;
    /// pump the run loop until the style context appears (or time out).
    private func waitForContext(_ store: WritingStyleStore, timeout: TimeInterval = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var ctx = store.generateStyleContext()
        while ctx.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            ctx = store.generateStyleContext()
        }
        return ctx
    }
}
