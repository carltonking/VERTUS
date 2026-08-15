//
//  CareerOpsManager.swift
//  Alfred
//
//  Alfred's local job-search command center — a Swift adaptation of the
//  open-source career-ops methodology (santifer/career-ops): scan job
//  listings, score each against the owner's profile on a 1.0–5.0 rubric,
//  tailor the CV and cover letter per job, and track every application.
//
//  What stays true to career-ops, and what is Alfred-shaped:
//
//   * Scoring is the career-ops rubric — five dimensions (match,
//     north-star alignment, comp, cultural signals, red flags) judged by an
//     LLM into one holistic 1.0–5.0, with 4.0 as the apply/don't-apply
//     threshold. In Alfred, Hermes writes the judgment; a deterministic
//     keyword scorer covers the cases where Hermes is busy or absent, so a
//     search is never left unscored.
//   * Scanning is honest about what works: career-ops reads Greenhouse /
//     Ashby / Lever JSON feeds because LinkedIn and Indeed block scrapers.
//     Alfred's first scan path is web search over the Crawlee bridge (no
//     API keys, no blocked hosts) — the same results a human would find.
//   * Applying is human-in-the-loop by design, exactly as career-ops ships:
//     `apply` records the application, generates the tailored CV + cover
//     letter, and hands the owner the apply URL. Nothing is ever submitted
//     on their behalf — form automation stays gated behind Browser-Use's
//     confirmation and the browser skill's never-submits rule.
//
//  Persistence follows the sibling managers (RoutineManager, AlfredCodeManager):
//  plain JSON under ~/.alfred/career/ — preferences.json, applications.json,
//  and cv.md (the base CV Hermes tailors from). No database dependency, and
//  the files are human-editable.
//
//  Threading: @MainActor like RoutineManager; the only network calls (search,
//  Hermes turns) are async and off the actor.

import CryptoKit
import Foundation

// MARK: - Models

/// What the owner wants in a role — the profile everything is scored against.
struct JobPreferences: Codable, Equatable {
    /// Role types / titles, e.g. "Internship", "Entry-level", "Software Engineer".
    var roleTypes: [String]
    /// Preferred cities / "Remote".
    var locations: [String]
    /// Minimum acceptable annual salary in USD; 0 = no floor.
    var minSalary: Int
    /// Companies the owner would specifically like to work for.
    var desiredCompanies: [String]
    /// Skills to highlight in a tailored CV ("Python", "React", …).
    var keywords: [String]
    /// Days of silence before a follow-up is due. 7 matches career-ops' default.
    var followUpDays: Int
    /// The apply/don't-apply threshold on the 1.0–5.0 score (career-ops: 4.0).
    var applyThreshold: Double

    static let `default` = JobPreferences(
        roleTypes: [],
        locations: [],
        minSalary: 0,
        desiredCompanies: [],
        keywords: [],
        followUpDays: 7,
        applyThreshold: 4.0)
}

