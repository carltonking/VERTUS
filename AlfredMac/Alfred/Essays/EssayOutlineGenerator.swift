// MARK: - EssayOutlineGenerator
//
// The deterministic skeleton behind every generated essay. Instead of asking
// the model to invent a structure from scratch, the skill picks a section
// template for the essay type (analysis, argument, research, history) and
// hands it to the model as an outline to fill in — the "per-class template"
// idea from the spec. The full generation prompt is also assembled here, pure
// and static so the exact text is unit-testable.

import Foundation

// MARK: - Essay type

enum EssayType: String, Codable, CaseIterable, Sendable {
    case analysis
    case argument
    case research
    case history

    var displayName: String {
        switch self {
        case .analysis: return "Analysis"
        case .argument: return "Argument"
        case .research: return "Research"
        case .history: return "History"
        }
    }

    /// Classify a prompt into an essay type, keyword-driven like the other
    /// domain classifiers. A wrong guess still produces a usable essay, so the
    /// bar is low.
    static func detect(from topic: String) -> EssayType {
        let lower = topic.lowercased()
        if lower.contains("argue") || lower.contains("should ") || lower.contains("persuade")
            || lower.contains("defend") || lower.contains("whether") {
            return .argument
        }
        if lower.contains("history") || lower.contains("century") || lower.contains("era")
            || lower.contains("movement") || lower.contains("war") || lower.contains("reign") {
            return .history
        }
        if lower.contains("research") || lower.contains("literature review")
            || lower.contains("sources") || lower.contains("findings") {
            return .research
        }
        return .analysis
    }
}

enum EssayOutlineGenerator {

    /// The section names for an essay type — the outline the model fills in.
    static func sections(for type: EssayType) -> [String] {
        switch type {
        case .analysis:
            return ["Introduction and thesis", "Context and background",
                    "Point-by-point analysis", "Interpretation and significance",
                    "Conclusion"]
        case .argument:
            return ["Introduction and thesis", "Claims with evidence",
                    "Counterargument", "Rebuttal", "Conclusion"]
        case .research:
            return ["Introduction and research question", "Review of sources",
                    "Analysis of findings", "Discussion", "Conclusion"]
        case .history:
            return ["Introduction and thesis", "Historical context",
                    "Events and developments", "Analysis and significance",
                    "Conclusion"]
        }
    }

    /// The full prompt the skill feeds to Hermes. Deterministic assembly:
    /// style injection, the outline, the citation instructions and the
    /// source material all land in the same text the way the other managers
    /// (TasteSkillManager, BriefingGenerator) build theirs.
    static func generationPrompt(
        topic: String,
        length: String,
        type: EssayType,
        tone: EssayTone,
        style: EssayStyleProfile,
        citationStyle: CitationStyle,
        sources: [EssaySource]
    ) -> String {
        var lines: [String] = []
        lines.append("You are Alfred's essay writer. Write a complete, submission-ready essay on the topic below.")

        lines.append("Topic: \(topic)")
        lines.append("Length: \(length) (aim for the requested length).")
        lines.append("Citation style: \(citationStyle.displayName).")

        let toneLine: String
        switch tone {
        case .matchMyStyle:
            let injection = style.toPromptInjection()
            toneLine = injection.isEmpty
                ? "Tone: match the user's learned writing voice."
                : "Tone: \(injection)"
        default:
            toneLine = "Tone: \(tone.displayName.lowercased())."
        }
        lines.append(toneLine)

        lines.append("Structure — follow this outline:")
        for (index, section) in sections(for: type).enumerated() {
            lines.append("\(index + 1). \(section)")
        }

        lines.append("""
        Citation rules:
        - Cite sources in-text in \(citationStyle.displayName) as you write \
        (author last name, with page or year as the style requires).
        - Do NOT write the reference list — I will append it. End the essay \
        body after the conclusion.
        """)

        if !sources.isEmpty {
            lines.append("Use these sources (cite by author or short title):")
            for source in sources.prefix(12) {
                var sourceLine = "- \(source.title)"
                if !source.url.isEmpty { sourceLine += " — \(source.url)" }
                if !source.summary.isEmpty { sourceLine += " — \(source.summary)" }
                lines.append(sourceLine)
            }
        }

        lines.append("""
        Quality bar:
        - Every claim is supported by evidence or a citation; no invented \
        facts, no fabricated quotations.
        - Paragraphs carry one idea; transitions link them.
        - The conclusion answers "so what?", not a restated summary.
        - Write the essay body only — no preamble, no markdown fences.
        """)

        return lines.joined(separator: "\n")
    }
}
