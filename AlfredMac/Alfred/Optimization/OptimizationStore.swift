// MARK: - OptimizationStore
//
// The SQLite home for the self-optimization loop's data — feedback, learned
// rules and compile-run history — in `~/.alfred/db/optimization.db`, separate
// from `memory.db` so the loop's writes never touch the unified memory graph's
// schema. Raw sqlite3 with per-call FULLMUTEX connections, the same pattern
// UnifiedMemoryLayer proved: a plain class, no actor, safe to call from any
// thread.

import Foundation
import SQLite3

private let OPT_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class OptimizationStore {

    static let shared = OptimizationStore()

    private static let defaultDatabasePath = NSHomeDirectory() + "/.alfred/db/optimization.db"

    private let databasePath: String

    init(databasePath: String = OptimizationStore.defaultDatabasePath) {
        self.databasePath = databasePath
        do {
            try FileManager.default.createDirectory(
                atPath: (databasePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let db = try Self.openDB(path: databasePath)
            defer { sqlite3_close(db) }
            try Self.runMigration(db)
        } catch {
            NSLog("[optimization] store init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Schema

    /// Idempotent DDL. `feedback` is the training set; `rules` are the active
    /// learned directives (one row per rule, versioned); `runs` is the audit
    /// trail every compile pass leaves so a bad version can be rolled back and
    /// the trend can be reported honestly.
    private static let migrationDDL = """
    CREATE TABLE IF NOT EXISTS feedback (
        id          TEXT PRIMARY KEY,
        kind        TEXT NOT NULL,
        prompt      TEXT NOT NULL,
        output      TEXT NOT NULL,
        rating      INTEGER NOT NULL,
        edited      INTEGER NOT NULL DEFAULT 0,
        context     TEXT,
        timestamp   REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_feedback_kind_time ON feedback(kind, timestamp);
    CREATE INDEX IF NOT EXISTS idx_feedback_time ON feedback(timestamp);

    CREATE TABLE IF NOT EXISTS rules (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        kind        TEXT NOT NULL,
        rule        TEXT NOT NULL,
        confidence  REAL NOT NULL DEFAULT 0.5,
        source      TEXT NOT NULL DEFAULT 'heuristic',
        version     INTEGER NOT NULL,
        active      INTEGER NOT NULL DEFAULT 1,
        created_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_rules_kind_active ON rules(kind, active);

    CREATE TABLE IF NOT EXISTS runs (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        kind        TEXT NOT NULL,
        version     INTEGER NOT NULL,
        before      REAL NOT NULL,
        after       REAL NOT NULL,
        examples    INTEGER NOT NULL,
        applied     INTEGER NOT NULL DEFAULT 0,
        rolled_back INTEGER NOT NULL DEFAULT 0,
        source      TEXT NOT NULL DEFAULT 'heuristic',
        created_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_runs_kind ON runs(kind, created_at);
    """

    // MARK: - Feedback

    func insertFeedback(_ entry: FeedbackEntry) {
        guard let db = try? Self.openDB(path: databasePath) else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            INSERT INTO feedback (id, kind, prompt, output, rating, edited, context, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, args: [
                .text(entry.id), .text(entry.kind.rawValue), .text(entry.prompt),
                .text(entry.output), .int(entry.rating), .int(entry.edited ? 1 : 0),
                entry.context.map { .text($0) } ?? .null, .double(entry.timestamp),
            ])
    }

    func feedback(since: TimeInterval, kind: OptimizationKind? = nil) -> [FeedbackEntry] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var out: [FeedbackEntry] = []
        var sql = """
            SELECT id, kind, prompt, output, rating, edited, context, timestamp
            FROM feedback WHERE timestamp >= ?
            """
        var args: [Bind] = [.double(since)]
        if let kind {
            sql += " AND kind = ?"
            args.append(.text(kind.rawValue))
        }
        sql += " ORDER BY timestamp ASC"
        do {
            try Self.queryRows(db, sql: sql, args: args) { stmt in
                guard let kind = OptimizationKind(rawValue: Self.textColumn(stmt, 1)) else { return }
                out.append(FeedbackEntry(
                    kind: kind,
                    prompt: Self.textColumn(stmt, 2),
                    output: Self.textColumn(stmt, 3),
                    rating: Self.intColumn(stmt, 4),
                    edited: Self.intColumn(stmt, 5) != 0,
                    context: Self.nullableTextColumn(stmt, 6),
                    timestamp: Self.doubleColumn(stmt, 7)))
            }
        } catch { }
        return out
    }

    func feedbackCount(since: TimeInterval) -> Int {
        guard let db = try? Self.openDB(path: databasePath) else { return 0 }
        defer { sqlite3_close(db) }
        var count = 0
        do {
            try Self.queryRows(db, sql: "SELECT COUNT(*) FROM feedback WHERE timestamp >= ?",
                               args: [.double(since)]) { stmt in
                count = Self.intColumn(stmt, 0)
            }
        } catch { }
        return count
    }

    // MARK: - Aggregates

    /// Average rating and sample count for a kind within a time window. The
    /// `edited` email signal is folded in: an edited draft counts as one point
    /// below its rating, so "sent as-is" is the real win the loop optimizes for.
    func aggregate(kind: OptimizationKind, since: TimeInterval) -> (average: Double, count: Int) {
        let entries = feedback(since: since, kind: kind)
        guard !entries.isEmpty else { return (0, 0) }
        let total = entries.reduce(0.0) { sum, entry in
            sum + (entry.kind == .email && entry.edited ? Double(max(1, entry.rating - 1)) : Double(entry.rating))
        }
        return (total / Double(entries.count), entries.count)
    }

    // MARK: - Rules

    /// Deactivate the current rule set for a kind and install the new one under
    /// a fresh version. Atomic enough for this loop: both writes happen on one
    /// connection, so a crash between them leaves either the old rules active
    /// or none — never a half-installed set.
    func installRules(_ rules: [OptimizationRule], kind: OptimizationKind, version: Int, source: String) {
        guard let db = try? Self.openDB(path: databasePath) else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: "UPDATE rules SET active = 0 WHERE kind = ?",
                  args: [.text(kind.rawValue)])
        let now = Date().timeIntervalSince1970
        for rule in rules {
            Self.exec(db, sql: """
                INSERT INTO rules (kind, rule, confidence, source, version, active, created_at)
                VALUES (?, ?, ?, ?, ?, 1, ?)
                """, args: [
                    .text(kind.rawValue), .text(rule.rule), .double(rule.confidence),
                    .text(source), .int(version), .double(now),
                ])
        }
    }

    func activeRules(kind: OptimizationKind) -> [OptimizationRule] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var out: [OptimizationRule] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT kind, rule, confidence, source, version FROM rules
                WHERE kind = ? AND active = 1 ORDER BY confidence DESC
                """, args: [.text(kind.rawValue)]) { stmt in
                guard let k = OptimizationKind(rawValue: Self.textColumn(stmt, 0)) else { return }
                out.append(OptimizationRule(
                    kind: k,
                    rule: Self.textColumn(stmt, 1),
                    confidence: Self.doubleColumn(stmt, 2),
                    source: Self.textColumn(stmt, 3),
                    version: Self.intColumn(stmt, 4)))
            }
        } catch { }
        return out
    }

    /// Every active rule across all kinds, flattened to their directive text —
    /// what the briefing card and report show as "active optimizations".
    func allActiveDirectives() -> [String] {
        OptimizationKind.allCases.flatMap { kind in
            activeRules(kind: kind).map(\.directive)
        }
    }

    func latestVersion(kind: OptimizationKind) -> Int {
        guard let db = try? Self.openDB(path: databasePath) else { return 0 }
        defer { sqlite3_close(db) }
        var version = 0
        do {
            try Self.queryRows(db, sql: """
                SELECT MAX(version) FROM rules WHERE kind = ?
                """, args: [.text(kind.rawValue)]) { stmt in
                version = Self.intColumn(stmt, 0)
            }
        } catch { }
        return version
    }

    /// Roll a kind back to the given version (or deactivate everything when
    /// version is 0 — "revert to baseline"). Returns true when rules existed to
    /// reactivate or the deactivation ran.
    @discardableResult
    func rollback(kind: OptimizationKind, to version: Int) -> Bool {
        guard let db = try? Self.openDB(path: databasePath) else { return false }
        defer { sqlite3_close(db) }
        if version <= 0 {
            Self.exec(db, sql: "UPDATE rules SET active = 0 WHERE kind = ?",
                      args: [.text(kind.rawValue)])
            return true
        }
        Self.exec(db, sql: "UPDATE rules SET active = 0 WHERE kind = ?",
                  args: [.text(kind.rawValue)])
        Self.exec(db, sql: "UPDATE rules SET active = 1 WHERE kind = ? AND version = ?",
                  args: [.text(kind.rawValue), .int(version)])
        return true
    }

    /// The version immediately below the current one for a kind — the rollback
    /// target when the newest compile regressed.
    func previousVersion(kind: OptimizationKind) -> Int {
        guard let db = try? Self.openDB(path: databasePath) else { return 0 }
        defer { sqlite3_close(db) }
        var versions: [Int] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT DISTINCT version FROM rules WHERE kind = ? ORDER BY version DESC LIMIT 2
                """, args: [.text(kind.rawValue)]) { stmt in
                versions.append(Self.intColumn(stmt, 0))
            }
        } catch { }
        return versions.count > 1 ? versions[1] : 0
    }

    // MARK: - Runs

    func insertRun(_ run: OptimizationRunRecord) {
        guard let db = try? Self.openDB(path: databasePath) else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            INSERT INTO runs (kind, version, before, after, examples, applied, rolled_back, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, args: [
                .text(run.kind), .int(run.version), .double(run.before), .double(run.after),
                .int(run.examples), .int(run.applied ? 1 : 0),
                .int(run.rolledBack ? 1 : 0), .text(run.source), .double(run.createdAt),
            ])
    }

    func markRolledBack(kind: String, version: Int) {
        guard let db = try? Self.openDB(path: databasePath) else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: "UPDATE runs SET rolled_back = 1 WHERE kind = ? AND version = ?",
                  args: [.text(kind), .int(version)])
    }

    /// Fill in a pending run's measured `after` average once the next compile
    /// has ratings to judge it with.
    func updateRunAfter(kind: String, version: Int, after: Double) {
        guard let db = try? Self.openDB(path: databasePath) else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: "UPDATE runs SET after = ? WHERE kind = ? AND version = ?",
                  args: [.double(after), .text(kind), .int(version)])
    }

    func lastRun(kind: OptimizationKind) -> OptimizationRunRecord? {
        guard let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        var found: OptimizationRunRecord?
        do {
            try Self.queryRows(db, sql: """
                SELECT kind, version, before, after, examples, applied, rolled_back, source, created_at
                FROM runs WHERE kind = ? ORDER BY created_at DESC LIMIT 1
                """, args: [.text(kind.rawValue)]) { stmt in
                found = Self.runRecord(stmt)
            }
        } catch { }
        return found
    }

    /// The most recent run across any kind (for the report's "last compiled").
    func mostRecentRun() -> OptimizationRunRecord? {
        guard let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        var found: OptimizationRunRecord?
        do {
            try Self.queryRows(db, sql: """
                SELECT kind, version, before, after, examples, applied, rolled_back, source, created_at
                FROM runs ORDER BY created_at DESC LIMIT 1
                """) { stmt in
                found = Self.runRecord(stmt)
            }
        } catch { }
        return found
    }

    private static func runRecord(_ stmt: OpaquePointer) -> OptimizationRunRecord {
        OptimizationRunRecord(
            kind: textColumn(stmt, 0),
            version: intColumn(stmt, 1),
            before: doubleColumn(stmt, 2),
            after: doubleColumn(stmt, 3),
            examples: intColumn(stmt, 4),
            applied: intColumn(stmt, 5) != 0,
            rolledBack: intColumn(stmt, 6) != 0,
            source: textColumn(stmt, 7),
            createdAt: doubleColumn(stmt, 8))
    }

    // MARK: - SQLite plumbing

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
            case .database(let message): return "optimization store error: \(message)"
            }
        }
    }

    private enum Bind {
        case text(String)
        case double(Double)
        case int(Int)
        case null
    }

    private static func exec(_ db: OpaquePointer, sql: String, args: [Bind] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("[optimization] exec prepare failed: %@", lastErrorMessage(db))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_CONSTRAINT {
            NSLog("[optimization] exec step failed (%d): %@", rc, lastErrorMessage(db))
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
                sqlite3_bind_text(stmt, i, value, -1, OPT_SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(stmt, i, value)
            case .int(let value):
                sqlite3_bind_int64(stmt, i, Int64(value))
            case .null:
                sqlite3_bind_null(stmt, i)
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

    private static func nullableTextColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : textColumn(stmt, index)
    }

    private static func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    private static func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }
}
