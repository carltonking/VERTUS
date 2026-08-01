import Foundation
import XCTest
@testable import Alfred

// MARK: - Fixtures and temp-directory helpers for the Owner Configuration tests.
//
// SAFETY: every store in these tests is constructed with a temporary directory. Nothing here reads
// or writes the developer's real `~/.alfred`, and `assertIsolatedFromRealHome` proves it.

enum OwnerConfigFixtures {

    // MARK: Configurations

    /// The smallest configuration that passes validation: the three fields the assistant cannot
    /// speak for someone without, plus a confirmed time zone.
    ///
    /// Deliberately configures NO secret references. That is the C1 regression condition — an
    /// all-`nil` `secrets` encodes as `{}` and used to make every default configuration
    /// unprojectable and therefore unsavable. Do not "fix" a failing test by adding a secret here.
    static func minimalValid(name: String = "Test Owner") -> OwnerConfig {
        var config = OwnerConfigDefaults.blank
        config.identity.fullName = name
        config.identity.preferredName = name
        config.identity.signOffName = name
        config.identity.timeZoneConfirmed = true
        return config
    }

    /// Exactly what `migrateFromLegacyIfNeeded` produces: three identity fields carried across, an
    /// UNCONFIRMED time zone, and nothing else.
    static func migrationSeeded(name: String = "Legacy Owner") -> OwnerConfig {
        var config = OwnerConfigDefaults.blank
        config.identity.fullName = name
        config.identity.preferredName = name
        config.identity.signOffName = name
        config.updatedBy = .migration
        return config
    }

    /// A configuration written by a NEWER build: same shape plus a top-level key this build does not
    /// model. Drives the H5 "preserve but never project" tests.
    static func withUnknownTopLevelField(name: String = "Forward Owner") -> OwnerConfig {
        var config = minimalValid(name: name)
        config.unknownFields = [
            "futureDomain": .object(["someSetting": .bool(true), "level": .number(3)]),
        ]
        return config
    }

    /// A configuration claiming a schema major this build does not understand.
    static func fromNewerSchema(name: String = "Future Owner") -> OwnerConfig {
        var config = minimalValid(name: name)
        config.schemaVersion = OwnerConfigDefaults.schemaVersion + 1
        return config
    }

    /// Only the two references the cloud resolves.
    static func withCloudSecretsOnly() -> OwnerConfig {
        var config = minimalValid(name: "Cloud Secrets Owner")
        config.secrets.cloudBotToken = .environment(name: "CLOUD_BOT_TOKEN")
        config.secrets.cloudOwnerId = .environment(name: "OWNER_CHAT_ID")
        return config
    }

    /// Only Mac-local references — the projection's `secrets` block must come out empty.
    static func withKeychainSecretsOnly() -> OwnerConfig {
        var config = minimalValid(name: "Keychain Secrets Owner")
        config.secrets.telegramBotToken = .keychain(service: "com.alfred.app", account: "telegram")
        config.secrets.mailPrimary = .keychain(service: "com.alfred.app", account: "mail")
        return config
    }

    /// Both kinds at once: cloud refs travel, Mac refs stay.
    static func withMixedSecrets() -> OwnerConfig {
        var config = withCloudSecretsOnly()
        config.secrets.telegramBotToken = .keychain(service: "com.alfred.app", account: "telegram")
        config.secrets.calendarPrimary = .keychain(service: "com.alfred.app", account: "calendar")
        return config
    }

