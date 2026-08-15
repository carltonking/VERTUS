import XCTest
@testable import Alfred

/// Covers the deterministic parts of the self-optimization (DSPy) loop: the
/// prompt-domain classifier, the pattern learner that turns good-vs-bad output
/// signals into rules, the SQLite store's round-trips and rollback, and the
/// optimizer's compile + prompt-injection path. Everything runs against a
/// throwaway database so the real `~/.alfred/db/optimization.db` is never
/// touched, and the shared settings key is restored after each test.
final class DSPyOptimizerTests: XCTestCase {

    private var originalSettings: OptimizationSettings?

    override func setUp() {
        super.setUp()
        originalSettings = DSPyOptimizer.loadForTest()
    }

    override func tearDown() {
        DSPyOptimizer.shared.settings = originalSettings ?? .default
        super.tearDown()
    }

    private func tempStorePath() -> String {
        NSTemporaryDirectory() + "alfred-optimization-\(UUID().uuidString).db"
    }

    private func makeOptimizer(minFeedback: Int = 2) -> (DSPyOptimizer, String) {
        let path = tempStorePath()
        let optimizer = DSPyOptimizer.makeForTesting(databasePath: path)
        optimizer.settings = OptimizationSettings(
            frequency: .manual, minFeedback: minFeedback,
            confidenceThreshold: 0.10, autoRollback: false, lastCompiledAt: nil)
        return (optimizer, path)
    }

    // MARK: - Kind detection

    func testDetectCode() {
        XCTAssertEqual(OptimizationKind.detect(from: "Refactor this to use async/await"), .code)
        XCTAssertEqual(OptimizationKind.detect(from: "fix the compile error in package.json"), .code)
    }

    func testDetectEmail() {
        XCTAssertEqual(OptimizationKind.detect(from: "Draft an email to my professor"), .email)
        XCTAssertEqual(OptimizationKind.detect(from: "write a cover letter for this internship"), .email)
    }

    func testDetectSummary() {
        XCTAssertEqual(OptimizationKind.detect(from: "Summarize this article's key points"), .summary)
    }

    func testDetectGeneralFallback() {
        XCTAssertEqual(OptimizationKind.detect(from: "What's the capital of France?"), .general)
    }

    // MARK: - Heuristic learner

    private func codeExample(rating: Int, withAsync: Bool) -> FeedbackEntry {
        let output = withAsync
            ? "Here is the fix: use Task { await fetch() } so the UI never blocks."
            : "Here is the fix: call fetch() and wait for it synchronously."
        return FeedbackEntry(kind: .code, prompt: "refactor this", output: output, rating: rating)
    }

    func testLearnPrefersAsyncWhenGoodOutputsUseIt() {
        let entries = [
            codeExample(rating: 5, withAsync: true),
            codeExample(rating: 5, withAsync: true),
            codeExample(rating: 1, withAsync: false),
            codeExample(rating: 2, withAsync: false),
        ]
        let rules = OptimizationHeuristics.learn(from: entries, kind: .code)
        XCTAssertTrue(rules.contains { $0.rule.contains("async/await") },
                      "async should be learned when good outputs use it and bad ones don't")
        XCTAssertTrue(rules.allSatisfy { $0.source == "heuristic" })
        XCTAssertFalse(rules.contains { $0.rule.contains("why, not what") },
                       "a feature both groups share must not become a rule")
    }

    func testLearnRequiresMinimumGoodSamples() {
        let entries = [
            codeExample(rating: 5, withAsync: true),
            codeExample(rating: 1, withAsync: false),
        ]
        XCTAssertTrue(OptimizationHeuristics.learn(from: entries, kind: .code).isEmpty)
    }

    func testLearnCapsRulesPerKind() {
        // All four code features present in good outputs, none in bad: every
        // feature would earn a rule, but the cap must hold it to three.
        var entries: [FeedbackEntry] = []
        for _ in 0..<4 {
            entries.append(FeedbackEntry(kind: .code, prompt: "refactor", output: """
                async Task { await run() } // why: the call blocks the main thread
                do { try run() } catch let e as CustomError { throw e }
                XCTest verify()
                """, rating: 5))
            entries.append(FeedbackEntry(kind: .code, prompt: "refactor", output: "run()", rating: 1))
        }
        let rules = OptimizationHeuristics.learn(from: entries, kind: .code)
        XCTAssertLessThanOrEqual(rules.count, OptimizationHeuristics.maxRulesPerKind)
    }

    func testLearnRulesSortedByConfidence() {
        let entries = [
            codeExample(rating: 5, withAsync: true),
            codeExample(rating: 5, withAsync: true),
            codeExample(rating: 1, withAsync: false),
        ]
        let rules = OptimizationHeuristics.learn(from: entries, kind: .code)
        let confidences = rules.map(\.confidence)
        XCTAssertEqual(confidences, confidences.sorted(by: >))
    }

    // MARK: - Store

    func testStoreFeedbackAggregate() {
        let store = OptimizationStore(databasePath: tempStorePath())
        let now = Date().timeIntervalSince1970
        store.insertFeedback(FeedbackEntry(kind: .code, prompt: "a", output: "x", rating: 4, timestamp: now))
        store.insertFeedback(FeedbackEntry(kind: .code, prompt: "b", output: "y", rating: 2, timestamp: now))
        let (average, count) = store.aggregate(kind: .code, since: now - 60)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(average, 3.0, accuracy: 0.001)
        XCTAssertEqual(store.feedbackCount(since: now - 60), 2)
    }

