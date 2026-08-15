import XCTest
@testable import Alfred

/// Covers the deterministic parts of the career-ops integration: the rubric
/// fallback scorer, search-result parsing, the tracker's follow-up window and
/// status transitions, persistence round-trips, and the JSON-contract
/// extractor. Everything here avoids Hermes, the Crawlee bridge and the
/// network — a fresh temp directory isolates each run from the owner's real
/// ~/.alfred/career data.
@MainActor
final class CareerOpsManagerTests: XCTestCase {

    private var tempDir: URL!
    private var manager: CareerOpsManager!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("career-test-\(UUID().uuidString)")
        manager = CareerOpsManager(directoryOverride: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func posting(_ title: String, company: String = "Acme", location: String = "New York",
                         description: String = "") -> JobPosting {
        JobPosting(
            id: JobPosting.id(for: title),
            title: title, company: company, location: location,
            description: description, salary: "",
            applyURL: "https://acme.com/jobs/\(title)", source: "search", postedAt: nil)
    }

    private func score(_ value: Double, threshold: Double = 4.0) -> JobScore {
        JobScore(score: value, match: value, northStar: value, comp: value,
                 culture: value, redFlags: 1, reasoning: "test", threshold: threshold)
    }

    private func preferences(
        roleTypes: [String] = ["Software Engineer"],
        locations: [String] = ["New York"],
        keywords: [String] = ["Swift", "React"],
        followUpDays: Int = 7,
        threshold: Double = 4.0
    ) -> JobPreferences {
        JobPreferences(roleTypes: roleTypes, locations: locations, minSalary: 0,
                       desiredCompanies: [], keywords: keywords,
                       followUpDays: followUpDays, applyThreshold: threshold)
    }

    // MARK: - Deterministic scorer

    func testStrongMatchClearsApplyThreshold() {
        let posting = posting("Software Engineer", description: "Swift and React, API design")
        let score = CareerOpsManager.deterministicScore(
            posting: posting, preferences: preferences(keywords: ["Swift", "React"]))
        XCTAssertGreaterThanOrEqual(score.score, 4.0, "a full keyword + role match must clear the 4.0 bar")
        XCTAssertTrue(score.shouldApply)
        XCTAssertEqual(score.threshold, 4.0)
    }

    func testPoorMatchFallsBelowThreshold() {
        let posting = posting("Barista", company: "Cafe", location: "",
                              description: "espresso and pastries")
        let score = CareerOpsManager.deterministicScore(
            posting: posting, preferences: preferences(keywords: ["Swift", "React", "Kotlin"]))
        XCTAssertLessThan(score.score, 4.0, "an unrelated role must never read as apply-worthy")
        XCTAssertFalse(score.shouldApply)
    }

    func testDesiredCompanyBumpsAnOtherwiseMarginalScore() {
        // Same posting, one profile with the company whitelisted and one without:
        // the whitelisted profile must score strictly higher.
        let posting = posting("Backend Engineer", company: "Stripe", description: "Go services")
        let base = JobPreferences(roleTypes: ["Backend Engineer"], locations: [], minSalary: 0,
                                  desiredCompanies: [], keywords: ["Go"],
                                  followUpDays: 7, applyThreshold: 4.0)
        let whitelisted = JobPreferences(roleTypes: ["Backend Engineer"], locations: [], minSalary: 0,
                                         desiredCompanies: ["Stripe"], keywords: ["Go"],
                                         followUpDays: 7, applyThreshold: 4.0)
        let plain = CareerOpsManager.deterministicScore(posting: posting, preferences: base)
        let boosted = CareerOpsManager.deterministicScore(posting: posting, preferences: whitelisted)
        XCTAssertGreaterThan(boosted.score, plain.score)
    }

    func testEmptyProfileScoresNeutrallyNotPenalized() {
        let posting = posting("Anything")
        let score = CareerOpsManager.deterministicScore(
            posting: posting,
            preferences: JobPreferences(roleTypes: [], locations: [], minSalary: 0,
                                        desiredCompanies: [], keywords: [],
                                        followUpDays: 7, applyThreshold: 4.0))
        XCTAssertEqual(score.score, 3.0, "no profile = neutral 3.0, never a knee-jerk pass or apply")
        XCTAssertTrue(score.reasoning.contains("No profile"))
    }

    // MARK: - Title parsing

    func testSplitTitleAtCompany() {
        let (title, company) = CareerOpsManager.splitTitle("Software Engineer at Google")
        XCTAssertEqual(title, "Software Engineer")
        XCTAssertEqual(company, "Google")
    }

    func testSplitTitleDashSeparator() {
        let (title, company) = CareerOpsManager.splitTitle("Frontend Intern - Spotify")
        XCTAssertEqual(title, "Frontend Intern")
        XCTAssertEqual(company, "Spotify")
    }

    func testSplitTitleNoSeparatorKeepsWhole() {
        let (title, company) = CareerOpsManager.splitTitle("Senior iOS Engineer")
        XCTAssertEqual(title, "Senior iOS Engineer")
        XCTAssertEqual(company, "")
    }

    // MARK: - Search-result parsing

    func testParseSearchResultsMapsHitsToPostings() {
        let results: [[String: Any]] = [
            ["title": "Software Engineer at Acme", "url": "https://acme.com/careers/1",
             "snippet": "Swift and React."],
            ["title": "No URL", "url": ""],
            ["title": "", "url": "https://x.com/job"],
        ]
        let postings = CareerOpsManager.parseSearchResults(
            results, role: "Software Engineer", location: "Remote")
        XCTAssertEqual(postings.count, 1, "entries without a URL or title are dropped")
        XCTAssertEqual(postings[0].company, "Acme")
        XCTAssertEqual(postings[0].location, "Remote")
        XCTAssertEqual(postings[0].source, "search")
    }

    func testPostingIDIsStablePerURL() {
        XCTAssertEqual(JobPosting.id(for: "https://x.com/job"), JobPosting.id(for: "https://x.com/job"))
        XCTAssertNotEqual(JobPosting.id(for: "https://x.com/job"), JobPosting.id(for: "https://x.com/other"))
    }

    // MARK: - Tracker

    func testRecordApplicationSetsFollowUpFromPreferences() {
        manager.setPreferences(preferences(followUpDays: 5))
        let application = manager.recordApplication(posting: posting("Engineer"), score: score(4.5))
        XCTAssertEqual(application.status, .applied)
        XCTAssertNotNil(application.nextFollowUpAt)
        XCTAssertEqual(application.nextFollowUpAt!, application.appliedAt + 5 * 86_400,
                       "the follow-up lands exactly appliedAt + the profile's window")
    }

    func testFollowUpsDueOnlyAfterWindow() throws {
        let now = Date().timeIntervalSince1970

        // A window that already passed is due.
        var seededDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("career-due-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: seededDir.path, withIntermediateDirectories: true)
        let past = JobApplication(id: UUID(), jobID: "j1", title: "Engineer", company: "Acme",
                                  applyURL: "https://acme.com", location: "", score: 4.5,
                                  appliedAt: now - 20 * 86_400, status: .applied,
                                  nextFollowUpAt: now - 10 * 86_400, notes: "", cvPath: nil)
        try JSONEncoder().encode([past]).write(to: seededDir.appendingPathComponent("applications.json"))
        XCTAssertEqual(CareerOpsManager(directoryOverride: seededDir).followUpsDue().count, 1)
        try? FileManager.default.removeItem(at: seededDir)

        // A window still ahead is not due.
        seededDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("career-future-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: seededDir.path, withIntermediateDirectories: true)
        let future = JobApplication(id: UUID(), jobID: "j2", title: "Engineer", company: "Acme",
                                    applyURL: "https://acme.com", location: "", score: 4.5,
                                    appliedAt: now, status: .applied,
                                    nextFollowUpAt: now + 5 * 86_400, notes: "", cvPath: nil)
        try JSONEncoder().encode([future]).write(to: seededDir.appendingPathComponent("applications.json"))
        XCTAssertEqual(CareerOpsManager(directoryOverride: seededDir).followUpsDue().count, 0)
        try? FileManager.default.removeItem(at: seededDir)
    }

    func testUpdateStatusClearsFollowUpForOffer() {
        let application = manager.recordApplication(posting: posting("Engineer"), score: score(4.5))
        let updated = manager.updateStatus(id: application.id, status: .offer)
        XCTAssertEqual(updated?.status, .offer)
        XCTAssertNil(updated?.nextFollowUpAt, "an answer retires the pending follow-up")
    }

    func testUpdateStatusClearsFollowUpForFollowUpSent() {
        let application = manager.recordApplication(posting: posting("Engineer"), score: score(4.5))
        let updated = manager.updateStatus(id: application.id, status: .followUpSent)
        XCTAssertEqual(updated?.status, .followUpSent)
        XCTAssertNil(updated?.nextFollowUpAt)
    }

    func testDeleteApplicationRemovesRecord() {
        let application = manager.recordApplication(posting: posting("Engineer"), score: score(4.5))
        XCTAssertEqual(manager.listApplications().count, 1)
        XCTAssertTrue(manager.deleteApplication(id: application.id))
        XCTAssertTrue(manager.listApplications().isEmpty)
        XCTAssertFalse(manager.deleteApplication(id: application.id), "a second delete is a no-op")
    }

    func testSummaryCountsStatuses() {
        let a = manager.recordApplication(posting: posting("Engineer"), score: score(4.5))
        let b = manager.recordApplication(posting: posting("Designer"), score: score(4.2))
        _ = manager.updateStatus(id: a.id, status: .interviewScheduled)
        _ = manager.updateStatus(id: b.id, status: .rejected)
        let summary = manager.summary()
        XCTAssertEqual(summary.applied, 2)
        XCTAssertEqual(summary.interviews, 1)
        XCTAssertEqual(summary.rejected, 1)
        XCTAssertEqual(summary.offers, 0)
    }

    // MARK: - Persistence

    func testPreferencesAndApplicationsRoundTripThroughDisk() {
        manager.setPreferences(preferences(roleTypes: ["Internship"], locations: ["Remote"],
                                          keywords: ["Python"], followUpDays: 10))
        _ = manager.recordApplication(posting: posting("Engineer"), score: score(4.5))

        let reloaded = CareerOpsManager(directoryOverride: tempDir)
        XCTAssertEqual(reloaded.preferences.roleTypes, ["Internship"])
        XCTAssertEqual(reloaded.preferences.locations, ["Remote"])
        XCTAssertEqual(reloaded.preferences.followUpDays, 10)
        XCTAssertEqual(reloaded.listApplications().count, 1)
    }

    func testCVPersistsAndSeedsStarter() {
        // First access seeds a starter document; a second manager reads it back.
        XCTAssertFalse(manager.cvText().isEmpty, "the starter CV is created on demand")
        let reloaded = CareerOpsManager(directoryOverride: tempDir)
        XCTAssertEqual(manager.cvText(), reloaded.cvText())
    }

    // MARK: - JSON extraction

    func testExtractJSONObjectSkipsProseFences() {
        let text = "Here you go:\n{\"score\": 4.5, \"match\": 5}\n\nBest regards"
        let json = CareerOpsManager.extractJSONObject(from: text)
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("\"score\""))
    }

    func testExtractJSONObjectHandlesNestedQuotes() {
        let text = "{\"reasoning\": \"a \\\"quoted\\\" phrase\", \"score\": 4}"
        let json = CareerOpsManager.extractJSONObject(from: text)
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.hasSuffix("}"))
    }

    func testExtractJSONObjectReturnsNilWithoutBrace() {
        XCTAssertNil(CareerOpsManager.extractJSONObject(from: "no object here"))
    }

    // MARK: - Summary line

    func testSummaryLineFormats() {
        let summary = CareerSummary(applied: 2, interviews: 1, offers: 0,
                                    rejected: 0, ghosted: 0, followUpsDue: 1)
        XCTAssertEqual(summary.line, "2 applications, 1 interview. 1 follow-up due.")

        let empty = CareerSummary(applied: 0, interviews: 0, offers: 0,
                                  rejected: 0, ghosted: 0, followUpsDue: 0)
        XCTAssertEqual(empty.line, "No applications yet.")
    }
}