    /// Every domain populated, still valid. Used by the projection leak tests — if a field can exist,
    /// this fixture has it, so "the projection excluded it" means something.
    static func maximallyPopulated() -> OwnerConfig {
        var config = minimalValid(name: "Maximal Owner")

        config.identity.pronouns = .init(subject: "she", object: "her", possessive: "her")
        config.identity.roleTitle = "Design Director"
        config.identity.organization = "Example Studio"
        config.identity.locale = "en_US"
        config.identity.timeFormat = .h24
        config.identity.dateFormat = .iso
        config.identity.signatures = [
            .init(id: "work", label: "Work", body: "Best,\nMaximal Owner"),
            .init(id: "private", label: "Private", body: "— M"),
        ]
        config.identity.workingHours = [.init(day: .monday, start: "09:00", end: "17:30")]
        config.identity.outOfHoursPolicy = .queue

        config.professional.summaryLine = "Leads packaging design and production."
        config.professional.expertiseAreas = ["packaging design", "production"]
        config.professional.industries = ["consumer goods"]
        config.professional.categories = ["beverage"]
        config.professional.responsibilities = ["approve artwork", "run printer releases"]
        config.professional.disciplines = ["structural", "graphic"]
        config.professional.terminology = [.init(term: "mechanical", definition: "print-ready artwork", aliases: ["mech"])]
        config.professional.authority = .init(canCommitBudget: .withApproval, canApproveArtwork: .yes,
                                              canSignOffProduction: .withApproval, canCommitDates: .no)
        config.professional.team = [.init(contactRef: "contact-1", relationship: .report)]

        config.communication.global.rules = ["Lead with the answer."]
        config.communication.voice.exemplars = ["EXEMPLAR_SENTINEL_should_never_reach_cloud"]
        config.communication.voice.learnFromSent = false
        config.communication.registers[.client] = .init(
            tone: "warm but precise", formality: 4, typicalLength: .medium,
            greeting: "Hi", signOff: "Best", signatureId: "work", directness: 3,
            useBullets: .whenListing, technicalDetail: .working,
            avoidPhrases: ["circle back"], avoidClaims: ["delivery dates"],
            approvalOverride: .doubleConfirm, cloudEligible: true)
        config.communication.registers[.personal] = .init(
            tone: "PERSONAL_SENTINEL_should_never_reach_cloud", cloudEligible: false)

        config.systems.email = [.init(provider: .imap,
                                      accountRef: .keychain(service: "com.alfred.app", account: "mail"),
                                      role: .work, capabilities: [.read, .draft])]
        config.systems.calendar = [.init(provider: .caldav,
                                         calendarRef: .keychain(service: "com.alfred.app", account: "cal"),
                                         role: .work, writeAllowed: false)]
        config.systems.projectManagement = .init(kind: .asana,
                                                 workspaceRef: .environment(name: "ASANA_WORKSPACE"))
        config.systems.applications = [.init(name: "Illustrator", bundleId: "com.adobe.illustrator",
                                             automation: .inspect)]
        config.systems.adobe = .init(illustrator: .installed, photoshop: .installed,
                                     indesign: .absent, acrobat: .absent)
        config.systems.rhino = .installed
        config.systems.fileStorage = [.init(provider: "dropbox",
                                            mountPath: "/Volumes/SENTINEL_STORAGE", role: .work)]
        config.systems.messagingChannels = [.init(kind: .telegram, enabled: false,
                                                  ownerRef: .keychain(service: "com.alfred.app",
                                                                      account: "telegram.owner"))]
        config.systems.researchSources = [.init(name: "Reviews", kind: "web", credentialRef: nil)]

        // Distinctive paths so a leak assertion can search for them by substring.
        config.roots.projectRoots = [.init(path: "/tmp/SENTINEL_PROJECT_ROOT", label: "Projects",
                                           classification: "internal", namespace: .work,
                                           readable: true, writable: true)]
        config.roots.artworkArchive = .init(path: "/tmp/SENTINEL_ARTWORK", classification: "confidential")
        config.roots.brandLibrary = .init(path: "/tmp/SENTINEL_BRAND")
        config.roots.output = .init(path: "/tmp/SENTINEL_OUTPUT", writable: true)
        config.roots.personal = [.init(path: "/tmp/SENTINEL_PERSONAL", namespace: .personal)]
        config.roots.restricted = [.init(path: "/tmp/SENTINEL_RESTRICTED", readable: false, writable: false)]
        config.roots.localModelOnly = [.init(path: "/tmp/SENTINEL_LOCAL_ONLY", classification: "confidential")]

        config.vocabulary.namespace = "work"
        config.vocabulary.terms = ["project": "Programme", "dieline": "Cutter guide"]
        config.vocabulary.milestoneTypes = [.init(id: "press", label: "Press check", defaultLeadDays: 5)]
        config.vocabulary.statusVocabulary = ["briefed", "in production"]
        config.vocabulary.approvalStages = [.init(id: "prepress", label: "Prepress", blocksRelease: true)]

        config.approvals.perApplication = ["com.adobe.illustrator": .doubleConfirm]
        config.approvals.restrictedRecipients = ["SENTINEL_RESTRICTED_RECIPIENT"]

        config.governance.crossNamespaceReads = [.init(from: .work, to: .personal)]

        config.features.morningBriefing = .init(enabled: true, topics: ["packaging"],
                                                sections: ["Category"], sendLocalTime: "07:00")
        config.features.telegram = .init(true)

        config.secrets.cloudBotToken = .environment(name: "CLOUD_BOT_TOKEN")
        config.secrets.cloudOwnerId = .environment(name: "OWNER_CHAT_ID")
        config.secrets.telegramBotToken = .keychain(service: "com.alfred.app", account: "telegram")
        config.secrets.mailPrimary = .keychain(service: "com.alfred.app", account: "mail")

        return config
    }

