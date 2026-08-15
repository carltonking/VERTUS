import XCTest
@testable import Alfred

/// Covers the deterministic parts of the Personal Tutor skill: the mastery
/// tracker's confidence trajectory, the learning-style analyzer, the Socratic
/// and explanation prompt builders, and the skill's orchestration (feedback →
/// mastery, weak-concept reporting, briefing card, settings). Everything runs
/// against throwaway databases so the real `~/.alfred/db/tutor.db` and real
/// MemPalace are never touched, and the shared settings key is restored after
/// each test.
final class TutorSkillTests: XCTestCase {

    private var originalSettings: TutorSettings?

    override func setUp() {
        super.setUp()
        originalSettings = PersonalTutorSkill.loadForTest()
    }

    override func tearDown() {
        // Restore the persisted settings unconditionally: the shared skill's
        // setter skips persistence when its in-memory copy already matches, so
        // a test that toggled `isEnabled` on its own instance would otherwise
        // leave the dirty value in UserDefaults for the next test to load.
        let restored = originalSettings ?? .default
        PersonalTutorSkill.shared.settings = restored
        if let data = try? JSONEncoder().encode(restored) {
            UserDefaults.standard.set(data, forKey: "alfred.tutor_settings")
        }
        super.tearDown()
    }

    private func tempDBPath() -> String {
        NSTemporaryDirectory() + "alfred-tutor-\(UUID().uuidString).db"
    }

    private func makeSkill() -> PersonalTutorSkill {
        PersonalTutorSkill.makeForTesting(databasePath: tempDBPath())
    }

    // MARK: - Session factory

    private func session(concept: String = "recursion", method: TeachingMethod,
                         outcome: TutoringOutcome,
                         mode: TutoringSessionMode = .explain,
                         id: String = UUID().uuidString) -> TutoringSessionRecord {
        TutoringSessionRecord(id: id, concept: concept, course: nil, mode: mode,
                              method: method, outcome: outcome,
                              createdAt: Date().timeIntervalSince1970)
    }

    // MARK: - Settings

    func testSettingsDefaults() {
        let defaults = TutorSettings.default
        XCTAssertTrue(defaults.enabled)
        XCTAssertEqual(defaults.mode, .learning)
        XCTAssertEqual(defaults.socraticDepth, .lightHints)
        XCTAssertEqual(defaults.explanationLength, .detailed)
        XCTAssertEqual(defaults.practiceIntensity, .medium)
    }

