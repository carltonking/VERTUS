//
//  NYU.swift
//  Alfred
//
//  The iOS half of the NYU coursework contract. These mirror the macOS
//  wire dictionaries in NYUIntegrationManager exactly — the phone decodes
//  `nyu.*` results with these, and encodes `nyu.set_settings` back with
//  them. Keep the two in lockstep.
//

import Foundation

/// How one assignment stands — must match the Mac's AssignmentStatus raw values.
enum AssignmentStatusPayload: String, Codable, Hashable, CaseIterable, Identifiable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case submitted
    case graded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .submitted: return "Submitted"
        case .graded: return "Graded"
        }
    }
}

/// One assignment as the Mac reports it.
struct NYUAssignmentPayload: Codable, Hashable, Identifiable {
    var id: Int
    var courseID: Int
    var courseName: String
    var name: String
    var details: String
    var dueAt: TimeInterval
    var points: Double
    var status: String
    var submittedAt: TimeInterval
    var score: Double
    var url: String
    var isOverdue: Bool
    var daysUntil: Int

    var statusPayload: AssignmentStatusPayload {
        AssignmentStatusPayload(rawValue: status) ?? .notStarted
    }

    /// "Due in 3 days" / "Overdue 2 days" / "No due date".
    var dueLabel: String {
        if isOverdue {
            return "Overdue \(abs(daysUntil))d"
        }
        if daysUntil > 0 {
            return daysUntil == 1 ? "Due tomorrow" : "Due in \(daysUntil) days"
        }
        return "No due date"
    }

    static func fromJSON(_ params: [String: Any]) -> NYUAssignmentPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(NYUAssignmentPayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// One course as the Mac reports it — the Grades list row.
struct NYUCoursePayload: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var code: String
    var term: String
    var professor: String
    var syllabus: String
    var currentScore: Double
    var previousScore: Double
    var projectedScore: Double
    var finalExamAt: TimeInterval
    var gradingBreakdown: [String: Double]
    var officeHours: String
    var schedule: String
    var trend: String

    /// "92.5" or "—" when Canvas hasn't posted a score yet.
    var scoreLabel: String {
        guard currentScore > 0 else { return "—" }
        return currentScore == currentScore.rounded()
            ? String(Int(currentScore)) : String(format: "%.1f", currentScore)
    }

    static func fromJSON(_ params: [String: Any]) -> NYUCoursePayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(NYUCoursePayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// The settings the phone sends to the Mac via nyu.set_settings — mirrors the
/// Mac's NYUSettings exactly (including the token, which crosses the wire once
/// so Sync Now works; the status wire only ever reports tokenSet).
struct NYUSettingsPayload: Codable, Hashable {
    var enabled: Bool = false
    var canvasToken: String = ""
    var targetGPA: Double = 0
    var syncFrequencyHours: Int = 6
    var remind24h: Bool = true
    var remind1h: Bool = true
    var calendarSyncEnabled: Bool = false
}

/// The integration's status: settings (token presence only — the token itself
/// never crosses the wire) plus last-sync counts.
struct NYUStatusPayload: Codable, Hashable {
    var enabled: Bool
    var tokenSet: Bool
    var targetGPA: Double
    var syncFrequencyHours: Int
    var remind24h: Bool
    var remind1h: Bool
    var calendarSyncEnabled: Bool
    var lastSyncAt: TimeInterval
    var courseCount: Int
    var assignmentCount: Int
    var overdueCount: Int
    var dueThisWeek: Int
    var gradedCount: Int

    var isConfigured: Bool { enabled && tokenSet }

    static func fromJSON(_ params: [String: Any]) -> NYUStatusPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(NYUStatusPayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// What one sync pass produced.
struct NYUSyncResultPayload: Codable, Hashable {
    var success: Bool
    var message: String
    var courses: Int
    var assignments: Int
    var announcements: Int
    var dueThisWeek: Int
    var overdue: Int
    var syncedAt: TimeInterval

    static func fromJSON(_ params: [String: Any]) -> NYUSyncResultPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let payload = try? JSONDecoder().decode(NYUSyncResultPayload.self, from: data)
        else { return nil }
        return payload
    }
}
