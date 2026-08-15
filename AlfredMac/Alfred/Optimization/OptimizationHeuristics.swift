// MARK: - OptimizationHeuristics
//
// The deterministic pattern learner behind the optimization loop. When the
// Python DSPy bridge isn't available (no python3, no `dspy` package, or an
// offline compile), this extracts the same "what makes a good output good"
// signal straight from the rated examples: split them into good (4–5) and bad
// (1–2), compare how often each structural feature appears in each group, and
// turn every feature the good outputs use *more* into a learned directive.
//
// It's the same philosophy as DSPy's optimize-by-example, in miniature: the
// loop learns preferences ("this codebase prefers async", "summaries should
// lead with insights") instead of hardcoding them. Pure and static so it unit
// tests with fixed expectations.

import Foundation

enum OptimizationHeuristics {

    // MARK: - Feature table

    /// One learnable feature: how to detect it in an output, and the directive
    /// to inject when good outputs use it significantly more than bad ones.
    private struct Feature {
        let key: String
        let present: (String) -> Bool
        let rule: String
    }

    /// Minimum gap between the good and bad usage rates before a feature earns
    /// a rule. Below this the difference is noise, not preference.
    static let minimumGap = 0.15

    /// Minimum number of good examples before a feature's rate is trusted.
    static let minimumGoodSamples = 2

    /// Hard cap on rules per kind, so a compile pass never bloats a prompt.
    static let maxRulesPerKind = 3

    // MARK: - Feature extractors

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        let lower = text.lowercased()
        return needles.contains { lower.contains($0) }
    }

    private static func bulletLineCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isNewline }).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*")
                || trimmed.range(of: #"^\d+[.)]"#, options: .regularExpression) != nil
        }.count
    }

    private static func hasContraction(_ text: String) -> Bool {
        text.lowercased().range(of: #"'(t|s|m|re|ve|ll|d)\b"#, options: .regularExpression) != nil
    }

    private static func features(for kind: OptimizationKind) -> [Feature] {
        switch kind {
        case .code:
            return [
                Feature(key: "async", present: {
                    containsAny($0, ["async", "await", "task {", "async/await"])
                }, rule: "Prefer async/await patterns over blocking synchronous code."),
                Feature(key: "why-comments", present: { text in
                    containsAny(text, ["why", "because", "edge case", "tradeoff", "// this"])
                }, rule: "Comments should explain why, not repeat what the code does."),
                Feature(key: "custom-errors", present: {
                    containsAny($0, ["throw", "catch", "error", "custom error", "exception"])
                }, rule: "Handle errors explicitly with specific error paths, not silent failures."),
                Feature(key: "tests", present: {
                    containsAny($0, ["test", "xctest", "assert", "verify"])
                }, rule: "Include a test or verification step with generated code."),
            ]
        case .email:
            return [
                Feature(key: "clear-ask", present: { text in
                    text.contains("?") || containsAny(text, [
                        "would you", "could you", "let me know", "please", "can you",
                    ])
                }, rule: "End drafts with one clear, specific ask."),
                Feature(key: "context", present: {
                    containsAny($0, ["because", "as we", "we discussed", "last week",
                                     "regarding", "you mentioned"])
                }, rule: "Give the recipient the relevant context before the ask."),
                Feature(key: "short-paragraphs", present: { text in
                    let paragraphs = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                    guard !paragraphs.isEmpty else { return false }
                    let average = paragraphs.map(\.count).reduce(0, +) / paragraphs.count
                    return average <= 160
                }, rule: "Keep paragraphs short — two to three sentences."),
                Feature(key: "casual", present: {
                    hasContraction($0)
                }, rule: "Match the recipient's tone: casual for friends, professional for professors and recruiters."),
            ]
        case .summary:
            return [
                Feature(key: "bullets", present: { bulletLineCount($0) >= 3 },
                        rule: "Prefer bullet points over long paragraphs."),
                Feature(key: "insights", present: {
                    containsAny($0, ["actionable", "takeaway", "next step", "so what",
                                     "what to do", "the key"])
                }, rule: "Lead with actionable insights, not background."),
                Feature(key: "data", present: { text in
                    text.range(of: #"\d+(\.\d+)?\s*(%|\$|x|hours|days|points)"#, options: .regularExpression) != nil
                }, rule: "Ground claims in specific data rather than speculation."),
            ]
        case .routine:
            return [
                Feature(key: "priority", present: {
                    containsAny($0, ["first", "priority", "salary", "sort", "order",
                                     "most important", "before"])
                }, rule: "Sort routine steps by what the user cares about most first."),
                Feature(key: "actionable", present: {
                    containsAny($0, ["check", "filter", "open", "read", "send", "review", "sort"])
                }, rule: "Make every routine step a concrete, doable action."),
            ]
        case .multistep:
            return [
                Feature(key: "numbered", present: { bulletLineCount($0) >= 2 },
                        rule: "Number the steps so the flow can be followed in order."),
                Feature(key: "confirm", present: {
                    containsAny($0, ["confirm", "verify", "double-check", "before moving on"])
                }, rule: "Confirm each step completed before starting the next."),
            ]
        case .general:
            return [
                Feature(key: "specific", present: {
                    containsAny($0, ["specifically", "for example", "such as", "in this case"])
                }, rule: "Answer with specifics and examples, not generalities."),
                Feature(key: "concise", present: { text in text.count <= 900 },
                        rule: "Keep answers concise — cut filler before it reaches the user."),
            ]
        }
    }

    // MARK: - Learning

    /// Learn up to `maxRulesPerKind` directives from a set of rated examples.
    /// Returns rules sorted by confidence (strongest first). Empty when there
    /// aren't enough contrasting examples to learn from.
    static func learn(from entries: [FeedbackEntry], kind: OptimizationKind) -> [OptimizationRule] {
        let good = entries.filter { $0.rating >= 4 }
        let bad = entries.filter { $0.rating <= 2 }
        guard good.count >= minimumGoodSamples else { return [] }

        var rules: [OptimizationRule] = []

        for feature in features(for: kind) {
            let goodRate = rate(of: feature, in: good)
            let badRate = rate(of: feature, in: bad)
            let gap = goodRate - badRate
            guard gap >= minimumGap else { continue }
            // Confidence scales with the gap: a decisive 0.6 gap is ~0.9; a
            // marginal 0.15 gap is ~0.3.
            let confidence = min(0.95, gap * 1.5)
            rules.append(OptimizationRule(
                kind: kind, rule: feature.rule, confidence: confidence,
                source: "heuristic", version: 0))
        }

        return Array(rules.sorted { $0.confidence > $1.confidence }.prefix(maxRulesPerKind))
    }

    /// The fraction of examples where the feature is present.
    private static func rate(of feature: Feature, in entries: [FeedbackEntry]) -> Double {
        guard !entries.isEmpty else { return 0 }
        let hits = entries.filter { feature.present($0.output) }.count
        return Double(hits) / Double(entries.count)
    }
}
