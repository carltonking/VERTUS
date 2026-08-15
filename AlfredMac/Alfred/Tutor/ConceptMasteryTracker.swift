// MARK: - ConceptMasteryTracker
//
// The SQLite home for the Personal Tutor skill's learning data, in
// `~/.alfred/db/tutor.db` — separate from `memory.db` (the unified graph) and
// `mempalace.db` (the confidence-scored vault), so the tutor's writes never
// touch either schema. Raw sqlite3 with per-call FULLMUTEX connections, the
// same pattern OptimizationStore proved: a plain class, no actor, safe to
// call from any thread.
//
// Four tables:
//
//   * `concepts`     — one row per concept: 1–5 confidence, session and
//                      confusion counts, mastery timestamps. The spec's
//                      mastery trajectory lives here.
//   * `sessions`     — one row per tutoring interaction, outcome first
//                      written as `abandoned` (no signal yet) and filled in
//                      by `recordFeedback`. This is the training set the
//                      style analyzer and the DSPy bridge learn from.
//   * `prerequisites`— concept → prerequisite edges ("integration" →
//                      "derivatives"), injected into explanation prompts so
//                      the tutor builds on what the user already knows.
//   * `preferences`  — key/value scratch (currently the DSPy bridge's
//                      learned teaching directives).

import Foundation
import SQLite3

