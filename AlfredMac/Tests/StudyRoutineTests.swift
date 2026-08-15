import XCTest
@testable import Alfred

/// Covers the deterministic parts of the Study Routines: the easy→hard
/// problem ordering, the spaced-repetition schedule, the exam-readiness
/// scoring, the weekly-review week math, the lecture/reading engines, the
/// settings wire round-trip, and the manager's Hermes-free orchestration
/// (problem-set tracking, exam-prep start, reading-quiz scoring, briefing
/// card). Everything runs against throwaway databases so the real
/// `~/.alfred/study.db` is never touched.
final class StudyRoutineTests: XCTestCase {

    private func tempDBPath() -> String {
        NSTemporaryDirectory() + "alfred-study-\(UUID().uuidString).db"
    }

    private func makeManager() -> StudyRoutineManager {
        StudyRoutineManager.makeForTesting(databasePath: tempDBPath())
    }

    // MARK: - Settings

    func testSettingsDefaults() {
        let defaults = StudyRoutineSettings.default
        XCTAssertTrue(defaults.enabled)
        XCTAssertEqual(defaults.examPrepLeadDays, 14)
        XCTAssertEqual(defaults.dailyPracticeCount, 5)
        XCTAssertEqual(defaults.readingQuizFrequency, .daily)
        XCTAssertEqual(defaults.reviewDay, 1)
    }

    func testSettingsWireRoundTrip() {
        let settings = StudyRoutineSettings(
            enabled: false, examPrepLeadDays: 21, dailyPracticeCount: 8,
            readingQuizFrequency: .weekly, reviewDay: 3)
        let wire = StudyRoutineManager.settingsWire(settings)
        let decoded = StudyRoutineManager.settings(from: wire)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Problem ordering

    func testDifficultyGradesProveHarderThanCompute() {
        XCTAssertEqual(ProblemSetRoutine.difficulty(of: "Compute the derivative of x^2"), 2)
        XCTAssertEqual(ProblemSetRoutine.difficulty(of: "Prove that the function is continuous"), 3)
        XCTAssertEqual(ProblemSetRoutine.difficulty(of: "What is 2 + 2"), 1)
    }

    func testOrderedIndicesPutEasyFirst() {
        let texts = [
            "Prove the fundamental theorem",  // hard
            "Compute the integral of x dx",   // medium
            "What is 2 + 2",                  // easy
        ]
        let indices = ProblemSetRoutine.orderedIndices(texts: texts)
        XCTAssertEqual(indices, [2, 1, 0])
    }

    func testBuildAssignsDifficultyAndOrder() {
        let items = ProblemSetRoutine.build(texts: [
            "Prove X", "Compute Y", "What is Z",
        ])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.text, "What is Z")
        XCTAssertEqual(items.first?.difficulty, 1)
        XCTAssertEqual(items.last?.text, "Prove X")
        XCTAssertEqual(items.last?.difficulty, 3)
        XCTAssertEqual(items.map(\.order), [0, 1, 2])
    }

