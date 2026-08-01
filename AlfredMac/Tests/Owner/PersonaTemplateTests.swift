import Foundation
import XCTest
@testable import Alfred

/// Persona rendering, prompt-slot ordering, and secret redaction (OCS §10, §7).
final class PersonaTemplateTests: XCTestCase {

    private let now = "Monday, July 27, 2026 at 09:00 EDT"

    private func snapshot(_ config: OwnerConfig) -> OwnerConfigSnapshot {
        OwnerConfigSnapshot(config: config, validation: OwnerConfigValidator().validate(config))
    }

    // MARK: 15. Persona contains the configured owner name

    func testPersonaRendersTheConfiguredName() {
        var config = OwnerConfigFixtures.minimalValid(name: "Configured Owner")
        config.identity.preferredName = "Configured Owner"
        config.identity.roleTitle = "Design Director"
        config.identity.organization = "Example Studio"

        let rendered = PersonaTemplate.render(snapshot: snapshot(config), currentDate: now)

        XCTAssertTrue(rendered.contains("Configured Owner"))
        XCTAssertTrue(rendered.contains("Design Director"))
        XCTAssertTrue(rendered.contains("Example Studio"))
    }

    func testPersonaRendersConfiguredPronouns() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.pronouns = .init(subject: "she", object: "her", possessive: "her")

        let rendered = PersonaTemplate.render(snapshot: snapshot(config), currentDate: now)