    /// Sentinel substrings that must never appear in a cloud projection.
    static let localOnlySentinels = [
        "SENTINEL_PROJECT_ROOT", "SENTINEL_ARTWORK", "SENTINEL_BRAND", "SENTINEL_OUTPUT",
        "SENTINEL_PERSONAL", "SENTINEL_RESTRICTED", "SENTINEL_LOCAL_ONLY", "SENTINEL_STORAGE",
        "EXEMPLAR_SENTINEL_should_never_reach_cloud",
        "PERSONAL_SENTINEL_should_never_reach_cloud",
        "SENTINEL_RESTRICTED_RECIPIENT",
    ]

    // MARK: Stores

    /// A store rooted in a fresh temporary directory. Caller must call `cleanUp`.
    ///
    /// Prefer `makeNeutralStore` / `makeProductionWiredStore` at call sites — they say which wiring
    /// the test intends, which is exactly the distinction that let a production-only migration
    /// failure hide behind a green suite.
    static func makeTempStore(legacyOwnerName: String? = nil,
                              historyLimit: Int = 20) -> (store: OwnerConfigStore, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "alfred-owner-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = OwnerConfigStore(
            paths: .init(directory: dir),
            validator: OwnerConfigValidator(legacyOwnerName: legacyOwnerName),
            historyLimit: historyLimit)
        return (store, dir)
    }

    /// A store with NO legacy owner — a fresh install. Correct for tests that have nothing to do
    /// with migration.
    static func makeNeutralStore(historyLimit: Int = 20) -> (store: OwnerConfigStore, directory: URL) {
        makeTempStore(legacyOwnerName: nil, historyLimit: historyLimit)
    }

    /// A store wired the way PRODUCTION wires it: `OwnerConfigStore.shared` constructs its validator
    /// with the existing `UserDefaults` `ownerName`, so on any real machine with an installed Alfred
    /// the validator always has a legacy name. Migration tests must use this, or they exercise a
    /// configuration the product never builds.
    static func makeProductionWiredStore(legacyOwnerName: String,
                                         historyLimit: Int = 20) -> (store: OwnerConfigStore, directory: URL) {
        makeTempStore(legacyOwnerName: legacyOwnerName, historyLimit: historyLimit)
    }

    /// The exact shape migration produces, including provenance.
    static func migrationSeededWithProvenance(name: String = "Legacy Owner") -> OwnerConfig {
        var config = migrationSeeded(name: name)
        config.migrationSeeded = .init(
            fields: Array(OwnerConfigDefaults.allowedMigrationSeedPaths),
            seededAt: Date(timeIntervalSince1970: 1_750_000_000))
        return config
    }

    static func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Isolation assertion

extension XCTestCase {
    /// Proves a store cannot reach the developer's real configuration (OCS acceptance test 26).
    func assertIsolatedFromRealHome(_ store: OwnerConfigStore,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let real = OwnerConfigStore.Paths.standard.directory.standardizedFileURL.path
        let used = store.paths.directory.standardizedFileURL.path
        XCTAssertNotEqual(used, real, "Test store must not point at the real ~/.alfred/owner.",
                          file: file, line: line)
        XCTAssertFalse(used.hasPrefix(real),
                       "Test store must not live inside the real ~/.alfred/owner.",
                       file: file, line: line)
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(used.hasPrefix(temp),
                      "Test store must live under the temporary directory, got \(used).",
                      file: file, line: line)
    }
}
