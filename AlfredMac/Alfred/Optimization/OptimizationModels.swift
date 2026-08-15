// MARK: - Optimization models
//
// The shared types for Alfred's self-optimization loop (DSPy integration).
// These are the shapes the store persists, the optimizer produces, the socket
// serves to iOS, and the briefing carries as its "Alfred Improvement" card.
//
// DSPy is the "program the LLM" layer: instead of hardcoding how Alfred should
// write code, draft email or summarize research, Alfred rates its own outputs
// and a weekly compile pass turns those ratings into learned prompt rules. The
// rules ride along as a bracketed injection in HermesSession.groundedPrompt,
// exactly like the writing-style and behavior injections already do.

import Foundation

// MARK: - Optimization kinds

/// What kind of output a rating applies to. One value per optimization domain
/// the loop learns about. `detect(from:)` is the cheap keyword classifier that
/// assigns an otherwise-unclassified prompt to a domain.
enum OptimizationKind: String, Codable, CaseIterable, Sendable {
    case code
    case email
    case summary
    case routine
    case multistep
    case general

    /// Human name for the briefing card and the iOS report.
    var displayName: String {
        switch self {
        case .code: return "Code quality"
        case .email: return "Email drafting"
        case .summary: return "Summaries"
        case .routine: return "Routines"
        case .multistep: return "Multi-step tasks"
        case .general: return "General answers"
        }
    }

    /// Classify a prompt into a domain. Conservative and keyword-driven, like
    /// `AppDelegate.engine(for:)`: a wrong guess costs little (the wrong set of
    /// rules rides along), while an empty guess costs the whole feature.
    static func detect(from text: String) -> OptimizationKind {
        let lower = text.lowercased()

        if lower.hasPrefix("code:") || lower.hasPrefix("/code ") {
            return .code
        }

        let codeMarkers = [
            "refactor", "unit test", "test suite", "compile error", "build error",
            "syntax error", "typeerror", "merge conflict", "pull request",
            "git commit", "git diff", "code review", "package.json", "cargo.toml",
            "pyproject.toml", "swift build", "npm install", "pip install",
            "codebase", "stack trace", "func ", "def ", "```",
        ]
        if codeMarkers.contains(where: { lower.contains($0) }) { return .code }

        let emailMarkers = [
            "draft", "email", "reply to", "respond to", "write to", "subject line",
            "cover letter", "thank-you note", "follow up with", "reach out to",
        ]
        if emailMarkers.contains(where: { lower.contains($0) }) { return .email }

        let summaryMarkers = [
            "summarize", "summary", "tl;dr", "tldr", "key points", "takeaways",
            "condense", "research this", "what's the gist",
        ]
        if summaryMarkers.contains(where: { lower.contains($0) }) { return .summary }

        let routineMarkers = [
            "routine", "morning check", "daily check", "job search routine",
            "research routine", "email routine", "every morning", "weekly workflow",
        ]
        if routineMarkers.contains(where: { lower.contains($0) }) { return .routine }

        let multistepMarkers = [
            "step by step", "walk me through", "then apply", "job application flow",
            "research, then", "first… then", "checklist", "plan the order",
        ]
        if multistepMarkers.contains(where: { lower.contains($0) }) { return .multistep }

        return .general
    }
}

// MARK: - Feedback

/// One rated output. This is the training example the DSPy compile pass learns
/// from — `prompt` is what the user asked, `output` is what Alfred produced,
/// `rating` is the 1–5 score, and `edited` marks whether the user rewrote the
/// result before using it (the email signal: sent-as-is is the real win).
struct FeedbackEntry: Codable, Equatable, Sendable {
    var id: String
    var kind: OptimizationKind
    var prompt: String
    var output: String
    var rating: Int
    var edited: Bool
    var context: String?
    var timestamp: TimeInterval

    init(kind: OptimizationKind, prompt: String, output: String, rating: Int,
         edited: Bool = false, context: String? = nil, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.id = UUID().uuidString
        self.kind = kind
        self.prompt = prompt
        self.output = output
        self.rating = min(5, max(1, rating))
        self.edited = edited
        self.context = context
        self.timestamp = timestamp
    }
}

// MARK: - Learned rules

/// One learned optimization. `rule` is a directive the model should follow
/// ("Comments should focus on why, not what"), `confidence` is how strongly
/// the compile pass believes it (0–1), `source` is "dspy" or "heuristic",
/// and `version` ties it to a compile run so it can be rolled back atomically.
struct OptimizationRule: Codable, Equatable, Sendable {
    var kind: OptimizationKind
    var rule: String
    var confidence: Double
    var source: String
    var version: Int

    /// The bracketed directive injected into prompts of this kind.
    var directive: String {
        let percent = Int((confidence * 100).rounded())
        return "\(rule) (learned \\(percent)% confidence)"
    }
}

// MARK: - Settings

/// How often the loop compiles, and how much evidence it needs before it will
/// touch a prompt.
enum OptimizationFrequency: String, Codable, CaseIterable, Sendable {
    case weekly
    case monthly
    case manual

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .manual: return "Manual"
        }
    }
}

/// Persisted configuration (UserDefaults, like TasteSettings). Defaults match
/// the spec: weekly, 10 ratings minimum, apply only above a 10% improvement,
/// and auto-rollback on a regression.
struct OptimizationSettings: Codable, Equatable, Sendable {
    var frequency: OptimizationFrequency
    var minFeedback: Int
    var confidenceThreshold: Double
    var autoRollback: Bool
    var lastCompiledAt: TimeInterval?

    static let `default` = OptimizationSettings(
        frequency: .weekly,
        minFeedback: 10,
        confidenceThreshold: 0.10,
        autoRollback: true,
        lastCompiledAt: nil)
}

// MARK: - Report

/// One domain's score, current week vs the week before — the trend the
/// briefing card and the iOS report show.
struct OptimizationKindScore: Codable, Equatable, Sendable {
    var kind: String
    var displayName: String
    var current: Double
    var previous: Double
    var samples: Int
}

/// The full optimization report. `weekDelta` is the overall average-rating
/// change week-over-week; `activeOptimizations` are the learned rules
/// currently riding along in prompts.
struct OptimizationReport: Codable, Equatable, Sendable {
    var averageRating: Double
    var weekDelta: Double
    var totalRatings: Int
    var perKind: [OptimizationKindScore]
    var activeOptimizations: [String]
    var lastCompiledAt: TimeInterval?
    var lastRun: OptimizationRunRecord?

    static let empty = OptimizationReport(
        averageRating: 0, weekDelta: 0, totalRatings: 0, perKind: [],
        activeOptimizations: [], lastCompiledAt: nil, lastRun: nil)
}

/// One compile run, kept for the rollback path and the "improvement over time"
/// line.
struct OptimizationRunRecord: Codable, Equatable, Sendable {
    var kind: String
    var version: Int
    var before: Double
    var after: Double
    var examples: Int
    var applied: Bool
    var rolledBack: Bool
    var source: String
    var createdAt: TimeInterval
}

/// The card the briefing carries. Kept small on purpose — a headline delta,
/// the per-kind trend, and the active rules.
struct ImprovementCard: Codable, Equatable, Sendable {
    var averageRating: Double
    var weekDelta: Double
    var totalRatings: Int
    var perKind: [OptimizationKindScore]
    var activeOptimizations: [String]
}
