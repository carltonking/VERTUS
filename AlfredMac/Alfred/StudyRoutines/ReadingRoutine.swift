// MARK: - ReadingRoutine
//
// The reading engine: spaced-repetition scheduling (SM-2-lite) plus the
// quiz / summary prompts. Scheduling is pure and deterministic — a passed
// quiz doubles the interval, a failed one resets it to a day — so it
// unit-tests cleanly; the manager does the Hermes turn.

import Foundation

enum ReadingRoutine {

    /// The next spacing interval in days: double on a pass, reset to 1 on a
    /// fail. Never below 1 day, capped at 30 so a long streak doesn't push a
    /// reading past the exam.
    static func nextInterval(current: Double, passed: Bool) -> Double {
        if passed { return min(30, max(1, current * 2)) }
        return 1
    }

    static func nextStreak(current: Int, passed: Bool) -> Int {
        passed ? current + 1 : 0
    }

    /// The comprehension-quiz prompt. When real content is supplied it quizzes
    /// on that; when only a title is given it still produces sensible study
    /// questions so the user gets value from a bare chapter name.
    static func quizPrompt(title: String, course: String?, keyPoints: [String],
                           content: String?, questionCount: Int) -> String {
        var context = ""
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context = "\nReading content:\n\(content)"
        } else if !keyPoints.isEmpty {
            context = "\nKnown key points:\n" + keyPoints.map { "  - \($0)" }.joined(separator: "\n")
        }

        return """
        You are Alfred's reading tutor. The user has been assigned a reading \
        and needs \(questionCount) comprehension questions to check they \
        actually absorbed it (not skimmed).

        Reading: \(title)
        \(course.map { "Course: \($0)\n" } ?? "")\(context)

        Generate \(questionCount) questions that test understanding — mix \
        recall, application and synthesis, not just trivia. For each, give \
        the question and a short model answer. Difficulty should match the \
        material.

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"key_points": ["..."], "questions": [{"question": "...", "answer": "..."}]}
        """
    }

    /// The reading-summary prompt (first pass: key points by section).
    static func summaryPrompt(title: String, course: String?, content: String) -> String {
        return """
        You are Alfred's reading tutor. Summarize the assigned reading below \
        section by section, then list the study questions that matter.

        Reading: \(title)
        \(course.map { "Course: \($0)\n" } ?? "")
        Content:
        \(content)

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"key_points": ["by-section key points"], "questions": ["study question 1", "..."]}
        """
    }

    /// Parse a user/agent-supplied quiz result into a 0…1 score. Accepts
    /// "passed"/"failed", "4/5", "80%", "0.8", or a bare number.
    static func score(from raw: String) -> (score: Double, passed: Bool)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "passed" || t == "pass" || t == "correct" || t == "yes" { return (1, true) }
        if t == "failed" || t == "fail" || t == "wrong" || t == "no" { return (0, false) }
        if let slash = t.firstIndex(of: "/") {
            let num = Double(t[..<slash].trimmingCharacters(in: .whitespaces)) ?? 0
            let den = Double(t[slash...].dropFirst().trimmingCharacters(in: .whitespaces)) ?? 1
            guard den > 0 else { return nil }
            let score = min(1, max(0, num / den))
            return (score, score >= 0.6)
        }
        if t.hasSuffix("%"), let pct = Double(t.dropLast()) {
            let score = min(1, max(0, pct / 100))
            return (score, score >= 0.6)
        }
        if let value = Double(t) {
            let score = value > 1 ? min(1, value / 100) : min(1, max(0, value))
            return (score, score >= 0.6)
        }
        return nil
    }

    /// The status text: due readings and their last score.
    static func statusText(readings: [ReadingAssignment], due: [ReadingAssignment]) -> String {
        if due.isEmpty {
            return readings.isEmpty
                ? "No readings assigned yet — add one and Alfred will quiz you on it."
                : "No readings due for a quiz right now."
        }
        let lines = due.map { reading -> String in
            let scorePart = reading.quizScore.map { " (last quiz \(Int(($0 * 100).rounded()))%)" } ?? ""
            return "• \(reading.title)\(scorePart)"
        }
        return "\(due.count) reading\(due.count == 1 ? "" : "s") due for a quiz:\n" + lines.joined(separator: "\n")
    }
}