    func testSettingsWireRoundTrip() {
        let settings = TutorSettings(
            enabled: false, mode: .answer, socraticDepth: .heavy,
            explanationLength: .quick, practiceIntensity: .hard)
        let wire = BriefingSocketServer.tutorSettingsWire(settings)
        let decoded = BriefingSocketServer.tutorSettings(from: wire)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Mastery tracker

    func testMasteryTrajectoryMatchesSpec() {
        let tracker = ConceptMasteryTracker(databasePath: tempDBPath())

        // First mention, confused → 1/5.
        var sessionID = tracker.recordSession(concept: "Integration", course: "MATH-UA 122",
                                              mode: .explain, method: .theory)
        var concept = tracker.recordOutcome(sessionID: sessionID, outcome: .confused)
        XCTAssertEqual(concept?.confidence, 1)
        XCTAssertEqual(concept?.confusedCount, 1)

        // Two tutoring sessions that landed → 3/5.
        for outcome: TutoringOutcome in [.understood, .understood] {
            sessionID = tracker.recordSession(concept: "Integration", course: "MATH-UA 122",
                                              mode: .explain, method: .stepByStep)
            concept = tracker.recordOutcome(sessionID: sessionID, outcome: outcome)
        }
        XCTAssertEqual(concept?.confidence, 3)

        // Practice problems → 4/5.
        sessionID = tracker.recordSession(concept: "Integration", course: "MATH-UA 122",
                                          mode: .examPrep, method: .stepByStep)
        concept = tracker.recordOutcome(sessionID: sessionID, outcome: .understood)
        XCTAssertEqual(concept?.confidence, 4)
        XCTAssertEqual(concept?.sessionCount, 4)
        XCTAssertNil(concept?.masteredAt)
    }

    func testMasteryClampsAtFiveAndSetsMastered() {
        let tracker = ConceptMasteryTracker(databasePath: tempDBPath())
        var concept: ConceptMastery?
        for _ in 0..<6 {
            let id = tracker.recordSession(concept: "recursion", course: nil,
                                           mode: .explain, method: .codeExample)
            concept = tracker.recordOutcome(sessionID: id, outcome: .understood)
        }
        XCTAssertEqual(concept?.confidence, 5)
        XCTAssertNotNil(concept?.masteredAt)
        XCTAssertEqual(tracker.masteredCount(), 1)
    }

    func testWeakConceptsOrderWeakestFirst() {
        let tracker = ConceptMasteryTracker(databasePath: tempDBPath())
        // "integrals" — asked 3 times, still confused → weakest.
        for _ in 0..<3 {
            let id = tracker.recordSession(concept: "integrals", course: "MATH-UA 122",
                                           mode: .explain, method: .stepByStep)
            _ = tracker.recordOutcome(sessionID: id, outcome: .confused)
        }
        // "recursion" — one understood session → strong.
        let id = tracker.recordSession(concept: "recursion", course: "CSCI-UA 101",
                                       mode: .explain, method: .codeExample)
        _ = tracker.recordOutcome(sessionID: id, outcome: .understood)

        let weak = tracker.weakConcepts(limit: 2)
        XCTAssertEqual(weak.first?.name, "integrals")
        XCTAssertEqual(weak.first?.confidence, 1)
        XCTAssertEqual(weak[1].name, "recursion")
    }

    func testPendingSessionResolvesLatest() {
        let tracker = ConceptMasteryTracker(databasePath: tempDBPath())
        _ = tracker.recordSession(concept: "recursion", course: nil,
                                  mode: .explain, method: .analogy)
        let pending = tracker.pendingSession(for: "Recursion")
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.method, .analogy)
        XCTAssertEqual(pending?.outcome, .abandoned)
    }

    func testSetMasteryDirect() {
        let tracker = ConceptMasteryTracker(databasePath: tempDBPath())
        let updated = tracker.setMastery(name: "oauth", confidence: 3, course: "TECH-UB 41")
        XCTAssertEqual(updated?.confidence, 3)
        XCTAssertEqual(tracker.mastery(for: "OAuth")?.course, "TECH-UB 41")
        // Clamps.
        XCTAssertEqual(tracker.setMastery(name: "oauth", confidence: 9, course: nil)?.confidence, 5)
    }

    func testPrerequisitesRoundTrip() {
        let tracker = ConceptMasteryTracker(databasePath: tempDBPath())
        XCTAssertTrue(tracker.setPrerequisite("derivatives", for: "integration"))
        XCTAssertTrue(tracker.setPrerequisite("calculus basics", for: "integration"))
        let prereqs = tracker.prerequisites(for: "Integration")
        XCTAssertEqual(Set(prereqs), Set(["derivatives", "calculus basics"]))
    }

    // MARK: - Learning style analyzer

    func testStyleLearnsPreferredMethods() {
        let sessions = [
            session(method: .codeExample, outcome: .understood),
            session(method: .codeExample, outcome: .understood),
            session(method: .theory, outcome: .confused),
            session(method: .theory, outcome: .confused),
        ]
        let style = LearningStyleAnalyzer.analyze(sessions: sessions)
        XCTAssertEqual(style.preferredMethods.first, .codeExample)
        XCTAssertTrue(style.methodsThatWork.contains("code examples"))
        XCTAssertTrue(style.methodsThatDont.contains("pure theory"))
    }

    func testStylePreferences() {
        let sessions = [
            session(concept: "a", method: .stepByStep, outcome: .understood),
            session(concept: "b", method: .stepByStep, outcome: .understood),
            session(concept: "c", method: .socratic, outcome: .understood),
            session(concept: "d", method: .socratic, outcome: .understood),
            session(concept: "e", method: .socratic, outcome: .moreDetail),
        ]
        let style = LearningStyleAnalyzer.analyze(sessions: sessions)
        XCTAssertEqual(style.structure, .stepByStep)
        XCTAssertEqual(style.guidance, .socratic)
        XCTAssertEqual(style.depth, .detailed)  // more detail requests beat plain understanding
    }

