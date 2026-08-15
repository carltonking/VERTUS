// MARK: - StudyRoutineManager
//
// The orchestrator behind Alfred's Study Routines. It owns the SQLite store,
// the settings, and the five routines' Hermes turns, and it is what the MCP
// tools, the routine `.study` steps, the briefing card and the socket routes
// all call.
//
// Adaptivity is inherited, not reimplemented: exam prep and the weekly review
// read the Personal Tutor's live mastery (weak/strong concepts) and learning
// style, so "focus on your weak areas" means the tracker's actual weak areas
// and "5 problems a day" uses the user's learned teaching style.
//
// Threading matches PersonalTutorSkill (the proven pattern): a plain class, an
// NSLock guards settings, the store opens per-call FULLMUTEX connections, and
// every model turn is bounded and serialized through a turn gate so a
// background routine can never hijack or interleave with the user's session.

import Foundation
import UserNotifications

final class StudyRoutineManager {

    static let shared = StudyRoutineManager()

    /// The agent that writes drills, quizzes, summaries and reviews. Handed
    /// over at launch by the app delegate.
    weak var hermes: HermesSession?

    /// Test seam: a manager backed by a throwaway database, with pinned
    /// settings so one test's mutation can't leak into the next.
    static func makeForTesting(databasePath: String,
                               settings: StudyRoutineSettings = .default) -> StudyRoutineManager {
        StudyRoutineManager(store: StudyRoutineStore(databasePath: databasePath),
                            settings: settings)
    }

    private let store: StudyRoutineStore

    private let storageKey = "alfred.study_routine_settings"
    private let lock = NSLock()
    private var storedSettings: StudyRoutineSettings

    private let turnGate = StudyTurnGate()
    /// Hard cap on one study-routine model turn.
    static let turnTimeout: TimeInterval = 90

    private var timer: Timer?

    private init(store: StudyRoutineStore = StudyRoutineStore(),
                 settings: StudyRoutineSettings? = nil) {
        self.store = store
        storedSettings = settings ?? Self.load() ?? .default
    }

    // MARK: - Lifecycle

    /// Start the notification ticker (spaced-repetition reading reminders and
    /// the Sunday review nudge). Idempotent.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.notificationTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSLog("[study] notification ticker started")
        notificationTick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Settings

    private func readSettings() -> StudyRoutineSettings {
        lock.lock()
        defer { lock.unlock() }
        return storedSettings
    }

