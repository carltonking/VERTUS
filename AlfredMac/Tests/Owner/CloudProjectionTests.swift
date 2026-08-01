import Foundation
import XCTest
@testable import Alfred

/// The cloud projection is the one place local data could escape the Mac, so these tests are
/// deliberately adversarial: they populate every field that exists and then prove the excluded ones
/// are absent from the serialized output (OCS §9).
final class CloudProjectionTests: XCTestCase {

    private func projectionJSON(_ config: OwnerConfig) throws -> String {
        let projection = try CloudProjection.generate(from: config)
        return try XCTUnwrap(String(data: try projection.encoded(), encoding: .utf8))
    }

    // MARK: 20–22. Nothing local reaches the cloud

    func testProjectionContainsNoLocalSentinelsAtAll() throws {
        let json = try projectionJSON(OwnerConfigFixtures.maximallyPopulated())
        for sentinel in OwnerConfigFixtures.localOnlySentinels {
            XCTAssertFalse(json.contains(sentinel), "\(sentinel) leaked into the projection.")
        }
    }

    func testProjectionContainsNoFilesystemRoots() throws {
        let json = try projectionJSON(OwnerConfigFixtures.maximallyPopulated())
        XCTAssertFalse(json.contains("projectRoots"))
        XCTAssertFalse(json.contains("artworkArchive"))
        XCTAssertFalse(json.contains("restricted"))
        XCTAssertFalse(json.contains("localModelOnly"))
        XCTAssertFalse(json.contains("/tmp/"), "No path-shaped value may appear.")
    }

    func testProjectionContainsNoWritingExemplars() throws {
        let config = OwnerConfigFixtures.maximallyPopulated()
        let json = try projectionJSON(config)
        XCTAssertFalse(json.contains("exemplars"))
        XCTAssertFalse(json.contains("EXEMPLAR_SENTINEL_should_never_reach_cloud"))
    }

    func testProjectionContainsNoComputerControlOrShellConfiguration() throws {
        let json = try projectionJSON(OwnerConfigFixtures.maximallyPopulated())
        XCTAssertFalse(json.contains("computerControl"))
        XCTAssertFalse(json.contains("shellExecution"))
        XCTAssertFalse(json.contains("screenCapture"))
        XCTAssertFalse(json.contains("perApplication"))
        XCTAssertFalse(json.contains("com.adobe.illustrator"))
    }

    func testProjectionContainsNoLocalAutomationOrTeamNotes() throws {
        let json = try projectionJSON(OwnerConfigFixtures.maximallyPopulated())
        XCTAssertFalse(json.contains("rhino"))
        XCTAssertFalse(json.contains("illustrator"))
        XCTAssertFalse(json.contains("\"team\""))
        XCTAssertFalse(json.contains("contact-1"))
        XCTAssertFalse(json.contains("authority"))
        XCTAssertFalse(json.contains("governance"))
    }

    func testProjectionCarriesSecretReferencesButNeverValues() throws {
        let projection = try CloudProjection.generate(from: OwnerConfigFixtures.maximallyPopulated())

        XCTAssertEqual(projection.secrets.cloudBotToken, .environment(name: "CLOUD_BOT_TOKEN"))
        XCTAssertEqual(projection.secrets.cloudOwnerId, .environment(name: "OWNER_CHAT_ID"))

        // Mac-only secret references stay behind.
        let json = try projectionJSON(OwnerConfigFixtures.maximallyPopulated())
        XCTAssertFalse(json.contains("telegramBotToken"))
        XCTAssertFalse(json.contains("mailPrimary"))
    }

    // MARK: 23. Required fields are present

    func testProjectionIncludesSignOffNameAndTimeZone() throws {
        var config = OwnerConfigFixtures.maximallyPopulated()
        config.identity.signOffName = "Sign Off Name"
        config.identity.timeZone = "Europe/London"
        config.identity.timeZoneConfirmed = true

        let projection = try CloudProjection.generate(from: config)

        XCTAssertEqual(projection.identity.signOffName, "Sign Off Name")
        XCTAssertEqual(projection.identity.timeZone, "Europe/London")
        XCTAssertEqual(projection.identity.pronouns.subject, "she")
        XCTAssertEqual(projection.professional.summaryLine, "Leads packaging design and production.")
        XCTAssertEqual(projection.briefing.sendLocalTime, "07:00")
        XCTAssertEqual(projection.vocabulary.terms["dieline"], "Cutter guide")
    }

    func testProjectionCarriesEnvelopeForDriftDetection() throws {
        let config = OwnerConfigFixtures.maximallyPopulated()
        let projection = try CloudProjection.generate(from: config)

        XCTAssertEqual(projection.configId, config.configId)
        XCTAssertEqual(projection.revision, config.revision)
        XCTAssertEqual(projection.schemaVersion, config.schemaVersion)
    }

