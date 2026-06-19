import XCTest
import GRDB
@testable import Alfred

/// Tests the `RoutineRecord` GRDB mapping + the `routines` schema against an in-memory db
/// (mirrors the `v11_routines` migration columns), independent of MemoryStore's on-disk db.
final class RoutineRecordTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.create(table: "routines") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull().defaults(to: "")
                t.column("prompt_text", .text).notNull().defaults(to: "")
                t.column("schedule_cron", .text).notNull().defaults(to: "")
                t.column("timezone", .text).notNull().defaults(to: "")
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("policy_class", .text).notNull().defaults(to: "unattended-safe")
                t.column("last_run_at", .double)
                t.column("next_run_at", .double)
                t.column("last_status", .text)
                t.column("last_output_summary", .text)
                t.column("created_at", .double).notNull()
            }
        }
        return db
    }

    private func sample(title: String = "Morning summary", enabled: Bool = true) -> RoutineRecord {
        RoutineRecord(
            id: nil,
            title: title,
            prompt_text: "Summarize my unread emails",
            schedule_cron: "0 6 * * *",
            timezone: "America/New_York",
            enabled: enabled,
            policy_class: "unattended-safe",
            last_run_at: nil,
            next_run_at: 123_456,
            last_status: nil,
            last_output_summary: nil,
            created_at: 1000
        )
    }

    func testInsertAssignsIdAndRoundTrips() throws {
        let db = try makeDB()
        var rec = sample()
        try db.write { db in try rec.insert(db) }
        XCTAssertNotNil(rec.id)

        let fetched = try db.read { db in try RoutineRecord.fetchOne(db, key: rec.id!) }
        XCTAssertEqual(fetched?.title, "Morning summary")
        XCTAssertEqual(fetched?.prompt_text, "Summarize my unread emails")
        XCTAssertEqual(fetched?.schedule_cron, "0 6 * * *")
        XCTAssertEqual(fetched?.timezone, "America/New_York")
        XCTAssertEqual(fetched?.enabled, true)
        XCTAssertEqual(fetched?.policy_class, "unattended-safe")
    }

    func testEnabledFilter() throws {
        let db = try makeDB()
        var on = sample(title: "on", enabled: true)
        var off = sample(title: "off", enabled: false)
        try db.write { db in try on.insert(db); try off.insert(db) }

        let enabled = try db.read { db in
            try RoutineRecord.filter(Column("enabled") == true).fetchAll(db)
        }
        XCTAssertEqual(enabled.count, 1)
        XCTAssertEqual(enabled.first?.title, "on")
    }

    func testUpdateRunOutcome() throws {
        let db = try makeDB()
        var rec = sample()
        try db.write { db in try rec.insert(db) }
        let id = rec.id!

        try db.write { db in
            try db.execute(
                sql: "UPDATE routines SET last_status = ?, last_output_summary = ?, last_run_at = ? WHERE id = ?",
                arguments: ["success", "Done.", 2000, id]
            )
        }
        let fetched = try db.read { db in try RoutineRecord.fetchOne(db, key: id) }
        XCTAssertEqual(fetched?.last_status, "success")
        XCTAssertEqual(fetched?.last_output_summary, "Done.")
        XCTAssertEqual(fetched?.last_run_at, 2000)
    }

    func testDeleteRemovesRow() throws {
        let db = try makeDB()
        var rec = sample()
        try db.write { db in try rec.insert(db) }
        try db.write { db in _ = try RoutineRecord.deleteOne(db, key: rec.id!) }
        let count = try db.read { db in try RoutineRecord.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }
}
