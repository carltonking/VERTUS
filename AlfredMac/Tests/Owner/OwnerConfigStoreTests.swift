import Foundation
import XCTest
@testable import Alfred

/// Storage, revision lifecycle, history, restore, snapshots, and the one-time identity migration
/// (OCS §4, §5, §6, §11). Every store here is rooted in a temporary directory.
final class OwnerConfigStoreTests: XCTestCase {

    private var store: OwnerConfigStore!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        let made = OwnerConfigFixtures.makeTempStore()
        store = made.store
        directory = made.directory
    }

    override func tearDown() {
        OwnerConfigFixtures.cleanUp(directory)
        store = nil
        directory = nil
        super.tearDown()
    }

    // MARK: 26. Tests never touch the real home directory

    func testStoreIsIsolatedFromRealHomeDirectory() {
        assertIsolatedFromRealHome(store)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: OwnerConfigStore.Paths.standard.directory.appending(path: "test-marker").path))
    }

    func testStandardPathsLiveOutsideDbAndProfile() {
        // Configuration must not sit inside db/ or profile/, so a memory reset can never take it.
        let dir = OwnerConfigStore.Paths.standard.directory.path
        XCTAssertTrue(dir.hasSuffix(".alfred/owner"))
        XCTAssertFalse(dir.contains("/db"))
        XCTAssertFalse(dir.contains("/profile"))
    }

    // MARK: 9. Save increments revision

    func testSaveIncrementsRevisionAndStampsMetadata() throws {
        let first = try store.save(OwnerConfigFixtures.minimalValid(), updatedBy: .onboarding)
        XCTAssertEqual(first.snapshot.revision, 1)
        XCTAssertNil(first.previousRevision)
        XCTAssertEqual(first.snapshot.config.updatedBy, .onboarding)

        let second = try store.save(first.snapshot.config, updatedBy: .user)
        XCTAssertEqual(second.snapshot.revision, 2)
        XCTAssertEqual(second.previousRevision, 1)
        XCTAssertEqual(second.snapshot.configId, first.snapshot.configId,
                       "configId must be stable across revisions.")
    }

    func testCallerCannotRewindTheRevisionCounter() throws {
        _ = try store.save(OwnerConfigFixtures.minimalValid(), updatedBy: .onboarding)
        var tampered = OwnerConfigFixtures.minimalValid()
        tampered.revision = 1                       // pretend it's still the first revision

        let result = try store.save(tampered, updatedBy: .user)

        XCTAssertEqual(result.snapshot.revision, 2, "The store owns the counter, not the caller.")
    }

    // MARK: Validation gating

    func testSavingInvalidConfigurationThrowsForTheStatedReason() {
        var invalid = OwnerConfigFixtures.minimalValid()
        invalid.identity.fullName = nil

        // Assert the SPECIFIC failure. Previously this only checked "something threw", which passed
        // even when the throw came from an unrelated projection defect (C1).
        XCTAssertThrowsError(try store.save(invalid, updatedBy: .user)) { error in
            guard case let OwnerConfigStore.StoreError.validationFailed(validation) = error else {
                return XCTFail("Expected .validationFailed, got \(error)")
            }
            XCTAssertTrue(validation.errors.contains {
                $0.path == "identity.fullName" && $0.code == .missingRequired
            }, "Expected the missing-name error, got \(validation.errors)")
        }
        XCTAssertFalse(store.exists, "Nothing may be written when validation fails.")
        XCTAssertNil(store.currentSnapshot())
    }

    /// C1 regression. A configuration with NO secret references must save. The all-`nil` `secrets`
    /// struct encodes as `{}`, which the projection registry previously left unclassified, making
    /// every default, migrated, and onboarding configuration impossible to write.
    func testC1_configurationWithNoSecretReferencesSaves() throws {
        let config = OwnerConfigFixtures.minimalValid()
        XCTAssertTrue(config.secrets.all.isEmpty, "This fixture must have no secret references.")

        let result = try store.save(config, updatedBy: .onboarding)

        XCTAssertEqual(result.snapshot.revision, 1)
        XCTAssertTrue(store.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.projectionFile.path))
    }

    /// C1 regression at the source: the blank default must be projectable.
    func testC1_blankConfigurationIsFullyClassified() {
        XCTAssertNoThrow(try CloudProjection.assertEveryFieldClassified(in: OwnerConfigDefaults.blank))
    }

    // MARK: 8. Failed save leaves the previous configuration unchanged

    func testFailedSaveLeavesPreviousConfigurationIntact() throws {
        let good = try store.save(OwnerConfigFixtures.minimalValid(name: "First Owner"),
                                  updatedBy: .onboarding)
        let bytesBefore = try Data(contentsOf: store.paths.configFile)

        var invalid = good.snapshot.config
        invalid.identity.signOffName = nil
        invalid.approvals.policies[.sendEmail] = .auto      // below floor as well

        XCTAssertThrowsError(try store.save(invalid, updatedBy: .user))

        let bytesAfter = try Data(contentsOf: store.paths.configFile)
        XCTAssertEqual(bytesBefore, bytesAfter, "The canonical file must be byte-identical.")
        XCTAssertEqual(store.reload()?.revision, 1)
        XCTAssertEqual(store.currentSnapshot()?.config.identity.fullName, "First Owner")
    }

    // MARK: 10. History stores the prior revision

    func testHistoryRetainsPreviousRevisions() throws {
        _ = try store.save(OwnerConfigFixtures.minimalValid(name: "One"), updatedBy: .onboarding)
        var second = OwnerConfigFixtures.minimalValid(name: "Two")
        second.identity.roleTitle = "Director"
        _ = try store.save(second, updatedBy: .user)
        _ = try store.save(OwnerConfigFixtures.minimalValid(name: "Three"), updatedBy: .user)

        XCTAssertEqual(store.historyRevisions(), [2, 1], "Newest first.")
        XCTAssertEqual(try store.configuration(atRevision: 1).identity.fullName, "One")
        XCTAssertEqual(try store.configuration(atRevision: 2).identity.fullName, "Two")
        XCTAssertEqual(store.currentSnapshot()?.config.identity.fullName, "Three")
    }

    func testHistoryIsPrunedToTheConfiguredLimit() throws {
        let made = OwnerConfigFixtures.makeTempStore(historyLimit: 2)
        defer { OwnerConfigFixtures.cleanUp(made.directory) }

        for i in 1...5 {
            _ = try made.store.save(OwnerConfigFixtures.minimalValid(name: "Owner \(i)"),
                                    updatedBy: .user)
        }

        XCTAssertEqual(made.store.historyRevisions().count, 2)
    }

    func testReadingAMissingRevisionThrows() {
        XCTAssertThrowsError(try store.configuration(atRevision: 99))
    }

    // MARK: 11. Restore creates a new revision rather than rewinding

    func testRestoreWritesANewRevision() throws {
        _ = try store.save(OwnerConfigFixtures.minimalValid(name: "Original"), updatedBy: .onboarding)
        _ = try store.save(OwnerConfigFixtures.minimalValid(name: "Replacement"), updatedBy: .user)
        XCTAssertEqual(store.currentSnapshot()?.revision, 2)

        let restored = try store.restore(revision: 1)

        XCTAssertEqual(restored.snapshot.revision, 3, "Restore moves forward, never back.")
        XCTAssertEqual(restored.snapshot.config.identity.fullName, "Original")
        XCTAssertEqual(restored.snapshot.config.updatedBy, .restore)
        XCTAssertEqual(store.historyRevisions(), [2, 1], "Both earlier revisions remain readable.")
    }

    // MARK: 12. Snapshot immutability

    func testSnapshotIsUnaffectedByALaterSave() throws {
        let first = try store.save(OwnerConfigFixtures.minimalValid(name: "Snapshot Owner"),
                                   updatedBy: .onboarding)
        let held = first.snapshot                       // as an in-flight task would hold it

        _ = try store.save(OwnerConfigFixtures.minimalValid(name: "Changed Owner"), updatedBy: .user)

        XCTAssertEqual(held.config.identity.fullName, "Snapshot Owner")
        XCTAssertEqual(held.revision, 1)
        XCTAssertEqual(store.currentSnapshot()?.config.identity.fullName, "Changed Owner")
        XCTAssertEqual(store.currentSnapshot()?.revision, 2)
    }

    // MARK: Diffs

    func testChangedPathsReportsFieldsWithoutValues() throws {
        let a = OwnerConfigFixtures.minimalValid(name: "A")
        var b = a
        b.identity.roleTitle = "Director"
        b.professional.summaryLine = "Leads packaging."

        let changed = OwnerConfigStore.changedPaths(from: a, to: b)

        XCTAssertTrue(changed.contains("identity.roleTitle"))
        XCTAssertTrue(changed.contains("professional.summaryLine"))
        XCTAssertFalse(changed.contains("revision"), "Bookkeeping fields are not user-visible changes.")
        XCTAssertFalse(changed.contains { $0.contains("Director") }, "A diff must not carry values.")
    }

    func testInitialSaveReportsInitialMarker() throws {
        let result = try store.save(OwnerConfigFixtures.minimalValid(), updatedBy: .onboarding)
        XCTAssertEqual(result.changedPaths, ["<initial>"])
    }

    // MARK: Round-tripping and forward compatibility

    func testConfigurationRoundTripsThroughDisk() throws {
        let original = OwnerConfigFixtures.maximallyPopulated()
        _ = try store.save(original, updatedBy: .user)

        let reloaded = try XCTUnwrap(store.reload()?.config)

        XCTAssertEqual(reloaded.identity.pronouns, original.identity.pronouns)
        XCTAssertEqual(reloaded.roots.projectRoots.first?.path, original.roots.projectRoots.first?.path)
        XCTAssertEqual(reloaded.approvals.policies, original.approvals.policies)
        XCTAssertEqual(reloaded.communication.registers[.client], original.communication.registers[.client])
        XCTAssertEqual(reloaded.secrets.cloudBotToken, original.secrets.cloudBotToken)
    }

    /// Two INDEPENDENTLY constructed but equivalent configurations must encode identically once the
    /// envelope (which legitimately varies) is pinned. Comparing one instance to itself, as the
    /// previous version did, proves nothing about key ordering or dictionary stability.
    func testEncodingIsDeterministicAcrossIndependentInstances() throws {
        let pinnedId = UUID()
        let pinnedDate = Date(timeIntervalSince1970: 1_750_000_000)

        func build() -> OwnerConfig {
            var c = OwnerConfigFixtures.maximallyPopulated()
            c.configId = pinnedId
            c.updatedAt = pinnedDate
            c.revision = 7
            c.updatedBy = .user
            return c
        }

        let a = build(), b = build()
        XCTAssertFalse(a.communication.registers.isEmpty, "Must exercise dictionary ordering.")
        XCTAssertFalse(a.approvals.policies.isEmpty)
        XCTAssertEqual(try a.encoded(), try b.encoded(),
                       "Sorted-key encoding must be byte-stable across separate instances.")
    }

    /// H5 regression, part 1: an unknown TOP-LEVEL key survives a round-trip through this build.
    func testH5_unknownTopLevelKeysSurviveARoundTrip() throws {
        let config = OwnerConfigFixtures.withUnknownTopLevelField()

        let decoded = try OwnerConfig.decoded(from: try config.encoded())

        XCTAssertEqual(decoded.unknownFields?["futureDomain"],
                       .object(["someSetting": .bool(true), "level": .number(3)]),
                       "A newer build's keys must not be destroyed by this one.")
    }

    /// H5 regression, part 2: and — the part that was broken — it can still be SAVED.
    func testH5_configurationWithUnknownFieldsIsStillSavable() throws {
        let result = try store.save(OwnerConfigFixtures.withUnknownTopLevelField(), updatedBy: .user)

        XCTAssertTrue(result.snapshot.validation.isValid,
                      "An unknown field is a warning, never a blocker.")
        XCTAssertTrue(result.snapshot.validation.warnings.contains { $0.code == .unknownFieldsPreserved },
                      "The owner must be told their file has fields this version doesn't model.")
        XCTAssertNotNil(store.reload()?.config.unknownFields?["futureDomain"],
                        "The preserved key must survive the write.")
    }

    /// H5 regression, part 3: preserved-but-never-projected.
    func testH5_unknownFieldsAreNeverProjectedAndFlagThePartialView() throws {
        let projection = try CloudProjection.generate(from: OwnerConfigFixtures.withUnknownTopLevelField())
        let json = try XCTUnwrap(String(data: try projection.encoded(), encoding: .utf8))

        XCTAssertFalse(json.contains("futureDomain"))
        XCTAssertFalse(json.contains("someSetting"))
        XCTAssertTrue(projection.sourceHadUnknownFields,
                      "The cloud must know its view is deliberately partial.")
        XCTAssertFalse(PromptFieldPolicy.isPromptEligible("futureDomain"))
    }

    /// H5 regression, part 4: the boundary that makes dropping NESTED unknown keys safe. Nested
    /// unknowns can only come from a newer schema, and a newer schema cannot be saved at all — so
    /// this build can never silently discard them.
    func testH5_newerSchemaIsReadableButNotSavable() throws {
        let newer = OwnerConfigFixtures.fromNewerSchema()

        let validation = store.validate(newer)
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.errors.contains { $0.code == .unsupportedSchemaVersion })
        XCTAssertTrue(validation.isDisabled(.allOwnerConfig))

        XCTAssertThrowsError(try store.save(newer, updatedBy: .user),
                             "This build must never overwrite data written by a newer one.")
        XCTAssertFalse(store.exists)
    }

    // MARK: Projection side-effects of saving

    func testSaveWritesTheCloudProjection() throws {
        _ = try store.save(OwnerConfigFixtures.maximallyPopulated(), updatedBy: .user)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.projectionFile.path))

        let data = try Data(contentsOf: store.paths.projectionFile)
        let projection = try OwnerConfig.makeDecoder().decode(CloudProjection.self, from: data)
        XCTAssertEqual(projection.revision, store.currentSnapshot()?.revision)
    }

    // MARK: 13. Migration is idempotent

    /// C2 regression. Migration used to seed only `fullName`/`preferredName`, leaving the REQUIRED
    /// `signOffName` nil — so validation failed, `save` threw, and no configuration was ever
    /// created. The feature was permanently inert.
    func testC2_migrationSeedsAllThreeRequiredIdentityFieldsAndSucceeds() throws {
        let outcome = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Legacy Owner")

        guard case let .seeded(revision) = outcome else {
            return XCTFail("Expected .seeded, got \(outcome)")
        }
        XCTAssertEqual(revision, 1)
        XCTAssertTrue(store.exists, "Migration must actually write a configuration.")

        let config = try XCTUnwrap(store.currentSnapshot()?.config)
        XCTAssertEqual(config.identity.fullName, "Legacy Owner")
        XCTAssertEqual(config.identity.preferredName, "Legacy Owner")
        XCTAssertEqual(config.identity.signOffName, "Legacy Owner")
        XCTAssertEqual(config.updatedBy, .migration)

        let validation = try XCTUnwrap(store.currentSnapshot()?.validation)
        XCTAssertTrue(validation.isValid, "Seeded config must be savable: \(validation.errors)")
        XCTAssertFalse(validation.isDisabled(.ownerProfileBlock), "General chat must work.")
    }

    /// The seeded configuration must still ASK about the things it only guessed.
    func testC2_migrationLeavesConfirmableFieldsMarked() throws {
        _ = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Legacy Owner")
        let snapshot = try XCTUnwrap(store.currentSnapshot())

        XCTAssertFalse(snapshot.config.identity.timeZoneConfirmed,
                       "A carried-over zone must keep prompting for confirmation.")
        XCTAssertTrue(snapshot.validation.warnings.contains { $0.path == "identity.timeZone" })
        XCTAssertEqual(snapshot.config.identity.pronouns, .neutral,
                       "Pronouns are never inferred from a name.")
        XCTAssertTrue(snapshot.config.identity.signatures.isEmpty,
                      "No signature body may be invented.")
    }

    // MARK: Production-wired migration
    //
    // `OwnerConfigStore.shared` builds its validator with the existing UserDefaults `ownerName`, so
    // on any machine with an installed Alfred the validator ALWAYS has a legacy name. Tests that use
    // a neutral store exercise a configuration the product never constructs — which is precisely how
    // a total production migration failure previously hid behind a green suite.

    func testProductionWiredMigrationSucceeds() throws {
        let wired = OwnerConfigFixtures.makeProductionWiredStore(legacyOwnerName: "Prior Owner")
        defer { OwnerConfigFixtures.cleanUp(wired.directory) }

        let outcome = wired.store.migrateFromLegacyIfNeeded(legacyOwnerName: "Prior Owner")

        guard case .seeded = outcome else {
            return XCTFail("Production-wired migration must succeed, got \(outcome)")
        }
        let snapshot = try XCTUnwrap(wired.store.currentSnapshot())
        XCTAssertTrue(snapshot.validation.isValid,
                      "Seeded config must validate under production wiring: \(snapshot.validation.errors)")
        XCTAssertTrue(snapshot.validation.errors.isEmpty)
    }

    /// The exact former blocker: the seeded sign-off carried the legacy name, the validator's path
    /// whitelist did not cover it, and migration failed with `.legacyOwnerNameRetained`.
    func testSeededSignOffIsAcceptedUnderMigrationProvenance() throws {
        let wired = OwnerConfigFixtures.makeProductionWiredStore(legacyOwnerName: "Prior Owner")
        defer { OwnerConfigFixtures.cleanUp(wired.directory) }
        _ = wired.store.migrateFromLegacyIfNeeded(legacyOwnerName: "Prior Owner")

        let snapshot = try XCTUnwrap(wired.store.currentSnapshot())

        XCTAssertEqual(snapshot.config.identity.signOffName, "Prior Owner")
        XCTAssertFalse(snapshot.validation.errors.contains { $0.code == .legacyOwnerNameRetained },
                       "Seeded sign-off must not be treated as illegal retention.")
        XCTAssertTrue(snapshot.validation.warnings.contains {
            $0.path == "identity.signOffName" && $0.code == .migrationValueAwaitingConfirmation
        }, "It must instead be flagged for confirmation.")
    }

    func testMigrationRecordsProvenanceForExactlyTheSeededFields() throws {
        let wired = OwnerConfigFixtures.makeProductionWiredStore(legacyOwnerName: "Prior Owner")
        defer { OwnerConfigFixtures.cleanUp(wired.directory) }
        _ = wired.store.migrateFromLegacyIfNeeded(legacyOwnerName: "Prior Owner")

        let seed = try XCTUnwrap(wired.store.currentSnapshot()?.config.migrationSeeded)
        XCTAssertEqual(Set(seed.fields), OwnerConfigDefaults.allowedMigrationSeedPaths)

        let warnings = try XCTUnwrap(wired.store.currentSnapshot()?.validation.warnings)
            .filter { $0.code == .migrationValueAwaitingConfirmation }
        XCTAssertEqual(Set(warnings.map(\.path)), OwnerConfigDefaults.allowedMigrationSeedPaths,
                       "All three seeded fields must be visibly marked for confirmation.")
    }

    /// Provenance must not be usable as a blanket exemption.
    func testLegacyNameInAnUnrelatedFieldIsStillAnError() throws {
        let wired = OwnerConfigFixtures.makeProductionWiredStore(legacyOwnerName: "Prior Owner")
        defer { OwnerConfigFixtures.cleanUp(wired.directory) }
        _ = wired.store.migrateFromLegacyIfNeeded(legacyOwnerName: "Prior Owner")

        var config = try XCTUnwrap(wired.store.currentSnapshot()?.config)
        config.professional.summaryLine = "Assistant to Prior Owner"

        let validation = wired.store.validate(config)
        XCTAssertTrue(validation.errors.contains {
            $0.path == "professional.summaryLine" && $0.code == .legacyOwnerNameRetained
        }, "Only the seeded identity fields may hold the legacy name.")
    }

    func testProvenanceNamingADisallowedFieldIsRejected() {
        let wired = OwnerConfigFixtures.makeProductionWiredStore(legacyOwnerName: "Prior Owner")
        defer { OwnerConfigFixtures.cleanUp(wired.directory) }

        var config = OwnerConfigFixtures.minimalValid(name: "Prior Owner")
        config.migrationSeeded = .init(fields: ["professional.summaryLine"], seededAt: Date())

        let validation = wired.store.validate(config)
        XCTAssertTrue(validation.errors.contains {
            $0.path == "migrationSeeded.fields" && $0.code == .invalidMigrationProvenance
        }, "Provenance cannot launder an exemption onto an arbitrary field.")
    }

    /// Guards the coverage hole itself: a neutral store must NOT be able to satisfy the
    /// production-wired assertions, so swapping the fixture back would fail loudly.
    func testNeutralStoreCannotSatisfyProductionWiredMigrationAssertions() {
        let neutral = OwnerConfigFixtures.makeNeutralStore()
        defer { OwnerConfigFixtures.cleanUp(neutral.directory) }
        _ = neutral.store.migrateFromLegacyIfNeeded(legacyOwnerName: "Prior Owner")

        let issues = neutral.store.currentSnapshot()?.validation.issues ?? []
        XCTAssertFalse(issues.contains { $0.code == .migrationValueAwaitingConfirmation },
                       "With no legacy name injected the scanner never runs — this store proves nothing about migration.")
        XCTAssertFalse(issues.contains { $0.code == .legacyOwnerNameRetained })
    }

    func testMigrationIsIdempotent() throws {
        _ = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Legacy Owner")

        let second = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Legacy Owner")
        XCTAssertEqual(second, .alreadyExists(revision: 1))
        XCTAssertEqual(store.currentSnapshot()?.revision, 1, "No second revision may be written.")

        let third = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Someone Different")
        XCTAssertEqual(third, .alreadyExists(revision: 1))
        XCTAssertEqual(store.currentSnapshot()?.config.identity.fullName, "Legacy Owner",
                       "Migration must never overwrite an existing configuration.")
    }

    func testMigrationDoesNotOverwriteOwnerEdits() throws {
        _ = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Legacy Owner")
        var edited = try XCTUnwrap(store.currentSnapshot()?.config)
        edited.identity.preferredName = "Chosen Name"
        _ = try store.save(edited, updatedBy: .user)

        _ = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Legacy Owner")

        XCTAssertEqual(store.currentSnapshot()?.config.identity.preferredName, "Chosen Name")
    }

    /// Migration carries the NAME only. Nothing learned about the previous owner comes across.
    func testMigrationCarriesNothingButTheName() {
        _ = store.migrateFromLegacyIfNeeded(legacyOwnerName: "Legacy Owner")
        let config = store.currentSnapshot()?.config

        XCTAssertEqual(config?.identity.pronouns, .neutral, "Pronouns are never inferred from a name.")
        XCTAssertEqual(config?.communication.global.rules, [])
        XCTAssertEqual(config?.communication.voice.exemplars, [])
        XCTAssertEqual(config?.communication.voice.mode, .curated)
        XCTAssertEqual(config?.professional.expertiseAreas, [])
        XCTAssertEqual(config?.roots.projectRoots.count, 0)
        XCTAssertNil(config?.professional.summaryLine)
    }

    /// With no legacy name there is nothing to carry across, so migration declines explicitly.
    /// This asserts `.skippedNoLegacyName` rather than "something went wrong" — the previous version
    /// asserted `.failed`, which passed for the wrong reason while migration was broken outright.
    func testMigrationWithNoLegacyNameIsSkippedNotFailed() {
        XCTAssertEqual(store.migrateFromLegacyIfNeeded(legacyOwnerName: nil), .skippedNoLegacyName)
        XCTAssertFalse(store.exists)
    }

    func testMigrationTreatsBlankLegacyNameAsAbsent() {
        XCTAssertEqual(store.migrateFromLegacyIfNeeded(legacyOwnerName: "   "), .skippedNoLegacyName)
        XCTAssertEqual(store.migrateFromLegacyIfNeeded(legacyOwnerName: "\n\t "), .skippedNoLegacyName)
        XCTAssertFalse(store.exists)
    }

    // MARK: Corrupt canonical file — preserve in place
    //
    // Policy: a canonical file that cannot be decoded is LEFT EXACTLY AS FOUND. Saves and migration
    // refuse; recovery is an explicit call. Previously a fresh process treated an unreadable file as
    // "no configuration", overwrote it, and reset the revision counter — destroying the only copy.

    /// Builds a store whose canonical file is corrupt but whose history holds a valid revision,
    /// observed through a FRESH store instance (no warm cache — i.e. the app restarted).
    private func makeCorruptedStore() throws -> (store: OwnerConfigStore, directory: URL, corruptBytes: Data) {
        let made = OwnerConfigFixtures.makeNeutralStore()
        _ = try made.store.save(OwnerConfigFixtures.minimalValid(name: "First"), updatedBy: .user)
        _ = try made.store.save(OwnerConfigFixtures.minimalValid(name: "Second"), updatedBy: .user)
        let corrupt = Data("{ this is not valid configuration".utf8)
        try corrupt.write(to: made.store.paths.configFile)
        let fresh = OwnerConfigStore(paths: made.store.paths, validator: OwnerConfigValidator())
        return (fresh, made.directory, corrupt)
    }

    func testCorruptCanonicalIsReportedAsCorruptNotMissing() throws {
        let c = try makeCorruptedStore()
        defer { OwnerConfigFixtures.cleanUp(c.directory) }

        guard case let .corrupt(info) = c.store.loadState() else {
            return XCTFail("Expected .corrupt, got \(c.store.loadState())")
        }
        XCTAssertEqual(info.byteCount, c.corruptBytes.count)
        XCTAssertTrue(info.isRecoverable)
        XCTAssertNotNil(c.store.corruptionStatus())
    }

    func testSaveOverCorruptCanonicalThrowsTheCorruptionErrorAndChangesNothing() throws {
        let c = try makeCorruptedStore()
        defer { OwnerConfigFixtures.cleanUp(c.directory) }

        XCTAssertThrowsError(try c.store.save(OwnerConfigFixtures.minimalValid(), updatedBy: .user)) { error in
            guard case OwnerConfigStore.StoreError.canonicalCorrupt = error else {
                return XCTFail("Expected .canonicalCorrupt, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: c.store.paths.configFile), c.corruptBytes,
                       "The corrupt bytes must be untouched.")
    }

    func testMigrationOverCorruptCanonicalIsRefusedAndChangesNothing() throws {
        let c = try makeCorruptedStore()
        defer { OwnerConfigFixtures.cleanUp(c.directory) }

        let outcome = c.store.migrateFromLegacyIfNeeded(legacyOwnerName: "Someone New")

        guard case let .refusedCanonicalCorrupt(recoverable) = outcome else {
            return XCTFail("Expected .refusedCanonicalCorrupt, got \(outcome)")
        }
        XCTAssertNotNil(recoverable)
        XCTAssertEqual(try Data(contentsOf: c.store.paths.configFile), c.corruptBytes)
    }

    func testRecoveryQuarantinesCorruptBytesAndWritesAForwardRevision() throws {
        let c = try makeCorruptedStore()
        defer { OwnerConfigFixtures.cleanUp(c.directory) }

        let result = try c.store.restoreAfterCorruption()

        // Forward, never rewound: history held revision 1 and the LOST canonical was 2, so the next
        // revision must exceed 2 — which is only knowable from the projection's recorded revision.
        XCTAssertGreaterThan(result.snapshot.revision, 2)
        XCTAssertEqual(result.snapshot.config.updatedBy, .recovery)
        XCTAssertEqual(result.snapshot.config.identity.fullName, "First",
                       "Recovered content comes from the newest ARCHIVED revision.")

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: c.store.paths.quarantineDirectory.path)
        let copies = quarantined.filter { $0.hasPrefix("owner.config.corrupt-") }
        XCTAssertEqual(copies.count, 1, "Corrupt bytes must be kept, never discarded.")
        XCTAssertEqual(try Data(contentsOf: c.store.paths.quarantineDirectory.appending(path: copies[0])),
                       c.corruptBytes)
        XCTAssertTrue(quarantined.contains { $0.hasPrefix("manifest-") })
    }

    func testUnrecoverableCorruptionReportsNoRecoverableRevision() throws {
        let made = OwnerConfigFixtures.makeNeutralStore()
        defer { OwnerConfigFixtures.cleanUp(made.directory) }
        _ = try made.store.save(OwnerConfigFixtures.minimalValid(name: "Only"), updatedBy: .user)
        _ = try made.store.save(OwnerConfigFixtures.minimalValid(name: "Two"), updatedBy: .user)
        // Corrupt BOTH the canonical file and the one archived revision.
        try Data("{bad".utf8).write(to: made.store.paths.configFile)
        try Data("{bad".utf8).write(to: made.store.paths.historyDirectory.appending(path: "1.json"))

        let fresh = OwnerConfigStore(paths: made.store.paths, validator: OwnerConfigValidator())

        XCTAssertNil(fresh.latestRecoverableRevision(), "A corrupt history entry must be ignored.")
        XCTAssertThrowsError(try fresh.restoreAfterCorruption()) { error in
            guard case OwnerConfigStore.StoreError.noRecoverableRevision = error else {
                return XCTFail("Expected .noRecoverableRevision, got \(error)")
            }
        }
    }

    func testRevisionSkipsPastAForeignHistoryFileRatherThanColliding() throws {
        let made = OwnerConfigFixtures.makeNeutralStore()
        defer { OwnerConfigFixtures.cleanUp(made.directory) }
        let first = try made.store.save(OwnerConfigFixtures.minimalValid(name: "Home"), updatedBy: .user)

        var foreign = OwnerConfigFixtures.minimalValid(name: "Foreign")
        foreign.configId = UUID()
        foreign.revision = 9
        try foreign.encoded().write(to: made.store.paths.historyDirectory.appending(path: "9.json"))

        let next = try made.store.save(OwnerConfigFixtures.minimalValid(name: "Home2"), updatedBy: .user)

        XCTAssertEqual(next.snapshot.revision, 10, "A reserved revision number must not be reused.")
        XCTAssertEqual(next.snapshot.configId, first.snapshot.configId,
                       "A foreign configId must not be adopted.")
    }

    // MARK: Persistence equality

    /// The date strategy used to truncate sub-second precision, so a configuration was never equal
    /// to itself after a round-trip.
    func testSaveThenReloadReturnsAnEqualConfiguration() throws {
        let saved = try store.save(OwnerConfigFixtures.minimalValid(name: "Equality"), updatedBy: .user)
        let reloaded = try XCTUnwrap(store.reload()?.config)

        XCTAssertEqual(saved.snapshot.config, reloaded)
    }

    func testHistoryAndRestoreRoundTripsAreEqual() throws {
        let first = try store.save(OwnerConfigFixtures.minimalValid(name: "One"), updatedBy: .user)
        _ = try store.save(OwnerConfigFixtures.minimalValid(name: "Two"), updatedBy: .user)

        XCTAssertEqual(try store.configuration(atRevision: first.snapshot.revision),
                       first.snapshot.config)

        let restored = try store.restore(revision: first.snapshot.revision)
        XCTAssertEqual(try XCTUnwrap(store.reload()?.config), restored.snapshot.config)
    }

    func testFractionalAndWholeSecondDatesBothRoundTrip() throws {
        var config = OwnerConfigFixtures.minimalValid()

        config.updatedAt = Date(timeIntervalSince1970: 1_750_000_000.123).ownerConfigStoragePrecision
        XCTAssertEqual(try OwnerConfig.decoded(from: try config.encoded()).updatedAt, config.updatedAt)

        config.updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(try OwnerConfig.decoded(from: try config.encoded()).updatedAt, config.updatedAt)
    }

    /// Configurations written before fractional seconds were introduced must still load.
    func testLegacyWholeSecondTimestampsStillDecode() throws {
        var config = OwnerConfigFixtures.minimalValid()
        config.updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let json = try XCTUnwrap(String(data: try config.encoded(), encoding: .utf8))
            .replacingOccurrences(of: OwnerConfig.iso8601Fractional.string(from: config.updatedAt),
                                  with: OwnerConfig.iso8601WholeSecond.string(from: config.updatedAt))

        let decoded = try OwnerConfig.decoded(from: Data(json.utf8))

        XCTAssertEqual(decoded.updatedAt, config.updatedAt)
    }

    // MARK: Last-known-good

    func testLastKnownGoodSurvivesACorruptedFile() throws {
        _ = try store.save(OwnerConfigFixtures.minimalValid(name: "Good Owner"), updatedBy: .user)
        let good = store.lastKnownGoodSnapshot()
        XCTAssertEqual(good?.config.identity.fullName, "Good Owner")

        try Data("{ not json".utf8).write(to: store.paths.configFile)

        XCTAssertNil(store.reload(), "A corrupted file must not decode.")
        XCTAssertEqual(store.lastKnownGoodSnapshot()?.config.identity.fullName, "Good Owner")
    }

    // MARK: Previews

    func testPreviewsRenderAndProjectionExcludesLocalPaths() throws {
        _ = try store.save(OwnerConfigFixtures.maximallyPopulated(), updatedBy: .user)

        let configPreview = try XCTUnwrap(store.configurationPreview())
        XCTAssertTrue(configPreview.contains("SENTINEL_PROJECT_ROOT"),
                      "The local preview shows the owner their own roots.")

        let projectionPreview = try XCTUnwrap(store.projectionPreview())
        for sentinel in OwnerConfigFixtures.localOnlySentinels {
            XCTAssertFalse(projectionPreview.contains(sentinel),
                           "\(sentinel) leaked into the cloud preview.")
        }
    }
}
