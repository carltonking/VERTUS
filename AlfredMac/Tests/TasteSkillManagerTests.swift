import XCTest
@testable import Alfred

/// Covers the deterministic parts of the taste-skill layer: the boringness
/// evaluator (phrase hits, thresholds, the generic-title heuristic), scope
/// and threshold gating, settings defaults + round-trip, the no-model
/// passthrough of polishIfNeeded, and generationGuidance's on/off behavior.
/// Everything avoids Hermes — polishIfNeeded runs with no hermes assigned,
/// which exercises the degrade-to-original path.
@MainActor
final class TasteSkillManagerTests: XCTestCase {

    private var originalSettings: TasteSettings!

    override func setUp() {
        super.setUp()
        originalSettings = TasteSkillManager.shared.settings
    }

    override func tearDown() {
        TasteSkillManager.shared.settings = originalSettings
        super.tearDown()
    }

    // MARK: - Evaluator: prose

    func testGenericBoilerplateScoresHigh() {
        let verdict = TasteBoringness.evaluate(
            "Thank you for your email. I appreciate your feedback. Please do not hesitate to reach out.",
            aggressiveness: .moderate)
        XCTAssertGreaterThanOrEqual(verdict.score, 0.4, "boilerplate must clear the moderate bar")
        XCTAssertTrue(verdict.needsPolish)
        XCTAssertFalse(verdict.matchedPhrases.isEmpty)
    }

    func testSpecificProseScoresZero() {
        let verdict = TasteBoringness.evaluate(
            "The demo moved to Thursday 2pm instead of Friday. I updated the deck and re-ran the auth tests.",
            aggressiveness: .aggressive)
        XCTAssertEqual(verdict.score, 0, "specific writing with real facts is never bland")
        XCTAssertFalse(verdict.needsPolish)
        XCTAssertTrue(verdict.matchedPhrases.isEmpty)
    }

    func testBuzzwordsContribute() {
        let verdict = TasteBoringness.evaluate(
            "We will leverage cutting-edge synergy to revolutionize the platform.",
            aggressiveness: .conservative)
        XCTAssertGreaterThanOrEqual(verdict.score, 0.5, "three buzzwords must clear even the conservative bar")
        XCTAssertTrue(verdict.needsPolish)
    }

    func testThresholdsSeparateAggressivenessLevels() {
        // One generic phrase scores 0.22: conservative (0.5) and moderate (0.35)
        // hold, aggressive (0.2) fires.
        let onePhrase = "I wanted to reach out about the project."
        XCTAssertFalse(TasteBoringness.evaluate(onePhrase, aggressiveness: .conservative).needsPolish)
        XCTAssertFalse(TasteBoringness.evaluate(onePhrase, aggressiveness: .moderate).needsPolish)
        XCTAssertTrue(TasteBoringness.evaluate(onePhrase, aggressiveness: .aggressive).needsPolish)

        // Two phrases score 0.44: moderate fires too.
        let twoPhrases = "I wanted to reach out about the project. Let me know if you have any questions."
        XCTAssertTrue(TasteBoringness.evaluate(twoPhrases, aggressiveness: .moderate).needsPolish)
        XCTAssertFalse(TasteBoringness.evaluate(twoPhrases, aggressiveness: .conservative).needsPolish)
    }

    func testOverlappingPhrasesDoNotDoubleCount() {
        // "please do not hesitate" contains "do not hesitate" — the same words
        // must not be charged twice, so only the longer phrase counts.
        let text = "Please do not hesitate to reach out with any questions."
        let verdict = TasteBoringness.evaluate(text, aggressiveness: .aggressive)
        XCTAssertEqual(verdict.matchedPhrases.count, 1,
                       "a phrase contained in a longer match is dropped")
        XCTAssertEqual(verdict.score, 0.22)
    }

    func testThresholdValuesAreMonotonic() {
        XCTAssertGreaterThan(
            TasteBoringness.threshold(for: .conservative),
            TasteBoringness.threshold(for: .moderate))
        XCTAssertGreaterThan(
            TasteBoringness.threshold(for: .moderate),
            TasteBoringness.threshold(for: .aggressive))
    }

    // MARK: - Evaluator: titles

    func testGenericTitleIsBland() {
        XCTAssertTrue(TasteBoringness.isGenericTitle("Daily research"))
        XCTAssertTrue(TasteBoringness.isGenericTitle("Check my email"))
        XCTAssertTrue(TasteBoringness.isGenericTitle("Morning summary"))
        let verdict = TasteBoringness.evaluate("Daily research", aggressiveness: .moderate)
        XCTAssertGreaterThanOrEqual(verdict.score, 0.5)
        XCTAssertTrue(verdict.needsPolish)
    }

    func testSpecificTitleIsNotBland() {
        XCTAssertFalse(TasteBoringness.isGenericTitle("Morning intelligence briefing"),
                       "'intelligence' names the content")
        XCTAssertFalse(TasteBoringness.isGenericTitle("Sarah's Project Review"),
                       "a proper noun makes the title specific")
        XCTAssertFalse(TasteBoringness.isGenericTitle("Q2 budget follow-up"),
                       "a number makes the title specific")
        XCTAssertFalse(TasteBoringness.isGenericTitle("Swift package audit"))
    }

