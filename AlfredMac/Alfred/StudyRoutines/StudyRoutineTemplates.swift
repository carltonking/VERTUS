// MARK: - StudyRoutineTemplates
//
// The pre-built Study Routines, offered alongside the generic templates as
// one-tap adds. Each is a single `.study` step; the StudyRoutineManager turns
// that step into the right action and adapts it to the user's current
// mastery, problem sets and readings. Seeded on first launch by
// RoutineManager (via `RoutineTemplates.all`).

import Foundation

enum StudyRoutineTemplates {

    static let all: [RoutineTemplates.Template] = [
        RoutineTemplates.Template(
            name: "Daily Exam Prep",
            description: "Drill the weak concepts for every active exam — 5 practice problems a day, weakest first, until test day.",
            steps: [.study(action: "exam_prep")],
            schedule: .daily(hour: 7, minute: 0)),
        RoutineTemplates.Template(
            name: "Problem Set Check",
            description: "Report every problem set you're working through, in the recommended easy→hard order, with completion.",
            steps: [.study(action: "problem_sets")],
            schedule: .daily(hour: 18, minute: 0)),
        RoutineTemplates.Template(
            name: "Reading Quiz",
            description: "Quiz you on the readings whose spaced-repetition window has come up, so you retain instead of skim.",
            steps: [.study(action: "reading_quiz")],
            schedule: .daily(hour: 9, minute: 0)),
        RoutineTemplates.Template(
            name: "Lecture Notes Review",
            description: "Surface the lecture notes summarized today and their study questions, while they're fresh.",
            steps: [.study(action: "lecture_review")],
            schedule: .daily(hour: 20, minute: 0)),
        RoutineTemplates.Template(
            name: "Weekly Study Review",
            description: "Sunday progress report: what you're strong in, what needs practice, and the focus for the week ahead.",
            steps: [.study(action: "weekly_review")],
            schedule: .weekly(dayOfWeek: 1, hour: 18, minute: 0)),
    ]
}