    // MARK: 24. Non-cloud-eligible registers are excluded

    func testNonCloudEligibleRegisterIsExcluded() throws {
        let projection = try CloudProjection.generate(from: OwnerConfigFixtures.maximallyPopulated())

        XCTAssertNil(projection.communication.registers["personal"],
                     "The personal register is not cloud-eligible by default.")
        XCTAssertNotNil(projection.communication.registers["client"])

        let json = try projectionJSON(OwnerConfigFixtures.maximallyPopulated())
        XCTAssertFalse(json.contains("PERSONAL_SENTINEL_should_never_reach_cloud"))
    }

    func testOnlySignaturesReferencedByCloudRegistersAreProjected() throws {
        let projection = try CloudProjection.generate(from: OwnerConfigFixtures.maximallyPopulated())
        let ids = projection.identity.signatures.map(\.id)

        XCTAssertEqual(ids, ["work"], "Only the signature an eligible register uses may travel.")
        XCTAssertFalse(ids.contains("private"))
    }

    func testOnlyCloudCapableActionsAppearInProjectedApprovals() throws {
        let projection = try CloudProjection.generate(from: OwnerConfigFixtures.maximallyPopulated())

        XCTAssertNotNil(projection.approvals.policies["sendEmail"])
        XCTAssertNil(projection.approvals.policies["runShellCommand"],
                     "Mac-only actions have no cloud meaning and must not be projected.")
        XCTAssertNil(projection.approvals.policies["useComputerControl"])
        XCTAssertNil(projection.approvals.policies["modifySourceArtwork"])
    }

    func testProjectedApprovalsPreserveExplicitDenies() throws {
        var config = OwnerConfigFixtures.maximallyPopulated()
        config.approvals.neverAllowed = [.sendEmail, .runShellCommand]

        let projection = try CloudProjection.generate(from: config)

        XCTAssertEqual(projection.approvals.policies["sendEmail"], .never)
        XCTAssertEqual(projection.approvals.neverAllowed, ["sendEmail"],
                       "Only cloud-capable denies are listed; the rest are irrelevant there.")
    }

    // MARK: 25. An unclassified field fails generation

    /// A GENUINELY new schema field — one this build does not model at all — must still fail closed.
    /// Expressed through the path-level seam, because adding a property to `OwnerConfig` is a
    /// compile-time act that no test can perform at runtime. (Unknown TOP-LEVEL keys are a separate,
    /// deliberately permitted case; see the H5 tests.)
    func testUnclassifiedFieldCausesGenerationToFail() {
        let paths = ["identity.fullName", "identity.homeAddress"]

        XCTAssertThrowsError(try CloudProjection.assertEveryPathClassified(paths, unknownRoots: [])) { error in
            guard case let CloudProjection.GenerationError.unclassifiedField(path) = error else {
                return XCTFail("Expected .unclassifiedField, got \(error)")
            }
            XCTAssertEqual(path, "identity.homeAddress")
        }
    }

    func testNewFieldsInFixedStructsAreUnclassifiedByDefault() {
        for path in ["identity.homeAddress", "secrets.newSlot", "professional.salary",
                     "features.newToggle.enabled", "somethingBrandNew"] {
            XCTAssertNil(CloudProjection.FieldRegistry.disposition(for: path),
                         "\(path) must require an explicit decision.")
        }
    }

    func testEveryFieldOfEveryFixtureIsClassified() throws {
        for (label, config) in [
            ("blank", OwnerConfigDefaults.blank),
            ("minimal", OwnerConfigFixtures.minimalValid()),
            ("migrationSeeded", OwnerConfigFixtures.migrationSeeded()),
            ("maximal", OwnerConfigFixtures.maximallyPopulated()),
            ("cloudSecretsOnly", OwnerConfigFixtures.withCloudSecretsOnly()),
            ("keychainSecretsOnly", OwnerConfigFixtures.withKeychainSecretsOnly()),
            ("mixedSecrets", OwnerConfigFixtures.withMixedSecrets()),
        ] {
            XCTAssertNoThrow(try CloudProjection.assertEveryFieldClassified(in: config),
                             "\(label) contains an unclassified field.")
        }
    }

    // MARK: C1 — empty containers

    /// C1 regression. An all-`nil` `secrets` encodes as `{}` and appears as the LEAF path `secrets`,
    /// which the registry previously did not classify — breaking every default configuration.
    func testC1_emptySecretsContainerIsExplicitlyClassified() throws {
        let config = OwnerConfigFixtures.minimalValid()
        XCTAssertTrue(config.secrets.all.isEmpty)

        XCTAssertEqual(CloudProjection.FieldRegistry.disposition(for: "secrets"), .exclude,
                       "The container itself needs its own decision, not just its children.")
        XCTAssertNoThrow(try CloudProjection.generate(from: config))
    }

