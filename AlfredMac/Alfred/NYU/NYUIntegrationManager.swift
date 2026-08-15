//
//  NYUIntegrationManager.swift
//  Alfred
//
//  The NYU coursework command center: Canvas sync → SQLite store → briefing
//  lines, deadline reminders and calendar events.
//
//  What Alfred does with the semester, end to end:
//
//   * **Sync** (`syncNow`) pulls courses, assignments, grades, announcements
//     and class-meeting calendar events from Canvas (NYUCanvasClient), upserts
//     them into `~/.alfred/nyu.db`, and runs the downstream passes — deadline
//     notification scheduling, EventKit calendar events, MemPalace syllabus
//     facts, and the sync broadcast to phones.
//   * **Deadline reminders** are scheduled as UNCalendarNotificationTrigger
//     notifications (24h and 1h before each due date, opt-in per window) and
//     re-scheduled from the store on every sync and on the hourly tick, so a
//     restart can't lose them. Marking an assignment submitted cancels its
//     pending reminders and removes its calendar due-event.
//   * **Calendar sync** (opt-in) mirrors class meetings (title, time,
//     location) and assignment due dates into the Mac's system calendar via
//     EventKit. Events Alfred created are tracked by key in the DB, so a
//     re-sync updates them instead of duplicating — and they're the only
//     events the manager ever touches.
//   * **Briefing** gets two optional lines — assignments (overdue + due this
//     week + next due) and grades (per-course score with trend) — nil while
//     the semester is empty, exactly like the job-hunt line.
//   * **MemPalace** receives the extractable syllabus facts (grading
//     breakdown percentages, the final exam date) as `learning` memories, so
//     "what's the final exam date?" is answerable from the vault too.
//
//  Persistence follows the sibling managers: SQLite (like MemPalace) for the
//  structured store, UserDefaults for settings. The Canvas token is stored in
//  UserDefaults like every other setting — Keychain storage is a stated
//  follow-up, not silently half-done.
//
//  Threading: @MainActor like CareerOpsManager; the network phase runs async
//  off the actor, and the SQLite helpers open per-call connections.

import EventKit
import Foundation
import SQLite3
import UserNotifications

private let NYU_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Models

/// How one assignment stands. `not_started` / `in_progress` are the owner's
/// own tracking; `submitted` / `graded` are what Canvas reports.
enum AssignmentStatus: String, Codable, CaseIterable, Identifiable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case submitted
    case graded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .submitted: return "Submitted"
        case .graded: return "Graded"
        }
    }
}

/// The NYU integration's settings. Persisted through NYUIntegrationManager
/// (UserDefaults); Codable so it can cross the wire to the phone.
struct NYUSettings: Codable, Equatable {
    var enabled: Bool = false
    /// Canvas personal access token. Empty = not configured.
    var canvasToken: String = ""
    /// The grade-watch floor: notifications fire when a course's score drops
    /// below this. 0 disables the grade watch.
    var targetGPA: Double = 0
    /// How often the sync runs: hours (1, 6, 24).
    var syncFrequencyHours: Int = 6
    var remind24h: Bool = true
    var remind1h: Bool = true
    /// Mirror class meetings + due dates into the system calendar.
    var calendarSyncEnabled: Bool = false
}

/// One assignment as stored, with its course name joined in for display.
struct NYUAssignmentRow: Codable, Equatable, Identifiable {
    var id: Int
    var courseID: Int
    var courseName: String
    var name: String
    var details: String
    var dueAt: TimeInterval?
    var points: Double
    var status: String
    var submittedAt: TimeInterval?
    var score: Double?
    var url: String
    /// dueAt passed and not submitted/graded.
    var isOverdue: Bool
    /// Whole days until due (negative = overdue); nil when no due date.
    var daysUntil: Int?
}

/// A course as stored, with the pieces the phone's Grades list shows.
struct NYUCourseRow: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var code: String
    var term: String
    var professor: String
    var syllabus: String
    var currentScore: Double?
    var previousScore: Double?
    var projectedScore: Double?
    var finalExamAt: TimeInterval?
    var gradingBreakdown: [String: Double]
    var officeHours: String
    var schedule: String

    /// "improving" | "declining" | "steady" | "new" — from the last sync's
    /// score delta. Used by the briefing line and the grades list.
    var trend: String {
        guard let current = currentScore, let previous = previousScore else {
            return "new"
        }
        if current > previous + 0.25 { return "improving" }
        if current < previous - 0.25 { return "declining" }
        return "steady"
    }
}

/// What one sync pass produced — for the phone's status row and the routine
/// step's output.
struct NYUSyncResult: Codable, Equatable {
    var success: Bool
    var message: String
    var courses: Int
    var assignments: Int
    var announcements: Int
    var dueThisWeek: Int
    var overdue: Int
    var syncedAt: TimeInterval
}

// MARK: - Manager

@MainActor
final class NYUIntegrationManager {

    static let shared = NYUIntegrationManager()

    /// Fired after every completed sync. The app delegate broadcasts
    /// `nyu.sync_complete` so phones refresh without polling.
    var onSyncCompleted: ((NYUSyncResult) -> Void)?

    private static let defaultDatabasePath = NSHomeDirectory() + "/.alfred/nyu.db"

    private let dbPath: String
    private var syncTimer: Timer?
    private var tickTimer: Timer?
    private var isSyncing = false

    private let settingsLock = NSLock()
    private var _settings = NYUSettings()

