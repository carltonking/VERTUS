// MARK: - WeeklyReviewRoutine
//
// The weekly-review engine: assembles the week's signal (mastery, problem
// sets, readings, lecture notes, grades) into a "strong in X, need practice
// in Y, focus on Z next week" report. The prompt goes to Hermes; a
// deterministic fallback covers every degraded case.

import Foundation

enum WeeklyReviewRoutine {

    /// The most recent review-day (default Sunday) on or before `date`.
    static func weekStart(for date: Date = Date(), reviewDay: Int = 1) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        let today = comps.weekday ?? 1
        var back = today - reviewDay
        if back < 0 { back += 7 }
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: -back, to: start) ?? start
    }

    /// The review prompt's context block: everything the report can draw on.
    static func buildPrompt(strong: [String], weak: [String],
                            grades: [String], problemSets: [String],
                            readings: [String], lectures: [String]) -> String {
        var lines: [String] = []
        if strong.isEmpty {
            lines.append("Strong areas: none recorded yet.")
        } else {
            lines.append("Strong areas: \(strong.joined(separator: ", ")).")
        }
        if weak.isEmpty {
            lines.append("Weak areas: none recorded yet.")
        } else {
            lines.append("Weak areas: \(weak.joined(separator: ", ")).")
        }
        if !grades.isEmpty {
            lines.append("Grades: \(grades.joined(separator: "; ")).")
        }
        if !problemSets.isEmpty {
            lines.append("Problem sets: \(problemSets.joined(separator: "; ")).")
        }
        if !readings.isEmpty {
            lines.append("Readings: \(readings.joined(separator: "; ")).")
        }
        if !lectures.isEmpty {
            lines.append("Lecture notes this week: \(lectures.joined(separator: ", ")).")
        }

        return """
        You are Alfred's weekly study reviewer. Write a short, honest weekly \
        progress report for the user. Name what they're strong in, what needs \
        practice, and the 2–3 focus areas for the week ahead — draw from the \
        data below, and keep it encouraging but specific.

        \(lines.joined(separator: "\n"))

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"strong": ["..."], "weak": ["..."], "focus_next_week": ["..."], "summary": "..."}
        """
    }

    /// Parse the model's JSON report.
    static func parseReport(_ obj: [String: Any]) -> (strong: [String], weak: [String], focus: [String], summary: String)? {
        guard let summary = obj["summary"] as? String, !summary.isEmpty else { return nil }
        let strong = obj["strong"] as? [String] ?? []
        let weak = obj["weak"] as? [String] ?? []
        let focus = obj["focus_next_week"] as? [String] ?? []
        return (strong, weak, focus, summary)
    }

    /// The deterministic fallback when Hermes can't write the prose.
    static func fallbackReport(strong: [String], weak: [String]) -> String {
        var lines: [String] = ["Weekly summary:"]
        if strong.isEmpty {
            lines.append("• Strong in: (not enough data yet — keep studying and Alfred will learn your strengths.)")
        } else {
            lines.append("• Strong in: \(strong.joined(separator: ", ")).")
        }
        if weak.isEmpty {
            lines.append("• Need practice in: nothing on record — nice week.")
        } else {
            lines.append("• Need practice in: \(weak.joined(separator: ", ")).")
        }
        let focus = weak.isEmpty ? ["keep the momentum"] : Array(weak.prefix(3))
        lines.append("• Focus for next week: \(focus.joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }
}
