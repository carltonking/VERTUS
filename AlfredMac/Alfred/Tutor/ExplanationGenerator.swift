// MARK: - ExplanationGenerator
//
// The personalized explanation builder. Given a concept, the user's mastery of
// it, their learned learning style and the tutor settings, it produces the
// JSON-contract prompt Hermes answers with. Every decision is deterministic
// and testable — which method to lead with, how long to go, what to assume
// the user already knows — so the same profile always produces the same
// teaching instructions. The model turn itself runs in PersonalTutorSkill.

import Foundation

enum ExplanationGenerator {

    /// The teaching method to lead with for a concept: the user's top learned
    /// preference when one exists, otherwise a course-aware default.
    static func method(for concept: String, style: LearningStyle,
                       course: String?) -> TeachingMethod {
        if let preferred = style.preferredMethods.first {
            return preferred
        }
        // First mention of a concept: fall back to what the course implies.
        return LearningStyleAnalyzer.defaultMethod(for: course)
    }

    /// The length instruction block.
    static func lengthBlock(_ length: ExplanationLength) -> String {
        switch length {
        case .quick:
            return "Keep the explanation to ONE tight paragraph — enough to make it click, no more."
        case .detailed:
            return "Give a full breakdown: definition, intuition, a worked example, common mistakes, and why it matters. Be thorough but never padded."
        }
    }

    /// The "what does the user already know" block: mastery level and any
    /// prerequisites the tracker knows about, so the tutor builds up instead
    /// of re-explaining or skipping ahead.
    static func masteryBlock(_ mastery: ConceptMastery?, prerequisites: [String]) -> String {
        var lines: [String] = []
        if let mastery {
            lines.append("The user's current level for this concept: \(mastery.confidence)/5"
                + " (asked about \(mastery.sessionCount) time\(mastery.sessionCount == 1 ? "" : "s")).")
        } else {
            lines.append("The user has never asked about this concept before — treat them as a beginner here.")
        }
        if !prerequisites.isEmpty {
            lines.append("The user already knows: \(prerequisites.joined(separator: ", "))."
                + " Build on these; do not re-explain them.")
        }
        return lines.joined(separator: " ")
    }

    /// The closing check — the spec's step c: ask whether it made sense, and
    /// what to do next.
    static func checkQuestion() -> String {
        "Does this make sense? Want me to go deeper, or show another angle?"
    }

    /// Build the full explanation prompt.
    static func buildPrompt(concept: String, course: String?, mastery: ConceptMastery?,
                            prerequisites: [String], style: LearningStyle,
                            settings: TutorSettings) -> String {
        let method = method(for: concept, style: style, course: course)
        let styleBlock = LearningStyleAnalyzer.promptBlock(style, course: course)
        return """
        You are Alfred, a personal tutor who knows exactly how this user \
        learns. Explain the concept below to them — not generically, but the \
        way that works for THEM.

        Learning profile for this user:
        \(styleBlock)

        Method to lead with: \(method.displayName).

        \(lengthBlock(settings.explanationLength))

        \(masteryBlock(mastery, prerequisites: prerequisites))

        Rules:
        - Lead with the chosen method (\(method.displayName)); switch to \
        another only if it genuinely fits the concept better.
        - Use concrete examples the user can anchor to; never lecture in the \
        abstract.
        - End with the check question (below), phrased naturally.

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"explanation": "the full explanation", "method_used": "\(method.rawValue)", "check": "the check question"}

        Concept to explain:
        \(concept)\(course.map { " (course: \($0))" } ?? "")
        """
    }

    /// Parse the model's method_used field back into a TeachingMethod,
    /// falling back to the planned method when the model didn't report one.
    static func resolveMethod(_ raw: String?, fallback: TeachingMethod) -> TeachingMethod {
        raw.flatMap(TeachingMethod.init(rawValue:)) ?? fallback
    }

    /// Render the explanation JSON into the string the MCP tool returns.
    /// Appends the check question so the conversation loop can continue.
    static func render(explanation: String, check: String) -> String {
        var text = explanation
        if !check.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\n\(check)"
        }
        return text
    }
}