    /// Creates the manager. `dbPathOverride` exists for tests — the shared
    /// instance always uses the real path (same pattern as MemPalaceManager).
    init(dbPathOverride: String? = nil) {
        self.dbPath = dbPathOverride ?? Self.defaultDatabasePath
        do {
            try FileManager.default.createDirectory(
                atPath: (dbPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let db = try self.openDB()
            defer { sqlite3_close(db) }
            Self.runMigration(db)
        } catch {
            NSLog("[nyu] init failed: %@", error.localizedDescription)
        }
        loadSettings()
    }

    // MARK: - Lifecycle

    /// Start the sync + reminder timers. Idempotent. The sync timer fires per
    /// the configured frequency; the hourly tick re-schedules pending deadline
    /// notifications from the store (so a restart can't lose them).
    func start() {
        guard syncTimer == nil else { return }
        let sync = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.syncTick()
        }
        RunLoop.main.add(sync, forMode: .common)
        syncTimer = sync
        let tick = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            self?.hourlyTick()
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
        NSLog("[nyu] timers scheduled (sync every \(settings.syncFrequencyHours)h, reminder tick hourly)")
        hourlyTick()
    }

    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func syncTick() {
        guard settings.enabled, !settings.canvasToken.isEmpty else { return }
        let interval = TimeInterval(max(settings.syncFrequencyHours, 1)) * 3600
        let now = Date().timeIntervalSince1970
        guard now - lastSyncAt >= interval else { return }
        Task { _ = await syncNow() }
    }

    private func hourlyTick() {
        scheduleDeadlineNotifications()
    }

    // MARK: - Settings

    var settings: NYUSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return _settings
    }

    var isConfigured: Bool { settings.enabled && !settings.canvasToken.isEmpty }

