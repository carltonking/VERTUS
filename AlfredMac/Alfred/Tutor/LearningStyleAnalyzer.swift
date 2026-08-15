// MARK: - LearningStyleAnalyzer
//
// The deterministic learner behind the Personal Tutor skill. From the session
// history it extracts how *this* user learns best — which teaching methods
// land, whether they want steps or the whole picture, overviews or detail,
// questions or answers — and returns a `LearningStyle` with a confidence that
// grows with session count (the spec's "after 5 sessions the style is
// learned, after 10 explanations are highly personalized").
//
// It is the same philosophy as OptimizationHeuristics (the DSPy loop's Swift
// fallback), in miniature: the model reports which method it used per
// explanation, the user's feedback scores it, and the analyzer turns those
// scored examples into preferences instead of hardcoding them. Pure and
// static so it unit-tests with fixed expectations; the Python DSPy bridge
// (dspy_tutor.py) can augment it with model-proposed directives, never
// replace it.

import Foundation

enum LearningStyleAnalyzer {

    /// How strongly each outcome moves a method's score. `abandoned` is
    /// neutral on purpose: "no feedback" is no signal, not a strike.
    static func outcomeWeight(_ outcome: TutoringOutcome) -> Double {
        switch outcome {
        case .understood: return 2.0
        case .moreDetail, .otherAngle: return 1.0
        case .confused: return -1.5
        case .abandoned: return 0.0
        }
    }

    /// Minimum sessions before a method's score is trusted as a preference.
    static let minimumMethodSessions = 2

    /// How many preferred methods the profile carries (ranked).
    static let maxPreferredMethods = 3

    /// Sessions at which the profile is considered settled.
    static let settledThreshold = 5

    /// Sessions at which confidence reaches 1.0 (the spec's "highly
    /// personalized" milestone).
    static let fullConfidenceThreshold = 10

    // MARK: - Analysis

    /// Learn the user's style from scored sessions. `externalDirectives` lets
    /// the DSPy bridge add its own learned teaching methods (as display-name
    /// phrases) on top of the deterministic signal; they never override it.
    static func analyze(sessions: [TutoringSessionRecord],
                        externalDirectives: [String] = []) -> LearningStyle {
        let scored = sessions.map { (session: $0, weight: outcomeWeight($0.outcome)) }

        // Per-method net score and usage counts.
        var net: [TeachingMethod: Double] = [:]
        var counts: [TeachingMethod: Int] = [:]
        var confusions: [TeachingMethod: Int] = [:]
        for item in scored {
            net[item.session.method, default: 0] += item.weight
            counts[item.session.method, default: 0] += 1
            if item.session.outcome == .confused {
                confusions[item.session.method, default: 0] += 1
            }
        }

        // Preferred methods: positive net score, ranked by score then usage.
        let ranked = TeachingMethod.allCases
            .filter { (net[$0] ?? 0) > 0 }
            .sorted {
                let a = (net[$0] ?? 0), b = (net[$1] ?? 0)
                if a != b { return a > b }
                return (counts[$0] ?? 0) > (counts[$1] ?? 0)
            }
        let preferred = Array(ranked.prefix(maxPreferredMethods))

        // Methods that work: repeatedly positive and mostly understood.
        var work: [String] = []
        var dont: [String] = []
        for method in TeachingMethod.allCases {
            let count = counts[method] ?? 0
            guard count >= 1 else { continue }
            let score = net[method] ?? 0
            let positiveRate = positiveRate(of: method, in: scored)
            if count >= minimumMethodSessions, score > 0, positiveRate >= 0.5 {
                work.append(method.displayName)
            } else if count >= minimumMethodSessions, score < 0 {
                dont.append(method.displayName)
            } else if count >= minimumMethodSessions, positiveRate < 0.5 {
                dont.append(method.displayName)
            }
        }

        // Structure: step-by-step works → sequenced; keeps failing → whole
        // picture at once.
        let stepScore = net[.stepByStep] ?? 0
        let stepCount = counts[.stepByStep] ?? 0
        let structure: StructurePreference
        if stepCount >= minimumMethodSessions && stepScore > 0 {
            structure = .stepByStep
        } else if stepCount >= 1 && stepScore < 0 {
            structure = .allAtOnce
        } else {
            structure = .unknown
        }

        // Depth: any request to go deeper wins over satisfied overviews — a
        // "more detail / another angle" reply is a strong signal that the
        // explanation didn't go far enough, even amid understood sessions.
        let depthAsks = scored.filter {
            $0.session.outcome == .moreDetail || $0.session.outcome == .otherAngle
        }.count
        let understood = scored.filter { $0.session.outcome == .understood }.count
        let depth: DepthPreference
        if depthAsks >= 1 {
            depth = .detailed
        } else if understood >= minimumMethodSessions {
            depth = .overview
        } else {
            depth = .unknown
        }

        // Guidance: whichever of socratic / direct has the better record.
        let socraticScore = net[.socratic] ?? 0
        let socraticCount = counts[.socratic] ?? 0
        let directScore = net[.direct] ?? 0
        let directCount = counts[.direct] ?? 0
        let guidance: GuidancePreference
        if socraticCount >= minimumMethodSessions && socraticScore > directScore {
            guidance = .socratic
        } else if directCount >= minimumMethodSessions && directScore > socraticScore {
            guidance = .direct
        } else {
            guidance = .unknown
        }

        // Confidence scales with session count toward the full-confidence
        // milestone; settled flips at the spec's 5-session threshold.
        let count = sessions.count
        let confidence = min(1.0, Double(count) / Double(fullConfidenceThreshold))

        var directives = externalDirectives
        for m in work where !directives.contains(m) { directives.append(m) }

        return LearningStyle(
            preferredMethods: preferred,
            structure: structure,
            depth: depth,
            guidance: guidance,
            methodsThatWork: Array(directives.prefix(maxPreferredMethods + 2)),
            methodsThatDont: dont,
            sessionCount: count,
            confidence: confidence,
            isSettled: count >= settledThreshold)
    }

