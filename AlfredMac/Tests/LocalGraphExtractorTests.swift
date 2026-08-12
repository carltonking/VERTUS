import XCTest
@testable import Alfred

/// Covers the pure, deterministic parts of the local graph extractor: the
/// tolerant key-value parser and the entity→edge builder. Nothing here touches
/// Ollama, the network, or the memory server — the model output is fed in
/// directly as a string.
final class LocalGraphExtractorTests: XCTestCase {

    // MARK: - Parsing

    func testCleanLinePerFactOutput() {
        let facts = LocalGraphExtractor.parse("""
        person: Carlton
        organization: Acme Corp
        communication_preference: email
        """)
        XCTAssertEqual(facts.entities.count, 3)
        XCTAssertEqual(facts.entities[0], GraphEntity(name: "Carlton", kind: .person, detail: nil))
        XCTAssertEqual(facts.entities[1], GraphEntity(name: "Acme Corp", kind: .organization, detail: nil))
        XCTAssertEqual(facts.entities[2], GraphEntity(name: "email", kind: .communicationPreference, detail: nil))
    }

    func testCommaSeparatedPairsOnOneLine() {
        let facts = LocalGraphExtractor.parse("person: Sarah, communication_preference: Slack, organization: Noodle")
        XCTAssertEqual(facts.entities.count, 3)
        XCTAssertTrue(facts.entities.contains(GraphEntity(name: "Sarah", kind: .person, detail: nil)))
        // Preference channels are normalized lowercase.
        XCTAssertTrue(facts.entities.contains(GraphEntity(name: "slack", kind: .communicationPreference, detail: nil)))
        XCTAssertTrue(facts.entities.contains(GraphEntity(name: "Noodle", kind: .organization, detail: nil)))
    }

    func testPluralKeysAndCapitalisation() {
        let facts = LocalGraphExtractor.parse("People: Leslie\nORG: Zeta Labs")
        XCTAssertEqual(facts.entities.count, 2)
        XCTAssertEqual(facts.entities[0].kind, .person)
        XCTAssertEqual(facts.entities[0].name, "Leslie")
        XCTAssertEqual(facts.entities[1].kind, .organization)
        XCTAssertEqual(facts.entities[1].name, "Zeta Labs")
    }

    func testValueWithEmDashQualifierFoldsIntoDetail() {
        let facts = LocalGraphExtractor.parse("person: Carlton — prefers email")
        XCTAssertEqual(facts.entities.count, 1)
        XCTAssertEqual(facts.entities[0].name, "Carlton")
        XCTAssertEqual(facts.entities[0].detail, "prefers email")
    }

    func testValueWithSpaceDashSeparatorKeepsNoStrayHyphen() {
        let facts = LocalGraphExtractor.parse("person: Carlton - works at Acme")
        XCTAssertEqual(facts.entities.count, 1)
        XCTAssertEqual(facts.entities[0].name, "Carlton")
        XCTAssertEqual(facts.entities[0].detail, "works at Acme")
    }

    func testPluralKeysAreAccepted() {
        let facts = LocalGraphExtractor.parse("organizations: Zeta Labs\ncommunication_preferences: slack")
        XCTAssertEqual(facts.entities.count, 2)
        XCTAssertEqual(facts.entities[0].kind, .organization)
        XCTAssertEqual(facts.entities[0].name, "Zeta Labs")
        XCTAssertEqual(facts.entities[1].kind, .communicationPreference)
        XCTAssertEqual(facts.entities[1].name, "slack")
    }

    func testPersonalDoesNotParseAsPerson() {
        // The \s*: guard must keep "personal:" from matching the "person" key.
        XCTAssertTrue(LocalGraphExtractor.parse("personal: John Smith").isEmpty)
    }

    func testExtraProseAroundPairsIsIgnored() {
        let facts = LocalGraphExtractor.parse("""
        Here are the facts I found:
        person: Priya
        organization: Metro Bank
        """)
        XCTAssertEqual(facts.entities.count, 2)
        XCTAssertEqual(facts.entities[0].name, "Priya")
        XCTAssertEqual(facts.entities[1].name, "Metro Bank")
    }

    func testNothingRelevantYieldsEmptySet() {
        XCTAssertTrue(LocalGraphExtractor.parse("What time is my dentist appointment tomorrow?").isEmpty)
        XCTAssertTrue(LocalGraphExtractor.parse("").isEmpty)
    }

    func testJunkValuesAreRejected() {
        // Bare numbers and control-char garbage are not entities.
        let facts = LocalGraphExtractor.parse("person: 12345\norganization: \u{0007}")
        XCTAssertTrue(facts.entities.isEmpty)
    }

    func testPlaceholderValuesAreRejected() {
        // The model writes "None"/"n/a" when a category has nothing in it.
        let facts = LocalGraphExtractor.parse("person: None\norganization: n/a\ncommunication_preference: unknown")
        XCTAssertTrue(facts.entities.isEmpty)
    }

    func testDuplicateEntityMerges() {
        let facts = LocalGraphExtractor.parse("person: Carlton, person: carlton, person: CARLTON")
        XCTAssertEqual(facts.entities.count, 1)
        XCTAssertEqual(facts.entities[0].name, "Carlton")
    }

    // MARK: - Relations

    func testRelationsBetweenPeopleAndOrganizations() {
        let facts = LocalGraphExtractor.parse("""
        person: Carlton
        person: Sarah
        organization: Acme Corp
        communication_preference: email
        """)
        let types = facts.relations.map(\.type)
        XCTAssertTrue(types.contains("knows"))
        XCTAssertTrue(types.contains("affiliated_with"))
        // Two people → the preference is ambiguous; no "prefers" edge.
        XCTAssertFalse(types.contains("prefers"))
    }

    func testPreferenceEdgeRequiresExactlyOnePerson() {
        // Two people → the preference is ambiguous, no "prefers" edge; the
        // preference entity is still kept.
        let two = LocalGraphExtractor.parse("person: Carlton, person: Sarah, communication_preference: email")
        XCTAssertFalse(two.relations.contains { $0.type == "prefers" })
        XCTAssertTrue(two.entities.contains { $0.kind == .communicationPreference })

        let one = LocalGraphExtractor.parse("person: Carlton, communication_preference: email")
        XCTAssertTrue(one.relations.contains { $0.type == "prefers" })
    }

    func testNoRelationsWithoutPeople() {
        let facts = LocalGraphExtractor.parse("organization: Acme Corp")
        XCTAssertTrue(facts.relations.isEmpty)
        XCTAssertEqual(facts.entities.count, 1)
    }
}