private let TUTOR_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ConceptMasteryTracker {

    static let shared = ConceptMasteryTracker()

    private static let defaultDatabasePath = NSHomeDirectory() + "/.alfred/db/tutor.db"

    private let databasePath: String

    init(databasePath: String = ConceptMasteryTracker.defaultDatabasePath) {
        self.databasePath = databasePath
        do {
            try FileManager.default.createDirectory(
                atPath: (databasePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let db = try Self.openDB(path: databasePath)
            defer { sqlite3_close(db) }
            try Self.runMigration(db)
        } catch {
            NSLog("[tutor] store init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Schema

    private static let migrationDDL = """
    CREATE TABLE IF NOT EXISTS concepts (
        id             TEXT PRIMARY KEY,
        name_key       TEXT NOT NULL UNIQUE,
        name           TEXT NOT NULL,
        course         TEXT,
        confidence     INTEGER NOT NULL DEFAULT 2,
        session_count  INTEGER NOT NULL DEFAULT 0,
        confused_count INTEGER NOT NULL DEFAULT 0,
        mastered_at    REAL,
        first_seen     REAL NOT NULL,
        last_seen      REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_concepts_confidence ON concepts(confidence);
    CREATE INDEX IF NOT EXISTS idx_concepts_last_seen ON concepts(last_seen);

    CREATE TABLE IF NOT EXISTS sessions (
        id         TEXT PRIMARY KEY,
        concept    TEXT NOT NULL,
        course     TEXT,
        mode       TEXT NOT NULL,
        method     TEXT NOT NULL,
        outcome    TEXT NOT NULL DEFAULT 'abandoned',
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_sessions_concept ON sessions(concept, created_at);
    CREATE INDEX IF NOT EXISTS idx_sessions_created ON sessions(created_at);

    CREATE TABLE IF NOT EXISTS prerequisites (
        concept      TEXT NOT NULL,
        prerequisite TEXT NOT NULL,
        PRIMARY KEY (concept, prerequisite)
    );

    CREATE TABLE IF NOT EXISTS preferences (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at REAL NOT NULL
    );
    """

    // MARK: - Concepts

    /// Look up one concept by name (case/whitespace-insensitive).
    func mastery(for name: String) -> ConceptMastery? {
        let key = Self.nameKey(name)
        guard !key.isEmpty, let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        var found: ConceptMastery?
        do {
            try Self.queryRows(db, sql: """
                SELECT id, name, course, confidence, session_count, confused_count,
                       mastered_at, first_seen, last_seen
                FROM concepts WHERE name_key = ? LIMIT 1
                """, args: [.text(key)]) { stmt in
                found = Self.concept(stmt)
            }
        } catch { }
        return found
    }

    /// Directly set a concept's confidence (the `track_mastery` tool — the
    /// user/agent tells Alfred the real level). Upserts the row and touches
    /// last_seen. Returns the updated concept.
    @discardableResult
    func setMastery(name: String, confidence: Int, course: String?) -> ConceptMastery? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = ConceptMastery.clampConfidence(confidence)
        guard !trimmed.isEmpty, let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        let now = Date().timeIntervalSince1970
        let key = Self.nameKey(trimmed)
        if let existing = mastery(for: trimmed) {
            Self.exec(db, sql: """
                UPDATE concepts SET confidence = ?, course = ?, last_seen = ?,
                       mastered_at = COALESCE(mastered_at, CASE WHEN ? >= 5 THEN ? ELSE NULL END)
                WHERE id = ?
                """, args: [.int(level), .text(course ?? existing.course ?? ""),
                            .double(now), .int(level), .double(now), .text(existing.id)])
        } else {
            let id = UUID().uuidString
            Self.exec(db, sql: """
                INSERT INTO concepts (id, name_key, name, course, confidence,
                                      session_count, confused_count, mastered_at, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
                """, args: [.text(id), .text(key), .text(trimmed), .text(course ?? ""),
                            .int(level), .double(level >= 5 ? now : 0),
                            .double(now), .double(now)])
        }
        return mastery(for: trimmed)
    }

    /// Record a tutoring interaction. Writes the session row (outcome still
    /// `abandoned` — no signal yet) and bumps the concept's session count.
    /// Returns the new session id so `recordFeedback` can resolve it later.
    @discardableResult
    func recordSession(concept: String, course: String?, mode: TutoringSessionMode,
                       method: TeachingMethod) -> String {
        let trimmed = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? Self.openDB(path: databasePath) else { return "" }
        defer { sqlite3_close(db) }
        let now = Date().timeIntervalSince1970
        let id = UUID().uuidString
        Self.exec(db, sql: """
            INSERT INTO sessions (id, concept, course, mode, method, outcome, created_at)
            VALUES (?, ?, ?, ?, ?, 'abandoned', ?)
            """, args: [.text(id), .text(trimmed), .text(course ?? ""),
                        .text(mode.rawValue), .text(method.rawValue), .double(now)])
        let key = Self.nameKey(trimmed)
        if let existing = mastery(for: trimmed) {
            Self.exec(db, sql: """
                UPDATE concepts SET session_count = session_count + 1, last_seen = ? WHERE id = ?
                """, args: [.double(now), .text(existing.id)])
        } else {
            let conceptID = UUID().uuidString
            Self.exec(db, sql: """
                INSERT INTO concepts (id, name_key, name, course, confidence,
                                      session_count, confused_count, mastered_at, first_seen, last_seen)
                VALUES (?, ?, ?, ?, 2, 1, 0, NULL, ?, ?)
                """, args: [.text(conceptID), .text(key), .text(trimmed),
                            .text(course ?? ""), .double(now), .double(now)])
        }
        return id
    }

    /// Fill in a pending session's outcome and move the concept's confidence:
    /// understood +1, confused −1 (floor 1), more detail / another angle
    /// unchanged. Returns the updated concept.
    @discardableResult
    func recordOutcome(sessionID: String, outcome: TutoringOutcome) -> ConceptMastery? {
        guard !sessionID.isEmpty, let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        guard let session = session(id: sessionID) else { return nil }
        Self.exec(db, sql: "UPDATE sessions SET outcome = ? WHERE id = ?",
                  args: [.text(outcome.rawValue), .text(sessionID)])
        guard let concept = mastery(for: session.concept) else { return nil }

        let delta: Int
        switch outcome {
        case .understood: delta = 1
        case .confused:   delta = -1
        case .moreDetail, .otherAngle, .abandoned: delta = 0
        }
        let newLevel = ConceptMastery.clampConfidence(concept.confidence + delta)
        let now = Date().timeIntervalSince1970
        Self.exec(db, sql: """
            UPDATE concepts SET confidence = ?,
                   confused_count = confused_count + ?,
                   mastered_at = COALESCE(mastered_at, CASE WHEN ? >= 5 THEN ? ELSE NULL END),
                   last_seen = ?
            WHERE id = ?
            """, args: [.int(newLevel),
                        .int(outcome == .confused ? 1 : 0),
                        .int(newLevel), .double(now), .double(now),
                        .text(concept.id)])
        return mastery(for: concept.name)
    }

    // MARK: - Weakness

    /// The concepts to work on, weakest first. Weakness = distance from
    /// mastery (5 − confidence), then how often the user reported confusion,
    /// then how long it's been since it was touched — the spec's "concepts
    /// you've asked about multiple times and still struggle with".
    func weakConcepts(limit: Int = 10) -> [ConceptMastery] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var rows: [ConceptMastery] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, name, course, confidence, session_count, confused_count,
                       mastered_at, first_seen, last_seen
                FROM concepts
                ORDER BY (5 - confidence) DESC, confused_count DESC, last_seen ASC
                LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.concept(stmt))
            }
        } catch { }
        return rows
    }

    /// Concepts at or near mastery (confidence ≥ 4), strongest first — the
    /// "strong areas" the weekly review reports.
    func strongConcepts(limit: Int = 10) -> [ConceptMastery] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var rows: [ConceptMastery] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, name, course, confidence, session_count, confused_count,
                       mastered_at, first_seen, last_seen
                FROM concepts
                WHERE confidence >= 4
                ORDER BY confidence DESC, session_count DESC
                LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.concept(stmt))
            }
        } catch { }
        return rows
    }

    func allConcepts(limit: Int = 200) -> [ConceptMastery] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var rows: [ConceptMastery] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, name, course, confidence, session_count, confused_count,
                       mastered_at, first_seen, last_seen
                FROM concepts ORDER BY last_seen DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.concept(stmt))
            }
        } catch { }
        return rows
    }

    /// Count of concepts the user has fully mastered (5/5).
    func masteredCount() -> Int {
        guard let db = try? Self.openDB(path: databasePath) else { return 0 }
        defer { sqlite3_close(db) }
        var count = 0
        do {
            try Self.queryRows(db, sql: "SELECT COUNT(*) FROM concepts WHERE confidence >= 5") { stmt in
                count = Self.intColumn(stmt, 0)
            }
        } catch { }
        return count
    }

    // MARK: - Sessions

    /// The latest session for a concept that hasn't received feedback yet —
    /// the one `recordFeedback` should resolve. Sessions store the trimmed
    /// concept name, so the match is case/whitespace-insensitive.
    func pendingSession(for concept: String) -> TutoringSessionRecord? {
        guard let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        var found: TutoringSessionRecord?
        do {
            try Self.queryRows(db, sql: """
                SELECT id, concept, course, mode, method, outcome, created_at
                FROM sessions
                WHERE lower(concept) = lower(?) AND outcome = 'abandoned'
                ORDER BY created_at DESC LIMIT 1
                """, args: [.text(concept)]) { stmt in
                found = Self.session(stmt)
            }
        } catch { }
        return found
    }

    func session(id: String) -> TutoringSessionRecord? {
        guard let db = try? Self.openDB(path: databasePath) else { return nil }
        defer { sqlite3_close(db) }
        var found: TutoringSessionRecord?
        do {
            try Self.queryRows(db, sql: """
                SELECT id, concept, course, mode, method, outcome, created_at
                FROM sessions WHERE id = ? LIMIT 1
                """, args: [.text(id)]) { stmt in
                found = Self.session(stmt)
            }
        } catch { }
        return found
    }

    /// Recent sessions, newest first — the style analyzer's training set.
    func recentSessions(limit: Int = 200) -> [TutoringSessionRecord] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var rows: [TutoringSessionRecord] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, concept, course, mode, method, outcome, created_at
                FROM sessions ORDER BY created_at DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.session(stmt))
            }
        } catch { }
        return rows
    }

    func sessionCount() -> Int {
        guard let db = try? Self.openDB(path: databasePath) else { return 0 }
        defer { sqlite3_close(db) }
        var count = 0
        do {
            try Self.queryRows(db, sql: "SELECT COUNT(*) FROM sessions") { stmt in
                count = Self.intColumn(stmt, 0)
            }
        } catch { }
        return count
    }

    // MARK: - Prerequisites

    /// Everything the user should already know before a concept is explained
    /// (e.g. "integration" → ["calculus basics", "derivatives"]).
    func prerequisites(for concept: String) -> [String] {
        guard let db = try? Self.openDB(path: databasePath) else { return [] }
        defer { sqlite3_close(db) }
        var rows: [String] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT prerequisite FROM prerequisites WHERE concept = ? ORDER BY prerequisite
                """, args: [.text(Self.nameKey(concept))]) { stmt in
                rows.append(Self.textColumn(stmt, 0))
            }
        } catch { }
        return rows
    }

    @discardableResult
    func setPrerequisite(_ prerequisite: String, for concept: String) -> Bool {
        let prereq = prerequisite.trimmingCharacters(in: .whitespacesAndNewlines)
        let conceptName = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prereq.isEmpty, !conceptName.isEmpty,
              let db = try? Self.openDB(path: databasePath) else { return false }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            INSERT OR IGNORE INTO prerequisites (concept, prerequisite) VALUES (?, ?)
            """, args: [.text(Self.nameKey(conceptName)), .text(prereq)])
        return true
    }

    // MARK: - Preferences (DSPy directives)

    /// Store the DSPy bridge's learned teaching directives as JSON.
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

    private static func concept(_ stmt: OpaquePointer) -> ConceptMastery {
        ConceptMastery(
            id: textColumn(stmt, 0),
            name: textColumn(stmt, 1),
            course: nullableTextColumn(stmt, 2),
            confidence: intColumn(stmt, 3),
            sessionCount: intColumn(stmt, 4),
            confusedCount: intColumn(stmt, 5),
            masteredAt: nullableDoubleColumn(stmt, 6),
            firstSeenAt: doubleColumn(stmt, 7),
            lastSeenAt: doubleColumn(stmt, 8))
    }

    private static func session(_ stmt: OpaquePointer) -> TutoringSessionRecord {
        TutoringSessionRecord(
            id: textColumn(stmt, 0),
            concept: textColumn(stmt, 1),
            course: nullableTextColumn(stmt, 2),
            mode: TutoringSessionMode(rawValue: textColumn(stmt, 3)) ?? .explain,
            method: TeachingMethod(rawValue: textColumn(stmt, 4)) ?? .direct,
            outcome: TutoringOutcome(rawValue: textColumn(stmt, 5)) ?? .abandoned,
            createdAt: doubleColumn(stmt, 6))
    }

    // MARK: - SQLite plumbing (mirrors OptimizationStore)

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
            case .database(let message): return "tutor store error: \(message)"
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
            NSLog("[tutor] exec prepare failed: %@", lastErrorMessage(db))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_CONSTRAINT {
            NSLog("[tutor] exec step failed (%d): %@", rc, lastErrorMessage(db))
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
                sqlite3_bind_text(stmt, i, value, -1, TUTOR_SQLITE_TRANSIENT)
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

    private static func nullableTextColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : textColumn(stmt, index)
    }

    private static func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    private static func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    private static func nullableDoubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    // MARK: - Text helpers

    static func nameKey(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