    func testStoreRuleInstallAndRollback() {
        let store = OptimizationStore(databasePath: tempStorePath())
        let v1 = [OptimizationRule(kind: .code, rule: "Prefer async", confidence: 0.9, source: "heuristic", version: 1)]
        let v2 = [OptimizationRule(kind: .code, rule: "Write tests", confidence: 0.8, source: "heuristic", version: 2)]
        store.installRules(v1, kind: .code, version: 1, source: "heuristic")
        store.installRules(v2, kind: .code, version: 2, source: "heuristic")
        XCTAssertEqual(store.latestVersion(kind: .code), 2)
        XCTAssertEqual(store.activeRules(kind: .code).first?.rule, "Write tests")

        store.rollback(kind: .code, to: 1)
        XCTAssertEqual(store.activeRules(kind: .code).first?.rule, "Prefer async")

        store.rollback(kind: .code, to: 0)
        XCTAssertTrue(store.activeRules(kind: .code).isEmpty)
    }

    func testStoreAggregateFoldsEditedEmailDown() {
        let store = OptimizationStore(databasePath: tempStorePath())
        let now = Date().timeIntervalSince1970
        store.insertFeedback(FeedbackEntry(kind: .email, prompt: "draft", output: "x", rating: 5, edited: true, timestamp: now))
        let (average, _) = store.aggregate(kind: .email, since: now - 60)
        // Edited-before-send counts one point lower: 5 → 4.
        XCTAssertEqual(average, 4.0, accuracy: 0.001)
    }

    // MARK: - Optimizer

    func testOptimizerCompilesAndInjectsLearnedRules() {
        let (optimizer, _) = makeOptimizer(minFeedback: 2)
        optimizer.recordFeedback(kind: .code, prompt: "refactor this",
                                 output: "Task { await run() }", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "refactor that",
                                 output: "async let x = fetch()", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "refactor other",
                                 output: "run() synchronously", rating: 1)

        _ = optimizer.compile()

        XCTAssertFalse(optimizer.activeRules(kind: .code).isEmpty,
                       "a compile pass over rated examples must learn rules")
        let injection = optimizer.promptInjection(for: "refactor the login flow to be async")
        XCTAssertTrue(injection.contains("Prefer async/await"),
                      "the learned rule must ride along on code prompts")
    }

    func testOptimizerInjectionEmptyForUnknownDomain() {
        let (optimizer, _) = makeOptimizer()
        optimizer.recordFeedback(kind: .code, prompt: "refactor",
                                 output: "Task { await run() }", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "refactor",
                                 output: "async run()", rating: 5)
        _ = optimizer.compile()
        // A general prompt has no learned code rules applied.
        XCTAssertEqual(optimizer.promptInjection(for: "What time is it?"), "")
    }

    func testOptimizerReportCountsCurrentWeekRatings() {
        let (optimizer, _) = makeOptimizer()
        optimizer.recordFeedback(kind: .code, prompt: "a", output: "x", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "b", output: "y", rating: 4)
        let report = optimizer.report()
        XCTAssertEqual(report.totalRatings, 1)  // one kind bucket counted
        XCTAssertEqual(report.averageRating, 4.5, accuracy: 0.001)
        XCTAssertEqual(report.perKind.first(where: { $0.kind == "code" })?.samples, 2)
    }

    func testRollbackRevertsToPreviousVersion() {
        let (optimizer, _) = makeOptimizer(minFeedback: 2)
        // Pass one: async learned.
        optimizer.recordFeedback(kind: .code, prompt: "refactor", output: "Task { await x() }", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "refactor", output: "await y()", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "refactor", output: "x()", rating: 1)
        _ = optimizer.compile()
        let v1Rules = optimizer.activeRules(kind: .code)
        XCTAssertFalse(v1Rules.isEmpty)

        // Pass two: a different signal dominates.
        optimizer.recordFeedback(kind: .code, prompt: "refactor", output: "XCTest verify()", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "refactor", output: "assert(true)", rating: 5)
        optimizer.recordFeedback(kind: .code, prompt: "refactor", output: "x()", rating: 1)
        _ = optimizer.compile()

        let rolledBack = optimizer.rollback(kind: .code)
        XCTAssertEqual(Set(rolledBack.map(\.version)), Set(v1Rules.map(\.version)),
                       "rollback must restore the previous rule set")
    }

    func testSettingsDefaults() {
        let defaults = OptimizationSettings.default
        XCTAssertEqual(defaults.frequency, .weekly)
        XCTAssertEqual(defaults.minFeedback, 10)
        XCTAssertEqual(defaults.confidenceThreshold, 0.10, accuracy: 0.0001)
        XCTAssertTrue(defaults.autoRollback)
    }

    func testImprovementCardNilUntilDataOrRules() {
        let (optimizer, path) = makeOptimizer()
        // Empty store → no card.
        XCTAssertNil(optimizer.improvementCard())
        // Some data → card appears.
        optimizer.recordFeedback(kind: .code, prompt: "a", output: "x", rating: 5)
        XCTAssertNotNil(optimizer.improvementCard())
        _ = path
    }
}