/// One job listing found by the scan. `id` is stable across re-scans (a hash
/// of the apply URL) so an application recorded against it survives a refresh.
struct JobPosting: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var company: String
    var location: String
    /// The listing text — a search snippet for web-search results.
    var description: String
    /// Raw salary text when the listing carried one ("$120k–150k").
    var salary: String
    var applyURL: String
    /// Where the listing came from ("search" today; board feeds later).
    var source: String
    var postedAt: TimeInterval?

    /// A stable id from an apply URL — the dedup key between scans.
    static func id(for url: String) -> String {
        guard let data = url.data(using: .utf8) else { return UUID().uuidString }
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// The career-ops rubric verdict: five 1–5 dimensions and the holistic score.
/// `redFlags` is negative-only (higher = more blockers), matching the source
/// methodology — it adjusts the holistic score, never stands alone.
struct JobScore: Codable, Equatable {
    var score: Double
    var match: Double
    var northStar: Double
    var comp: Double
    var culture: Double
    var redFlags: Double
    var reasoning: String
    /// The threshold this verdict was measured against (the profile's).
    var threshold: Double

    /// Whether the owner should apply: score meets the profile threshold.
    var shouldApply: Bool { score >= threshold }

    /// A one-line verdict for a card: "4.6 — strong match" / "2.8 — below threshold".
    var verdictLine: String {
        let label: String
        switch score {
        case 4.5...: label = "strong match"
        case 4.0..<4.5: label = "worth applying"
        case 3.5..<4.0: label = "decent, not ideal"
        default: label = "below threshold"
        }
        return String(format: "%.1f — %@", score, label)
    }
}

/// Where one application stands. Mirrors career-ops' tracker statuses.
enum ApplicationStatus: String, Codable, CaseIterable, Identifiable {
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
struct JobApplication: Codable, Equatable, Identifiable {
    var id: UUID
    /// The `JobPosting.id` it was recorded from — stable across scans.
    var jobID: String
    var title: String
    var company: String
    var applyURL: String
    var location: String
    /// The rubric score at apply time.
    var score: Double
    var appliedAt: TimeInterval
    var status: ApplicationStatus
    /// When a follow-up is due: appliedAt + preferences.followUpDays. Cleared
    /// when a follow-up is sent or the application resolves.
    var nextFollowUpAt: TimeInterval?
    var notes: String
    /// Path of the tailored CV, when one was generated.
    var cvPath: String?
}

/// The tracker dashboard counts, plus a human sentence for the briefing.
struct CareerSummary: Codable, Equatable {
    var applied: Int
    var interviews: Int
    var offers: Int
    var rejected: Int
    var ghosted: Int
    var followUpsDue: Int

    /// "4 applications, 1 interview, 0 offers — 2 follow-ups due."
    var line: String {
        var parts: [String] = []
        if applied > 0 { parts.append("\(applied) application\(applied == 1 ? "" : "s")") }
        if interviews > 0 { parts.append("\(interviews) interview\(interviews == 1 ? "" : "s")") }
        if offers > 0 { parts.append("\(offers) offer\(offers == 1 ? "" : "s")") }
        if rejected > 0 { parts.append("\(rejected) rejected") }
        if ghosted > 0 { parts.append("\(ghosted) silent") }
        var line = parts.isEmpty ? "No applications yet." : parts.joined(separator: ", ")
        if followUpsDue > 0 {
            let suffix = line.hasSuffix(".") ? "" : "."
            line += suffix + " \(followUpsDue) follow-up\(followUpsDue == 1 ? "" : "s") due."
        }
        return line
    }
}

// MARK: - Manager

/// Owns job search, scoring, CV tailoring and the application tracker.
/// Persists to ~/.alfred/career/ and exposes everything to the phone through
/// BriefingSocketServer's `career.*` methods, and to routines through the
/// `career` step kind.
@MainActor
final class CareerOpsManager {

    static let shared = CareerOpsManager()

    /// The agent that writes rubric judgments and tailored documents. Handed
    /// over at launch by the app delegate, like the briefing generator's.
    weak var hermes: HermesSession?

    /// Fired whenever an application is added, updated or deleted — the app
    /// delegate broadcasts `career.applications_changed` so the phone's Jobs
    /// tab refreshes without asking.
    var onApplicationsChanged: (() -> Void)?

    private(set) var preferences: JobPreferences
    private(set) var applications: [JobApplication]

    /// Live results of the most recent scan, keyed by their stable id — lets
    /// the phone's apply flow reference a posting by id without re-searching.
    private var recentPostings: [String: JobPosting] = [:]

    private let dirURL: URL
    private let prefsURL: URL
    private let appsURL: URL
    private let cvURL: URL

    /// Creates the manager. `directoryOverride` exists for tests — the
    /// production singleton uses the real ~/.alfred/career location; a test
    /// passes a fresh temp directory so nothing touches the owner's data.
    init(directoryOverride: URL? = nil) {
        let home = NSHomeDirectory() as NSString
        let defaultDir = URL(fileURLWithPath: home.appendingPathComponent(".alfred/career") as String)
        let dir = directoryOverride ?? defaultDir
        try? FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        dirURL = dir
        prefsURL = dir.appendingPathComponent("preferences.json")
        appsURL = dir.appendingPathComponent("applications.json")
        cvURL = dir.appendingPathComponent("cv.md")
        preferences = Self.loadPreferences(from: prefsURL)
        applications = Self.loadApplications(from: appsURL)
        seedCVIfMissing()
        NSLog("[career] loaded — \(applications.count) application(s), \(preferences.roleTypes.count) role type(s)")
    }

    // MARK: - Preferences

    func setPreferences(_ newValue: JobPreferences) {
        preferences = newValue
        save()
        NSLog("[career] preferences updated — roles=\(newValue.roleTypes), locations=\(newValue.locations), threshold=\(newValue.applyThreshold)")
    }

    // MARK: - Base CV

    /// The base CV Alfred tailors from. Creates a starter document on first
    /// use so the tailoring prompt always has something to work with — the
    /// owner edits ~/.alfred/career/cv.md (or asks Alfred to).
    func cvText() -> String {
        seedCVIfMissing()
        return (try? String(contentsOf: cvURL, encoding: .utf8)) ?? ""
    }

    private func seedCVIfMissing() {
        guard !FileManager.default.fileExists(atPath: cvURL.path) else { return }
        let starter = """
        # CV — edit me, or ask Alfred to help

        ## Profile
        - Name:
        - Location:
        - Contact:

        ## Education
        -

        ## Skills
        -

        ## Experience
        -

        ## Projects
        -

        """
        try? starter.data(using: .utf8)?.write(to: cvURL, options: .atomic)
        NSLog("[career] seeded starter CV at \(cvURL.path)")
    }

    // MARK: - Search

    /// Scan for jobs. With `role`/`location` given they override the profile;
    /// otherwise the profile's first role type and locations drive the query.
    /// Runs over the Crawlee bridge's web search (DDG/Bing HTML — no API key,
    /// no blocked host), so the results are what a human would find searching
    /// the same words. Never throws; a dead bridge yields an empty array.
    func searchJobs(role: String? = nil, location: String? = nil, limit: Int = 10) async -> [JobPosting] {
        var role = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if role.isEmpty { role = preferences.roleTypes.first ?? "" }
        var location = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if location.isEmpty { location = preferences.locations.first ?? "" }
        guard !role.isEmpty else { return [] }

        let query = "\(role) \(location) job opening".trimmingCharacters(in: .whitespaces)
        NSLog("[career] scanning — \(query)")
        let result = await CrawleeClient.shared.search(query: query)
        guard result.succeeded, let results = result.payload?["results"] as? [[String: Any]] else {
            NSLog("[career] scan failed — %@", result.message)
            return []
        }

        let postings = Self.parseSearchResults(results, role: role, location: location)
            .prefix(limit)
            .map { posting in
                recentPostings[posting.id] = posting
                return posting
            }
        NSLog("[career] scan found \(postings.count) listing(s)")
        return postings
    }

    func posting(id: String) -> JobPosting? {
        recentPostings[id]
    }

    /// Turn Crawlee search hits into job postings. A search title usually reads
    /// "Role at Company" or "Role - Company"; the best-effort split keeps the
    /// human label intact and lets company filtering (desired companies,
    /// dedup) work on real names. Pure and static so it is unit-tested.
    static func parseSearchResults(_ results: [[String: Any]], role: String, location: String) -> [JobPosting] {
        results.compactMap { item in
            guard let rawURL = item["url"] as? String,
                  !rawURL.isEmpty,
                  let rawTitle = item["title"] as? String,
                  !rawTitle.isEmpty
            else { return nil }
            let cleaned = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let (title, company) = splitTitle(cleaned)
            let snippet = (item["snippet"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return JobPosting(
                id: JobPosting.id(for: rawURL),
                title: title,
                company: company,
                location: location,
                description: snippet,
                salary: "",
                applyURL: rawURL,
                source: "search",
                postedAt: nil)
        }
    }

    /// "Software Engineer at Google — Mountain View" → title "Software Engineer",
    /// company "Google". Splits on " at ", then " - " / " — " / " | ".
    static func splitTitle(_ raw: String) -> (title: String, company: String) {
        let separators = [" at ", " — ", " - ", " | ", " – "]
        var best = (title: raw, company: "")
        var bestIndex = -1
        for sep in separators {
            guard let range = raw.range(of: sep) else { continue }
            let company = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !company.isEmpty else { continue }
            let idx = raw.distance(from: raw.startIndex, to: range.lowerBound)
            if idx > bestIndex {
                bestIndex = idx
                best = (String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), company)
            }
        }
        return best
    }

    // MARK: - Scoring

    /// Score a posting with the career-ops rubric. Hermes writes the judgment
    /// when it's free and answers; the deterministic scorer covers every other
    /// case so a scan always comes back scored.
    func scoreJob(_ posting: JobPosting) async -> JobScore {
        if let hermes, await !hermes.isTurnActive,
           let verdict = await askHermesForScore(posting) {
            return verdict
        }
        return Self.deterministicScore(posting: posting, preferences: preferences)
    }

    /// Score and rank a scan in one pass, strong matches first — the phone's
    /// Discover list shows the top of the pile.
    func scoreAndRank(_ postings: [JobPosting]) async -> [(posting: JobPosting, score: JobScore)] {
        var ranked: [(JobPosting, JobScore)] = []
        for posting in postings {
            ranked.append((posting, await scoreJob(posting)))
        }
        return ranked.sorted { lhs, rhs in
            if lhs.1.shouldApply != rhs.1.shouldApply { return lhs.1.shouldApply }
            return lhs.1.score > rhs.1.score
        }
    }

    /// The rubric turn — the same JSON-contract pattern as the briefing and
    /// mail triager: tool-free, `capture: false`, strict JSON.
    private func askHermesForScore(_ posting: JobPosting) async -> JobScore? {
        guard let hermes else { return nil }
        let profile = profileBlock()
        let postingBlock = """
        Title: \(posting.title)
        Company: \(posting.company)
        Location: \(posting.location)
        Salary: \(posting.salary.isEmpty ? "not stated" : posting.salary)
        \(posting.description.isEmpty ? "" : "Description: \(posting.description)")
        """
        let prompt = """
        You are a job-fit scorer using the career-ops rubric. Score the job \
        posting against the person's profile on five dimensions, each 1–5:

        - match: skills and experience alignment — cite what lines up.
        - north_star: how well the role fits their target role types.
        - comp: salary vs market rate (estimate when not stated).
        - culture: company signals — stage, remote policy, stability.
        - red_flags: negative-only risk — blockers, no sponsorship, ghost-post \
        markers. Higher = worse.

        Then give a holistic score from 1.0 to 5.0, where 4.0 or higher means \
        the person should apply. Be honest: a poor fit must score below 4.0.

        Profile:
        \(profile)

        Posting:
        \(postingBlock)

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"score": 1.0-5.0, "match": 1-5, "north_star": 1-5, "comp": 1-5, \
        "culture": 1-5, "red_flags": 1-5, "reasoning": "one short paragraph"}
        """
        var transcript = ""
        for await event in await hermes.prompt(prompt, capture: false) {
            switch event {
            case .text(let chunk):
                transcript += chunk
            case .failed(let message):
                NSLog("[career] scoring turn failed: %@", message)
                return nil
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                break
            }
        }
        guard let json = Self.extractJSONObject(from: transcript),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let score = obj["score"] as? Double
        else {
            NSLog("[career] scoring JSON unparsable — falling back to deterministic")
            return nil
        }
        return JobScore(
            score: min(max(score, 1.0), 5.0),
            match: Self.dimension(obj["match"]),
            northStar: Self.dimension(obj["north_star"]),
            comp: Self.dimension(obj["comp"]),
            culture: Self.dimension(obj["culture"]),
            redFlags: Self.dimension(obj["red_flags"]),
            reasoning: obj["reasoning"] as? String ?? "",
            threshold: preferences.applyThreshold)
    }

    private static func dimension(_ value: Any?) -> Double {
        guard let number = value as? Double else { return 0 }
        return min(max(number, 1), 5)
    }

    /// The profile in the form the rubric prompt consumes.
    private func profileBlock() -> String {
        var lines: [String] = []
        if !preferences.roleTypes.isEmpty {
            lines.append("Target role types: \(preferences.roleTypes.joined(separator: ", "))")
        }
        if !preferences.locations.isEmpty {
            lines.append("Locations: \(preferences.locations.joined(separator: ", "))")
        }
        if preferences.minSalary > 0 {
            lines.append("Minimum salary: $\(preferences.minSalary)")
        }
        if !preferences.desiredCompanies.isEmpty {
            lines.append("Desired companies: \(preferences.desiredCompanies.joined(separator: ", "))")
        }
        if !preferences.keywords.isEmpty {
            lines.append("Key skills: \(preferences.keywords.joined(separator: ", "))")
        }
        return lines.isEmpty ? "New to the job hunt — no profile yet." : lines.joined(separator: "\n")
    }

    /// Deterministic fallback scorer — no model, always answers. Weights are
    /// deliberately simple: keyword/role overlap is the bulk of the score,
    /// location and company whitelist add, salary presence nudges. Pure and
    /// static so it is unit-tested with fixed expectations.
    static func deterministicScore(posting: JobPosting, preferences: JobPreferences) -> JobScore {
        let haystack = "\(posting.title) \(posting.company) \(posting.description)".lowercased()

        // Match: fraction of the profile's keywords present in the listing.
        let keywords = preferences.keywords.map { $0.lowercased() }
        let matchedKeywords = keywords.filter { haystack.contains($0) }
        let keywordScore = keywords.isEmpty ? 3.0 : 5.0 * Double(matchedKeywords.count) / Double(keywords.count)

        // North-star: any target role type phrase in the title or description.
        let roles = preferences.roleTypes.map { $0.lowercased() }
        let roleMatch = roles.contains { haystack.contains($0) }
        let northStar = roleMatch ? 4.5 : (roles.isEmpty ? 3.0 : 2.0)

        // Comp: salary present at all gets a baseline; unknown is neutral.
        let comp = posting.salary.isEmpty ? 3.0 : 4.0

        // Culture: desired companies whitelist bumps it.
        let companies = preferences.desiredCompanies.map { $0.lowercased() }
        let whitelisted = companies.contains { posting.company.lowercased().contains($0) }
        let culture = whitelisted ? 4.5 : 3.0

        // Red flags: negative-only. A listing with no location and no company
        // name reads like a repost/aggregator — a mild flag, nothing punitive.
        let redFlags = (posting.company.isEmpty || posting.location.isEmpty) ? 3.0 : 1.0

        // Holistic: career-ops is holistic, but the fallback needs a formula —
        // the dims weighted, red flags pulling it down, threshold applied last.
        var score = keywordScore * 0.5 + northStar * 0.25 + comp * 0.1 + culture * 0.15
        score -= (redFlags - 1.0) * 0.3
        score = min(max(score, 1.0), 5.0)

        let reasoning: String
        if whitelisted {
            reasoning = "Matches \(matchedKeywords.count)/\(keywords.count) target skills; company is on your desired list."
        } else if roleMatch {
            reasoning = "Matches \(matchedKeywords.count)/\(keywords.count) target skills and your target role type."
        } else if keywords.isEmpty && roles.isEmpty {
            reasoning = "No profile preferences set yet — scored neutrally."
        } else {
            reasoning = "Weak overlap with your target role and skills."
        }
        return JobScore(
            score: score,
            match: keywordScore,
            northStar: northStar,
            comp: comp,
            culture: culture,
            redFlags: redFlags,
            reasoning: reasoning,
            threshold: preferences.applyThreshold)
    }

    // MARK: - CV tailoring

    /// Tailor the base CV to a posting: Hermes rewrites it to emphasize the
    /// posting's requirements against the owner's profile. The result is saved
    /// under ~/.alfred/career/tailored/<jobId>.md and returned. Nil when Hermes
    /// is busy or the turn fails — the base CV remains the fallback.
    func tailoredCV(for posting: JobPosting) async -> String? {
        guard let hermes else { return nil }
        let base = cvText()
        guard !base.isEmpty else { return nil }
        let prompt = """
        Tailor the person's CV below to this job posting. Keep it truthful — \
        only reorder, emphasize and rephrase what the CV already claims, never \
        invent experience. Highlight the skills the posting asks for that the \
        person has. Output the full tailored CV as markdown, nothing else.

        Job posting:
        Title: \(posting.title)
        Company: \(posting.company)
        \(posting.description.isEmpty ? "" : "Description: \(posting.description)")

        Base CV:
        \(base)
        """
        guard let result = await hermesTextTurn(prompt) else { return nil }
        let file = dirURL.appendingPathComponent("tailored/\(posting.id).md")
        try? FileManager.default.createDirectory(atPath: file.deletingLastPathComponent().path,
                                                 withIntermediateDirectories: true)
        try? result.data(using: .utf8)?.write(to: file, options: .atomic)
        NSLog("[career] tailored CV for \(posting.title) — \(result.count) chars")
        return result
    }

    /// A short, personalized cover letter for a posting, saved next to the
    /// tailored CV. Nil when Hermes is unavailable.
    func coverLetter(for posting: JobPosting) async -> String? {
        guard let hermes else { return nil }
        let base = cvText()
        let profile = profileBlock()
        let prompt = """
        Write a short, professional cover letter (2–3 short paragraphs) for \
        the job below, grounded in the person's profile and CV. Personalize it \
        to the company and role; mention one or two concrete skills the person \
        actually has. No invented experience. Output only the letter text.

        \(profile)

        Job: \(posting.title) at \(posting.company) (\(posting.location))

        CV:
        \(base)
        """
        guard let result = await hermesTextTurn(prompt) else { return nil }
        let file = dirURL.appendingPathComponent("tailored/\(posting.id)-cover.md")
        try? result.data(using: .utf8)?.write(to: file, options: .atomic)
        return result
    }

    /// One Hermes turn that just returns prose (no JSON contract).
    private func hermesTextTurn(_ prompt: String) async -> String? {
        guard let hermes else { return nil }
        var transcript = ""
        for await event in await hermes.prompt(prompt, capture: false) {
            switch event {
            case .text(let chunk):
                transcript += chunk
            case .failed(let message):
                NSLog("[career] Hermes turn failed: %@", message)
                return nil
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                break
            }
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Application tracker

    /// All tracked applications, newest first — the phone's tracker list.
    func listApplications() -> [JobApplication] {
        applications.sorted { $0.appliedAt > $1.appliedAt }
    }

    func application(id: UUID) -> JobApplication? {
        applications.first { $0.id == id }
    }

    /// Record an application — the human-in-the-loop version of "apply": the
    /// entry is created, the tailored package is offered, and the owner does
    /// the actual submission at the apply URL. Returns the new record.
    @discardableResult
    func recordApplication(posting: JobPosting, score: JobScore, notes: String = "") -> JobApplication {
        let now = Date().timeIntervalSince1970
        let application = JobApplication(
            id: UUID(),
            jobID: posting.id,
            title: posting.title,
            company: posting.company,
            applyURL: posting.applyURL,
            location: posting.location,
            score: score.score,
            appliedAt: now,
            status: .applied,
            nextFollowUpAt: now + Double(max(preferences.followUpDays, 1)) * 86_400,
            notes: notes,
            cvPath: nil)
        applications.insert(application, at: 0)
        save()
        NSLog("[career] recorded application — \(posting.title) at \(posting.company)")
        onApplicationsChanged?()
        return application
    }

    @discardableResult
    func updateStatus(id: UUID, status: ApplicationStatus) -> JobApplication? {
        guard let index = applications.firstIndex(where: { $0.id == id }) else { return nil }
        var application = applications[index]
        application.status = status
        // A follow-up sent (or an answer received) retires the pending date.
        switch status {
        case .followUpSent, .offer, .rejected, .ghosted:
            application.nextFollowUpAt = nil
        default:
            break
        }
        applications[index] = application
        save()
        NSLog("[career] application status → \(status.rawValue) (\(application.title))")
        onApplicationsChanged?()
        return application
    }

    @discardableResult
    func deleteApplication(id: UUID) -> Bool {
        let before = applications.count
        applications.removeAll { $0.id == id }
        if applications.count != before {
            save()
            onApplicationsChanged?()
            return true
        }
        return false
    }

    /// Applications whose follow-up date has passed — the `career.follow_ups`
    /// routine step's work list.
    func followUpsDue(now: Date = Date()) -> [JobApplication] {
        applications.filter { app in
            guard let due = app.nextFollowUpAt else { return false }
            return due <= now.timeIntervalSince1970
        }
    }

    func summary() -> CareerSummary {
        CareerSummary(
            applied: applications.count,
            interviews: applications.filter { $0.status == .interviewScheduled }.count,
            offers: applications.filter { $0.status == .offer }.count,
            rejected: applications.filter { $0.status == .rejected }.count,
            ghosted: applications.filter { $0.status == .ghosted }.count,
            followUpsDue: followUpsDue().count)
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(applications) {
            try? data.write(to: appsURL, options: .atomic)
        }
    }

    private static func loadPreferences(from url: URL) -> JobPreferences {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(JobPreferences.self, from: data)
        else { return .default }
        return stored
    }

    private static func loadApplications(from url: URL) -> [JobApplication] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([JobApplication].self, from: data)
        else { return [] }
        return stored
    }

    // MARK: - JSON extraction

    /// Pull the first balanced JSON object out of a model's reply, tolerating
    /// prose fences around it — the same contract the briefing generator uses.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.range(of: "{")?.lowerBound else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in text[start...].indices {
            let char = text[index]
            if inString {
                if escaped { escaped = false; continue }
                if char == "\\" { escaped = true; continue }
                if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            default: break
            }
        }
        return nil
    }
}
