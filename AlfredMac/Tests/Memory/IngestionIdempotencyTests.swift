import GRDB
import XCTest
@testable import Alfred

/// Covers the coordinated ingestion fixes: idempotent inserts (UNIQUE(source, text) + INSERT OR
/// IGNORE) and the "commit before advancing the cursor" contract (recordWritingSamples returns
/// whether the write durably committed).
final class IngestionIdempotencyTests: XCTestCase {

    private func makeStore() throws -> MemoryStore {
        try MemoryStore(path: NSTemporaryDirectory() + "alfred-idem-\(UUID().uuidString).sqlite")
    }

    func testReimportInsertsNoNewRows() throws {
        let store = try makeStore()
        guard let wss = store.writingStyleStore else { return XCTFail("no writing-style store") }

        let samples: [(text: String, source: WritingSource)] = [
            ("Thanks so much for sending that over, I will review it tonight.", .email),
            ("Hey, are we still on for lunch on Thursday afternoon?", .imessage),
        ]
        XCTAssertTrue(wss.recordWritingSamples(samples))
        let count1 = try store.db.read { try WritingSampleRecord.fetchCount($0) }
        XCTAssertEqual(count1, 2)

        // Re-import the exact same samples — UNIQUE(source, text) + INSERT OR IGNORE ⇒ no new rows.
        XCTAssertTrue(wss.recordWritingSamples(samples))
        let count2 = try store.db.read { try WritingSampleRecord.fetchCount($0) }
        XCTAssertEqual(count2, count1, "re-import inserts no new rows")
    }

    func testSameEmailViaTwoPathsStoredOnce() throws {
        // The same email body reaching both the Gmail API path and Apple Mail → same (source:.email,
        // text) → stored once (kills the Workspace/custom-domain double-import).
        let store = try makeStore()
        guard let wss = store.writingStyleStore else { return XCTFail() }
        let body = "Appreciate the update — let us regroup on Friday to finalize the numbers."

        XCTAssertTrue(wss.recordWritingSamples([(body, .email)]))
        XCTAssertTrue(wss.recordWritingSamples([(body, .email)]))
        let count = try store.db.read { try WritingSampleRecord.fetchCount($0) }
        XCTAssertEqual(count, 1, "the same email via two paths is stored once")
    }

    func testRecordWritingSamplesReturnsFalseWhenWriteFails() throws {
        // An empty DB has no writing_samples table → the insert throws → returns false, so the
        // caller must NOT advance its watermark/seen-set.
        let wss = try WritingStyleStore(db: DatabaseQueue())
        XCTAssertFalse(wss.recordWritingSamples([("A substantive sentence for the failure test.", .email)]),
                       "returns false when the DB write fails, so the cursor isn't advanced")
    }
}