    func testLongTextNeverUsesTitleHeuristic() {
        // 9+ words: the title heuristic must not fire even when every word is generic.
        XCTAssertFalse(TasteBoringness.isGenericTitle(
            "daily check of my email and tasks and todos and reminders for the day"))
    }

    // MARK: - Gating

    func testShouldPolishFalseWhenDisabled() {
        TasteSkillManager.shared.isEnabled = false
        TasteSkillManager.shared.scopes = [.emails, .routines]
        XCTAssertFalse(TasteSkillManager.shared.shouldPolish(
            scope: .routines, text: "Daily research"))
    }

    func testShouldPolishFalseForUnselectedScope() {
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.emails]
        XCTAssertFalse(TasteSkillManager.shared.shouldPolish(
            scope: .briefing, text: "I wanted to reach out about the project."))
    }

    func testShouldPolishTrueForBlandInScope() {
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.emails]
        TasteSkillManager.shared.aggressiveness = .moderate
        XCTAssertTrue(TasteSkillManager.shared.shouldPolish(
            scope: .emails, text: "Thank you for your email. I appreciate your feedback."))
    }

    func testShouldPolishFalseForSpecificText() {
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.emails]
        TasteSkillManager.shared.aggressiveness = .aggressive
        XCTAssertFalse(TasteSkillManager.shared.shouldPolish(
            scope: .emails, text: "The demo moved to Thursday 2pm — deck updated, auth tests re-run."))
    }

    func testShouldPolishFalseForEmptyText() {
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.emails]
        XCTAssertFalse(TasteSkillManager.shared.shouldPolish(scope: .emails, text: "   "))
    }

    // MARK: - Polish passthrough (no model)

    func testPolishIfNeededReturnsOriginalWhenDisabled() async {
        TasteSkillManager.shared.isEnabled = false
        let original = "Thank you for your email. I appreciate your feedback."
        let result = await TasteSkillManager.shared.polishIfNeeded(original, scope: .emails)
        XCTAssertEqual(result, original)
    }

    func testPolishIfNeededReturnsOriginalWhenBlandButNoHermes() async {
        // Enabled + bland, but no hermes assigned (tests never assign one):
        // must degrade to the original, never nil and never throw.
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.emails]
        let original = "Thank you for your email. I appreciate your feedback."
        let result = await TasteSkillManager.shared.polishIfNeeded(original, scope: .emails)
        XCTAssertEqual(result, original)
    }

    func testPolishIfNeededReturnsOriginalWhenSpecific() async {
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.emails]
        TasteSkillManager.shared.aggressiveness = .aggressive
        let original = "The demo moved to Thursday 2pm instead of Friday."
        let result = await TasteSkillManager.shared.polishIfNeeded(original, scope: .emails)
        XCTAssertEqual(result, original, "specific text skips the model turn entirely")
    }

    // MARK: - Generation guidance

    func testGuidanceEmptyWhenDisabled() {
        TasteSkillManager.shared.isEnabled = false
        XCTAssertEqual(TasteSkillManager.shared.generationGuidance(scope: .briefing), "")
        XCTAssertEqual(TasteSkillManager.shared.generationGuidance(scope: .code), "")
    }

    func testGuidanceEmptyForUnselectedScope() {
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.code]
        XCTAssertEqual(TasteSkillManager.shared.generationGuidance(scope: .briefing), "")
        XCTAssertFalse(TasteSkillManager.shared.generationGuidance(scope: .code).isEmpty)
    }

    func testGuidanceHasTasteContent() {
        TasteSkillManager.shared.isEnabled = true
        TasteSkillManager.shared.scopes = [.briefing, .code]
        XCTAssertTrue(TasteSkillManager.shared.generationGuidance(scope: .briefing)
            .contains("clichés"))
        XCTAssertTrue(TasteSkillManager.shared.generationGuidance(scope: .code)
            .contains("why"))
        // Emails/routines are post-hoc scopes — never injected into prompts.
        XCTAssertEqual(TasteSkillManager.shared.generationGuidance(scope: .emails), "")
        XCTAssertEqual(TasteSkillManager.shared.generationGuidance(scope: .routines), "")
    }

    // MARK: - Settings

    func testSettingsDefaults() {
        XCTAssertEqual(TasteSkillManager.shared.settings, .default)
        XCTAssertTrue(TasteSkillManager.shared.isEnabled)
        XCTAssertEqual(TasteSkillManager.shared.aggressiveness, .moderate)
        XCTAssertEqual(TasteSkillManager.shared.voice, .matchUser)
        XCTAssertTrue(TasteSkillManager.shared.scopes.contains(.emails))
    }

    func testSettingsRoundTripThroughUserDefaults() {
        TasteSkillManager.shared.settings = TasteSettings(
            enabled: false, aggressiveness: .aggressive,
            voice: .casual, scopes: [.routines])
        // A fresh load from the same storage key sees the persisted value.
        let stored = TasteSkillManager.loadForTest()
        XCTAssertEqual(stored?.enabled, false)
        XCTAssertEqual(stored?.aggressiveness, .aggressive)
        XCTAssertEqual(stored?.voice, .casual)
        XCTAssertEqual(stored?.scopes, [.routines])
    }
}

/// Test-only access to the persisted settings behind the singleton.
extension TasteSkillManager {
    static func loadForTest() -> TasteSettings? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.taste_settings"),
              let settings = try? JSONDecoder().decode(TasteSettings.self, from: data)
        else { return nil }
        return settings
    }
}
