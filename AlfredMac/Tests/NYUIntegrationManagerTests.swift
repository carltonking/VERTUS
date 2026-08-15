//
//  NYUIntegrationManagerTests.swift
//  Alfred
//
//  Covers the deterministic half of the NYU integration: Canvas JSON parsing
//  (the static NYUCanvasClient parsers), the SQLite store (seeded through
//  storeSync, the same path a real sync uses), briefing lines, deadline
//  filtering, grade trends, and the syllabus fact extraction.
//

import XCTest
@testable import Alfred

@MainActor
final class NYUIntegrationManagerTests: XCTestCase {

    private var manager: NYUIntegrationManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyu-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("nyu.db").path
        manager = NYUIntegrationManager(dbPathOverride: dbPath)
    }

    override func tearDown() {
        manager = nil
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        super.tearDown()
    }

    // MARK: - Canvas parsing

    func testParseCoursesReadsEnrollmentAndSyllabus() {
        let rows: [[String: Any]] = [
            [
                "id": 101,
                "name": "Calculus I",
                "course_code": "MATH-UA 121",
                "term": ["name": "Fall 2026"],
                "enrollments": [
                    ["type": "student", "computed_current_score": 92.5, "computed_final_score": 90.0],
                ],
                "teachers": [["display_name": "Dr. Lively"]],
                "syllabus_body": "<p>Grading: homework 20%</p><br>Final: December 18",
            ],
            [
                "id": 102,
                "name": "Art History",
                "course_code": "ARTH-UA 90",
                "enrollments": [["type": "teacher"]],
                "syllabus_body": "",
            ],
        ]
        let courses = NYUCanvasClient.parseCourses(rows)
        XCTAssertEqual(courses.count, 2)

        let calc = courses[0]
        XCTAssertEqual(calc.id, 101)
        XCTAssertEqual(calc.name, "Calculus I")
        XCTAssertEqual(calc.code, "MATH-UA 121")
        XCTAssertEqual(calc.term, "Fall 2026")
        XCTAssertEqual(calc.professor, "Dr. Lively")
        XCTAssertEqual(calc.currentScore ?? 0, 92.5, accuracy: 0.001)
        XCTAssertEqual(calc.projectedScore ?? 0, 90.0, accuracy: 0.001)
        XCTAssertTrue(calc.syllabus.contains("homework 20%"))
        XCTAssertFalse(calc.syllabus.contains("<p>"))

        // A non-student enrollment contributes no score.
        XCTAssertNil(courses[1].currentScore)
    }

    func testParseAssignmentsReadsSubmission() {
        let rows: [[String: Any]] = [
            [
                "id": 501,
                "name": "Problem Set 3",
                "description": "<p>Integrals</p>",
                "due_at": "2026-09-10T23:59:59Z",
                "points_possible": 20,
                "submission": ["submitted_at": "2026-09-09T12:00:00Z", "score": 18],
                "html_url": "https://canvas.nyu.edu/courses/101/assignments/501",
            ],
            [
                "id": 502,
                "name": "Essay draft",
                "points_possible": 10,
                "html_url": "",
            ],
        ]
        let assignments = NYUCanvasClient.parseAssignments(rows, courseID: 101)
        XCTAssertEqual(assignments.count, 2)

        let set = assignments[0]
        XCTAssertEqual(set.id, 501)
        XCTAssertEqual(set.courseID, 101)
        XCTAssertEqual(set.name, "Problem Set 3")
        XCTAssertEqual(set.details, "Integrals")
        XCTAssertEqual(set.submittedAt ?? 0, 1_788_955_200, accuracy: 1) // 2026-09-09T12:00:00Z
        XCTAssertEqual(set.score ?? 0, 18, accuracy: 0.001)
        XCTAssertEqual(set.pointsPossible, 20)

        XCTAssertNil(assignments[1].dueAt)
        XCTAssertNil(assignments[1].submittedAt)
    }

    func testParseAnnouncementsExtractsCourseID() {
        let rows: [[String: Any]] = [
            [
                "id": 701,
                "title": "Midterm moved",
                "message": "The midterm is now on December 18.",
                "posted_at": "2026-09-01T10:00:00Z",
                "context_code": "course_101",
            ],
            [
                "id": 702,
                "title": "Office hours",
                "message": "Th 2-4pm",
                "posted_at": "2026-09-02T10:00:00Z",
                "url": "https://canvas.nyu.edu/courses/102/discussion_topics/702",
            ],
            ["id": 703, "title": "No context", "message": "", "posted_at": "2026-09-03T10:00:00Z"],
        ]
        let announcements = NYUCanvasClient.parseAnnouncements(rows)
        XCTAssertEqual(announcements.count, 2)
        XCTAssertEqual(announcements[0].courseID, 101)
        XCTAssertEqual(announcements[1].courseID, 102)
    }

    func testParseCalendarEventsWithFractionalSeconds() {
        let rows: [[String: Any]] = [
            [
                "id": 801,
                "title": "Lecture",
                "start_at": "2026-09-01T09:30:00.000Z",
                "end_at": "2026-09-01T10:45:00.000Z",
                "location_name": "WWH 101",
                "event_type": "event",
            ],
        ]
        let events = NYUCanvasClient.parseCalendarEvents(rows, courseID: 101)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].location, "WWH 101")
        XCTAssertEqual(events[0].endAt - events[0].startAt, 4500, accuracy: 1)
        XCTAssertEqual(events[0].eventType, "event")
    }

    // MARK: - Store

    func testStoreAndListAssignments() {
        let now = Date().timeIntervalSince1970
        storeFixture(now: now)

        let assignments = manager.listAssignments()
        XCTAssertEqual(assignments.count, 3)

        // Graded assignment came in with a score.
        let graded = assignments.first { $0.id == 501 }
        XCTAssertEqual(graded?.status, AssignmentStatus.graded.rawValue)
        XCTAssertEqual(graded?.score ?? 0, 18, accuracy: 0.001)

        // Past-due, not submitted → overdue.
        let overdue = assignments.first { $0.id == 502 }
        XCTAssertEqual(overdue?.isOverdue, true)
        XCTAssertEqual(overdue?.status, AssignmentStatus.notStarted.rawValue)

        // Future → not overdue, daysUntil positive.
        let future = assignments.first { $0.id == 503 }
        XCTAssertEqual(future?.isOverdue, false)
        XCTAssertEqual(future?.daysUntil ?? 0, 3)

        XCTAssertEqual(manager.listCourses().count, 1)
    }

    func testManualStatusSurvivesResyncUntilSubmission() {
        let now = Date().timeIntervalSince1970
        storeFixture(now: now)

        _ = manager.updateAssignmentStatus(id: 503, status: AssignmentStatus.inProgress.rawValue)
        XCTAssertEqual(manager.listAssignments().first { $0.id == 503 }?.status,
                       AssignmentStatus.inProgress.rawValue)

        // Re-sync without a submission: the manual status survives.
        let assignments = manager.listAssignments()
        let course = NYUCourse(id: 101, name: "Calculus I", code: "MATH-UA 121", term: "Fall 2026",
                               professor: "", syllabus: "", currentScore: 92.5, projectedScore: nil)
        manager.storeSync(courses: [course], assignments: assignments.map {
            NYUAssignment(id: $0.id, courseID: 101, name: $0.name, details: "",
                          dueAt: $0.dueAt, pointsPossible: $0.points,
                          submittedAt: nil, score: nil, url: "")
        }, announcements: [], now: now + 3600)
        XCTAssertEqual(manager.listAssignments().first { $0.id == 503 }?.status,
                       AssignmentStatus.inProgress.rawValue)

        // Now the submission arrives: Canvas wins.
        let withSubmission = manager.listAssignments().map {
            NYUAssignment(id: $0.id, courseID: 101, name: $0.name, details: "",
                          dueAt: $0.dueAt, pointsPossible: $0.points,
                          submittedAt: now + 7200, score: nil, url: "")
        }
        manager.storeSync(courses: [course], assignments: withSubmission,
                          announcements: [], now: now + 7200)
        XCTAssertEqual(manager.listAssignments().first { $0.id == 503 }?.status,
                       AssignmentStatus.submitted.rawValue)
    }

    func testUpdateAssignmentStatusMarksSubmitted() {
        let now = Date().timeIntervalSince1970
        storeFixture(now: now)

        let updated = manager.updateAssignmentStatus(id: 503, status: AssignmentStatus.submitted.rawValue)
        XCTAssertEqual(updated?.status, AssignmentStatus.submitted.rawValue)
        XCTAssertNotNil(updated?.submittedAt)
        XCTAssertEqual(manager.listAssignments().first { $0.id == 503 }?.isOverdue, false)
    }

    // MARK: - Deadline logic

    func testDueWithinAndNextDeadline() {
        let now = Date().timeIntervalSince1970
        storeFixture(now: now)

        let thisWeek = manager.dueWithin(days: 7, now: Date(timeIntervalSince1970: now))
        XCTAssertEqual(thisWeek.count, 1)
        XCTAssertEqual(thisWeek.first?.id, 503)

        XCTAssertEqual(manager.overdue(now: Date(timeIntervalSince1970: now)).count, 1)

        let next = manager.nextDeadline(now: Date(timeIntervalSince1970: now))
        XCTAssertEqual(next?.id, 503)
    }

    // MARK: - Briefing lines

    func testAssignmentsLine() {
        let now = Date().timeIntervalSince1970
        storeFixture(now: now)

        let line = manager.assignmentsLine(now: Date(timeIntervalSince1970: now))
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("1 assignment due this week"))
        XCTAssertTrue(line!.contains("1 overdue"))
        XCTAssertTrue(line!.contains("Essay draft"))
    }

    func testAssignmentsLineNilWhenQuiet() {
        let course = NYUCourse(id: 101, name: "Calculus I", code: "MATH-UA 121", term: "",
                               professor: "", syllabus: "", currentScore: nil, projectedScore: nil)
        let done = NYUAssignment(id: 501, courseID: 101, name: "Done", details: "",
                                 dueAt: Date().timeIntervalSince1970 - 86_400,
                                 pointsPossible: 10, submittedAt: Date().timeIntervalSince1970 - 86_400,
                                 score: 9, url: "")
        manager.storeSync(courses: [course], assignments: [done], announcements: [], now: Date().timeIntervalSince1970)
        XCTAssertNil(manager.assignmentsLine())
    }

    func testGradesLineTracksTrend() {
        let now = Date().timeIntervalSince1970
        var course = NYUCourse(id: 101, name: "Calculus I", code: "MATH-UA 121", term: "",
                               professor: "Dr. Lively", syllabus: "",
                               currentScore: 90, projectedScore: nil)
        manager.storeSync(courses: [course], assignments: [], announcements: [], now: now)

        // Second sync with a higher score → previous_score records the old one.
        course = NYUCourse(id: 101, name: "Calculus I", code: "MATH-UA 121", term: "",
                           professor: "Dr. Lively", syllabus: "",
                           currentScore: 95, projectedScore: nil)
        manager.storeSync(courses: [course], assignments: [], announcements: [], now: now + 3600)

        let row = manager.listCourses().first
        XCTAssertEqual(row?.trend, "improving")

        let line = manager.gradesLine()
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("Calculus I"))
        XCTAssertTrue(line!.contains("improving"))
    }

    // MARK: - Syllabus extraction

    func testGradingBreakdownExtractsPercentages() {
        let syllabus = """
        Grading:
        Homework 20%
        Midterm 30%
        Final exam 50%
        Participation 5%
        """
        let breakdown = NYUIntegrationManager.gradingBreakdown(from: syllabus)
        XCTAssertEqual(breakdown["homework"], 20)
        XCTAssertEqual(breakdown["midterm"], 30)
        XCTAssertEqual(breakdown["final exam"], 50)
        XCTAssertEqual(breakdown["participation"], 5)
    }

    func testExamDateParsesMonthName() {
        let syllabus = """
        There is no makeup for the midterm.
        Final Exam: December 18
        Office hours Th 2-4pm.
        """
        let date = NYUIntegrationManager.examDate(from: syllabus)
        XCTAssertNotNil(date)
        let components = Calendar.current.dateComponents([.month, .day], from: date!)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 18)
    }

    func testExamDateParsesISO() {
        let date = NYUIntegrationManager.parseDate(in: "Final on 2026-12-18 at 2pm")
        XCTAssertNotNil(date)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 18)
    }

    // MARK: - Helpers

    /// One course + three assignments: graded, overdue, and due in 2 days.
    private func storeFixture(now: TimeInterval) {
        let course = NYUCourse(id: 101, name: "Calculus I", code: "MATH-UA 121", term: "Fall 2026",
                               professor: "Dr. Lively", syllabus: "",
                               currentScore: 92.5, projectedScore: 90.0)
        let graded = NYUAssignment(id: 501, courseID: 101, name: "Problem Set 3", details: "",
                                   dueAt: now - 86_400, pointsPossible: 20,
                                   submittedAt: now - 2 * 86_400, score: 18, url: "")
        let overdue = NYUAssignment(id: 502, courseID: 101, name: "Essay draft", details: "",
                                    dueAt: now - 86_400, pointsPossible: 10,
                                    submittedAt: nil, score: nil, url: "")
        let future = NYUAssignment(id: 503, courseID: 101, name: "CS project", details: "",
                                   dueAt: now + 3 * 86_400 + 3600, pointsPossible: 50,
                                   submittedAt: nil, score: nil, url: "")
        manager.storeSync(courses: [course], assignments: [graded, overdue, future],
                          announcements: [], now: now)
    }
}
