import XCTest
import SQLite3
@testable import Alfred

/// Deterministic tests for the Homework Assistant — no model involved. The
/// classifier, style matcher, JSON extraction and formatter are pure; the
/// tracker gets a throwaway database in the temp dir (mirroring
/// MemPalaceManagerTests); the skill is exercised only through its guards and
/// its wire round-trip, so no HermesSession is ever spawned.
final class HomeworkAssistantSkillTests: XCTestCase {

    private var tracker: ProblemTypeTracker!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("homework-test-\(UUID().uuidString)")
            .appendingPathComponent("homework.db")
            .path
        tracker = ProblemTypeTracker(databasePath: dbPath)
        // Settings persist to UserDefaults; reset so test order never matters.
        UserDefaults.standard.removeObject(forKey: "alfred.homework_settings")
    }

    private func makeSkill() -> HomeworkAssistantSkill {
        HomeworkAssistantSkill.makeForTesting(tracker: tracker)
    }

    // MARK: - Problem classifier

    func testClassifierDetectsCS() {
        XCTAssertEqual(HomeworkProblemClassifier.classify(
            "Write a recursive function to reverse a string"), .cs)
    }

    func testClassifierDetectsMath() {
        XCTAssertEqual(HomeworkProblemClassifier.classify(
            "Evaluate the integral of x squared from 0 to 1"), .math)
    }

    func testClassifierDetectsPhysics() {
        XCTAssertEqual(HomeworkProblemClassifier.classify(
            "A mass of 5 kg is pulled by a force of 10 N, find the acceleration"), .physics)
    }

    func testClassifierFallsBackToMath() {
        XCTAssertEqual(HomeworkProblemClassifier.classify(
            "What is the answer to this question?"), .math)
    }

    func testClassifierEmptyIsNil() {
        XCTAssertNil(HomeworkProblemClassifier.classify("   \n  "))
    }

    // MARK: - Solution style matcher

    func testStyleInjectionCombines() {
        XCTAssertEqual(SolutionStyleMatcher.injection(writingProfile: "concise", learnedStyle: "solves in prose"),
                       "concise solves in prose")
    }

    func testStyleInjectionEmptyWhenNothingKnown() {
        XCTAssertEqual(SolutionStyleMatcher.injection(writingProfile: "", learnedStyle: nil), "")
    }

    // MARK: - JSON extraction (the model reply parser)

    func testExtractJSONObjectFromProse() throws {
        let raw = "Here you go: {\"solution\": \"x = 2\", \"steps\": [\"a\", \"b\"]} Done."
        let cleaned = HomeworkAssistantSkill.extractJSONObject(from: raw)
        let data = try XCTUnwrap(cleaned.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["solution"] as? String, "x = 2")
        XCTAssertEqual((obj["steps"] as? [String])?.count, 2)
    }

    func testExtractJSONObjectFromFence() throws {
        let raw = "```json\n{\"approach\": \"try small cases\"}\n```"
        let cleaned = HomeworkAssistantSkill.extractJSONObject(from: raw)
        let data = try XCTUnwrap(cleaned.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["approach"] as? String, "try small cases")
    }

    func testExtractJSONObjectNoBracesReturnsTrimmed() {
        let raw = "  I have no structured answer  "
        XCTAssertEqual(HomeworkAssistantSkill.extractJSONObject(from: raw), "I have no structured answer")
    }

    // MARK: - Formatter (pure, instant)

    func testFormatSolutionCodeWrapsWhenUnfenced() {
        let out = makeSkill().formatSolution("print(1)", format: "code")
        XCTAssertTrue(out.hasPrefix("```"))
        XCTAssertTrue(out.hasSuffix("```"))
    }

    func testFormatSolutionCodePassthroughWhenAlreadyFenced() {
        let fenced = "```\nprint(1)\n```"
        XCTAssertEqual(makeSkill().formatSolution(fenced, format: "code"), fenced)
    }

    func testFormatSolutionLatexWrapsMathyContent() {
        let out = makeSkill().formatSolution("y = mx + b", format: "latex")
        XCTAssertTrue(out.hasPrefix("\\("), "expected literal \\( prefix, got \(out)")
        XCTAssertTrue(out.hasSuffix("\\)"))
    }

    func testFormatSolutionLatexNeverDoubleWraps() {
        let already = "$y = mx + b$"
        XCTAssertEqual(makeSkill().formatSolution(already, format: "latex"), already)
    }

    func testFormatSolutionTextPassthrough() {
        let plain = "Just a sentence."
        XCTAssertEqual(makeSkill().formatSolution(plain, format: "text"), plain)
    }

    // MARK: - Settings wire round-trip

    func testSettingsWireRoundTrip() {
        let defaults = HomeworkSettings.default
        let wire = HomeworkAssistantSkill.homeworkSettingsWire(defaults)
        let decoded = HomeworkAssistantSkill.homeworkSettings(from: wire)
        XCTAssertEqual(decoded, defaults)
    }

    func testSettingsWireRoundTripCustom() {
        let custom = HomeworkSettings(enabled: false, defaultMode: .submit,
                                      codeStyle: .generic, showSteps: .never,
                                      difficulty: .challenge, format: .latex)
        let decoded = HomeworkAssistantSkill.homeworkSettings(
            from: HomeworkAssistantSkill.homeworkSettingsWire(custom))
        XCTAssertEqual(decoded, custom)
    }

    // MARK: - Skill guards (no session touched)

    func testSolveProblemEmptyInput() async {
        let reply = await makeSkill().solveProblem("   ", mode: nil)
        XCTAssertEqual(reply, "What problem are you working on?")
    }

    func testSolveProblemDisabled() async {
        let skill = makeSkill()
        skill.isEnabled = false
        let reply = await skill.solveProblem("Solve this integral", mode: nil)
        XCTAssertEqual(reply, "Homework help is off in Settings — turn it on and ask again.")
    }

    func testExplainProblemEmptyInput() async {
        let reply = await makeSkill().explainProblem("")
        XCTAssertEqual(reply, "What problem should I walk you through?")
    }

    func testExplainProblemDisabled() async {
        let skill = makeSkill()
        skill.isEnabled = false
        let reply = await skill.explainProblem("How do I start this proof?")
        XCTAssertEqual(reply, "Homework help is off in Settings — turn it on and ask again.")
    }

    func testStruggleSummaryEmptyState() {
        XCTAssertTrue(makeSkill().struggleSummary().contains("No problem types on record yet"))
    }

    // MARK: - Tracker (throwaway SQLite db)

    func testTrackerRecordsStruggleAndSolve() {
        tracker.recordStruggle(domain: .math, topic: "integration by parts")
        tracker.recordStruggle(domain: .math, topic: "integration by parts")
        tracker.recordSolved(domain: .math, topic: "integration by parts")

        let topics = tracker.struggleTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics[0].struggles, 2)
        XCTAssertEqual(topics[0].solved, 1)
        XCTAssertEqual(topics[0].domain, .math)
        XCTAssertEqual(tracker.masteredCount(), 0)
    }

    func testTrackerUpsertsSameTopicAcrossCase() {
        tracker.recordStruggle(domain: .cs, topic: "Recursion")
        tracker.recordStruggle(domain: .cs, topic: "recursion")
        XCTAssertEqual(tracker.allTopics().count, 1)
        XCTAssertEqual(tracker.struggleTopics(limit: 10).count, 1)
    }

    func testTrackerSeparatesTopics() {
        tracker.recordStruggle(domain: .cs, topic: "recursion")
        tracker.recordStruggle(domain: .math, topic: "limits")
        XCTAssertEqual(tracker.allTopics().count, 2)
        XCTAssertEqual(tracker.masteredCount(), 0)
    }

    func testTrackerMasteredCount() {
        tracker.recordSolved(domain: .cs, topic: "binary search")
        XCTAssertEqual(tracker.masteredCount(), 1)
    }

    func testTrackerPreferencesRoundTrip() {
        tracker.setPreference("learned_solution_style", value: "solves in prose")
        XCTAssertEqual(tracker.preference("learned_solution_style"), "solves in prose")
        XCTAssertNil(tracker.preference("missing"))
    }

    func testTrackerStruggleLine() {
        tracker.recordStruggle(domain: .math, topic: "series convergence")
        XCTAssertTrue(tracker.struggleLine().contains("series convergence"))
        XCTAssertTrue(tracker.struggleLine().contains("struggled 1×"))
    }
}