    func testStyleConfidenceScalesWithSessions() {
        var sessions: [TutoringSessionRecord] = []
        for i in 0..<10 {
            sessions.append(session(concept: "c\(i)", method: .codeExample, outcome: .understood,
                                    id: "id\(i)"))
        }
        let style = LearningStyleAnalyzer.analyze(sessions: sessions)
        XCTAssertEqual(style.confidence, 1.0, accuracy: 0.001)
        XCTAssertTrue(style.isSettled)

        let sparse = LearningStyleAnalyzer.analyze(sessions: Array(sessions.prefix(4)))
        XCTAssertFalse(sparse.isSettled)
        XCTAssertEqual(sparse.confidence, 0.4, accuracy: 0.001)
    }

    func testStyleEmptyWithoutSessions() {
        let style = LearningStyleAnalyzer.analyze(sessions: [])
        XCTAssertTrue(style.preferredMethods.isEmpty)
        XCTAssertEqual(style.structure, .unknown)
        XCTAssertFalse(style.isSettled)
    }

    func testStyleMergesExternalDirectives() {
        let sessions = [session(method: .codeExample, outcome: .understood)]
        let style = LearningStyleAnalyzer.analyze(sessions: sessions,
                                                  externalDirectives: ["visual diagrams"])
        XCTAssertTrue(style.methodsThatWork.contains("visual diagrams"))
    }

    func testDefaultMethodPerCourse() {
        XCTAssertEqual(LearningStyleAnalyzer.defaultMethod(for: "CSCI-UA 101"), .codeExample)
        XCTAssertEqual(LearningStyleAnalyzer.defaultMethod(for: "MATH-UA 122"), .stepByStep)
        XCTAssertEqual(LearningStyleAnalyzer.defaultMethod(for: "PHYS-UA 15"), .visual)
        XCTAssertEqual(LearningStyleAnalyzer.defaultMethod(for: "ARTH-UA 661"), .analogy)
        XCTAssertEqual(LearningStyleAnalyzer.defaultMethod(for: "TECH-UB 41"), .realWorld)
        XCTAssertEqual(LearningStyleAnalyzer.defaultMethod(for: nil), .analogy)
    }

    // MARK: - Prompt builders

    func testSocraticGuidanceDepth() {
        XCTAssertTrue(SocraticMethodEngine.guidanceBlock(depth: .heavy).contains("Do NOT give the answer"))
        XCTAssertTrue(SocraticMethodEngine.guidanceBlock(depth: .lightHints).contains("hint"))
        XCTAssertTrue(SocraticMethodEngine.guidanceBlock(depth: .justAnswer).contains("just wants the answer"))
        let prompt = SocraticMethodEngine.buildPrompt(problem: "fib(5)?", concept: "recursion",
                                                      depth: .heavy)
        XCTAssertTrue(prompt.contains("fib(5)?"))
        XCTAssertTrue(prompt.contains("recursion"))
    }

    func testExplanationGeneratorMethodFallback() {
        let empty = LearningStyle.empty
        XCTAssertEqual(ExplanationGenerator.method(for: "series", style: empty,
                                                   course: "MATH-UA 122"), .stepByStep)
        let styled = LearningStyle(preferredMethods: [.analogy], structure: .unknown,
                                   depth: .unknown, guidance: .unknown,
                                   methodsThatWork: [], methodsThatDont: [],
                                   sessionCount: 6, confidence: 0.6, isSettled: true)
        XCTAssertEqual(ExplanationGenerator.method(for: "series", style: styled,
                                                   course: "MATH-UA 122"), .analogy)
    }

    func testExplanationPromptContainsProfile() {
        let style = LearningStyle(preferredMethods: [.codeExample], structure: .unknown,
                                  depth: .unknown, guidance: .unknown,
                                  methodsThatWork: [], methodsThatDont: [],
                                  sessionCount: 0, confidence: 0, isSettled: false)
        let prompt = ExplanationGenerator.buildPrompt(
            concept: "recursion", course: "CSCI-UA 101", mastery: nil,
            prerequisites: ["basic loops"], style: style,
            settings: TutorSettings.default)
        XCTAssertTrue(prompt.contains("recursion"))
        XCTAssertTrue(prompt.contains("basic loops"))
        XCTAssertTrue(prompt.contains("code examples"))
    }