    // MARK: - Prompt block

    /// Render the style into the instruction block the explanation generator
    /// embeds, so Hermes explains the way this user learns. Never empty — a
    /// fresh profile still gets a sensible default.
    static func promptBlock(_ style: LearningStyle, course: String?) -> String {
        var lines: [String] = []

        if !style.preferredMethods.isEmpty {
            let methods = style.preferredMethods.map(\.displayName)
            lines.append("This user learns best with: \(methods.joined(separator: ", ")). Lead with these.")
        }
        if !style.methodsThatWork.isEmpty {
            lines.append("Teaching methods that have worked: \(style.methodsThatWork.joined(separator: ", ")).")
        }
        if !style.methodsThatDont.isEmpty {
            lines.append("Teaching methods that have NOT worked for this user: \(style.methodsThatDont.joined(separator: ", ")). Avoid them.")
        }
        if style.structure != .unknown {
            lines.append("Structure: \(style.structure.displayName).")
        }
        if style.depth != .unknown {
            lines.append("Depth: \(style.depth.displayName).")
        }
        if style.guidance != .unknown {
            lines.append("Guidance: \(style.guidance.displayName).")
        }
        if lines.isEmpty {
            lines.append("No learning profile yet — default to the method for this course (\(defaultMethod(for: course).displayName)).")
        }
        return lines.joined(separator: " ")
    }

    /// The default teaching method for a course code when no style exists yet.
    /// Course-aware, so CSCI-UA 101 gets code and ARTH-UA 661 gets analogy
    /// from the very first explanation.
    static func defaultMethod(for course: String?) -> TeachingMethod {
        let c = (course ?? "").lowercased()
        // "ub" covers Stern's course codes (TECH-UB 41, BSPA-UB …), which
        // would otherwise fall through to the CS branch via "tech".
        if c.contains("bus") || c.contains("business") || c.contains("ai in")
            || c.contains("ub") {
            return .realWorld
        }
        if c.contains("cs") || c.contains("comp") || c.contains("code")
            || c.contains("tech") || c.contains("program") || c.contains("data structure") {
            return .codeExample
        }
        if c.contains("math") || c.contains("calc") || c.contains("stat") {
            return .stepByStep
        }
        if c.contains("phys") || c.contains("astro") || c.contains("cosmo") {
            return .visual
        }
        if c.contains("art") || c.contains("hist") || c.contains("urb") || c.contains("arch") {
            return .analogy
        }
        return .analogy
    }

    /// The fraction of a method's sessions that ended in "understood".
    private static func positiveRate(of method: TeachingMethod,
                                     in scored: [(session: TutoringSessionRecord, weight: Double)]) -> Double {
        let used = scored.filter { $0.session.method == method }
        guard !used.isEmpty else { return 0 }
        let good = used.filter { $0.session.outcome == .understood }.count
        let bad = used.filter { $0.session.outcome == .confused }.count
        guard good + bad > 0 else { return 0 }
        return Double(good) / Double(good + bad)
    }
}
