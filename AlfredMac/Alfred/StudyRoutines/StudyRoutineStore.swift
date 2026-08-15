// MARK: - StudyRoutineStore
//
// The SQLite home for the Study Routines' data in `~/.alfred/study.db` —
// separate from `tutor.db` (mastery) and `nyu.db` (Canvas), so the routines'
// writes never touch another schema. Raw sqlite3 with per-call FULLMUTEX
// connections, the same pattern ConceptMasteryTracker and OptimizationStore
// proved: a plain class, no actor, safe to call from any thread.
//
// Tables:
//   * exam_preps      — one row per started exam-prep plan.
//   * problem_sets    — the set header (name, course, source, due).
//   * problems        — one row per problem, ordered easy → hard.
//   * readings        — reading assignments + spaced-repetition state.
//   * lectures        — summarized lecture notes.
//   * weekly_reviews  — the Sunday progress reports.
//
// Arrays (topics, key points, questions) are stored as JSON text, the same
// way the NYU store persists its grading breakdown.

import Foundation
import SQLite3

private let STUDY_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class StudyRoutineStore {

    private let databasePath: String

    init(databasePath: String = NSHomeDirectory() + "/.alfred/study.db") {
        self.databasePath = databasePath
        do {
            try FileManager.default.createDirectory(
                atPath: (databasePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let db = try Self.openDB(path: databasePath)
            defer { sqlite3_close(db) }
            try Self.runMigration(db)
        } catch {
            NSLog("[study] store init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Schema

    private static let migrationDDL = """
    CREATE TABLE IF NOT EXISTS exam_preps (
        id           TEXT PRIMARY KEY,
        course       TEXT,
        exam_date    REAL,
        topics       TEXT NOT NULL DEFAULT '[]',
        drills_run   INTEGER NOT NULL DEFAULT 0,
        last_run_at  REAL,
        created_at   REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS problem_sets (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        course        TEXT,
        source        TEXT NOT NULL DEFAULT 'manual',
        assignment_id INTEGER,
        due_at        REAL,
        created_at    REAL NOT NULL,
        updated_at    REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_problem_sets_updated ON problem_sets(updated_at);

    CREATE TABLE IF NOT EXISTS problems (
        id         TEXT PRIMARY KEY,
        set_id     TEXT NOT NULL,
        text       TEXT NOT NULL,
        difficulty INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL DEFAULT 0,
        status     TEXT NOT NULL DEFAULT 'unsolved',
        concept    TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_problems_set ON problems(set_id, sort_order);

    CREATE TABLE IF NOT EXISTS readings (
        id           TEXT PRIMARY KEY,
        title        TEXT NOT NULL,
        course       TEXT,
        key_points   TEXT NOT NULL DEFAULT '[]',
        questions    TEXT NOT NULL DEFAULT '[]',
        quiz_score   REAL,
        streak       INTEGER NOT NULL DEFAULT 0,
        interval_days REAL NOT NULL DEFAULT 1,
        last_quiz_at REAL,
        next_due_at  REAL,
        created_at   REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS lectures (
        id         TEXT PRIMARY KEY,
        title      TEXT NOT NULL,
        course     TEXT,
        summary    TEXT NOT NULL DEFAULT '',
        key_points TEXT NOT NULL DEFAULT '[]',
        questions  TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_lectures_created ON lectures(created_at);

    CREATE TABLE IF NOT EXISTS weekly_reviews (
        id         TEXT PRIMARY KEY,
        week_start REAL NOT NULL,
        strong     TEXT NOT NULL DEFAULT '[]',
        weak       TEXT NOT NULL DEFAULT '[]',
        focus      TEXT NOT NULL DEFAULT '[]',
        summary    TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL
    );
    """

    // MARK: - Exam prep plans

    @discardableResult
    func upsertExamPrep(id: String, course: String?, examDate: TimeInterval?,
                        topics: [String]) -> ExamPrepPlan {
        let now = Date().timeIntervalSince1970
        let topicsJSON = Self.jsonString(topics)
        if let existing = examPrep(id: id) {
            Self.withDB(path: databasePath) { db in
                Self.exec(db, sql: """
                    UPDATE exam_preps SET course = ?, exam_date = ?, topics = ? WHERE id = ?
                    """, args: [.text(course ?? existing.course ?? ""),
                                .optionalDouble(examDate ?? existing.examDate),
                                .text(topicsJSON), .text(id)])
            }
        } else {
            Self.withDB(path: databasePath) { db in
                Self.exec(db, sql: """
                    INSERT INTO exam_preps (id, course, exam_date, topics, drills_run, last_run_at, created_at)
                    VALUES (?, ?, ?, ?, 0, NULL, ?)
                    """, args: [.text(id), .text(course ?? ""),
                                .optionalDouble(examDate), .text(topicsJSON), .double(now)])
            }
        }
        return examPrep(id: id) ?? ExamPrepPlan(
            id: id, course: course, examDate: examDate, topics: topics,
            drillsRun: 0, lastRunAt: nil, createdAt: now)
    }

    func examPrep(id: String) -> ExamPrepPlan? {
        var found: ExamPrepPlan?
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, course, exam_date, topics, drills_run, last_run_at, created_at
                FROM exam_preps WHERE id = ? LIMIT 1
                """, args: [.text(id)]) { stmt in
                found = ExamPrepPlan(
                    id: Self.textColumn(stmt, 0),
                    course: Self.nullableTextColumn(stmt, 1),
                    examDate: Self.nullableDoubleColumn(stmt, 2),
                    topics: Self.stringArray(Self.textColumn(stmt, 3)),
                    drillsRun: Self.intColumn(stmt, 4),
                    lastRunAt: Self.nullableDoubleColumn(stmt, 5),
                    createdAt: Self.doubleColumn(stmt, 6))
            }
        }
        return found
    }

    func activeExamPreps(now: TimeInterval = Date().timeIntervalSince1970) -> [ExamPrepPlan] {
        var rows: [ExamPrepPlan] = []
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, course, exam_date, topics, drills_run, last_run_at, created_at
                FROM exam_preps
                WHERE exam_date IS NULL OR exam_date >= ?
                ORDER BY exam_date ASC
                """, args: [.double(now)]) { stmt in
                rows.append(ExamPrepPlan(
                    id: Self.textColumn(stmt, 0),
                    course: Self.nullableTextColumn(stmt, 1),
                    examDate: Self.nullableDoubleColumn(stmt, 2),
                    topics: Self.stringArray(Self.textColumn(stmt, 3)),
                    drillsRun: Self.intColumn(stmt, 4),
                    lastRunAt: Self.nullableDoubleColumn(stmt, 5),
                    createdAt: Self.doubleColumn(stmt, 6)))
            }
        }
        return rows
    }

    func recordDrill(id: String) {
        let now = Date().timeIntervalSince1970
        Self.withDB(path: databasePath) { db in
            Self.exec(db, sql: """
                UPDATE exam_preps SET drills_run = drills_run + 1, last_run_at = ? WHERE id = ?
                """, args: [.double(now), .text(id)])
        }
    }

    // MARK: - Problem sets

    @discardableResult
    func upsertProblemSet(_ set: ProblemSet) -> ProblemSet {
        let now = Date().timeIntervalSince1970
        let exists = problemSet(id: set.id) != nil
        Self.withDB(path: databasePath) { db in
            Self.exec(db, sql: """
                INSERT INTO problem_sets (id, name, course, source, assignment_id, due_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, course = excluded.course, source = excluded.source,
                    assignment_id = excluded.assignment_id, due_at = excluded.due_at,
                    updated_at = excluded.updated_at
                """, args: [.text(set.id), .text(set.name), .text(set.course ?? ""),
                            .text(set.source), .optionalInt(set.assignmentID),
                            .optionalDouble(set.dueAt),
                            .double(exists ? set.createdAt : now), .double(now)])
            // Replace the problem rows so a re-parse stays in sync.
            Self.exec(db, sql: "DELETE FROM problems WHERE set_id = ?", args: [.text(set.id)])
            for problem in set.problems {
                Self.exec(db, sql: """
                    INSERT INTO problems (id, set_id, text, difficulty, sort_order, status, concept)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, args: [.text(problem.id), .text(set.id), .text(problem.text),
                                .int(problem.difficulty), .int(problem.order),
                                .text(problem.status.rawValue), .text(problem.concept ?? "")])
            }
        }
        return problemSet(id: set.id) ?? set
    }

    func problemSet(id: String) -> ProblemSet? {
        var header: (name: String, course: String?, source: String, assignmentID: Int?, dueAt: TimeInterval?, createdAt: TimeInterval, updatedAt: TimeInterval)?
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT name, course, source, assignment_id, due_at, created_at, updated_at
                FROM problem_sets WHERE id = ? LIMIT 1
                """, args: [.text(id)]) { stmt in
                header = (Self.textColumn(stmt, 0),
                          Self.nullableTextColumn(stmt, 1),
                          Self.textColumn(stmt, 2),
                          Self.nullableIntColumn(stmt, 3),
                          Self.nullableDoubleColumn(stmt, 4),
                          Self.doubleColumn(stmt, 5),
                          Self.doubleColumn(stmt, 6))
            }
        }
        guard let header else { return nil }
        let problems = problems(setID: id)
        return ProblemSet(
            id: id, name: header.name, course: header.course, source: header.source,
            assignmentID: header.assignmentID, dueAt: header.dueAt,
            problems: problems, createdAt: header.createdAt, updatedAt: header.updatedAt)
    }

    func listProblemSets(limit: Int = 100) -> [ProblemSet] {
        var ids: [String] = []
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id FROM problem_sets ORDER BY updated_at DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                ids.append(Self.textColumn(stmt, 0))
            }
        }
        return ids.compactMap { problemSet(id: $0) }
    }

    /// One problem set row + its problems. Updates both tables in one place.
    func setProblemStatus(problemID: String, status: ProblemStatus) -> ProblemSet? {
        Self.withDB(path: databasePath) { db in
            Self.exec(db, sql: "UPDATE problems SET status = ? WHERE id = ?",
                      args: [.text(status.rawValue), .text(problemID)])
        }
        guard let setID = problemSetID(forProblem: problemID) else { return nil }
        return problemSet(id: setID)
    }

    func problemSetID(forProblem problemID: String) -> String? {
        var found: String?
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: "SELECT set_id FROM problems WHERE id = ? LIMIT 1",
                                args: [.text(problemID)]) { stmt in
                found = Self.textColumn(stmt, 0)
            }
        }
        return found
    }

    private func problems(setID: String) -> [ProblemItem] {
        var rows: [ProblemItem] = []
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, text, difficulty, sort_order, status, concept
                FROM problems WHERE set_id = ? ORDER BY sort_order ASC
                """, args: [.text(setID)]) { stmt in
                rows.append(ProblemItem(
                    id: Self.textColumn(stmt, 0),
                    text: Self.textColumn(stmt, 1),
                    difficulty: Self.intColumn(stmt, 2),
                    order: Self.intColumn(stmt, 3),
                    status: ProblemStatus(rawValue: Self.textColumn(stmt, 4)) ?? .unsolved,
                    concept: Self.nullableTextColumn(stmt, 5)))
            }
        }
        return rows
    }

    // MARK: - Readings

    @discardableResult
    func upsertReading(_ assignment: ReadingAssignment) -> ReadingAssignment {
        Self.withDB(path: databasePath) { db in
            Self.exec(db, sql: """
                INSERT INTO readings (id, title, course, key_points, questions, quiz_score,
                                      streak, interval_days, last_quiz_at, next_due_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title, course = excluded.course,
                    key_points = excluded.key_points, questions = excluded.questions,
                    quiz_score = excluded.quiz_score, streak = excluded.streak,
                    interval_days = excluded.interval_days, last_quiz_at = excluded.last_quiz_at,
                    next_due_at = excluded.next_due_at
                """, args: [.text(assignment.id), .text(assignment.title), .text(assignment.course ?? ""),
                            .text(Self.jsonString(assignment.keyPoints)),
                            .text(Self.jsonString(assignment.questions)),
                            .optionalDouble(assignment.quizScore), .int(assignment.streak),
                            .double(assignment.intervalDays),
                            .optionalDouble(assignment.lastQuizAt),
                            .optionalDouble(assignment.nextDueAt),
                            .double(assignment.createdAt)])
        }
        return reading(id: assignment.id) ?? assignment
    }

    func reading(id: String) -> ReadingAssignment? {
        var found: ReadingAssignment?
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, title, course, key_points, questions, quiz_score, streak,
                       interval_days, last_quiz_at, next_due_at, created_at
                FROM readings WHERE id = ? LIMIT 1
                """, args: [.text(id)]) { stmt in
                found = Self.reading(stmt)
            }
        }
        return found
    }

    func listReadings(limit: Int = 200) -> [ReadingAssignment] {
        var rows: [ReadingAssignment] = []
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, title, course, key_points, questions, quiz_score, streak,
                       interval_days, last_quiz_at, next_due_at, created_at
                FROM readings ORDER BY created_at DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.reading(stmt))
            }
        }
        return rows
    }

    /// Readings whose spaced-repetition window is open (nextDueAt <= now).
    func readingsDue(now: TimeInterval = Date().timeIntervalSince1970) -> [ReadingAssignment] {
        listReadings().filter { $0.nextDueAt.map { $0 <= now } ?? true }
    }

    func latestReading(id: String) -> ReadingAssignment? { reading(id: id) }

    // MARK: - Lectures

    @discardableResult
    func upsertLecture(_ lecture: LectureNote) -> LectureNote {
        Self.withDB(path: databasePath) { db in
            Self.exec(db, sql: """
                INSERT OR REPLACE INTO lectures (id, title, course, summary, key_points, questions, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, args: [.text(lecture.id), .text(lecture.title), .text(lecture.course ?? ""),
                            .text(lecture.summary), .text(Self.jsonString(lecture.keyPoints)),
                            .text(Self.jsonString(lecture.questions)),
                            .double(lecture.createdAt)])
        }
        return lecture
    }

    func listLectures(since: TimeInterval? = nil, limit: Int = 100) -> [LectureNote] {
        var rows: [LectureNote] = []
        let floor = since ?? 0
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, title, course, summary, key_points, questions, created_at
                FROM lectures WHERE created_at >= ? ORDER BY created_at DESC LIMIT ?
                """, args: [.double(floor), .int(limit)]) { stmt in
                rows.append(LectureNote(
                    id: Self.textColumn(stmt, 0),
                    title: Self.textColumn(stmt, 1),
                    course: Self.nullableTextColumn(stmt, 2),
                    summary: Self.textColumn(stmt, 3),
                    keyPoints: Self.stringArray(Self.textColumn(stmt, 4)),
                    questions: Self.stringArray(Self.textColumn(stmt, 5)),
                    createdAt: Self.doubleColumn(stmt, 6)))
            }
        }
        return rows
    }

    // MARK: - Weekly reviews

    @discardableResult
    func addWeeklyReview(_ report: WeeklyReviewReport) -> WeeklyReviewReport {
        Self.withDB(path: databasePath) { db in
            Self.exec(db, sql: """
                INSERT OR REPLACE INTO weekly_reviews (id, week_start, strong, weak, focus, summary, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, args: [.text(report.id), .double(report.weekStart),
                            .text(Self.jsonString(report.strong)),
                            .text(Self.jsonString(report.weak)),
                            .text(Self.jsonString(report.focusNextWeek)),
                            .text(report.summary), .double(report.createdAt)])
        }
        return report
    }

    func latestWeeklyReview() -> WeeklyReviewReport? {
        var found: WeeklyReviewReport?
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, week_start, strong, weak, focus, summary, created_at
                FROM weekly_reviews ORDER BY week_start DESC LIMIT 1
                """) { stmt in
                found = WeeklyReviewReport(
                    id: Self.textColumn(stmt, 0),
                    weekStart: Self.doubleColumn(stmt, 1),
                    strong: Self.stringArray(Self.textColumn(stmt, 2)),
                    weak: Self.stringArray(Self.textColumn(stmt, 3)),
                    focusNextWeek: Self.stringArray(Self.textColumn(stmt, 4)),
                    summary: Self.textColumn(stmt, 5),
                    createdAt: Self.doubleColumn(stmt, 6))
            }
        }
        return found
    }

    func weeklyReview(forWeekStart weekStart: TimeInterval) -> WeeklyReviewReport? {
        var found: WeeklyReviewReport?
        Self.withDB(path: databasePath) { db in
            try? Self.queryRows(db, sql: """
                SELECT id, week_start, strong, weak, focus, summary, created_at
                FROM weekly_reviews WHERE week_start = ? LIMIT 1
                """, args: [.double(weekStart)]) { stmt in
                found = WeeklyReviewReport(
                    id: Self.textColumn(stmt, 0),
                    weekStart: Self.doubleColumn(stmt, 1),
                    strong: Self.stringArray(Self.textColumn(stmt, 2)),
                    weak: Self.stringArray(Self.textColumn(stmt, 3)),
                    focusNextWeek: Self.stringArray(Self.textColumn(stmt, 4)),
                    summary: Self.textColumn(stmt, 5),
                    createdAt: Self.doubleColumn(stmt, 6))
            }
        }
        return found
    }

    // MARK: - Row reader

    private static func reading(_ stmt: OpaquePointer) -> ReadingAssignment {
        ReadingAssignment(
            id: textColumn(stmt, 0),
            title: textColumn(stmt, 1),
            course: nullableTextColumn(stmt, 2),
            keyPoints: stringArray(textColumn(stmt, 3)),
            questions: stringArray(textColumn(stmt, 4)),
            quizScore: nullableDoubleColumn(stmt, 5),
            streak: intColumn(stmt, 6),
            intervalDays: doubleColumn(stmt, 7),
            lastQuizAt: nullableDoubleColumn(stmt, 8),
            nextDueAt: nullableDoubleColumn(stmt, 9),
            createdAt: doubleColumn(stmt, 10))
    }

    // MARK: - SQLite plumbing (mirrors ConceptMasteryTracker)

    private enum StoreError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self {
            case .database(let message): return "study store error: \(message)"
            }
        }
    }

    private enum Bind {
        case text(String)
        case double(Double)
        case optionalDouble(Double?)
        case int(Int)
        case optionalInt(Int?)
    }

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

    private static func withDB(path: String, _ body: (OpaquePointer) -> Void) {
        guard let db = try? openDB(path: path) else { return }
        defer { sqlite3_close(db) }
        body(db)
    }

    private static func exec(_ db: OpaquePointer, sql: String, args: [Bind] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("[study] exec prepare failed: %@", lastErrorMessage(db))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_CONSTRAINT {
            NSLog("[study] exec step failed (%d): %@", rc, lastErrorMessage(db))
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
                sqlite3_bind_text(stmt, i, value, -1, STUDY_SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(stmt, i, value)
            case .optionalDouble(let value):
                if let value { sqlite3_bind_double(stmt, i, value) }
                else { sqlite3_bind_null(stmt, i) }
            case .int(let value):
                sqlite3_bind_int64(stmt, i, Int64(value))
            case .optionalInt(let value):
                if let value { sqlite3_bind_int64(stmt, i, Int64(value)) }
                else { sqlite3_bind_null(stmt, i) }
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

    private static func nullableIntColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : intColumn(stmt, index)
    }

    private static func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    private static func nullableDoubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    // MARK: - JSON helpers

    private static func jsonString(_ array: [String]) -> String {
        guard let data = try? JSONEncoder().encode(array) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func stringArray(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }
}
