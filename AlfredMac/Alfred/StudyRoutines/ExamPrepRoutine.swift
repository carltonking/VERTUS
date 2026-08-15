// MARK: - ExamPrepRoutine
//
// The exam-prep engine: turns the tutor's live mastery data and the problem
// sets into a readiness score, the focus list, and the right drill for the
// distance to the exam. Pure and static so the scoring unit-tests with fixed
// expectations; the manager does the Hermes turn and store writes.

import Foundation

enum ExamPrepRoutine {

    /// Which prep phase today's drill belongs in, by days until the exam.
    enum Phase: Equatable {
        /// No date on the plan — a steady daily drill on weak areas.
        case steadyDrill
        /// More than a week out — targeted daily practice.
        case dailyPractice
        /// The final week — a full, timed, realistic practice test.
        case fullPracticeTest
        /// The day before — final review of formulas / key concepts.
        case finalReview
        /// Exam day (or past) — a last-minute recap.
        case examDay

        var label: String {
            switch self {
            case .steadyDrill:      return "Daily practice"
            case .dailyPractice:    return "Daily practice"
            case .fullPracticeTest: return "Full practice test"
            case .finalReview:      return "Final review"
            case .examDay:          return "Exam-day recap"
            }
        }
    }

    /// Whole days until the exam (ceiling, so "tomorrow" is 1, "today" is 0).
    static func daysUntil(examDate: TimeInterval?, now: Date = Date()) -> Int? {
        guard let examDate else { return nil }
        let delta = examDate - now.timeIntervalSince1970
        return Int((delta / 86_400).rounded(.up))
    }

    /// The prep phase for a given distance. No date → steady drill.
    static func phase(daysUntil: Int?) -> Phase {
        guard let daysUntil else { return .steadyDrill }
        if daysUntil <= 0 { return .examDay }
        if daysUntil <= 1 { return .finalReview }
        if daysUntil <= 7 { return .fullPracticeTest }
        return .dailyPractice
    }

    /// A 0–100 readiness: half from how well the weak concepts are held,
    /// half from problem-set completion. No weak concepts → that half is
    /// full marks; no problem sets → that half sits at a neutral 50 (no
    /// signal yet, not a failing grade).
    static func computeReadiness(weakConcepts: [ConceptMastery],
                                 problemSets: [ProblemSet]) -> Int {
        let confidenceScore: Double
        if weakConcepts.isEmpty {
            confidenceScore = 100
        } else {
            let total = weakConcepts.map(\.confidence).reduce(0, +)
            let average = Double(total) / Double(weakConcepts.count)
            confidenceScore = ((average - 1) / 4) * 100
        }

        let completionScore: Double
        if problemSets.isEmpty {
            completionScore = 50
        } else {
            let total = problemSets.map(\.completion).reduce(0, +)
            completionScore = (total / Double(problemSets.count)) * 100
        }

        let raw = 0.5 * confidenceScore + 0.5 * completionScore
        return min(100, max(0, Int(raw.rounded())))
    }

    /// The weakest concept names, up to `limit`.
    static func focus(for weakConcepts: [ConceptMastery], limit: Int = 3) -> [String] {
        Array(weakConcepts.prefix(limit).map(\.name))
    }

    /// The status line the MCP tool and briefing show:
    /// "Calculus exam Dec 15 (12 days): 85% ready. Focus on integrals, series."
    static func statusText(plan: ExamPrepPlan, readiness: Int, focus: [String],
                           now: Date = Date()) -> String {
        let coursePart = plan.course.map { "\($0) exam" } ?? "Exam"
        let datePart: String
        if let days = daysUntil(examDate: plan.examDate, now: now) {
            if days <= 0 {
                datePart = "is today"
            } else if let date = plan.examDate {
                datePart = "is \(Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .omitted)) (\(days) day\(days == 1 ? "" : "s"))"
            } else {
                datePart = "is in \(days) day\(days == 1 ? "" : "s")"
            }
        } else {
            datePart = "has no date set"
        }

        var line = "\(coursePart) \(datePart): \(readiness)% ready"
        if !focus.isEmpty {
            line += ". Focus on \(focus.joined(separator: ", "))."
        } else {
            line += "."
        }
        return line
    }

    /// The instruction block the drill prompt embeds, keyed to the phase so
    /// the final week produces a full test and the last day a formula recap.
    static func phaseInstruction(_ phase: Phase, practiceCount: Int) -> String {
        switch phase {
        case .steadyDrill, .dailyPractice:
            return "Generate \(practiceCount) practice problems on the weak concepts below, weakest first, each with its full answer and a short explanation."
        case .fullPracticeTest:
            return "Generate a full, timed, realistic practice test (aim ~45 minutes) covering the weak concepts below plus a spread of the surrounding topics, with answers and explanations so the user can self-grade."
        case .finalReview:
            return "Produce a final review of the key formulas, definitions and concepts the user must have cold, ordered by the weak concepts below, tight and memorizable."
        case .examDay:
            return "Produce a one-screen recap of the most important formulas and concepts — the last thing to look at before walking in."
        }
    }
}