    private static let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "nyu.enabled"
        static let token = "nyu.canvasToken"
        static let targetGPA = "nyu.targetGPA"
        static let frequency = "nyu.syncFrequencyHours"
        static let remind24h = "nyu.remind24h"
        static let remind1h = "nyu.remind1h"
        static let calendarSync = "nyu.calendarSync"
        static let lastSync = "nyu.lastSyncAt"
    }

    /// Mutate settings atomically and persist. `lastSyncAt` is managed by the
    /// sync pass, so it isn't part of NYUSettings (which the phone round-trips).
    func updateSettings(_ mutate: (inout NYUSettings) -> Void) {
        settingsLock.lock()
        mutate(&_settings)
        let snapshot = _settings
        settingsLock.unlock()
        persistSettings(snapshot)
        scheduleDeadlineNotifications()
    }

    private func loadSettings() {
        let stored = Self.defaults
        _settings.enabled = stored.object(forKey: Keys.enabled) as? Bool ?? false
        _settings.canvasToken = stored.string(forKey: Keys.token) ?? ""
        _settings.targetGPA = stored.object(forKey: Keys.targetGPA) as? Double ?? 0
        _settings.syncFrequencyHours = stored.object(forKey: Keys.frequency) as? Int ?? 6
        _settings.remind24h = stored.object(forKey: Keys.remind24h) as? Bool ?? true
        _settings.remind1h = stored.object(forKey: Keys.remind1h) as? Bool ?? true
        _settings.calendarSyncEnabled = stored.object(forKey: Keys.calendarSync) as? Bool ?? false
    }

    private func persistSettings(_ snapshot: NYUSettings) {
        let stored = Self.defaults
        stored.set(snapshot.enabled, forKey: Keys.enabled)
        stored.set(snapshot.canvasToken, forKey: Keys.token)
        stored.set(snapshot.targetGPA, forKey: Keys.targetGPA)
        stored.set(snapshot.syncFrequencyHours, forKey: Keys.frequency)
        stored.set(snapshot.remind24h, forKey: Keys.remind24h)
        stored.set(snapshot.remind1h, forKey: Keys.remind1h)
        stored.set(snapshot.calendarSyncEnabled, forKey: Keys.calendarSync)
    }

    private var lastSyncAt: TimeInterval {
        get { Self.defaults.double(forKey: Keys.lastSync) }
        set { Self.defaults.set(newValue, forKey: Keys.lastSync) }
    }

    // MARK: - Sync

    /// Run one full Canvas sync. Never throws — a failure becomes a
    /// `success: false` result with a human message, so the phone always has
    /// something to show. All downstream passes (notifications, calendar,
    /// MemPalace) run only after the store lands.
    @discardableResult
    func syncNow() async -> NYUSyncResult {
        guard !isSyncing else {
            return NYUSyncResult(success: false, message: "A sync is already running.",
                                 courses: 0, assignments: 0, announcements: 0,
                                 dueThisWeek: 0, overdue: 0, syncedAt: Date().timeIntervalSince1970)
        }
        isSyncing = true
        defer { isSyncing = false }

        guard settings.enabled else {
            return failed("NYU sync is off — enable it in Settings.")
        }
        guard !settings.canvasToken.isEmpty else {
            return failed("No Canvas token — add it in Settings (NYU → Canvas token).")
        }

        var client = NYUCanvasClient(token: settings.canvasToken)
        let now = Date().timeIntervalSince1970
        do {
            let courses = try await client.fetchCourses()
            guard !courses.isEmpty else {
                return failed("Canvas returned no active courses. If you just enrolled, it can take a day for the term to appear.")
            }

            var announcements: [NYUAnnouncement] = []
            let bounded = Array(courses.prefix(15))
            // Fetch every course's assignments + calendar events concurrently —
            // a dozen sequential request pairs would drag the sync out.
            let (assignments, classEvents) = await withTaskGroup(
                of: (assignments: [NYUAssignment], events: [NYUCalendarEvent]).self
            ) { group in
                for course in bounded {
                    group.addTask {
                        let assignments = (try? await client.fetchAssignments(courseID: course.id)) ?? []
                        let events = (try? await client.fetchCalendarEvents(courseID: course.id)) ?? []
                        return (assignments, events)
                    }
                }
                var assignments: [NYUAssignment] = []
                var events: [NYUCalendarEvent] = []
                for await batch in group {
                    assignments.append(contentsOf: batch.assignments)
                    events.append(contentsOf: batch.events)
                }
                return (assignments, events)
            }
            if let anns = try? await client.fetchAnnouncements(courseIDs: bounded.map(\.id)) {
                announcements = anns
            }

            let stored = storeSync(courses: courses, assignments: assignments,
                                   announcements: announcements, now: now)
            storeClassEvents(classEvents, now: now)
            scheduleDeadlineNotifications()
            if settings.calendarSyncEnabled {
                await syncCalendar(assignments: assignments, classEvents: classEvents)
            }
            rememberSyllabusFacts(courses: courses)
            maybeNotifyAnnouncements(announcements)
            maybeWatchGrades(courses: courses)

            lastSyncAt = Date().timeIntervalSince1970
            let result = NYUSyncResult(
                success: true,
                message: "Synced \(courses.count) course\(courses.count == 1 ? "" : "s"), \(stored.assignments) assignments. \(stored.dueThisWeek) due this week, \(stored.overdue) overdue.",
                courses: courses.count,
                assignments: stored.assignments,
                announcements: announcements.count,
                dueThisWeek: stored.dueThisWeek,
                overdue: stored.overdue,
                syncedAt: Date().timeIntervalSince1970)
            NSLog("[nyu] sync complete — %@", result.message)
            onSyncCompleted?(result)
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("[nyu] sync failed — %@", message)
            return failed(message)
        }
    }

    private func failed(_ message: String) -> NYUSyncResult {
        NYUSyncResult(success: false, message: message, courses: 0, assignments: 0,
                      announcements: 0, dueThisWeek: 0, overdue: 0,
                      syncedAt: Date().timeIntervalSince1970)
    }

    // MARK: - Store

    /// Upsert the sync's fetched data. Assignment statuses the owner set
    /// manually (in_progress) survive unless Canvas reports a submission.
    /// Pure-ish (DB writes), returns the row counts for the result message.
    func storeSync(courses: [NYUCourse], assignments: [NYUAssignment],
                           announcements: [NYUAnnouncement], now: TimeInterval) -> (assignments: Int, dueThisWeek: Int, overdue: Int) {
        guard let db = try? openDB() else { return (0, 0, 0) }
        defer { sqlite3_close(db) }

        for course in courses {
            let previous = Self.courseRow(db, id: course.id)?.currentScore
            _ = try? Self.exec(db, sql: """
                INSERT INTO courses (id, name, code, term, professor, syllabus,
                                     current_score, previous_score, projected_score,
                                     final_exam_date, grading_breakdown, office_hours,
                                     schedule, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, code = excluded.code, term = excluded.term,
                    professor = excluded.professor, syllabus = excluded.syllabus,
                    current_score = excluded.current_score,
                    previous_score = COALESCE(courses.current_score, courses.previous_score),
                    projected_score = excluded.projected_score,
                    final_exam_date = COALESCE(courses.final_exam_date, excluded.final_exam_date),
                    grading_breakdown = COALESCE(courses.grading_breakdown, excluded.grading_breakdown),
                    office_hours = COALESCE(courses.office_hours, excluded.office_hours),
                    schedule = COALESCE(courses.schedule, excluded.schedule),
                    updated_at = excluded.updated_at
                """, args: [.text(String(course.id)), .text(course.name), .text(course.code),
                            .text(course.term), .text(course.professor), .text(course.syllabus),
                            .optionalDouble(course.currentScore), .optionalDouble(previous),
                            .optionalDouble(course.projectedScore),
                            .optionalDouble(nil), .text("{}"), .text(""), .text(""),
                            .double(now)])
        }

        var dueThisWeek = 0
        var overdue = 0
        let weekEnd = now + 7 * 86_400
        for assignment in assignments {
            let stored = Self.assignmentStatus(db, id: assignment.id)
            // Canvas's submission wins; otherwise keep the owner's manual state.
            var status = stored ?? "not_started"
            if assignment.score != nil {
                status = AssignmentStatus.graded.rawValue
            } else if assignment.submittedAt != nil {
                status = AssignmentStatus.submitted.rawValue
            } else if stored == nil {
                status = AssignmentStatus.notStarted.rawValue
            }
            if let due = assignment.dueAt {
                if due < now, assignment.score == nil, assignment.submittedAt == nil {
                    overdue += 1
                } else if due <= weekEnd, due >= now, assignment.score == nil, assignment.submittedAt == nil {
                    dueThisWeek += 1
                }
            }
            _ = try? Self.exec(db, sql: """
                INSERT INTO assignments (id, course_id, name, description, due_at,
                                         points, status, submitted_at, score, url, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    course_id = excluded.course_id, name = excluded.name,
                    description = excluded.description, due_at = excluded.due_at,
                    points = excluded.points, status = excluded.status,
                    submitted_at = excluded.submitted_at, score = excluded.score,
                    url = excluded.url, updated_at = excluded.updated_at
                """, args: [.text(String(assignment.id)), .text(String(assignment.courseID)),
                            .text(assignment.name), .text(assignment.details),
                            .optionalDouble(assignment.dueAt), .double(assignment.pointsPossible),
                            .text(status), .optionalDouble(assignment.submittedAt),
                            .optionalDouble(assignment.score), .text(assignment.url),
                            .double(now)])
        }

        for announcement in announcements {
            _ = try? Self.exec(db, sql: """
                INSERT OR IGNORE INTO announcements (id, course_id, title, message, posted_at, read)
                VALUES (?, ?, ?, ?, ?, 0)
                """, args: [.text(String(announcement.id)), .text(String(announcement.courseID)),
                            .text(announcement.title), .text(announcement.message),
                            .double(announcement.postedAt)])
        }

        return (assignments.count, dueThisWeek, overdue)
    }

    /// Class meetings → the `schedule` column ("Tue/Thu 9:30–10:45").
    private func storeClassEvents(_ events: [NYUCalendarEvent], now: TimeInterval) {
        guard let db = try? openDB() else { return }
        defer { sqlite3_close(db) }
        let meetings = events.filter { $0.eventType == "event" || $0.eventType == "class" }
        let grouped = Dictionary(grouping: meetings, by: { $0.courseID })
        for (courseID, courseEvents) in grouped {
            let sorted = courseEvents.sorted { $0.startAt < $1.startAt }
            guard let first = sorted.first else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "EEEE"
            let days = Set(sorted.map { formatter.string(from: Date(timeIntervalSince1970: $0.startAt)) })
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "h:mm a"
            let start = timeFmt.string(from: Date(timeIntervalSince1970: first.startAt))
            let end = timeFmt.string(from: Date(timeIntervalSince1970: first.endAt))
            let schedule = "\(Array(days).sorted().joined(separator: "/")) \(start)–\(end)"
            _ = try? Self.exec(db, sql: "UPDATE courses SET schedule = ?, updated_at = ? WHERE id = ?",
                               args: [.text(schedule), .double(now), .text(String(courseID))])
        }
    }

    // MARK: - Reads

    func listAssignments(limit: Int = 200) -> [NYUAssignmentRow] {
        guard let db = try? openDB() else { return [] }
        defer { sqlite3_close(db) }
        let now = Date().timeIntervalSince1970
        var rows: [NYUAssignmentRow] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT a.id, a.course_id, c.name, a.name, a.description, a.due_at,
                       a.points, a.status, a.submitted_at, a.score, a.url
                FROM assignments a LEFT JOIN courses c ON c.id = a.course_id
                ORDER BY a.due_at ASC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                let status = Self.textColumn(stmt, 7)
                let submitted = Self.nullableDoubleColumn(stmt, 8)
                let score = Self.nullableDoubleColumn(stmt, 9)
                let due = Self.nullableDoubleColumn(stmt, 5)
                let finished = status == AssignmentStatus.submitted.rawValue
                    || status == AssignmentStatus.graded.rawValue
                let isOverdue = !finished && due.map { $0 < now } ?? false
                let daysUntil = due.map { Int(($0 - now) / 86_400) }
                rows.append(NYUAssignmentRow(
                    id: Self.intColumn(stmt, 0),
                    courseID: Self.intColumn(stmt, 1),
                    courseName: Self.textColumn(stmt, 2),
                    name: Self.textColumn(stmt, 3),
                    details: Self.textColumn(stmt, 4),
                    dueAt: due,
                    points: Self.doubleColumn(stmt, 6),
                    status: status,
                    submittedAt: submitted,
                    score: score,
                    url: Self.textColumn(stmt, 10),
                    isOverdue: isOverdue,
                    daysUntil: daysUntil))
            }
        } catch { }
        return rows
    }

    func listCourses() -> [NYUCourseRow] {
        guard let db = try? openDB() else { return [] }
        defer { sqlite3_close(db) }
        var rows: [NYUCourseRow] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, name, code, term, professor, syllabus, current_score,
                       previous_score, projected_score, final_exam_date,
                       grading_breakdown, office_hours, schedule
                FROM courses ORDER BY name ASC
                """) { stmt in
                rows.append(Self.courseRow(from: stmt))
            }
        } catch { }
        return rows
    }

    func courseInfo(id: Int) -> NYUCourseRow? {
        guard let db = try? openDB() else { return nil }
        defer { sqlite3_close(db) }
        var found: NYUCourseRow?
        do {
            try Self.queryRows(db, sql: """
                SELECT id, name, code, term, professor, syllabus, current_score,
                       previous_score, projected_score, final_exam_date,
                       grading_breakdown, office_hours, schedule
                FROM courses WHERE id = ?
                """, args: [.text(String(id))]) { stmt in
                found = Self.courseRow(from: stmt)
            }
        } catch { }
        return found
    }

    /// Assignments due within `days` days (not submitted/graded) — the
    /// deadline routine step's work list.
    func dueWithin(days: Int, now: Date = Date()) -> [NYUAssignmentRow] {
        let start = now.timeIntervalSince1970
        let end = start + Double(days) * 86_400
        return listAssignments().filter { row in
            guard let due = row.dueAt, due >= start, due <= end else { return false }
            let finished = row.status == AssignmentStatus.submitted.rawValue
                || row.status == AssignmentStatus.graded.rawValue
            return !finished
        }
    }

    func overdue(now: Date = Date()) -> [NYUAssignmentRow] {
        listAssignments().filter { $0.isOverdue }
    }

    func nextDeadline(now: Date = Date()) -> NYUAssignmentRow? {
        listAssignments().first { row in
            guard let due = row.dueAt, due >= now.timeIntervalSince1970 else { return false }
            let finished = row.status == AssignmentStatus.submitted.rawValue
                || row.status == AssignmentStatus.graded.rawValue
            return !finished
        }
    }

    @discardableResult
    func updateAssignmentStatus(id: Int, status: String) -> NYUAssignmentRow? {
        guard let db = try? openDB() else { return nil }
        defer { sqlite3_close(db) }
        let normalized: String
        switch status {
        case AssignmentStatus.inProgress.rawValue, AssignmentStatus.submitted.rawValue:
            normalized = status
        default:
            normalized = AssignmentStatus.notStarted.rawValue
        }
        _ = try? Self.exec(db, sql: """
            UPDATE assignments SET status = ?, submitted_at = ?, updated_at = ? WHERE id = ?
            """, args: [.text(normalized),
                        .optionalDouble(normalized == AssignmentStatus.submitted.rawValue ? Date().timeIntervalSince1970 : nil),
                        .double(Date().timeIntervalSince1970), .text(String(id))])
        let updated = listAssignments().first { $0.id == id }
        if normalized == AssignmentStatus.submitted.rawValue, let updated {
            cancelNotifications(for: updated)
            removeCalendarEvent(key: "due:\(updated.courseID):\(updated.id)")
        }
        return updated
    }

    // MARK: - Briefing lines

    /// "3 assignments due this week (CS project in 2 days); 1 overdue — Art History essay"
    /// Nil when nothing is pending, so an inactive semester never clogs the briefing.
    func assignmentsLine(now: Date = Date()) -> String? {
        let upcoming = dueWithin(days: 7, now: now)
        let overdue = self.overdue(now: now)
        guard !upcoming.isEmpty || !overdue.isEmpty else { return nil }

        var parts: [String] = []
        if !upcoming.isEmpty {
            let count = upcoming.count
            var text = "\(count) assignment\(count == 1 ? "" : "s") due this week"
            if let next = upcoming.first, let days = next.daysUntil {
                text += " (\(next.name) in \(days) day\(days == 1 ? "" : "s"))"
            }
            parts.append(text)
        }
        if !overdue.isEmpty {
            let first = overdue[0]
            parts.append("\(overdue.count) overdue — \(first.name) (\(first.daysUntil.map { "\(abs($0))d" } ?? "no due date"))")
        }
        return parts.joined(separator: "; ")
    }

    /// "Current grades: Calculus 92.5, Art History 88 — 2 improving, 1 declining"
    /// Nil when no graded course exists yet.
    func gradesLine() -> String? {
        let courses = listCourses().filter { $0.currentScore != nil }
        guard !courses.isEmpty else { return nil }
        let names = courses.prefix(3).map {
            "\($0.name): \(Self.fmt($0.currentScore ?? 0))"
        }.joined(separator: ", ")
        let improving = courses.filter { $0.trend == "improving" }.count
        let declining = courses.filter { $0.trend == "declining" }.count
        var line = "Current grades: \(names)"
        if improving > 0 || declining > 0 {
            var trends: [String] = []
            if improving > 0 { trends.append("\(improving) improving") }
            if declining > 0 { trends.append("\(declining) declining") }
            line += " — " + trends.joined(separator: ", ")
        }
        return line
    }

    // MARK: - Deadline notifications

    /// Schedule (or refresh) the 24h / 1h deadline notifications from the
    /// store. Called after every sync, on settings change, and on the hourly
    /// tick — idempotent because each assignment's reminders are removed and
    /// re-added by stable identifiers.
    func scheduleDeadlineNotifications(now: Date = Date()) {
        guard Self.notificationsAvailable else { return }
        let settings = settings
        guard settings.enabled, settings.remind24h || settings.remind1h else { return }
        let rows = listAssignments()
        for row in rows {
            guard let due = row.dueAt, due > now.timeIntervalSince1970 else { continue }
            let finished = row.status == AssignmentStatus.submitted.rawValue
                || row.status == AssignmentStatus.graded.rawValue
            guard !finished else { continue }

            let ids = ["nyu-24h-\(row.id)", "nyu-1h-\(row.id)"]
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            let course = row.courseName.isEmpty ? "" : " — \(row.courseName)"
            let body = "\(row.name)\(course) is due"

            if settings.remind24h {
                let when = due - 24 * 3600
                if when > now.timeIntervalSince1970 {
                    scheduleNotification(id: "nyu-24h-\(row.id)", title: "Due in 24 hours",
                                         body: body, at: Date(timeIntervalSince1970: when))
                }
            }
            if settings.remind1h {
                let when = due - 3600
                if when > now.timeIntervalSince1970 {
                    scheduleNotification(id: "nyu-1h-\(row.id)", title: "Due in 1 hour",
                                         body: body, at: Date(timeIntervalSince1970: when))
                }
            }
        }
    }

    /// UNUserNotificationCenter and EKEventStore require a real app bundle —
    /// in the XCTest runner, `Bundle.main` has no bundle proxy and both
    /// frameworks abort the process. Every such call is guarded behind this.
    private static var notificationsAvailable: Bool {
        NSClassFromString("XCTestCase") == nil
    }

    private func cancelNotifications(for row: NYUAssignmentRow) {
        guard Self.notificationsAvailable else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["nyu-24h-\(row.id)", "nyu-1h-\(row.id)"])
    }

    private func scheduleNotification(id: String, title: String, body: String, at date: Date) {
        guard Self.notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .timeSensitive
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[nyu] notification scheduling failed: %@", error.localizedDescription)
            }
        }
    }

    /// One immediate notification per new announcement (new since last sync).
    private func maybeNotifyAnnouncements(_ announcements: [NYUAnnouncement]) {
        guard Self.notificationsAvailable, !announcements.isEmpty else { return }
        let fresh = announcements.filter { $0.postedAt > lastSyncAt - 24 * 3600 }
        for announcement in fresh.prefix(3) {
            let course = listCourses().first { $0.id == announcement.courseID }?.name ?? "Course"
            let content = UNMutableNotificationContent()
            content.title = "Announcement — \(course)"
            content.body = announcement.title
            let request = UNNotificationRequest(
                identifier: "nyu-ann-\(announcement.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("[nyu] announcement notification failed: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Grade watch: one notification per course that dropped below the target.
    private func maybeWatchGrades(courses: [NYUCourse]) {
        guard Self.notificationsAvailable, settings.targetGPA > 0 else { return }
        let now = Date().timeIntervalSince1970
        for course in courses {
            guard let score = course.currentScore else { continue }
            guard let db = try? openDB() else { continue }
            defer { sqlite3_close(db) }
            let previous = Self.courseRow(db, id: course.id)?.previousScore
            guard let previous, score < previous - 0.5, score < settings.targetGPA else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Grade dropped — \(course.name)"
            content.body = String(format: "Now %.1f, was %.1f (below your %.1f target).", score, previous, settings.targetGPA)
            let request = UNNotificationRequest(
                identifier: "nyu-grade-\(course.id)-\(Int(now))", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("[nyu] grade notification failed: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Calendar sync (EventKit)

    /// Mirror class meetings + assignment due dates into the system calendar.
    /// Every event Alfred creates is tracked by key in synced_events, so a
    /// re-sync updates rather than duplicates, and only those events are ever
    /// touched or removed.
    func syncCalendar(assignments: [NYUAssignment], classEvents: [NYUCalendarEvent]) async {
        let store: EKEventStore
        do {
            store = try await authorizedEventStore()
        } catch {
            NSLog("[nyu] calendar sync skipped: %@", error.localizedDescription)
            return
        }
        let courseNames = Dictionary(uniqueKeysWithValues: listCourses().map { ($0.id, $0.name) })
        for event in classEvents where event.eventType == "event" || event.eventType == "class" {
            let courseName = courseNames[event.courseID] ?? "Course"
            upsertCalendarEvent(store: store, key: "cal:\(event.courseID):\(event.id)",
                                title: "\(event.title) — \(courseName)",
                                start: event.startAt, end: event.endAt,
                                location: event.location)
        }
        for assignment in assignments {
            guard let due = assignment.dueAt else { continue }
            upsertCalendarEvent(store: store, key: "due:\(assignment.courseID):\(assignment.id)",
                                title: "Due: \(assignment.name)",
                                start: due, end: due + 30 * 60,
                                location: nil)
        }
    }

    private func upsertCalendarEvent(store: EKEventStore, key: String, title: String,
                                     start: TimeInterval, end: TimeInterval, location: String?) {
        guard let db = try? openDB() else { return }
        let existingIdentifier = Self.syncedEventIdentifier(db, key: key)
        sqlite3_close(db)

        if let existingIdentifier {
            guard let event = store.event(withIdentifier: existingIdentifier) else {
                removeSyncedEventRow(key: key)
                return
            }
            event.title = title
            event.startDate = Date(timeIntervalSince1970: start)
            event.endDate = Date(timeIntervalSince1970: end)
            event.location = location
            try? store.save(event, span: .thisEvent, commit: true)
            return
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = Date(timeIntervalSince1970: start)
        event.endDate = Date(timeIntervalSince1970: end)
        event.location = location
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent, commit: true)
            guard let db = try? openDB() else { return }
            _ = try? Self.exec(db, sql: """
                INSERT OR REPLACE INTO synced_events (key, event_identifier) VALUES (?, ?)
                """, args: [.text(key), .text(event.eventIdentifier)])
            sqlite3_close(db)
        } catch {
            NSLog("[nyu] calendar event save failed: %@", error.localizedDescription)
        }
    }

    /// Remove one Alfred-created calendar event (used when an assignment is
    /// marked submitted — the due reminder event is no longer true).
    private func removeCalendarEvent(key: String) {
        guard Self.notificationsAvailable else { return }
        guard let db = try? openDB() else { return }
        let identifier = Self.syncedEventIdentifier(db, key: key)
        _ = try? Self.exec(db, sql: "DELETE FROM synced_events WHERE key = ?", args: [.text(key)])
        sqlite3_close(db)
        guard let identifier else { return }
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: identifier) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
    }

    private func removeSyncedEventRow(key: String) {
        guard let db = try? openDB() else { return }
        _ = try? Self.exec(db, sql: "DELETE FROM synced_events WHERE key = ?", args: [.text(key)])
        sqlite3_close(db)
    }

    private func authorizedEventStore() async throws -> EKEventStore {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return store
        case .notDetermined:
            _ = try? await store.requestFullAccessToEvents()
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized:
                return store
            default:
                throw CapabilityError.denied("Calendar access denied.")
            }
        default:
            throw CapabilityError.denied("Calendar access denied.")
        }
    }

    // MARK: - MemPalace facts

    /// Extract the syllabus facts worth remembering — grading breakdown
    /// percentages and the final exam date — and store them as learning
    /// memories, so the vault can answer "what's the final exam date?".
    private func rememberSyllabusFacts(courses: [NYUCourse]) {
        let palace = MemPalaceManager.shared
        for course in courses {
            let breakdown = Self.gradingBreakdown(from: course.syllabus)
            if !breakdown.isEmpty, let json = try? JSONSerialization.data(withJSONObject: breakdown),
               let text = String(data: json, encoding: .utf8) {
                palace.remember(content: "\(course.name) grading breakdown: \(text)",
                                category: .learning, source: "canvas_sync", confidence: 0.7)
            }
            if let examDate = Self.examDate(from: course.syllabus) {
                let formatted = Self.dateString(examDate)
                palace.remember(content: "\(course.name) final exam is on \(formatted)",
                                category: .learning, source: "canvas_sync", confidence: 0.75)
            }
        }
    }

    /// Extract "20% homework, 30% midterm, 50% final" style breakdowns from a
    /// syllabus's plain text: every "<word(s)> N%" pattern, aggregated.
    static func gradingBreakdown(from syllabus: String) -> [String: Double] {
        let pattern = #"([A-Za-z][A-Za-z /\-]{0,40}?)\s*(\d{1,3})\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = syllabus as NSString
        var result: [String: Double] = [:]
        for match in regex.matches(in: syllabus, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = Double(ns.substring(with: match.range(at: 2))) ?? 0
            guard value > 0, value <= 100, !label.isEmpty else { continue }
            let key = label.split(separator: " ").suffix(2).joined(separator: " ").lowercased()
            if result[key] == nil { result[key] = value }
        }
        return result
    }

    /// Find a final exam date: a date near a "final exam" mention. Returns the
    /// first date (month-name or ISO) on the same or next line.
    static func examDate(from syllabus: String) -> Date? {
        let lines = syllabus.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard line.lowercased().contains("final exam") || line.lowercased().contains("final:") else { continue }
            let window = [line] + (index + 1 < lines.count ? [lines[index + 1]] : [])
            for candidate in window {
                if let date = Self.parseDate(in: candidate) { return date }
            }
        }
        return nil
    }

    /// First date found in a string: ISO yyyy-mm-dd or "June 12" / "Jun 12".
    static func parseDate(in text: String) -> Date? {
        if let iso = text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let raw = String(text[iso])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: raw)
        }
        let monthPattern = #"(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?"#
        if let month = text.range(of: monthPattern, options: [.regularExpression, .caseInsensitive]) {
            let raw = String(text[month])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "MMMM d"
            if let date = formatter.date(from: raw) { return date }
            formatter.dateFormat = "MMM d"
            return formatter.date(from: raw)
        }
        return nil
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - Wire helpers

    static func settingsWire(_ settings: NYUSettings) -> [String: Any] {
        [
            "enabled": settings.enabled,
            "tokenSet": !settings.canvasToken.isEmpty,
            "targetGPA": settings.targetGPA,
            "syncFrequencyHours": settings.syncFrequencyHours,
            "remind24h": settings.remind24h,
            "remind1h": settings.remind1h,
            "calendarSyncEnabled": settings.calendarSyncEnabled,
        ]
    }

    /// Pure decoder — touches no MainActor state, so it is safe to call from
    /// the socket server's nonisolated handlers.
    nonisolated static func settings(from raw: Any?) -> NYUSettings? {
        guard let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return try? JSONDecoder().decode(NYUSettings.self, from: data)
    }

    static func assignmentWire(_ row: NYUAssignmentRow) -> [String: Any] {
        [
            "id": row.id,
            "courseID": row.courseID,
            "courseName": row.courseName,
            "name": row.name,
            "details": row.details,
            "dueAt": row.dueAt ?? 0,
            "points": row.points,
            "status": row.status,
            "submittedAt": row.submittedAt ?? 0,
            "score": row.score ?? 0,
            "url": row.url,
            "isOverdue": row.isOverdue,
            "daysUntil": row.daysUntil ?? 0,
        ]
    }

    static func courseWire(_ row: NYUCourseRow) -> [String: Any] {
        [
            "id": row.id,
            "name": row.name,
            "code": row.code,
            "term": row.term,
            "professor": row.professor,
            "syllabus": row.syllabus,
            "currentScore": row.currentScore ?? 0,
            "previousScore": row.previousScore ?? 0,
            "projectedScore": row.projectedScore ?? 0,
            "finalExamAt": row.finalExamAt ?? 0,
            "gradingBreakdown": row.gradingBreakdown,
            "officeHours": row.officeHours,
            "schedule": row.schedule,
            "trend": row.trend,
        ]
    }

    static func syncResultWire(_ result: NYUSyncResult) -> [String: Any] {
        [
            "success": result.success,
            "message": result.message,
            "courses": result.courses,
            "assignments": result.assignments,
            "announcements": result.announcements,
            "dueThisWeek": result.dueThisWeek,
            "overdue": result.overdue,
            "syncedAt": result.syncedAt,
        ]
    }

    static func statusWire() -> [String: Any] {
        let manager = NYUIntegrationManager.shared
        let rows = manager.listAssignments()
        let now = Date().timeIntervalSince1970
        let dueThisWeek = rows.filter { row in
            guard let due = row.dueAt, due <= now + 7 * 86_400, due >= now else { return false }
            let finished = row.status == AssignmentStatus.submitted.rawValue
                || row.status == AssignmentStatus.graded.rawValue
            return !finished
        }.count
        var wire = settingsWire(manager.settings)
        wire["lastSyncAt"] = manager.lastSyncAt
        wire["courseCount"] = manager.listCourses().count
        wire["assignmentCount"] = rows.count
        wire["overdueCount"] = manager.overdue().count
        wire["dueThisWeek"] = dueThisWeek
        wire["gradedCount"] = rows.filter { $0.status == AssignmentStatus.graded.rawValue }.count
        return wire
    }

    // MARK: - SQLite plumbing

    private enum SQLiteValue {
        case text(String)
        case double(Double)
        case optionalDouble(Double?)
        case int(Int)
    }

    private func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "nyu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open \(dbPath)"])
        }
        return db
    }

    private static func runMigration(_ db: OpaquePointer) {
        let ddl = """
        CREATE TABLE IF NOT EXISTS courses (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            code TEXT DEFAULT '',
            term TEXT DEFAULT '',
            professor TEXT DEFAULT '',
            syllabus TEXT DEFAULT '',
            current_score REAL,
            previous_score REAL,
            projected_score REAL,
            final_exam_date REAL,
            grading_breakdown TEXT DEFAULT '{}',
            office_hours TEXT DEFAULT '',
            schedule TEXT DEFAULT '',
            updated_at REAL
        );
        CREATE TABLE IF NOT EXISTS assignments (
            id INTEGER PRIMARY KEY,
            course_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            description TEXT DEFAULT '',
            due_at REAL,
            points REAL DEFAULT 0,
            status TEXT DEFAULT 'not_started',
            submitted_at REAL,
            score REAL,
            url TEXT DEFAULT '',
            updated_at REAL
        );
        CREATE TABLE IF NOT EXISTS announcements (
            id INTEGER PRIMARY KEY,
            course_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            message TEXT DEFAULT '',
            posted_at REAL,
            read INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS synced_events (
            key TEXT PRIMARY KEY,
            event_identifier TEXT NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, ddl, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            NSLog("[nyu] migration failed: %@", message)
        }
    }

    @discardableResult
    private static func exec(_ db: OpaquePointer, sql: String, args: [SQLiteValue]) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        for (index, arg) in args.enumerated() {
            let slot = Int32(index + 1)
            switch arg {
            case .text(let text):
                sqlite3_bind_text(statement, slot, text, -1, NYU_SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(statement, slot, value)
            case .optionalDouble(let value):
                if let value {
                    sqlite3_bind_double(statement, slot, value)
                } else {
                    sqlite3_bind_null(statement, slot)
                }
            case .int(let value):
                sqlite3_bind_int(statement, slot, Int32(value))
            }
        }
        let step = sqlite3_step(statement)
        return step == SQLITE_DONE || step == SQLITE_ROW
    }

    private static func queryRows(_ db: OpaquePointer, sql: String, args: [SQLiteValue] = [],
                                  row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "nyu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(sql)"])
        }
        defer { sqlite3_finalize(statement) }
        for (index, arg) in args.enumerated() {
            let slot = Int32(index + 1)
            switch arg {
            case .text(let text):
                sqlite3_bind_text(statement, slot, text, -1, NYU_SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(statement, slot, value)
            case .optionalDouble(let value):
                if let value {
                    sqlite3_bind_double(statement, slot, value)
                } else {
                    sqlite3_bind_null(statement, slot)
                }
            case .int(let value):
                sqlite3_bind_int(statement, slot, Int32(value))
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            try row(statement)
        }
    }

    // MARK: - Column readers

    private static func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private static func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    private static func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int(stmt, index))
    }

    private static func nullableDoubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    private static func courseRow(from stmt: OpaquePointer) -> NYUCourseRow {
        let breakdownJSON = textColumn(stmt, 10)
        let breakdown = (try? JSONSerialization.jsonObject(with: Data(breakdownJSON.utf8)))
            as? [String: Double] ?? [:]
        return NYUCourseRow(
            id: intColumn(stmt, 0),
            name: textColumn(stmt, 1),
            code: textColumn(stmt, 2),
            term: textColumn(stmt, 3),
            professor: textColumn(stmt, 4),
            syllabus: textColumn(stmt, 5),
            currentScore: nullableDoubleColumn(stmt, 6),
            previousScore: nullableDoubleColumn(stmt, 7),
            projectedScore: nullableDoubleColumn(stmt, 8),
            finalExamAt: nullableDoubleColumn(stmt, 9),
            gradingBreakdown: breakdown,
            officeHours: textColumn(stmt, 11),
            schedule: textColumn(stmt, 12))
    }

    private static func courseRow(_ db: OpaquePointer, id: Int) -> NYUCourseRow? {
        var found: NYUCourseRow?
        do {
            try queryRows(db, sql: """
                SELECT id, name, code, term, professor, syllabus, current_score,
                       previous_score, projected_score, final_exam_date,
                       grading_breakdown, office_hours, schedule
                FROM courses WHERE id = ?
                """, args: [.text(String(id))]) { stmt in
                found = courseRow(from: stmt)
            }
        } catch { }
        return found
    }

    private static func assignmentStatus(_ db: OpaquePointer, id: Int) -> String? {
        var status: String?
        do {
            try queryRows(db, sql: "SELECT status FROM assignments WHERE id = ?",
                          args: [.text(String(id))]) { stmt in
                status = textColumn(stmt, 0)
            }
        } catch { }
        return status
    }

    private static func syncedEventIdentifier(_ db: OpaquePointer, key: String) -> String? {
        var identifier: String?
        do {
            try queryRows(db, sql: "SELECT event_identifier FROM synced_events WHERE key = ?",
                          args: [.text(key)]) { stmt in
                identifier = textColumn(stmt, 0)
            }
        } catch { }
        return identifier
    }

    private static func fmt(_ score: Double) -> String {
        score == score.rounded() ? String(Int(score)) : String(format: "%.1f", score)
    }
}
