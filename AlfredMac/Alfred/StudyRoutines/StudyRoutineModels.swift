// MARK: - Study routine models
//
// The shared types for Alfred's Study Routines. These are the shapes the
// SQLite store persists, the routine engines produce, and the briefing /
// socket / MCP surfaces carry. Everything is Codable so settings and cards
// cross the wire unchanged (same contract as TutorSettings / NYUSettings).

import Foundation

// MARK: - Settings

/// How often spaced-repetition reading quizzes can fire. The actual schedule
/// is the per-reading interval (SM-2-lite); this is the floor for how often
/// a *due* reading is re-quizzed.
enum ReadingQuizFrequency: String, Codable, CaseIterable, Sendable {
    case daily
    case every2Days = "every_2_days"
    case weekly

    var displayName: String {
        switch self {
        case .daily:      return "Daily"
        case .every2Days: return "Every 2 days"
        case .weekly:     return "Weekly"
        }
    }

    /// Minimum seconds between quizzes for the same reading under this
    /// frequency (spaced repetition can only lengthen it, never shorten).
    var minimumInterval: TimeInterval {
        switch self {
        case .daily:      return 86_400
        case .every2Days: return 2 * 86_400
        case .weekly:     return 7 * 86_400
        }
    }
}

/// The persisted study-routine configuration. Defaults match the spec: exam
/// prep starts 2 weeks out, 5 practice problems a day, daily reading quizzes,
/// Sunday review.
struct StudyRoutineSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    /// Days before an exam that the daily prep routine starts drilling.
    var examPrepLeadDays: Int
    /// Practice problems per daily exam-prep drill.
    var dailyPracticeCount: Int
    /// Floor for reading-quiz cadence (spaced repetition lengthens it).
    var readingQuizFrequency: ReadingQuizFrequency
    /// Weekly review day: 1 = Sunday … 7 = Saturday (Foundation's weekday).
    var reviewDay: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case examPrepLeadDays = "exam_prep_lead_days"
        case dailyPracticeCount = "daily_practice_count"
        case readingQuizFrequency = "reading_quiz_frequency"
        case reviewDay = "review_day"
    }

    static let `default` = StudyRoutineSettings(
        enabled: true,
        examPrepLeadDays: 14,
        dailyPracticeCount: 5,
        readingQuizFrequency: .daily,
        reviewDay: 1)
}

// MARK: - Problem sets

enum ProblemStatus: String, Codable, CaseIterable, Sendable {
    case unsolved
    case solved
}

/// One problem within a problem set, ordered easy → hard.
struct ProblemItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    /// 1 (easy) … 3 (hard), from the deterministic difficulty heuristic.
    var difficulty: Int
    var order: Int
    var status: ProblemStatus
    var concept: String?
}

/// A tracked problem set (from Canvas or typed in by hand).
struct ProblemSet: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var course: String?
    /// "canvas" | "manual".
    var source: String
    /// Canvas assignment id, when it came from a sync.
    var assignmentID: Int?
    var dueAt: TimeInterval?
    var problems: [ProblemItem]
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    var solvedCount: Int { problems.filter { $0.status == .solved }.count }
    var total: Int { problems.count }
    /// 0…1 fraction complete; an empty set counts as done.
    var completion: Double { total == 0 ? 1 : Double(solvedCount) / Double(total) }
    var isComplete: Bool { solvedCount == total }
}

// MARK: - Reading

/// One reading assignment with its comprehension questions and the
/// spaced-repetition state that decides when it's next quizzed.
struct ReadingAssignment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var course: String?
    var keyPoints: [String]
    var questions: [String]
    /// 0…1 fraction correct on the last quiz; nil until first quizzed.
    var quizScore: Double?
    /// Consecutive passed quizzes — drives interval doubling.
    var streak: Int
    /// Current spacing interval in days.
    var intervalDays: Double
    var lastQuizAt: TimeInterval?
    var nextDueAt: TimeInterval?
    var createdAt: TimeInterval
}

// MARK: - Lecture notes

/// One summarized lecture: transcript/summary, key points, study questions.
struct LectureNote: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var course: String?
    var summary: String
    var keyPoints: [String]
    var questions: [String]
    var createdAt: TimeInterval
}

// MARK: - Exam prep

/// A started exam-prep plan. Readiness and focus concepts are computed live
/// from the tutor's mastery tracker and the problem sets (they change as the
/// user studies), so the plan only stores the stable intent.
struct ExamPrepPlan: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var course: String?
    var examDate: TimeInterval?
    var topics: [String]
    var drillsRun: Int
    var lastRunAt: TimeInterval?
    var createdAt: TimeInterval
}

// MARK: - Weekly review

/// One Sunday review: strong areas, weak areas, and the week-ahead focus.
struct WeeklyReviewReport: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// Sunday (local) that starts the reviewed week.
    var weekStart: TimeInterval
    var strong: [String]
    var weak: [String]
    var focusNextWeek: [String]
    var summary: String
    var createdAt: TimeInterval
}

// MARK: - Briefing card

/// One exam's readiness line on the Study briefing card.
struct StudyExamLine: Codable, Equatable, Sendable {
    var course: String?
    var readiness: Int
    var daysUntilExam: Int?
    var focus: [String]
}

/// One in-progress problem set on the Study briefing card.
struct StudyProblemSetLine: Codable, Equatable, Sendable {
    var name: String
    var solved: Int
    var total: Int
}

/// One due reading on the Study briefing card.
struct StudyReadingLine: Codable, Equatable, Sendable {
    var title: String
    var score: Double?
}

/// The Study card the briefing carries. Optional on the wire so an old
/// briefing without the key still decodes, and nil while there is nothing to
/// report (no active prep, no problem sets, no readings, no review yet).
struct StudyBriefingCard: Codable, Equatable, Sendable {
    var exams: [StudyExamLine]
    var problemSets: [StudyProblemSetLine]
    var readingsDue: [StudyReadingLine]
    var weeklySummary: String?
}
