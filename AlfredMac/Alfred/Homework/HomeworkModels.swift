// MARK: - Homework models
//
// The shared types for Alfred's Homework Assistant skill. These are the
// shapes the SQLite tracker persists, the solver prompts consume, and the
// settings cross the wire to the phone (same contract as TutorSettings /
// TasteSettings). Everything is Codable so the settings travel unchanged.

import Foundation

// MARK: - Settings

/// How the homework assistant behaves by default: teach the user to the
/// answer themselves, or just produce the submission-ready solution. The
/// spec's two modes, defaulting to teaching (the tutor's one hard rule:
/// hints first, answers only when explicitly asked).
enum HomeworkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Socratic guidance — delegate to the tutor, learn by doing.
    case teach
    /// Full submission-ready solution in the user's style.
    case submit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .teach:  return "Teaching — guide me"
        case .submit: return "Submission — just do it"
        }
    }
}

/// Whether generated code should copy the user's own coding conventions
/// (naming, error handling, comments, complexity) or generic best practices.
enum HomeworkCodeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case matchMine = "match_mine"
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matchMine: return "Match my past code"
        case .generic:   return "Generic best practices"
        }
    }
}

/// How much of the solution's working to show. Defaults to always so a
/// submitted write-up and a learning session both have the steps.
enum HomeworkShowSteps: String, Codable, CaseIterable, Identifiable, Sendable {
    case always
    case onRequest = "on_request"
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always:    return "Always show steps"
        case .onRequest: return "Show steps on request"
        case .never:     return "Never show steps"
        }
    }
}

/// How hard the solution should be. Match the user's level by default.
enum HomeworkDifficulty: String, Codable, CaseIterable, Identifiable, Sendable {
    case matchLevel = "match_level"
    case challenge
    case simplify

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matchLevel: return "Match my level"
        case .challenge:  return "Challenge me"
        case .simplify:   return "Simplify"
        }
    }
}

/// The submission format: plain prose, LaTeX for written math, or code.
enum HomeworkFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case latex
    case code

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text:  return "Text"
        case .latex: return "LaTeX"
        case .code:  return "Code"
        }
    }
}

/// The persisted homework configuration. Defaults: on, teaching first,
/// match my code style, always show steps, match my level, plain text.
struct HomeworkSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var defaultMode: HomeworkMode
    var codeStyle: HomeworkCodeStyle
    var showSteps: HomeworkShowSteps
    var difficulty: HomeworkDifficulty
    var format: HomeworkFormat

    static let `default` = HomeworkSettings(
        enabled: true,
        defaultMode: .teach,
        codeStyle: .matchMine,
        showSteps: .always,
        difficulty: .matchLevel,
        format: .text)
}

// MARK: - Problem types

/// Which subject a problem belongs to — drives which solver prompt fires.
/// Wire names are the raw values.
enum HomeworkDomain: String, Codable, CaseIterable, Identifiable, Sendable {
    case cs
    case math
    case physics

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cs:      return "CS"
        case .math:    return "Math"
        case .physics: return "Physics"
        }
    }
}

/// One tracked problem type: how often the user has struggled with it and
/// how often they've gotten a submission out — the raw material for "what
/// trips Carlton up" in the briefing and prompt injection.
struct ProblemTypeStat: Codable, Equatable, Sendable {
    var id: String
    var domain: HomeworkDomain
    var topic: String
    var struggles: Int
    var solved: Int
    var lastSeen: TimeInterval
    var createdAt: TimeInterval
}
