// MARK: - ProblemSetRoutine
//
// The problem-set engine: parses a list of pasted problems, grades each
// easy → hard with a deterministic heuristic, and produces the recommended
// order. Completion tracking lives in the store; this file is the pure
// ordering + grading + status-text logic so it unit-tests cleanly.

import Foundation

enum ProblemSetRoutine {

    /// 1 (easy), 2 (medium) or 3 (hard) for one problem's text. Signals are
    /// verbs the professor actually uses: "compute" is drill, "prove" is hard.
    static func difficulty(of text: String) -> Int {
        let t = text.lowercased()
        let hardHints = [
            "prove", "proof", "derive", "show that", "justify", "challeng",
            "generalize", "optional", "bonus", "induction", "counterexample",
            "is it true", "if and only if", "hard",
        ]
        if hardHints.contains(where: { t.contains($0) }) { return 3 }

        let mediumHints = [
            "explain", "compare", "analyze", "discuss", "solve", "sketch",
            "graph", "evaluate", "integrate", "compute", "find the", "draw",
            "describe", "apply",
        ]
        if mediumHints.contains(where: { t.contains($0) }) { return 2 }

        // A long, multi-part prompt is rarely a warm-up.
        if text.count > 220 { return 2 }
        return 1
    }

    /// The original indices of `texts`, reordered easy → hard (difficulty,
    /// then length, then original order as tiebreaks). The recommended order.
    static func orderedIndices(texts: [String]) -> [Int] {
        texts.indices.sorted { a, b in
            let da = difficulty(of: texts[a]), db = difficulty(of: texts[b])
            if da != db { return da < db }
            if texts[a].count != texts[b].count { return texts[a].count < texts[b].count }
            return a < b
        }
    }

    /// Build the ordered `ProblemItem`s from raw problem texts (optional
    /// per-problem concept hints). Order 0 is the easiest.
    static func build(texts: [String], concepts: [String?] = []) -> [ProblemItem] {
        orderedIndices(texts: texts).enumerated().map { order, index in
            ProblemItem(
                id: UUID().uuidString,
                text: texts[index],
                difficulty: difficulty(of: texts[index]),
                order: order,
                status: .unsolved,
                concept: index < concepts.count ? concepts[index] : nil)
        }
    }

    /// The status text the MCP tool and routine step show:
    /// "HW 3 — Calculus (4/8 done, next: problem 5)."
    static func statusText(for set: ProblemSet) -> String {
        let coursePart = set.course.map { " — \($0)" } ?? ""
        if set.isComplete {
            return "\(set.name)\(coursePart) — complete (\(set.total) problem\(set.total == 1 ? "" : "s"))."
        }
        let next = set.problems.first { $0.status == .unsolved }
        let nextPart = next.map { "next: problem \($0.order + 1)" } ?? ""
        return "\(set.name)\(coursePart) — \(set.solvedCount)/\(set.total) done\(nextPart.isEmpty ? "" : ", \(nextPart)")."
    }

    /// The routine-step roll-up across every set.
    static func statusText(sets: [ProblemSet]) -> String {
        let open = sets.filter { !$0.isComplete }
        if open.isEmpty {
            return sets.isEmpty
                ? "No problem sets tracked yet — paste one in to start."
                : "Every tracked problem set is complete. 🎉"
        }
        return open.map { statusText(for: $0) }.joined(separator: "\n")
    }
}
