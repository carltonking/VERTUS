// MARK: - Tutor models
//
// The shared types for Alfred's Personal Tutor skill. These are the shapes
// the SQLite tracker persists, the style analyzer produces, the skill serves
// to Hermes as MCP tools, and the briefing carries as its "Weak Concepts"
// card. Everything is Codable so the settings cross the wire to the phone
// unchanged (same contract as TasteSettings / OptimizationSettings).

import Foundation

// MARK: - Settings

/// How the tutor behaves by default: guide the user to the answer (learning)
/// or just tell them (answer). The spec's two tutoring modes.
enum TutoringMode: String, Codable, CaseIterable, Sendable {
    /// Explain + guide — the user works toward understanding (Socratic when
    /// the depth setting allows it).
    case learning
    /// Just tell me — burn-out mode: a direct answer, no questions.
    case answer

    var displayName: String {
        switch self {
        case .learning: return "Learning — explain and guide"
        case .answer:   return "Answer — just tell me"
        }
    }
}

/// How much Socratic questioning homework help uses before giving anything
/// away. Mirrors the spec's "Heavy questions / Light hints / Just answer".
enum SocraticDepth: String, Codable, CaseIterable, Sendable {
    /// Guiding questions only — the user reaches the answer themselves.
    case heavy
    /// One question plus a small nudge when they're stuck.
    case lightHints = "light_hints"
    /// Skip the questions and answer directly.
    case justAnswer = "just_answer"

    var displayName: String {
        switch self {
        case .heavy:       return "Heavy questions"
        case .lightHints:  return "Light hints"
        case .justAnswer:  return "Just answer"
        }
    }
}

/// How long explanations run: one tight paragraph vs a full breakdown.
enum ExplanationLength: String, Codable, CaseIterable, Sendable {
    case quick
    case detailed

    var displayName: String {
        switch self {
        case .quick:    return "Quick — one paragraph"
        case .detailed: return "Detailed — full breakdown"
        }
    }
}

/// Difficulty of generated practice problems.
enum PracticeIntensity: String, Codable, CaseIterable, Sendable {
    case easy
    case medium
    case hard

    var displayName: String {
        switch self {
        case .easy:   return "Easy"
        case .medium: return "Medium"
        case .hard:   return "Hard"
        }
    }
}

/// The persisted tutoring configuration. Defaults match the spec: learning
/// mode first, light hints, detailed explanations, medium practice.
struct TutorSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var mode: TutoringMode
    var socraticDepth: SocraticDepth
    var explanationLength: ExplanationLength
    var practiceIntensity: PracticeIntensity

    /// The wire/persistence keys are snake_case (same contract as the other
    /// settings structs' wire helpers), so JSON round-trips unchanged.
    enum CodingKeys: String, CodingKey {
        case enabled
        case mode
        case socraticDepth = "socratic_depth"
        case explanationLength = "explanation_length"
        case practiceIntensity = "practice_intensity"
    }

    static let `default` = TutorSettings(
        enabled: true,
        mode: .learning,
        socraticDepth: .lightHints,
        explanationLength: .detailed,
        practiceIntensity: .medium)
}

// MARK: - Teaching methods

/// The ways an explanation can be delivered. One value per method the style
/// analyzer scores and the explanation generator instructs the model to use.
/// The wire names are snake_case; `displayName` is what the user sees.
enum TeachingMethod: String, Codable, CaseIterable, Sendable {
    case codeExample = "code_example"
    case analogy
    case visual
    case stepByStep = "step_by_step"
    case socratic
    case direct
    case theory
    case realWorld = "real_world"

    var displayName: String {
        switch self {
        case .codeExample: return "code examples"
        case .analogy:     return "real-world analogies"
        case .visual:      return "visual diagrams"
        case .stepByStep:  return "step-by-step walkthroughs"
        case .socratic:    return "Socratic questions"
        case .direct:      return "direct answers"
        case .theory:      return "pure theory"
        case .realWorld:   return "real-world applications"
        }
    }
}

// MARK: - Feedback outcomes

/// What the user said after an explanation. This is the training signal the
/// style analyzer learns from — the tutor equivalent of a 1–5 rating.
enum TutoringOutcome: String, Codable, CaseIterable, Sendable {
    /// "Got it." — the strongest positive signal.
    case understood
    /// "Still lost." — the strongest negative signal.
    case confused
    /// "Go deeper." — wants more technical detail.
    case moreDetail = "more_detail"
    /// "Show me another angle." — wants a different framing.
    case otherAngle = "other_angle"
    /// No feedback was given — neutral, no signal.
    case abandoned