    private func mutateSettings(_ change: (inout StudyRoutineSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var updated = storedSettings
        change(&updated)
        guard updated != storedSettings else { return }
        storedSettings = updated
        persist()
    }

    var settings: StudyRoutineSettings {
        get { readSettings() }
        set { mutateSettings { $0 = newValue } }
    }

    var isEnabled: Bool {
        get { readSettings().enabled }
        set { mutateSettings { $0.enabled = newValue } }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func load() -> StudyRoutineSettings? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.study_routine_settings"),
              let settings = try? JSONDecoder().decode(StudyRoutineSettings.self, from: data)
        else { return nil }
        return settings
    }

    /// Test seam: reload persisted settings without the cached copy.
    static func loadForTest() -> StudyRoutineSettings? { load() }

    // MARK: - Wire helpers

    static func settingsWire(_ settings: StudyRoutineSettings) -> [String: Any] {
        [
            "enabled": settings.enabled,
            "exam_prep_lead_days": settings.examPrepLeadDays,
            "daily_practice_count": settings.dailyPracticeCount,
            "reading_quiz_frequency": settings.readingQuizFrequency.rawValue,
            "review_day": settings.reviewDay,
        ]
    }

    static func settings(from raw: Any?) -> StudyRoutineSettings? {
        guard let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return try? JSONDecoder().decode(StudyRoutineSettings.self, from: data)
    }

    /// The phone-facing aggregate: settings, exams, problem sets, readings.
    func statusWire() -> [String: Any] {
        var wire = Self.settingsWire(readSettings())
        wire["exams"] = examPrepLines().map { line -> [String: Any] in
            [
                "course": line.course ?? "",
                "readiness": line.readiness,
                "days_until_exam": line.daysUntilExam ?? 0,
                "focus": line.focus,
            ]
        }
        wire["problem_sets"] = store.listProblemSets().map { set -> [String: Any] in
            [
                "id": set.id, "name": set.name, "course": set.course ?? "",
                "source": set.source, "solved": set.solvedCount, "total": set.total,
                "completion": set.completion,
            ]
        }
        wire["readings"] = store.listReadings().map { reading -> [String: Any] in
            [
                "id": reading.id, "title": reading.title, "course": reading.course ?? "",
                "score": reading.quizScore ?? -1, "next_due_at": reading.nextDueAt ?? 0,
            ]
        }
        return wire
    }

    // MARK: - Exam prep

    /// The `start_exam_prep` tool: create/refresh an exam-prep plan. The daily
    /// routine (and briefing) then drill this plan's weak concepts until the
    /// exam. Returns the status line.
    func startExamPrep(examDate: String?, topics: [String], course: String?) -> String {
        guard readSettings().enabled else {
            return "Study routines are off — enable them in Settings."
        }
        let dateInterval = examDate.flatMap { Self.parseExamDate($0) }
        let id = "exam:" + (course?.lowercased() ?? "default")
        let plan = store.upsertExamPrep(id: id, course: course,
                                        examDate: dateInterval, topics: topics)
        let weak = PersonalTutorSkill.shared.weakConcepts()
        let readiness = ExamPrepRoutine.computeReadiness(
            weakConcepts: weak, problemSets: store.listProblemSets())
        let focus = ExamPrepRoutine.focus(for: weak)

        var lines = ["Exam prep started. " + ExamPrepRoutine.statusText(
            plan: plan, readiness: readiness, focus: focus)]
        if dateInterval == nil, let examDate, !examDate.isEmpty {
            lines.append("(I couldn't parse \"\(examDate)\" as a date — use YYYY-MM-DD, a weekday like \"Friday\", or \"in 14 days\". The plan will drill daily with no end date.)")
        }
        return lines.joined(separator: "\n")
    }

    /// One exam line per active plan, readiness + focus computed live.
    func examPrepLines() -> [StudyExamLine] {
        let weak = PersonalTutorSkill.shared.weakConcepts()
        let sets = store.listProblemSets()
        return store.activeExamPreps().map { plan in
            StudyExamLine(
                course: plan.course,
                readiness: ExamPrepRoutine.computeReadiness(weakConcepts: weak, problemSets: sets),
                daysUntilExam: ExamPrepRoutine.daysUntil(examDate: plan.examDate),
                focus: ExamPrepRoutine.focus(for: weak))
        }
    }

    // MARK: - Problem sets

    /// The `track_problem_set` tool: order the problems easy → hard and track
    /// completion. Re-posting with `solvedIndices` updates progress.
    func trackProblemSet(problems: [String], course: String?, name: String?,
                         source: String, solvedIndices: [Int] = []) -> String {
        guard readSettings().enabled else {
            return "Study routines are off — enable them in Settings."
        }
        let cleaned = problems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "No problems to track — pass the problem list." }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let setName = trimmedName.isEmpty
            ? "Problem set \(Date().formatted(date: .abbreviated, time: .omitted))"
            : trimmedName
        let id = trimmedName.isEmpty ? UUID().uuidString : "set:" + setName.lowercased()

        var items = ProblemSetRoutine.build(texts: cleaned)
        for index in solvedIndices where index >= 0 && index < items.count {
            items[index].status = .solved
        }

        let set = ProblemSet(
            id: id, name: setName, course: course, source: source,
            assignmentID: nil, dueAt: nil, problems: items,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970)
        store.upsertProblemSet(set)

        let difficultyNames = ["easy", "medium", "hard"]
        var lines = ["Tracking \(setName)\(course.map { " — \($0)" } ?? "") — \(items.count) problem\(items.count == 1 ? "" : "s"), ordered easy → hard:"]
        lines.append(contentsOf: items.map { item in
            let mark = item.status == .solved ? "✓" : " "
            return "\\(mark) \\(item.order + 1). [\\(difficultyNames[item.difficulty - 1])] \\(item.text.prefix(80))"
        })
        lines.append("")
        lines.append("\(set.solvedCount)/\(set.total) solved. Re-post the list with `solved` indices as you finish problems and I'll keep the count current.")
        return lines.joined(separator: "\n")
    }