    /// Every empty container across every domain must resolve — not just `secrets`.
    func testC1_everyEmptyContainerInABlankConfigResolves() throws {
        let tree = try JSONValue.from(OwnerConfigDefaults.blank)
        var emptyContainers: [String] = []
        for path in tree.leafPaths() {
            switch tree.value(at: path) {
            case .object(let o) where o.isEmpty: emptyContainers.append(path)
            case .array(let a) where a.isEmpty: emptyContainers.append(path)
            default: break
            }
        }

        XCTAssertGreaterThan(emptyContainers.count, 20, "Blank config should be mostly empty.")
        for path in emptyContainers {
            XCTAssertNotNil(CloudProjection.FieldRegistry.disposition(for: path),
                            "Empty container \(path) has no projection decision.")
        }
    }

    // MARK: C1 — secret-reference combinations

    func testC1_cloudOnlySecretsAreProjected() throws {
        let projection = try CloudProjection.generate(from: OwnerConfigFixtures.withCloudSecretsOnly())

        XCTAssertEqual(projection.secrets.cloudBotToken, .environment(name: "CLOUD_BOT_TOKEN"))
        XCTAssertEqual(projection.secrets.cloudOwnerId, .environment(name: "OWNER_CHAT_ID"))
    }

    func testC1_keychainOnlySecretsProduceAnEmptyProjectedSecretsBlock() throws {
        let config = OwnerConfigFixtures.withKeychainSecretsOnly()
        let projection = try CloudProjection.generate(from: config)
        let json = try XCTUnwrap(String(data: try projection.encoded(), encoding: .utf8))

        XCTAssertNil(projection.secrets.cloudBotToken)
        XCTAssertNil(projection.secrets.cloudOwnerId)
        XCTAssertFalse(json.contains("keychainRef"), "No Keychain reference may travel.")
        XCTAssertFalse(json.contains("telegramBotToken"))
        XCTAssertFalse(json.contains("mailPrimary"))
    }

    func testC1_mixedSecretsProjectOnlyTheCloudOnes() throws {
        let projection = try CloudProjection.generate(from: OwnerConfigFixtures.withMixedSecrets())
        let json = try XCTUnwrap(String(data: try projection.encoded(), encoding: .utf8))

        XCTAssertEqual(projection.secrets.cloudBotToken, .environment(name: "CLOUD_BOT_TOKEN"))
        XCTAssertFalse(json.contains("keychainRef"))
        XCTAssertFalse(json.contains("telegramBotToken"))
        XCTAssertFalse(json.contains("calendarPrimary"))
    }

    // MARK: Registry resolution

    func testRegistryResolutionPrefersTheLongestAndMostSpecificEntry() {
        let r = CloudProjection.FieldRegistry.self

        // Exact entries beat a broader subtree.
        XCTAssertEqual(r.disposition(for: "communication.voice.mode"), .include)
        XCTAssertEqual(r.disposition(for: "communication.voice.exemplars"), .exclude)

        // Container excluded, specific children included.
        XCTAssertEqual(r.disposition(for: "secrets"), .exclude)
        XCTAssertEqual(r.disposition(for: "secrets.cloudBotToken"), .include)
        XCTAssertEqual(r.disposition(for: "secrets.cloudBotToken.environmentRef"), .include)
        XCTAssertEqual(r.disposition(for: "secrets.telegramBotToken.keychainRef"), .exclude)

        // Blanket-excluded domains cover arbitrary depth.
        XCTAssertEqual(r.disposition(for: "roots.projectRoots"), .exclude)
        XCTAssertEqual(r.disposition(for: "roots.anything.nested.deeply"), .exclude)
        XCTAssertEqual(r.disposition(for: "governance.retention.memories"), .exclude)

        // Dynamic-key maps are include-subtree by explicit decision.
        XCTAssertEqual(r.disposition(for: "vocabulary.terms.anyOwnerKey"), .include)
        XCTAssertEqual(r.disposition(for: "approvals.policies.sendEmail"), .include)
        XCTAssertEqual(r.disposition(for: "providers.models.groq"), .include)

        XCTAssertNil(r.disposition(for: "somethingBrandNew"))
    }

    /// `includeSubtree` is the only kind that can leak a not-yet-existing field, so its use is
    /// restricted to dynamic-key containers. This pins that list so a future edit is deliberate.
    func testIncludeSubtreeIsLimitedToDynamicKeyContainers() {
        XCTAssertEqual(Set(CloudProjection.FieldRegistry.includeSubtree), Set([
            "approvals.policies",
            "communication.registers",
            "vocabulary.terms",
            "providers.models",
            "secrets.cloudBotToken",
            "secrets.cloudOwnerId",
        ]))
    }

    func testRegistryNeverMarksRootsForTheCloud() {
        XCTAssertFalse(CloudProjection.registryIncludesAnyRootPath)
    }
}