        XCTAssertTrue(rendered.contains("she/her/her"))
    }

    func testPersonaDefaultsToNeutralPronounsWhenUnset() {
        let rendered = PersonaTemplate.render(snapshot: snapshot(OwnerConfigFixtures.minimalValid()),
                                              currentDate: now)
        XCTAssertTrue(rendered.contains("they/them/their"),
                      "Pronouns must never be inferred from a name.")
    }

    // MARK: 16. No owner literal in source

    func testInvariantInstructionsContainNoOwnerIdentity() {
        let invariant = PersonaTemplate.invariantInstructions(currentDate: now)

        // The invariant half is owner-agnostic: no name, no pronoun assertion, no voice preference
        // presented as something the owner asked for.
        XCTAssertFalse(invariant.contains("they've asked for this specifically"))
        XCTAssertFalse(invariant.lowercased().contains("24-hour"),
                       "Time format is configuration, not an invariant.")
        XCTAssertFalse(invariant.contains("No bullet-point lists"),
                       "Bullet usage is configuration, not an invariant.")
    }

    func testInvariantInstructionsRetainSafetyRules() {
        let invariant = PersonaTemplate.invariantInstructions(currentDate: now)

        XCTAssertTrue(invariant.contains("NEVER invent or guess status"))
        XCTAssertTrue(invariant.contains("irreversible or outward-facing"))
        XCTAssertTrue(invariant.contains("never return an empty message"))
        XCTAssertTrue(invariant.contains("ask ONE"))
    }

    // MARK: 18. Missing optional values produce no placeholder text

    func testUnsetOptionalFieldsProduceNoPlaceholders() {
        let rendered = PersonaTemplate.render(snapshot: snapshot(OwnerConfigFixtures.minimalValid()),
                                              currentDate: now)

        for placeholder in ["REQUIRES_USER_INPUT", "NOT_CONFIGURED", "DISABLED_BY_DEFAULT",
                            "nil", "Optional(", "null"] {
            XCTAssertFalse(rendered.contains(placeholder),
                           "\(placeholder) must never appear in a prompt.")
        }
    }

    func testEmptyConfigurationRendersInvariantOnly() {
        var config = OwnerConfigDefaults.blank
        config.identity.fullName = nil
        config.identity.preferredName = nil

        let block = PersonaTemplate.ownerBlock(snapshot(config))

        XCTAssertTrue(block.isEmpty, "With nothing configured there should be no owner block at all.")
    }

    func testInvalidConfigurationFallsBackToInvariantOnly() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.fullName = nil          // disables .ownerProfileBlock

        let rendered = PersonaTemplate.render(snapshot: snapshot(config), currentDate: now)

        XCTAssertEqual(rendered, PersonaTemplate.invariantInstructions(currentDate: now))
    }

    func testNilSnapshotRendersInvariantOnly() {
        let rendered = PersonaTemplate.render(snapshot: nil, currentDate: now)
        XCTAssertEqual(rendered, PersonaTemplate.invariantInstructions(currentDate: now))
    }

    // MARK: Voice preferences come from configuration

    func testVoicePreferencesRenderFromTheDefaultRegister() {
        var config = OwnerConfigFixtures.minimalValid()
        config.communication.global.defaultRegister = .internalPeer
        config.communication.registers[.internalPeer] = .init(
            tone: "plain and direct", formality: 2, typicalLength: .short,
            directness: 5, useBullets: .never, technicalDetail: .deep)

        let rendered = PersonaTemplate.render(snapshot: snapshot(config), currentDate: now)

        XCTAssertTrue(rendered.contains("plain and direct"))
        XCTAssertTrue(rendered.contains("Default to short answers"))
        XCTAssertTrue(rendered.contains("Do not use bullet-point lists"))
        XCTAssertTrue(rendered.contains("Be direct"))
        XCTAssertTrue(rendered.contains("Deep technical detail"))
        XCTAssertTrue(rendered.contains("casual"))
    }

    func testGlobalRulesAndTimeFormatRender() {
        var config = OwnerConfigFixtures.minimalValid()
        config.communication.global.rules = ["Always cite the source file."]
        config.identity.timeFormat = .h12

        let rendered = PersonaTemplate.render(snapshot: snapshot(config), currentDate: now)

        XCTAssertTrue(rendered.contains("Always cite the source file."))
        XCTAssertTrue(rendered.contains("12-hour"))
    }

    func testOwnerBlockDeclaresItselfAuthoritative() {
        let rendered = PersonaTemplate.ownerBlock(snapshot(OwnerConfigFixtures.minimalValid()))
        XCTAssertTrue(rendered.contains("authoritative"),
                      "The block must tell the model it outranks learned context.")
    }

    // MARK: 17. Slot ordering — authored block above learned context

    func testOwnerBlockAppearsAfterInvariantAndBeforeAnyLearnedBlock() {
        var config = OwnerConfigFixtures.minimalValid(name: "Ordering Owner")
        config.professional.summaryLine = "OWNER_SUMMARY_MARKER"

        let persona = PersonaTemplate.render(snapshot: snapshot(config), currentDate: now)

        // Reproduces the assembly order of AssistantCore.buildSystem: persona first, then the
        // learned blocks appended after it.
        let assembled = [
            persona,
            "WHAT ALFRED KNOWS ABOUT THE USER (private profile) — PROFILE_DIGEST_MARKER",
            "HOW THE OWNER WANTS YOU TO RESPOND — LEARNED_STYLE_MARKER",
            "RELEVANT MEMORIES:\nMEMORY_MARKER",
            "RECENT CONVERSATION:\nHISTORY_MARKER",
        ].joined(separator: "\n\n")

        let invariantIndex = try? XCTUnwrap(assembled.range(of: "GROUND RULES")?.lowerBound)
        let ownerIndex = try? XCTUnwrap(assembled.range(of: "OWNER_SUMMARY_MARKER")?.lowerBound)
        let digestIndex = try? XCTUnwrap(assembled.range(of: "PROFILE_DIGEST_MARKER")?.lowerBound)
        let styleIndex = try? XCTUnwrap(assembled.range(of: "LEARNED_STYLE_MARKER")?.lowerBound)
        let memoryIndex = try? XCTUnwrap(assembled.range(of: "MEMORY_MARKER")?.lowerBound)
        let historyIndex = try? XCTUnwrap(assembled.range(of: "HISTORY_MARKER")?.lowerBound)

        guard let invariantIndex, let ownerIndex, let digestIndex,
              let styleIndex, let memoryIndex, let historyIndex else {
            return XCTFail("Missing a marker in the assembled prompt.")
        }

        XCTAssertLessThan(invariantIndex, ownerIndex, "Invariant instructions come first.")
        XCTAssertLessThan(ownerIndex, digestIndex, "Authored owner block outranks the profile digest.")
        XCTAssertLessThan(ownerIndex, styleIndex, "Authored owner block outranks learned style rules.")
        XCTAssertLessThan(ownerIndex, memoryIndex, "Authored owner block outranks memories.")
        XCTAssertLessThan(ownerIndex, historyIndex, "Authored owner block outranks conversation history.")
    }

    // MARK: Audit label

    func testAuditLabelIdentifiesRevisionWithoutContent() {
        let snap = snapshot(OwnerConfigFixtures.minimalValid(name: "Audited Owner"))
        let label = PersonaTemplate.auditLabel(snapshot: snap)

        XCTAssertTrue(label.contains("@\(snap.revision)"))
        XCTAssertTrue(label.contains("template:v\(PersonaTemplate.templateVersion)"))
        XCTAssertFalse(label.contains("Audited Owner"), "An audit label must not carry content.")
    }

    func testAuditLabelHandlesNoConfiguration() {
        XCTAssertTrue(PersonaTemplate.auditLabel(snapshot: nil).contains("ownerConfig:none"))
    }
}