    // MARK: - Skill orchestration

    func testSkillExplainDegradesGracefullyWithoutAgent() async {
        let skill = makeSkill()
        let result = await skill.explain(concept: "recursion", course: "CSCI-UA 101")
        XCTAssertFalse(result.isEmpty)
        // No session should have been recorded (the turn never ran).
        XCTAssertEqual(skill.tutorCard(), nil)
    }

    func testSkillFeedbackMovesMastery() {
        let skill = makeSkill()
        let first = skill.recordFeedback(concept: "integrals", outcome: .confused,
                                         course: "MATH-UA 122")
        XCTAssertEqual(first?.confidence, 1)
        let second = skill.recordFeedback(concept: "integrals", outcome: .understood,
                                          course: "MATH-UA 122")
        XCTAssertEqual(second?.confidence, 2)
        XCTAssertEqual(second?.sessionCount, 2)
    }

    func testSkillWeakAtListsStruggles() {
        let skill = makeSkill()
        skill.recordFeedback(concept: "integrals", outcome: .confused, course: "MATH-UA 122")
        skill.recordFeedback(concept: "integrals", outcome: .confused, course: "MATH-UA 122")
        skill.recordFeedback(concept: "recursion", outcome: .understood, course: "CSCI-UA 101")

        let text = skill.whatAmIWeakAt()
        XCTAssertTrue(text.contains("integrals"))
        // The weakest concept is listed first.
        let integralsLine = text.firstRange(of: "integrals")!
        let recursionLine = text.firstRange(of: "recursion")!
        XCTAssertLessThan(integralsLine.lowerBound, recursionLine.lowerBound)

        let weak = skill.weakConcepts()
        XCTAssertEqual(weak.first?.name, "integrals")
        XCTAssertEqual(weak.first?.confusedCount, 2)
    }

    func testSkillTrackMastery() {
        let skill = makeSkill()
        let updated = skill.trackMastery(concept: "oauth", confidence: 3, course: "TECH-UB 41")
        XCTAssertEqual(updated?.confidence, 3)
        XCTAssertTrue(skill.whatAmIWeakAt().contains("oauth"))
    }

    func testSkillLearningStyleSummary() {
        let skill = makeSkill()
        XCTAssertTrue(skill.myLearningStyle().contains("no tutoring sessions"))
        skill.recordFeedback(concept: "recursion", outcome: .understood, course: "CSCI-UA 101")
        skill.recordFeedback(concept: "pointers", outcome: .understood, course: "CSCI-UA 101")
        skill.recordFeedback(concept: "recursion", outcome: .confused, course: "CSCI-UA 101")
        skill.recordFeedback(concept: "recursion", outcome: .understood, course: "CSCI-UA 101")
        skill.recordFeedback(concept: "pointers", outcome: .understood, course: "CSCI-UA 101")
        let summary = skill.myLearningStyle()
        XCTAssertTrue(summary.contains("sessions logged"))
        XCTAssertTrue(skill.learningStyle().isSettled)
    }

    func testSkillTutorCardAppearsWithData() {
        let skill = makeSkill()
        XCTAssertNil(skill.tutorCard())
        skill.recordFeedback(concept: "series", outcome: .confused, course: "MATH-UA 122")
        let card = skill.tutorCard()
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.weakConcepts.first?.name, "series")
        XCTAssertEqual(card?.sessionCount, 1)
    }

    func testSkillDisabledSuppressesWeakConcepts() {
        let skill = makeSkill()
        skill.isEnabled = false
        skill.recordFeedback(concept: "series", outcome: .confused, course: "MATH-UA 122")
        XCTAssertTrue(skill.weakConcepts().isEmpty)
        XCTAssertNil(skill.tutorCard())
    }

    // MARK: - JSON extraction

    func testExtractJSONObjectToleratesProse() {
        let raw = "Here you go:\n```json\n{\"explanation\": \"a\", \"method_used\": \"analogy\"}\n```\nEnjoy!"
        let extracted = PersonalTutorSkill.extractJSONObject(from: raw)
        XCTAssertTrue(extracted.contains("\"explanation\""))
        XCTAssertFalse(extracted.contains("Here you go"))
    }
}