    func markProblemSolved(problemID: String) -> String {
        guard let set = store.setProblemStatus(problemID: problemID, status: .solved) else {
            return "I couldn't find that problem."
        }
        return ProblemSetRoutine.statusText(for: set)
    }

    // MARK: - Reading

    /// Readings whose spaced-repetition window is open.
    func dueReadings() -> [ReadingAssignment] {
        store.readingsDue(now: Date().timeIntervalSince1970)
    }

    /// Record a quiz result: score + schedule the next quiz (SM-2-lite,
    /// floored by the configured frequency).
    @discardableResult
    func recordReadingQuiz(readingID: String, result: String) -> ReadingAssignment? {
        guard let reading = store.reading(id: readingID),
              let parsed = ReadingRoutine.score(from: result) else { return nil }
        let now = Date().timeIntervalSince1970
        let interval = ReadingRoutine.nextInterval(current: reading.intervalDays,
                                                   passed: parsed.passed)
        let floorDays = readSettings().readingQuizFrequency.minimumInterval / 86_400
        var updated = reading
        updated.quizScore = parsed.score
        updated.streak = ReadingRoutine.nextStreak(current: reading.streak,
                                                   passed: parsed.passed)
        updated.intervalDays = max(interval, floorDays)
        updated.lastQuizAt = now
        updated.nextDueAt = now + updated.intervalDays * 86_400
        return store.upsertReading(updated)
    }

