// MARK: - ProblemTypeTracker
//
// The SQLite home for the Homework Assistant's learning data, in
// `~/.alfred/db/homework.db` — separate from `memory.db` (the unified graph),
// `mempalace.db` (the confidence-scored vault) and `tutor.db` (concept
// mastery), so the homework writes never touch any of those schemas. Raw
// sqlite3 with per-call FULLMUTEX connections, the same pattern
// ConceptMasteryTracker and OptimizationStore proved.
//
// Two tables:
//
//   * `problem_types` — one row per problem topic (normalized key, so
//     "recursion" and "Recursion" are the same row): how many times the user
//     struggled with it (teach-mode requests and confused feedback) and how
//     many submission-mode solves came out the other end.
//   * `preferences`   — key/value scratch: the user's learned solution style
//     (a compact prose description produced by SolutionStyleMatcher) so a
//     future submission can be written in the same voice.

import Foundation
import SQLite3

private let HOMEWORK_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ProblemTypeTracker {

    static let shared = ProblemTypeTracker()

    private static let defaultDatabasePath = NSHomeDirectory() + "/.alfred/db/homework.db"

    private let databasePath: String

    init(databasePath: String = ProblemTypeTracker.defaultDatabasePath) {
        self.databasePath = databasePath
        do {
            try FileManager.default.createDirectory(
                atPath: (databasePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let db = try Self.openDB(path: databasePath)
            defer { sqlite3_close(db) }
            try Self.runMigration(db)
        } catch {
            NSLog("[homework] store init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Schema

    private static let migrationDDL = """
    CREATE TABLE IF NOT EXISTS problem_types (
        id         TEXT PRIMARY KEY,
        domain     TEXT NOT NULL,
        topic_key  TEXT NOT NULL UNIQUE,
        topic      TEXT NOT NULL,
        struggles  INTEGER NOT NULL DEFAULT 0,
        solved     INTEGER NOT NULL DEFAULT 0,
        last_seen  REAL NOT NULL,
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_problem_types_domain ON problem_types(domain);
    CREATE INDEX IF NOT EXISTS idx_problem_types_last_seen ON problem_types(last_seen);

    CREATE TABLE IF NOT EXISTS preferences (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at REAL NOT NULL
    );
    """

    // MARK: - Recording

    /// The user asked for help (teach mode) or reported confusion on a topic.
    /// Upserts the row, bumps the struggle count, touches last_seen.
    func recordStruggle(domain: HomeworkDomain, topic: String) {
        record(domain: domain, topic: topic, bumpStruggle: true, bumpSolved: false)
    }

    /// A submission-mode solve (or "got it" feedback) on a topic.
    func recordSolved(domain: HomeworkDomain, topic: String) {
        record(domain: domain, topic: topic, bumpStruggle: false, bumpSolved: true)
    }

    private func record(domain: HomeworkDomain, topic: String,
                        bumpStruggle: Bool, bumpSolved: Bool) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? Self.openDB(path: databasePath) else { return }
        defer { sqlite3_close(db) }
        let now = Date().timeIntervalSince1970
        let key = Self.nameKey(trimmed)

        // A strict 60-char cap keeps one pasted problem from becoming a
        // "topic" — topics are the recurring types, not whole assignments.
        let topicName = trimmed.count <= 60 ? trimmed : String(trimmed.prefix(57)) + "…"

        if let existing = Self.row(db, topicKey: key) {
            var sql = "UPDATE problem_types SET last_seen = ?"
            var args: [Bind] = [.double(now)]
            if bumpStruggle { sql += ", struggles = struggles + 1" }
            if bumpSolved { sql += ", solved = solved + 1" }
            sql += " WHERE id = ?"
            args.append(.text(existing.id))
            Self.exec(db, sql: sql, args: args)
        } else {
            let id = UUID().uuidString
            Self.exec(db, sql: """
                INSERT INTO problem_types (id, domain, topic_key, topic,
                                           struggles, solved, last_seen, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, args: [.text(id), .text(domain.rawValue), .text(key),
                            .text(topicName),
                            .int(bumpStruggle ? 1 : 0), .int(bumpSolved ? 1 : 0),
                            .double(now), .double(now)])
        }
    }

    // MARK: - Queries

    /// The problem types the user keeps struggling with, most-struggled
    /// first. The raw material for the briefing's Homework card and the
    /// prompt injection.
    func struggleTopics(limit: Int = 10) -> [ProblemTypeStat] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var rows: [ProblemTypeStat] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, domain, topic, struggles, solved, last_seen, created_at
                FROM problem_types
                WHERE struggles > 0
                ORDER BY struggles DESC, last_seen DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.stat(stmt))
            }
        } catch { }
        return rows
    }

    /// Everything tracked, most recent first.
    func allTopics(limit: Int = 50) -> [ProblemTypeStat] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var rows: [ProblemTypeStat] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, domain, topic, struggles, solved, last_seen, created_at
                FROM problem_types ORDER BY last_seen DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.stat(stmt))
            }
        } catch { }
        return rows
    }

    /// A one-line summary for the briefing / prompt injection: the weakest
    /// problem types, ranked. Empty when there's nothing on record yet.
    func struggleLine(limit: Int = 3) -> String {
        let topics = struggleTopics(limit: limit)
        guard !topics.isEmpty else { return "" }
        return topics.map { stat in
            "\(stat.topic) (\(stat.domain.displayName), struggled \(stat.struggles)×)"
        }.joined(separator: ", ")
    }

    /// The count of problem types the user has fully worked through — the
    /// encouragement signal for the briefing card.
    func masteredCount() -> Int {
        guard let db = try? Self.openDB(path: databasePath) else { return 0 }
        defer { sqlite3_close(db) }
        var count = 0
        do {
            try Self.queryRows(db, sql: """
                SELECT COUNT(*) FROM problem_types WHERE struggles = 0 AND solved > 0
                """) { stmt in
                count = Self.intColumn(stmt, 0)
            }
        } catch { }
        return count
    }

    // MARK: - Preferences (learned solution style)

    /// Store the learned solution-style profile (produced by
    /// SolutionStyleMatcher) as JSON.
    func setPreference(_ key: String, value: String) {
        guard let db = try? Self.openDB(path: databasePath) else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            INSERT INTO preferences (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, args: [.text(key), .text(value), .double(Date().timeIntervalSince1970)])
    }

    func preference(_ key: String) -> String? {
        guard let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        var found: String?
        do {
            try Self.queryRows(db, sql: """
                SELECT value FROM preferences WHERE key = ? LIMIT 1
                """, args: [.text(key)]) { stmt in
                found = Self.textColumn(stmt, 0)
            }
        } catch { }
        return found
    }

    // MARK: - Row readers

    private struct Row {
        let id: String
    }

    private static func row(_ db: OpaquePointer, topicKey: String) -> Row? {
        var found: Row?
        do {
            try queryRows(db, sql: """
                SELECT id FROM problem_types WHERE topic_key = ? LIMIT 1
                """, args: [.text(topicKey)]) { stmt in
                found = Row(id: textColumn(stmt, 0))
            }
        } catch { }
        return found
    }

    private static func stat(_ stmt: OpaquePointer) -> ProblemTypeStat {
        ProblemTypeStat(
            id: textColumn(stmt, 0),
            domain: HomeworkDomain(rawValue: textColumn(stmt, 1)) ?? .cs,
            topic: textColumn(stmt, 2),
            struggles: intColumn(stmt, 3),
            solved: intColumn(stmt, 4),
            lastSeen: doubleColumn(stmt, 5),
            createdAt: doubleColumn(stmt, 6))
    }

    // MARK: - SQLite plumbing (mirrors ConceptMasteryTracker)

    private static func openDB(path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let db else {
            throw StoreError.database("could not open \(path) (\(rc))")
        }
        return db
    }

    private static func runMigration(_ db: OpaquePointer) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, migrationDDL, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StoreError.database(message)
        }
    }

    private enum StoreError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self {
            case .database(let message): return "homework store error: \(message)"
            }
        }
    }

    private enum Bind {
        case text(String)
        case double(Double)
        case int(Int)
    }

    private static func exec(_ db: OpaquePointer, sql: String, args: [Bind] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("[homework] exec prepare failed: %@", lastErrorMessage(db))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_CONSTRAINT {
            NSLog("[homework] exec step failed (%d): %@", rc, lastErrorMessage(db))
        }
    }

    private static func queryRows(_ db: OpaquePointer, sql: String, args: [Bind] = [],
                                  row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.database(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            row(stmt)
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {
            throw StoreError.database(lastErrorMessage(db))
        }
    }

    private static func bind(_ stmt: OpaquePointer, _ args: [Bind]) {
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            switch arg {
            case .text(let value):
                sqlite3_bind_text(stmt, i, value, -1, HOMEWORK_SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(stmt, i, value)
            case .int(let value):
                sqlite3_bind_int64(stmt, i, Int64(value))
            }
        }
    }

    private static func lastErrorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private static func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    private static func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    // MARK: - Text helpers

    static func nameKey(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
