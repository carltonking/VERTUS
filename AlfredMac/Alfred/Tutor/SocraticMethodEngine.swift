// MARK: - SocraticMethodEngine
//
// Homework help in learning mode: instead of handing over the answer, Alfred
// asks guiding questions — "What's the base case?", "What happens on the
// recursive call?" — and only reveals the answer when the depth setting says
// to (or the user is in Answer mode / burned out).
//
// The engine owns the deterministic parts: the depth → instruction mapping
// and the JSON-contract prompt. The model turn itself runs in
// PersonalTutorSkill through the shared bounded-turn path.

import Foundation

enum SocraticMethodEngine {

    /// The instruction block for a Socratic depth. `heavy` asks questions
    /// only; `light_hints` pairs each question with a small nudge; `justAnswer`
    /// skips questions entirely (used with Answer mode).
    static func guidanceBlock(depth: SocraticDepth) -> String {
        switch depth {
        case .heavy:
            return """
            You are a Socratic tutor. Do NOT give the answer or the solution. \
            Ask 2-4 guiding questions, one at a time, that lead the user to \
            discover the answer themselves. Questions must be concrete and \
            build on each other (first the setup, then the key step, then the \
            edge case). After each question, stop and wait for their reply — \
            never answer your own question.
            """
        case .lightHints:
            return """
            You are a Socratic tutor. Ask 2-3 guiding questions, but allow \
            yourself one small hint per question when the user is stuck (a \
            nudge, never the answer itself). Keep the user working toward the \
            solution; only give it away if they explicitly give up.
            """
        case .justAnswer:
            return """
            The user just wants the answer. Explain the solution clearly and \
            briefly, with the key steps, without dragging it out into questions.
            """
        }
    }

    /// Build the guiding-question prompt for one problem. Returns questions as
    /// JSON so the skill can hand them to the user cleanly.
    static func buildPrompt(problem: String, concept: String?, depth: SocraticDepth) -> String {
        let conceptLine = concept.map { "Concept: \($0)." } ?? ""
        return """
        \(guidanceBlock(depth: depth))

        \(conceptLine)
        The user's problem:
        \(problem)

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"questions": ["first question", "second question"], "hints": ["optional hint for question 1", ""]}

        - For depth "heavy": questions only — leave hints as empty strings.
        - For depth "light_hints": one short hint per question.
        - For depth "just_answer": questions may be empty; put the explanation \
        in a single question entry prefixed with "ANSWER: ".
        """
    }

    /// The celebratory + memory-storing line when the user arrives at the
    /// answer themselves (learning-mode payoff).
    static func successLine() -> String {
        "You got it — nice work! That's how the Socratic method works: the answer clicks because you built it. I've noted that this approach works for you."
    }
}