    /// The `quiz_on_reading` tool. Two modes: generate comprehension questions
    /// (no `result`), or record how the user did and schedule the next quiz
    /// (`result` = "passed" / "3/5" / "80%").
    func quizOnReading(chapter: String, course: String?, content: String?,
                       result: String?) async -> String {
        let trimmed = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Which reading would you like to be quizzed on?" }
        guard readSettings().enabled else { return "Study routines are off — enable them in Settings." }

        if let result {
            guard let reading = store.listReadings().first(where: {
                $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame
                    || $0.title.range(of: trimmed, options: .caseInsensitive) != nil
            }) else {
                return "I don't have a reading titled \"\(trimmed)\" yet — quiz it once first to create it."
            }
            guard let updated = recordReadingQuiz(readingID: reading.id, result: result) else {
                return "I couldn't parse \"\(result)\" — say \"passed\" or a score like \"4/5\" or \"80%\"."
            }
            let next = updated.nextDueAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "soon"
            return "Logged \(Int(((updated.quizScore ?? 0) * 100).rounded()))% on \"\(updated.title)\". Next quiz: \(next)."
        }

        guard let hermes else {
            return "I'm not set up to quiz you right now — try again when Alfred's agent is running."
        }
        let existing = store.listReadings().first {
            $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        let prompt = ReadingRoutine.quizPrompt(
            title: trimmed, course: course, keyPoints: existing?.keyPoints ?? [],
            content: content, questionCount: 5)
        guard let json = await runBoundedTurn(prompt),
              let questions = json["questions"] as? [[String: Any]],
              !questions.isEmpty else {
            return "I couldn't put together a quiz just now. Try again in a moment."
        }
        let keyPoints = json["key_points"] as? [String] ?? []
        let now = Date().timeIntervalSince1970
        let reading = ReadingAssignment(
            id: existing?.id ?? UUID().uuidString,
            title: trimmed, course: course, keyPoints: keyPoints,
            questions: questions.compactMap { $0["question"] as? String },
            quizScore: existing?.quizScore, streak: existing?.streak ?? 0,
            intervalDays: existing?.intervalDays ?? 1,
            lastQuizAt: existing?.lastQuizAt, nextDueAt: existing?.nextDueAt ?? now,
            createdAt: existing?.createdAt ?? now)
        store.upsertReading(reading)

        var lines = ["Quiz on \"\(trimmed)\" (reading id: \(reading.id)):"]
        for (index, question) in reading.questions.enumerated() {
            lines.append("Q\(index + 1). \(question)")
        }
        lines.append("")
        lines.append("Ask the user these, then grade against the model answers and record the result by calling quiz_on_reading with `result`.")
        lines.append("Model answers (do NOT show the user):")
        for (index, question) in questions.enumerated() {
            lines.append("\(index + 1). \(question["answer"] as? String ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lecture notes

    /// The `summarize_lecture` tool: summarize dictated notes or a pasted
    /// transcript, then store the notes + study questions.
    func summarizeLecture(recordingOrNotes: String, course: String?,
                          title: String?) async -> String {
        let trimmed = recordingOrNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What would you like me to summarize?" }
        guard readSettings().enabled else { return "Study routines are off — enable them in Settings." }

        if LectureNoteRoutine.isRecordingReference(trimmed) {
            return "That looks like a recording path. Audio transcription isn't wired up yet — paste the transcript (or dictate your notes as text) and I'll summarize it."
        }
        guard let hermes else {
            return "I'm not set up to summarize right now — try again when Alfred's agent is running."
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lectureTitle = trimmedTitle.isEmpty
            ? "Lecture \(Date().formatted(date: .abbreviated, time: .omitted))"
            : trimmedTitle
        let prompt = LectureNoteRoutine.lecturePrompt(
            title: lectureTitle, course: course, content: trimmed)
        guard let json = await runBoundedTurn(prompt),
              let summary = json["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "I couldn't summarize that just now. Try again in a moment."
        }
        let keyPoints = json["key_points"] as? [String] ?? []
        let questions = json["questions"] as? [String] ?? []
        let note = LectureNote(
            id: UUID().uuidString, title: lectureTitle, course: course,
            summary: summary, keyPoints: keyPoints, questions: questions,
            createdAt: Date().timeIntervalSince1970)
        store.upsertLecture(note)

        var lines = ["\(lectureTitle)\(course.map { " — \($0)" } ?? ""):", "", summary]
        if !keyPoints.isEmpty {
            lines.append("")
            lines.append("Key points:")
            lines.append(contentsOf: keyPoints.map { "• \($0)" })
        }
        if !questions.isEmpty {
            lines.append("")
            lines.append("Study questions:")
            lines.append(contentsOf: questions.map { "• \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Weekly review

    /// The `weekly_review` tool and Sunday routine step: a progress report
    /// built from mastery, grades, problem sets, readings and lectures.
    func weeklyReview() async -> String {
        guard readSettings().enabled else {
            return "Study routines are off — enable them in Settings."
        }
        let tutor = PersonalTutorSkill.shared
        let weak = tutor.weakConcepts().map(\.name)
        let strong = tutor.strongConcepts().map(\.name)

        let weekStart = WeeklyReviewRoutine.weekStart(
            for: Date(), reviewDay: readSettings().reviewDay).timeIntervalSince1970
        let lectures = store.listLectures(since: weekStart).map(\.title)
        let setLines = store.listProblemSets()
            .filter { !$0.isComplete }
            .map { ProblemSetRoutine.statusText(for: $0) }
        let readings = store.listReadings().map { reading -> String in
            let score = reading.quizScore.map { "\(Int(($0 * 100).rounded()))%" } ?? "not quizzed"
            return "\(reading.title) (\(score))"
        }
        let gradesLines: [String] = await MainActor.run {
            if let line = NYUIntegrationManager.shared.gradesLine() { return [line] }
            return []
        }

        let prompt = WeeklyReviewRoutine.buildPrompt(
            strong: strong, weak: weak, grades: gradesLines,
            problemSets: setLines, readings: readings, lectures: lectures)

        var summary: String
        var strongOut = strong
        var weakOut = weak
        var focusOut: [String] = []
        if let hermes, let json = await runBoundedTurn(prompt),
           let parsed = WeeklyReviewRoutine.parseReport(json) {
            strongOut = parsed.strong
            weakOut = parsed.weak
            focusOut = parsed.focus
            summary = parsed.summary
        } else {
            summary = WeeklyReviewRoutine.fallbackReport(strong: strong, weak: weak)
            focusOut = weak.isEmpty ? [] : Array(weak.prefix(3))
        }

        let report = WeeklyReviewReport(
            id: UUID().uuidString, weekStart: weekStart,
            strong: strongOut, weak: weakOut, focusNextWeek: focusOut,
            summary: summary, createdAt: Date().timeIntervalSince1970)
        store.addWeeklyReview(report)

        if focusOut.isEmpty { return summary }
        return summary + "\n\nFocus for next week: \(focusOut.joined(separator: ", "))."
    }

    // MARK: - Routine step

    /// Execute one `.study` routine step. Never throws; every action is a
    /// `(success, output)` pair for the RoutineManager step runner.
    func runStep(action: String) async -> (success: Bool, output: String) {
        guard readSettings().enabled else {
            return (false, "Study routines are off — enable them in Settings.")
        }
        switch action {
        case "exam_prep":
            return await runExamPrepStep()
        case "problem_sets":
            let text = ProblemSetRoutine.statusText(sets: store.listProblemSets())
            return (true, text)
        case "reading_quiz":
            let due = dueReadings()
            var text = ReadingRoutine.statusText(readings: store.listReadings(), due: due)
            if !due.isEmpty {
                text += "\n\nSay \"quiz me on <reading>\" to take the quiz now."
            }
            return (true, text)
        case "lecture_review":
            let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let notes = store.listLectures(since: start)
            return (true, LectureNoteRoutine.statusText(notes: notes))
        case "weekly_review":
            return (true, await weeklyReview())
        default:
            return (false, "Unknown study action '\(action)'.")
        }
    }

    /// The exam-prep step: for each active plan, report readiness + focus and
    /// generate the phase-appropriate drill (daily practice → full practice
    /// test in the final week → final review the day before).
    private func runExamPrepStep() async -> (success: Bool, output: String) {
        let plans = store.activeExamPreps()
        guard !plans.isEmpty else {
            return (true, "No exam-prep plan is active. Say \"prepare for my exam\" (or call start_exam_prep) and Alfred will drill your weak concepts daily.")
        }
        let weak = PersonalTutorSkill.shared.weakConcepts()
        let sets = store.listProblemSets()
        let settings = readSettings()
        var sections: [String] = []
        for plan in plans {
            let days = ExamPrepRoutine.daysUntil(examDate: plan.examDate)
            let phase = ExamPrepRoutine.phase(daysUntil: days)
            let readiness = ExamPrepRoutine.computeReadiness(weakConcepts: weak, problemSets: sets)
            let focus = ExamPrepRoutine.focus(for: weak)
            var header = "\(plan.course ?? "Exam") — \(phase.label) (\(readiness)% ready)"
            if !focus.isEmpty { header += " · focus: \(focus.joined(separator: ", "))" }
            store.recordDrill(id: plan.id)

            let examLabel = plan.examDate.map {
                Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted)
            }
            let instruction = ExamPrepRoutine.phaseInstruction(
                phase, practiceCount: settings.dailyPracticeCount)
            let drill = await PersonalTutorSkill.shared.examPrep(
                examDate: examLabel, topics: plan.topics, instruction: instruction)
            sections.append(header + (drill.isEmpty ? "" : "\n\n\(drill)"))
        }
        return (true, sections.joined(separator: "\n\n"))
    }

    // MARK: - Briefing

    /// The Study card for the briefing. Nil while there is nothing to report.
    func briefingCard() -> StudyBriefingCard? {
        guard readSettings().enabled else { return nil }
        let exams = examPrepLines()
        let sets = store.listProblemSets()
            .filter { !$0.isComplete }
            .map { StudyProblemSetLine(name: $0.name, solved: $0.solvedCount, total: $0.total) }
        let readings = dueReadings().map { StudyReadingLine(title: $0.title, score: $0.quizScore) }
        let weekly = store.latestWeeklyReview()?.summary
        guard !exams.isEmpty || !sets.isEmpty || !readings.isEmpty || weekly != nil else {
            return nil
        }
        return StudyBriefingCard(
            exams: exams, problemSets: sets, readingsDue: readings,
            weeklySummary: weekly)
    }

    /// One compact sentence for the briefing summary (the prose, not the card).
    func briefingLine() -> String? {
        guard readSettings().enabled else { return nil }
        var parts: [String] = []
        for line in examPrepLines() {
            parts.append("\(line.course ?? "Exam") \(line.readiness)% ready")
        }
        let open = store.listProblemSets().filter { !$0.isComplete }
        if !open.isEmpty {
            let done = open.reduce(0) { $0 + $1.solvedCount }
            let total = open.reduce(0) { $0 + $1.total }
            parts.append("\(open.count) problem set\(open.count == 1 ? "" : "s") in progress (\(done)/\(total) done)")
        }
        let due = dueReadings()
        if !due.isEmpty {
            parts.append("\(due.count) reading\(due.count == 1 ? "" : "s") due for a quiz")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }

    // MARK: - Notifications

    /// Every minute: nudge on due readings (deduplicated by the set of due
    /// ids) and the weekly review on the configured review day (once a week).
    private func notificationTick() {
        guard readSettings().enabled else { return }
        let notifiedKey = "alfred.study_readings_notified"
        let due = dueReadings()
        let signature = due.map(\.id).sorted().joined(separator: ",")
        let previous = UserDefaults.standard.string(forKey: notifiedKey) ?? ""
        if !due.isEmpty, signature != previous {
            let body = due.count == 1
                ? "Quiz time on \"\(due[0].title)\"."
                : "\(due.count) readings are due for a quiz."
            postNotification(title: "Reading quiz due", body: body)
            UserDefaults.standard.set(signature, forKey: notifiedKey)
        } else if due.isEmpty, !previous.isEmpty {
            UserDefaults.standard.set("", forKey: notifiedKey)
        }

        let weeklyKey = "alfred.study_weekly_notified"
        let weekday = Calendar.current.component(.weekday, from: Date())
        if weekday == readSettings().reviewDay {
            let weekStart = WeeklyReviewRoutine.weekStart(
                for: Date(), reviewDay: readSettings().reviewDay).timeIntervalSince1970
            let lastNotified = UserDefaults.standard.double(forKey: weeklyKey)
            if weekStart > lastNotified {
                postNotification(
                    title: "Weekly study review",
                    body: "Your weekly review is ready — see where you stand and what to focus on.")
                UserDefaults.standard.set(weekStart, forKey: weeklyKey)
            }
        }
    }

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .active
        let request = UNNotificationRequest(
            identifier: "study-\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("[study] notification failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Date parsing

    /// Parse a user-typed exam date: ISO, "December 15", a weekday, "in N
    /// days/weeks", "today", "tomorrow". Nil when unparseable.
    static func parseExamDate(_ raw: String) -> TimeInterval? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let cal = Calendar.current
        let now = Date()

        if lower == "today" { return now.timeIntervalSince1970 }
        if lower == "tomorrow" {
            return cal.date(byAdding: .day, value: 1, to: now)?.timeIntervalSince1970
        }
        if let range = lower.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: String(lower[range]))?.timeIntervalSince1970
        }
        for format in ["MMMM d yyyy", "MMM d yyyy", "MMMM d", "MMM d"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = format
            if let date = f.date(from: t) { return date.timeIntervalSince1970 }
        }
        let weekdays = cal.weekdaySymbols.map { $0.lowercased() }
        if let index = weekdays.firstIndex(of: lower) {
            let target = index + 1
            let today = cal.component(.weekday, from: now)
            var days = target - today
            if days <= 0 { days += 7 }
            return cal.date(byAdding: .day, value: days, to: now)?.timeIntervalSince1970
        }
        if let match = lower.range(of: #"in\s+(\d+)\s+(day|week)s?"#, options: .regularExpression) {
            let parts = lower[match].split(separator: " ")
            guard parts.count == 3, let count = Int(parts[1]) else { return nil }
            let unit = parts[2].hasPrefix("week") ? 7 : 1
            return cal.date(byAdding: .day, value: count * unit, to: now)?.timeIntervalSince1970
        }
        return nil
    }

    // MARK: - Bounded Hermes turn (mirrors PersonalTutorSkill)

    private func runBoundedTurn(_ prompt: String,
                                timeout: TimeInterval = turnTimeout) async -> [String: Any]? {
        guard let hermes else { return nil }
        let outcome = await turnGate.enqueue { [weak self] in
            guard let self, let hermes = self.hermes else { return nil }
            guard !(await hermes.isTurnActive) else { return nil }
            return await PersonalTutorSkill.runPromptBounded(hermes, prompt: prompt, timeout: timeout)
        }
        return outcome
    }
}

// MARK: - Turn gate

/// Serializes the manager's model turns, mirroring PersonalTutorSkill's gate:
/// HermesSession is single-turn, so a second concurrent prompt would
/// overwrite the first's event sink. The `isTurnActive` re-check runs inside
/// the gate at prompt time (TOCTOU-safe).
private actor StudyTurnGate {
    private var previous: Task<[String: Any]?, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> [String: Any]?)
        async -> [String: Any]? {
        let prior = previous
        let task = Task { [prior] in
            _ = await prior?.value
            return await operation()
        }
        previous = task
        return await task.value
    }
}