    func testProblemSetCompletionAndStatus() {
        let items = ProblemSetRoutine.build(texts: ["A", "B", "C"])
        var set = ProblemSet(
            id: "s1", name: "HW 1", course: "MATH-UA 122", source: "manual",
            assignmentID: nil, dueAt: nil, problems: items,
            createdAt: 0, updatedAt: 0)
        XCTAssertEqual(set.completion, 0, accuracy: 0.001)
        XCTAssertFalse(set.isComplete)
        XCTAssertTrue(ProblemSetRoutine.statusText(for: set).contains("0/3 done"))

        set.problems[0].status = .solved
        set.problems[1].status = .solved
        XCTAssertEqual(set.completion, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertTrue(ProblemSetRoutine.statusText(for: set).contains("2/3 done"))
    }

    // MARK: - Spaced repetition

    func testSpacingDoublesOnPassAndResetsOnFail() {
        XCTAssertEqual(ReadingRoutine.nextInterval(current: 1, passed: true), 2)
        XCTAssertEqual(ReadingRoutine.nextInterval(current: 4, passed: true), 8)
        XCTAssertEqual(ReadingRoutine.nextInterval(current: 20, passed: true), 30)  // capped
        XCTAssertEqual(ReadingRoutine.nextInterval(current: 8, passed: false), 1)
        XCTAssertEqual(ReadingRoutine.nextStreak(current: 2, passed: true), 3)
        XCTAssertEqual(ReadingRoutine.nextStreak(current: 3, passed: false), 0)
    }

    func testReadingScoreParsing() {
        XCTAssertEqual(ReadingRoutine.score(from: "passed")?.passed, true)
        XCTAssertEqual(ReadingRoutine.score(from: "failed")?.passed, false)
        XCTAssertEqual(ReadingRoutine.score(from: "4/5")?.score ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(ReadingRoutine.score(from: "80%")?.score ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(ReadingRoutine.score(from: "0.75")?.score ?? 0, 0.75, accuracy: 0.001)
        XCTAssertNil(ReadingRoutine.score(from: "meh"))
    }

    // MARK: - Exam readiness

    func testReadinessCombinesWeakConfidenceAndCompletion() {
        // No weak concepts (full confidence half) + no problem sets (neutral
        // 50) → (100 + 50) / 2 = 75.
        let weak: [ConceptMastery] = []
        let sets: [ProblemSet] = []
        XCTAssertEqual(ExamPrepRoutine.computeReadiness(weakConcepts: weak, problemSets: sets), 75)

        // Weak concepts at confidence 1 (0%) + no sets (50%) → 25.
        let confused = ConceptMastery(
            id: "c", name: "integrals", course: nil, confidence: 1,
            sessionCount: 1, confusedCount: 1, masteredAt: nil,
            firstSeenAt: 0, lastSeenAt: 0)
        XCTAssertEqual(ExamPrepRoutine.computeReadiness(weakConcepts: [confused], problemSets: []), 25)
    }

    func testExamPhaseByDistance() {
        XCTAssertEqual(ExamPrepRoutine.phase(daysUntil: nil), .steadyDrill)
        XCTAssertEqual(ExamPrepRoutine.phase(daysUntil: 10), .dailyPractice)
        XCTAssertEqual(ExamPrepRoutine.phase(daysUntil: 5), .fullPracticeTest)
        XCTAssertEqual(ExamPrepRoutine.phase(daysUntil: 1), .finalReview)
        XCTAssertEqual(ExamPrepRoutine.phase(daysUntil: 0), .examDay)
        XCTAssertEqual(ExamPrepRoutine.daysUntil(examDate: Date().timeIntervalSince1970 + 2 * 86_400), 2)
    }

    // MARK: - Weekly review

    func testWeekStartIsMostRecentSunday() {
        let cal = Calendar.current
        let start = WeeklyReviewRoutine.weekStart(for: Date(), reviewDay: 1)
        XCTAssertEqual(cal.component(.weekday, from: start), 1)
        XCTAssertLessThanOrEqual(start.timeIntervalSince1970, Date().timeIntervalSince1970)
    }

    func testWeeklyFallbackAndParse() {
        let fallback = WeeklyReviewRoutine.fallbackReport(strong: ["recursion"], weak: ["series"])
        XCTAssertTrue(fallback.contains("recursion"))
        XCTAssertTrue(fallback.contains("series"))
        XCTAssertTrue(fallback.contains("Focus for next week"))

        let parsed = WeeklyReviewRoutine.parseReport([
            "strong": ["a"], "weak": ["b"], "focus_next_week": ["c"],
            "summary": "You're doing well.",
        ])
        XCTAssertEqual(parsed?.strong, ["a"])
        XCTAssertEqual(parsed?.focus, ["c"])
        XCTAssertNil(WeeklyReviewRoutine.parseReport(["strong": ["a"]]))
    }

    // MARK: - Lecture engine

    func testRecordingReferenceDetection() {
        XCTAssertTrue(LectureNoteRoutine.isRecordingReference("/Users/c/lecture.m4a"))
        XCTAssertTrue(LectureNoteRoutine.isRecordingReference("~/notes.mp3"))
        XCTAssertFalse(LectureNoteRoutine.isRecordingReference("Today we covered integrals and series."))
    }

    // MARK: - Store round-trips

    func testStoreProblemSetRoundTrip() {
        let store = StudyRoutineStore(databasePath: tempDBPath())
        let items = ProblemSetRoutine.build(texts: ["A", "B"])
        let set = ProblemSet(
            id: "s1", name: "HW 2", course: "CSCI-UA 101", source: "manual",
            assignmentID: nil, dueAt: nil, problems: items,
            createdAt: 1, updatedAt: 1)
        store.upsertProblemSet(set)
        XCTAssertEqual(store.problemSet(id: "s1")?.problems.count, 2)
        XCTAssertEqual(store.listProblemSets().count, 1)

        let solved = store.setProblemStatus(problemID: items[0].id, status: .solved)
        XCTAssertEqual(solved?.solvedCount, 1)
    }

    func testStoreReadingsDue() {
        let store = StudyRoutineStore(databasePath: tempDBPath())
        let past = Date().timeIntervalSince1970 - 100
        let future = Date().timeIntervalSince1970 + 86_400
        store.upsertReading(ReadingAssignment(
            id: "due", title: "Ch 1", course: nil, keyPoints: [], questions: [],
            quizScore: nil, streak: 0, intervalDays: 1, lastQuizAt: nil,
            nextDueAt: past, createdAt: past))
        store.upsertReading(ReadingAssignment(
            id: "later", title: "Ch 2", course: nil, keyPoints: [], questions: [],
            quizScore: nil, streak: 0, intervalDays: 1, lastQuizAt: nil,
            nextDueAt: future, createdAt: past))
        XCTAssertEqual(store.readingsDue().map(\.id), ["due"])
    }

    func testStoreExamPrepAndWeeklyReview() {
        let store = StudyRoutineStore(databasePath: tempDBPath())
        store.upsertExamPrep(id: "exam:calc", course: "MATH-UA 122",
                             examDate: Date().timeIntervalSince1970 + 86_400, topics: [])
        XCTAssertEqual(store.activeExamPreps().count, 1)
        store.recordDrill(id: "exam:calc")
        XCTAssertEqual(store.examPrep(id: "exam:calc")?.drillsRun, 1)

        let report = WeeklyReviewReport(
            id: "w", weekStart: 100, strong: ["a"], weak: ["b"],
            focusNextWeek: ["b"], summary: "s", createdAt: 200)
        store.addWeeklyReview(report)
        XCTAssertEqual(store.latestWeeklyReview()?.summary, "s")
    }

    // MARK: - Manager orchestration (Hermes-free)

    func testTrackProblemSetReportsCompletion() {
        let manager = makeManager()
        let text = manager.trackProblemSet(
            problems: ["Prove X", "Compute Y", "What is Z"],
            course: "MATH-UA 122", name: "HW 3", source: "manual")
        XCTAssertTrue(text.contains("HW 3"))
        XCTAssertTrue(text.contains("0/3 solved"))
        // Re-post with one solved → completion updates.
        let updated = manager.trackProblemSet(
            problems: ["Prove X", "Compute Y", "What is Z"],
            course: "MATH-UA 122", name: "HW 3", source: "manual", solvedIndices: [0])
        XCTAssertTrue(updated.contains("1/3 solved"))
    }

    func testStartExamPrepCreatesPlanAndStatus() {
        let manager = makeManager()
        let text = manager.startExamPrep(
            examDate: "in 14 days", topics: [], course: "MATH-UA 122")
        XCTAssertTrue(text.contains("Exam prep started"))
        XCTAssertTrue(text.contains("MATH-UA 122"))
        let exams = manager.statusWire()["exams"] as? [[String: Any]] ?? []
        XCTAssertEqual(exams.count, 1)
    }

    func testRecordReadingQuizSchedulesNext() {
        let path = tempDBPath()
        let store = StudyRoutineStore(databasePath: path)
        store.upsertReading(ReadingAssignment(
            id: "r1", title: "Chapter 3", course: nil, keyPoints: [], questions: [],
            quizScore: nil, streak: 0, intervalDays: 1, lastQuizAt: nil,
            nextDueAt: Date().timeIntervalSince1970, createdAt: Date().timeIntervalSince1970))

        let manager = StudyRoutineManager.makeForTesting(databasePath: path)
        let updated = manager.recordReadingQuiz(readingID: "r1", result: "4/5")
        XCTAssertEqual(updated?.quizScore ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(updated?.streak, 1)
        XCTAssertEqual(updated?.intervalDays ?? 0, 2, accuracy: 0.001)
        XCTAssertNotNil(updated?.nextDueAt)
    }

    func testBriefingCardNilWhenEmptyAndPopulatedWhenTracking() {
        let manager = makeManager()
        XCTAssertNil(manager.briefingCard())
        XCTAssertNil(manager.briefingLine())

        manager.trackProblemSet(
            problems: ["A", "B"], course: nil, name: "HW", source: "manual")
        let card = manager.briefingCard()
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.problemSets.first?.name, "HW")
        XCTAssertEqual(card?.problemSets.first?.solved, 0)
        XCTAssertTrue(manager.briefingLine()?.contains("problem set") == true)
    }

    func testRunStepNoOpWithoutData() async {
        let manager = makeManager()
        let result = await manager.runStep(action: "problem_sets")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("No problem sets tracked"))
        let examResult = await manager.runStep(action: "exam_prep")
        XCTAssertTrue(examResult.output.contains("No exam-prep plan is active"))
    }

    // MARK: - Date parsing

    func testParseExamDate() {
        XCTAssertNil(StudyRoutineManager.parseExamDate("next tuesday-ish"))
        let today = StudyRoutineManager.parseExamDate("today")
        XCTAssertNotNil(today)
        if let today {
            XCTAssertEqual(today, Date().timeIntervalSince1970, accuracy: 120)
        }

        let twoWeeks = StudyRoutineManager.parseExamDate("in 14 days")
        XCTAssertNotNil(twoWeeks)
        if let twoWeeks {
            let expected = Date().timeIntervalSince1970 + 14 * 86_400
            XCTAssertEqual(twoWeeks, expected, accuracy: 120)
        }

        let iso = StudyRoutineManager.parseExamDate("2026-12-15")
        XCTAssertNotNil(iso)

        let friday = StudyRoutineManager.parseExamDate("friday")
        XCTAssertNotNil(friday)
        if let friday {
            let weekday = Calendar.current.component(.weekday, from: Date(timeIntervalSince1970: friday))
            XCTAssertEqual(weekday, 6)  // Friday
        }
    }
}
