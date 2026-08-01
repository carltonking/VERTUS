import Foundation
import XCTest
@testable import Alfred

/// Validation layers 1–3 (OCS §3). Assertions are on `code`, never on `message`, so wording can
/// change without breaking the suite.
final class OwnerConfigValidationTests: XCTestCase {

    private let validator = OwnerConfigValidator()

    private func codes(_ v: OwnerConfigValidation) -> Set<OwnerConfigIssue.Code> {
        Set(v.issues.map(\.code))
    }

    // MARK: 1. Default configuration validates

    func testMinimalValidConfigurationPasses() {
        let result = validator.validate(OwnerConfigFixtures.minimalValid())
        XCTAssertTrue(result.isValid, "Expected valid, got: \(result.errors)")
        XCTAssertTrue(result.disabledFeatures.isEmpty)
    }

    func testMaximallyPopulatedConfigurationPasses() {
        let result = validator.validate(OwnerConfigFixtures.maximallyPopulated())
        XCTAssertTrue(result.isValid, "Expected valid, got: \(result.errors)")
    }

    /// The blank default is deliberately INVALID — that is how onboarding knows it isn't finished.
    func testBlankConfigurationFailsOnIdentityOnly() {
        let result = validator.validate(OwnerConfigDefaults.blank)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.allSatisfy { $0.code == .missingRequired },
                      "Blank config should fail only on missing required fields.")
    }

    // MARK: 2. Missing required identity field produces a named error

    func testMissingSignOffNameIsNamedAndDisablesDraftingOnly() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.signOffName = nil

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        let issue = result.errors.first { $0.path == "identity.signOffName" }
        XCTAssertNotNil(issue, "Error must name the exact field path.")
        XCTAssertEqual(issue?.code, .missingRequired)
        XCTAssertEqual(issue?.disablesFeature, .emailDrafting)
        // General chat must survive a missing sign-off (OCS §12: fail closed per feature).
        XCTAssertTrue(result.isDisabled(.emailDrafting))
        XCTAssertFalse(result.isDisabled(.ownerProfileBlock))
    }

    /// Validation reports EVERY problem in one pass, not just the first.
    func testValidationReturnsAllErrorsAtOnce() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.fullName = nil
        config.identity.preferredName = nil
        config.identity.signOffName = nil
        config.identity.timeZone = "Not/AZone"

        let result = validator.validate(config)
        let paths = Set(result.errors.map(\.path))

        XCTAssertTrue(paths.contains("identity.fullName"))
        XCTAssertTrue(paths.contains("identity.preferredName"))
        XCTAssertTrue(paths.contains("identity.signOffName"))
        XCTAssertTrue(paths.contains("identity.timeZone"))
        XCTAssertGreaterThanOrEqual(result.errors.count, 4)
    }

    /// A migration-seeded configuration must be valid — the C2 condition, asserted at the validator
    /// level so a regression is caught without going through the store.
    func testC2_migrationSeededConfigurationIsValid() {
        let result = validator.validate(OwnerConfigFixtures.migrationSeeded())

        XCTAssertTrue(result.isValid, "Seeded config must be savable, got: \(result.errors)")
        XCTAssertFalse(result.isDisabled(.emailDrafting),
                       "Sign-off is seeded, so drafting is not blocked.")
        XCTAssertFalse(result.isDisabled(.ownerProfileBlock))
        // It should still be warning about what it only guessed.
        XCTAssertTrue(result.warnings.contains { $0.path == "identity.timeZone" })
    }

    /// H5: an unknown top-level key is a warning, never an error.
    func testH5_unknownFieldsWarnButDoNotInvalidate() {
        let result = validator.validate(OwnerConfigFixtures.withUnknownTopLevelField())

        XCTAssertTrue(result.isValid)
        let warning = result.warnings.first { $0.code == .unknownFieldsPreserved }
        XCTAssertNotNil(warning, "The owner must be told about fields this version doesn't model.")
        XCTAssertTrue(warning?.message.contains("futureDomain") == true)
        XCTAssertNil(warning?.disablesFeature, "It must not disable anything.")
    }

    // MARK: 3. Unknown schema major version is rejected

    func testUnsupportedSchemaVersionIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.schemaVersion = OwnerConfigDefaults.schemaVersion + 1

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(codes(result).contains(.unsupportedSchemaVersion))
        XCTAssertTrue(result.isDisabled(.allOwnerConfig),
                      "An unknown schema must disable the whole subsystem, not degrade silently.")
    }

    // MARK: 4. Invalid time zone is rejected

    func testInvalidTimeZoneIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.timeZone = "Mars/Olympus_Mons"

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errors.first { $0.path == "identity.timeZone" }?.code, .invalidTimeZone)
    }

    func testUnconfirmedTimeZoneWarnsButRemainsValid() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.timeZoneConfirmed = false

        let result = validator.validate(config)

        XCTAssertTrue(result.isValid, "An unconfirmed zone is a warning, not a blocker.")
        XCTAssertTrue(result.warnings.contains { $0.path == "identity.timeZone" })
    }

    // MARK: 5. Invalid secret reference is rejected

    func testDisallowedKeychainServiceIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.secrets.telegramBotToken = .keychain(service: "com.someone.else", account: "token")

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(codes(result).contains(.disallowedKeychainService))
    }

    func testMalformedEnvironmentNameIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.secrets.cloudBotToken = .environment(name: "lower case name")

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(codes(result).contains(.invalidEnvironmentName))
    }

    func testWellFormedSecretReferencesPass() {
        var config = OwnerConfigFixtures.minimalValid()
        config.secrets.cloudBotToken = .environment(name: "CLOUD_BOT_TOKEN")
        config.secrets.telegramBotToken = .keychain(service: "com.alfred.app", account: "telegram")
        config.secrets.mailPrimary = .secretId("mail-primary")

        XCTAssertTrue(validator.validate(config).isValid)
    }

    // MARK: 6. Direct secret-looking values in prohibited fields are rejected

    func testCredentialShapedValueAnywhereInConfigIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        // Pasted into an ordinary text field, not a secret slot.
        config.communication.global.rules = ["sk-ant-abcdefghijklmnopqrstuvwxyz012345"]

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(codes(result).contains(.secretValueInConfig))
        XCTAssertTrue(result.isDisabled(.allOwnerConfig))
    }

    func testCredentialScannerIgnoresOrdinaryProse() {
        var config = OwnerConfigFixtures.minimalValid()
        config.communication.global.rules = ["Mention the API key rotation policy when asked."]
        config.professional.summaryLine = "Leads packaging design and production."

        XCTAssertTrue(validator.validate(config).isValid)
    }

    func testSecretShapeScannerRecognizesCommonFormats() {
        XCTAssertTrue(SecretShapeScanner.looksLikeSecret("ghp_abcdefghijklmnopqrstuvwxyz01"))
        XCTAssertTrue(SecretShapeScanner.looksLikeSecret("AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123"))
        XCTAssertTrue(SecretShapeScanner.looksLikeSecret("123456789:AAExampleTokenValueThatIsLongEnough"))
        XCTAssertFalse(SecretShapeScanner.looksLikeSecret("packaging design"))
        XCTAssertFalse(SecretShapeScanner.looksLikeSecret("short"))
    }

    // MARK: 7. Approval settings below their code floor are rejected

    func testApprovalBelowFloorIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.approvals.policies[.sendEmail] = .auto      // floor is .confirm

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        let issue = result.errors.first { $0.path == "approvals.policies.sendEmail" }
        XCTAssertEqual(issue?.code, .approvalBelowFloor)
        XCTAssertTrue(result.isDisabled(.allOwnerConfig))
    }

    func testApprovalAboveFloorIsAccepted() {
        var config = OwnerConfigFixtures.minimalValid()
        config.approvals.policies[.sendEmail] = .doubleConfirm

        XCTAssertTrue(validator.validate(config).isValid, "Tightening must always be allowed.")
    }

    func testEveryPresetSatisfiesEveryFloor() {
        for preset in OwnerConfigDefaults.ApprovalPreset.allCases {
            var config = OwnerConfigFixtures.minimalValid()
            config.approvals.policies = preset.policies
            let result = validator.validate(config)
            XCTAssertTrue(result.isValid, "Preset \(preset.rawValue) produced: \(result.errors)")
        }
    }

    func testMissingPolicyFailsClosed() {
        var config = OwnerConfigFixtures.minimalValid()
        config.approvals.policies.removeValue(forKey: .runShellCommand)

        let result = validator.validate(config)

        XCTAssertTrue(result.warnings.contains { $0.code == .unknownApprovalAction })
        XCTAssertEqual(config.approvals.policy(for: .runShellCommand), .never,
                       "An unconfigured action must resolve to never, not to a permissive default.")
    }

    func testExplicitDenyOverridesConfiguredPolicy() {
        var config = OwnerConfigFixtures.minimalValid()
        config.approvals.policies[.sendEmail] = .confirm
        config.approvals.neverAllowed = [.sendEmail]

        XCTAssertEqual(config.approvals.policy(for: .sendEmail), .never)
    }

    // MARK: Policy invariants — roots, classifications, references

    func testConfidentialClassificationCannotBeCloudEligible() {
        var config = OwnerConfigFixtures.minimalValid()
        config.governance.classifications = [
            .init(id: "confidential", label: "Confidential", cloudEligible: true, retentionDays: 90),
        ]

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(codes(result).contains(.confidentialMarkedCloudEligible))
        XCTAssertTrue(result.isDisabled(.cloudProjection))
    }

    func testOverbroadRootPathsAreRejected() {
        for path in ["/", NSHomeDirectory(), "/Users", "/System", "/Volumes", "relative/path", ""] {
            var config = OwnerConfigFixtures.minimalValid()
            config.roots.projectRoots = [.init(path: path)]
            let result = validator.validate(config)
            XCTAssertFalse(result.isValid, "\(path) should be rejected as a scope.")
            XCTAssertTrue(codes(result).contains(.invalidRootPath), "\(path) produced \(codes(result))")
        }
    }

    /// KNOWN GAP, deliberately pinned rather than silently expected to pass.
    ///
    /// `rootPathIssue` calls `NSString.standardizingPath`, which collapses `..` BEFORE the traversal
    /// check runs — so `/tmp/../etc` normalizes to `/etc` and is accepted. The guard is self-
    /// defeating. This is a deferred audit finding (root traversal / symlink containment is out of
    /// scope for the blocker-correction package); the test documents today's behaviour so the fix
    /// is a visible, intentional change rather than a surprise.
    func testKnownGap_pathTraversalIsCurrentlyNotDetected() {
        XCTAssertNil(OwnerConfigValidator.rootPathIssue("/tmp/../etc"),
                     "If this now fails, traversal detection was added — update this test and remove the deferred finding.")
        XCTAssertNil(OwnerConfigValidator.rootPathIssue("/tmp/a/../../etc/passwd"))
        // The specific-path case must keep working either way.
        XCTAssertNil(OwnerConfigValidator.rootPathIssue("/tmp/alfred-projects"))
    }

    func testSpecificRootPathIsAccepted() {
        var config = OwnerConfigFixtures.minimalValid()
        config.roots.projectRoots = [.init(path: "/tmp/alfred-test-projects")]
        XCTAssertTrue(validator.validate(config).isValid)
    }

    func testRestrictedRootCannotBeWritable() {
        var config = OwnerConfigFixtures.minimalValid()
        config.roots.restricted = [.init(path: "/tmp/alfred-restricted", writable: true)]

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(codes(result).contains(.restrictedRootWritable))
    }

    func testDanglingSignatureReferenceIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.communication.registers[.client] = .init(signatureId: "does-not-exist")

        let result = validator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(codes(result).contains(.danglingReference))
    }

    func testUnknownClassificationOnRootIsRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.roots.projectRoots = [.init(path: "/tmp/alfred-x", classification: "made-up")]

        XCTAssertTrue(codes(validator.validate(config)).contains(.danglingReference))
    }

    func testDuplicateSignatureIdsAreRejected() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.signatures = [.init(id: "a", label: nil, body: "one"),
                                      .init(id: "a", label: nil, body: "two")]

        XCTAssertTrue(codes(validator.validate(config)).contains(.duplicateIdentifier))
    }

    // MARK: Legacy owner name retention

    func testLegacyOwnerNameOutsideSeededFieldsIsAnError() {
        let legacyValidator = OwnerConfigValidator(legacyOwnerName: "Previous Owner")
        var config = OwnerConfigFixtures.minimalValid()
        config.updatedBy = .user
        config.professional.summaryLine = "Assistant for Previous Owner."

        let result = legacyValidator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(Set(result.issues.map(\.code)).contains(.legacyOwnerNameRetained))
    }

    /// The exemption is driven by PROVENANCE, not by `updatedBy`. `updatedBy` describes the last
    /// write; it says nothing about where a particular value came from, and a later user edit to an
    /// unrelated field would otherwise revoke the exemption and invalidate the configuration.
    func testLegacyOwnerNameInSeededIdentityFieldsIsAWarningWhenProvenanceCoversThem() {
        let legacyValidator = OwnerConfigValidator(legacyOwnerName: "Previous Owner")
        let config = OwnerConfigFixtures.migrationSeededWithProvenance(name: "Previous Owner")

        let result = legacyValidator.validate(config)

        XCTAssertTrue(result.isValid, "Migration seeding must not block startup: \(result.errors)")
        XCTAssertEqual(
            Set(result.warnings.filter { $0.code == .migrationValueAwaitingConfirmation }.map(\.path)),
            OwnerConfigDefaults.allowedMigrationSeedPaths)
        XCTAssertFalse(result.issues.contains { $0.code == .legacyOwnerNameRetained })
    }

    /// Without provenance the same values are illegal retention — `updatedBy` alone grants nothing.
    func testUpdatedByMigrationAloneGrantsNoExemption() {
        let legacyValidator = OwnerConfigValidator(legacyOwnerName: "Previous Owner")
        var config = OwnerConfigFixtures.minimalValid(name: "Previous Owner")
        config.updatedBy = .migration
        config.migrationSeeded = nil

        let result = legacyValidator.validate(config)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.code == .legacyOwnerNameRetained })
    }

    /// Once the owner edits a seeded field, the value no longer matches and no exemption applies —
    /// and none is needed, because the previous owner's name is gone.
    func testEditingASeededFieldClearsTheWarningWithoutBecomingAnError() {
        let legacyValidator = OwnerConfigValidator(legacyOwnerName: "Previous Owner")
        var config = OwnerConfigFixtures.migrationSeededWithProvenance(name: "Previous Owner")
        config.identity.signOffName = "New Person"

        let result = legacyValidator.validate(config)

        XCTAssertTrue(result.isValid)
        XCTAssertFalse(result.issues.contains { $0.path == "identity.signOffName" })
    }

    // MARK: Field limits

    func testPronounLengthAndPresenceAreEnforced() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.pronouns = .init(subject: "", object: "them", possessive: "their")
        XCTAssertTrue(codes(validator.validate(config)).contains(.missingRequired))

        config.identity.pronouns = .init(subject: String(repeating: "x", count: 21),
                                         object: "them", possessive: "their")
        XCTAssertTrue(codes(validator.validate(config)).contains(.tooLong))
    }

    func testRegisterNumericRangesAreEnforced() {
        var config = OwnerConfigFixtures.minimalValid()
        config.communication.registers[.executive] = .init(formality: 9, directness: 0)

        XCTAssertTrue(codes(validator.validate(config)).contains(.invalidRange))
    }

    func testWorkingHoursMustBeOrderedAndWellFormed() {
        var config = OwnerConfigFixtures.minimalValid()
        config.identity.workingHours = [.init(day: .monday, start: "17:00", end: "09:00")]
        XCTAssertTrue(codes(validator.validate(config)).contains(.invalidRange))

        config.identity.workingHours = [.init(day: .monday, start: "9am", end: "5pm")]
        XCTAssertTrue(codes(validator.validate(config)).contains(.invalidFormat))
    }

    func testVocabularyNamespaceMustBeASlug() {
        var config = OwnerConfigFixtures.minimalValid()
        config.vocabulary.namespace = "Not A Slug"
        XCTAssertTrue(codes(validator.validate(config)).contains(.invalidNamespace))
    }

    // MARK: Prompt-eligibility invariant

    func testNoSecretPathIsPromptEligible() {
        for (path, _) in OwnerConfigFixtures.maximallyPopulated().secrets.all {
            XCTAssertFalse(PromptFieldPolicy.isPromptEligible(path),
                           "\(path) must never be prompt-eligible.")
        }
        for path in ["secrets", "roots", "approvals", "governance", "systems.email"] {
            XCTAssertFalse(PromptFieldPolicy.isPromptEligible(path))
        }
    }

    func testIdentityFieldsArePromptEligible() {
        XCTAssertTrue(PromptFieldPolicy.isPromptEligible("identity.preferredName"))
        XCTAssertTrue(PromptFieldPolicy.isPromptEligible("identity.pronouns.subject"))
        XCTAssertTrue(PromptFieldPolicy.isPromptEligible("professional.summaryLine"))
    }
}