    var displayName: String {
        switch self {
        case .understood: return "Understood it"
        case .confused:   return "Still confused"
        case .moreDetail: return "Wants more detail"
        case .otherAngle: return "Wants another angle"
        case .abandoned:  return "No feedback"
        }
    }
}

// MARK: - Session modes

/// What kind of tutoring interaction a session was. `recordSession` writes one
/// row per interaction; the analyzer groups by method, the tracker by concept.
enum TutoringSessionMode: String, Codable, CaseIterable, Sendable {
    case explain    // explain_concept
    case socratic   // socratic_guide / homework help
    case practice   // practice problems inside exam prep
    case examPrep   // exam_prep_routine
    case manual     // track_mastery (direct set by the user/agent)
}

// MARK: - Concept mastery

/// One concept's knowledge level and learning history — the spec's example:
/// first mention confused (1/5), after two tutoring sessions 3/5, after
/// practice 4/5. `confidence` is 1–5; `sessionCount` counts interactions and
/// `confusedCount` the times the user reported being lost.
struct ConceptMastery: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var course: String?
    var confidence: Int
    var sessionCount: Int
    var confusedCount: Int
    var masteredAt: TimeInterval?
    var firstSeenAt: TimeInterval
    var lastSeenAt: TimeInterval

    /// 1–5, clamped.
    static func clampConfidence(_ value: Int) -> Int {
        min(5, max(1, value))
    }
}

/// One recorded tutoring interaction. `outcome` starts `.abandoned` (no
/// signal yet) and is filled in by `recordFeedback` when the user answers the
/// "does this make sense?" check.
struct TutoringSessionRecord: Codable, Equatable, Sendable {
    let id: String
    var concept: String
    var course: String?
    var mode: TutoringSessionMode
    var method: TeachingMethod
    var outcome: TutoringOutcome
    var createdAt: TimeInterval
}

// MARK: - Learning style

/// Structure preference: does the user learn best in sequenced steps or by
/// seeing the whole picture at once?
enum StructurePreference: String, Codable, CaseIterable, Sendable {
    case stepByStep = "step_by_step"
    case allAtOnce = "all_at_once"
    case unknown

    var displayName: String {
        switch self {
        case .stepByStep: return "step-by-step"
        case .allAtOnce:  return "all-at-once"
        case .unknown:    return "not settled yet"
        }
    }
}

/// Depth preference: high-level overview vs deep technical detail.
enum DepthPreference: String, Codable, CaseIterable, Sendable {
    case overview
    case detailed
    case unknown

    var displayName: String {
        switch self {
        case .overview: return "high-level overviews"
        case .detailed: return "deep technical detail"
        case .unknown:  return "not settled yet"
        }
    }
}

/// Guidance preference: being led by questions vs being told directly.
enum GuidancePreference: String, Codable, CaseIterable, Sendable {
    case socratic
    case direct
    case unknown

    var displayName: String {
        switch self {
        case .socratic: return "Socratic questions"
        case .direct:   return "direct answers"
        case .unknown:  return "not settled yet"
        }
    }
}

/// Alfred's learned understanding of how this user learns. Produced by
/// LearningStyleAnalyzer from the session history — the deterministic learner
/// that is always available (the DSPy bridge augments it when configured).
/// `confidence` grows toward 1.0 with session count (settled at ~10 sessions),
/// and `isSettled` flips at 5 sessions, matching the spec's milestones.
struct LearningStyle: Codable, Equatable, Sendable {
    var preferredMethods: [TeachingMethod]
    var structure: StructurePreference
    var depth: DepthPreference
    var guidance: GuidancePreference
    /// The teaching approaches proven to land, as display names.
    var methodsThatWork: [String]
    /// The approaches that keep failing, as display names.
    var methodsThatDont: [String]
    var sessionCount: Int
    var confidence: Double
    var isSettled: Bool

    static let empty = LearningStyle(
        preferredMethods: [], structure: .unknown, depth: .unknown,
        guidance: .unknown, methodsThatWork: [], methodsThatDont: [],
        sessionCount: 0, confidence: 0, isSettled: false)
}

// MARK: - Briefing card

/// One weak concept on the "Weak Concepts" briefing card.
struct TutorWeakConcept: Codable, Equatable, Sendable {
    var name: String
    var course: String?
    var confidence: Int
    var sessions: Int
    var confusedCount: Int
}

/// The card the briefing carries (the spec's BriefingGenerator addition).
/// Optional on the wire so an old briefing without the key still decodes, and
/// nil while the tutor has nothing to report yet.
struct TutorCard: Codable, Equatable, Sendable {
    var weakConcepts: [TutorWeakConcept]
    var preferredMethods: [String]
    var sessionCount: Int
    var masteredCount: Int
}
