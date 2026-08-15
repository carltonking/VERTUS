//
//  Career.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Models/Career.swift).
//

import Foundation

/// One job listing as the Mac reports it. `id` is stable across scans (a hash
/// of the apply URL), so an application recorded against it survives a refresh.
struct JobPostingPayload: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var company: String
    var location: String
    var description: String
    var salary: String
    var applyURL: String
    var source: String
    var postedAt: TimeInterval?

    static func fromJSON(_ params: [String: Any]) -> JobPostingPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let posting = try? JSONDecoder().decode(JobPostingPayload.self, from: data)
        else { return nil }
        return posting
    }

    /// The dictionary form the Mac's career.apply / career.score accept.
    var wireDictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": id, "title": title, "company": company, "location": location,
            "description": description, "salary": salary, "applyURL": applyURL,
            "source": source,
        ]
        if let postedAt { dict["postedAt"] = postedAt }
        return dict
    }
}

/// The career-ops rubric verdict for one posting.
struct JobScorePayload: Codable, Hashable {
    var score: Double
    var match: Double
    var northStar: Double
    var comp: Double
    var culture: Double
    var redFlags: Double
    var reasoning: String
    var threshold: Double
    var shouldApply: Bool
    var verdictLine: String

    static func fromJSON(_ params: [String: Any]) -> JobScorePayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let score = try? JSONDecoder().decode(JobScorePayload.self, from: data)
        else { return nil }
        return score
    }
}

/// A scored listing from career.search — the Discover list's row.
struct ScoredJobPayload: Codable, Hashable, Identifiable {
    var posting: JobPostingPayload
    var score: JobScorePayload

    var id: String { posting.id }

    static func fromJSON(_ params: [String: Any]) -> ScoredJobPayload? {
        guard let postingRaw = params["posting"] as? [String: Any],
              let scoreRaw = params["score"] as? [String: Any],
              let posting = JobPostingPayload.fromJSON(postingRaw),
              let score = JobScorePayload.fromJSON(scoreRaw)
        else { return nil }
        return ScoredJobPayload(posting: posting, score: score)
    }
}

/// Where one application stands — must match the Mac's ApplicationStatus raw values.
enum ApplicationStatusPayload: String, Codable, Hashable, CaseIterable, Identifiable {
    case applied
    case interviewScheduled
    case offer
    case rejected
    case ghosted
    case followUpSent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .applied: return "Applied"
        case .interviewScheduled: return "Interview scheduled"
        case .offer: return "Offer received"
        case .rejected: return "Rejected"
        case .ghosted: return "Ghosted"
        case .followUpSent: return "Follow-up sent"
        }
    }
}

/// One tracked application.
struct JobApplicationPayload: Codable, Hashable, Identifiable {
    var id: UUID
    var jobID: String
    var title: String
    var company: String
    var applyURL: String
    var location: String
    var score: Double
    var appliedAt: TimeInterval
    var status: ApplicationStatusPayload
    var nextFollowUpAt: TimeInterval
    var notes: String
    var cvPath: String

    static func fromJSON(_ params: [String: Any]) -> JobApplicationPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let application = try? JSONDecoder().decode(JobApplicationPayload.self, from: data)
        else { return nil }
        return application
    }

    /// A follow-up is overdue when a date is set and it has passed.
    var isFollowUpOverdue: Bool {
        nextFollowUpAt > 0 && nextFollowUpAt <= Date().timeIntervalSince1970
    }
}

/// The job-hunt profile, edited in Settings and pushed with career.set_preferences.
struct JobPreferencesPayload: Codable, Hashable {
    var roleTypes: [String]
    var locations: [String]
    var minSalary: Int
    var desiredCompanies: [String]
    var keywords: [String]
    var followUpDays: Int
    var applyThreshold: Double

    static let `default` = JobPreferencesPayload(
        roleTypes: [], locations: [], minSalary: 0,
        desiredCompanies: [], keywords: [],
        followUpDays: 7, applyThreshold: 4.0)

    static func fromJSON(_ params: [String: Any]) -> JobPreferencesPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let preferences = try? JSONDecoder().decode(JobPreferencesPayload.self, from: data)
        else { return nil }
        return preferences
    }
}

/// The tracker dashboard counts.
struct CareerSummaryPayload: Codable, Hashable {
    var applied: Int
    var interviews: Int
    var offers: Int
    var rejected: Int
    var ghosted: Int
    var followUpsDue: Int
    var line: String

    static func fromJSON(_ params: [String: Any]) -> CareerSummaryPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let summary = try? JSONDecoder().decode(CareerSummaryPayload.self, from: data)
        else { return nil }
        return summary
    }
}
