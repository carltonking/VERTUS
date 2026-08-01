import Foundation

// MARK: - CloudProjection (OCS §8, §9)
//
// The cloud assistant is deliberately narrower than the Mac: it has no filesystem, no screen, no
// local memory. Its configuration should be narrower too. This file produces that subset.
//
// The important property is HOW the subset is decided. It is not a hand-maintained "don't forget to
// exclude X" list — those rot, and the failure mode is a silent leak. Instead:
//
//   1. `FieldRegistry` records an explicit include/exclude decision for every field path.
//   2. Generation walks the ACTUAL encoded configuration and refuses to run if it meets a path with
//      no decision.
//
// So adding a field to `OwnerConfig` without classifying it breaks projection generation (and its
// test) rather than quietly shipping the field to the cloud.
//
// # Forward compatibility (H5 policy: "preserve but never project")
//
// Two distinct situations, resolved differently and deliberately:
//
//  1. SAME schema version, unknown TOP-LEVEL key (a hand-edited file, or a sibling build).
//     The key is preserved verbatim in the canonical file and history, is skipped by the
//     classification check, is unconditionally absent from the projection, and is invisible to the
//     prompt builder. `sourceHadUnknownFields` records that the cloud's view is partial. Saving
//     still works — the alternative (demanding a registry entry for a field we cannot understand)
//     made the configuration permanently unsavable.
//
//  2. NEWER schema version, which is the only way unknown NESTED keys can legitimately appear.
//     `OwnerConfigValidator` rejects an unrecognized `schemaVersion` with `.unsupportedSchemaVersion`
//     and `disablesFeature: .allOwnerConfig`, and `OwnerConfigStore.save` refuses to write anything
//     that fails validation. The newer file is therefore readable but NOT editable by this build, so
//     nested keys this build would drop can never be silently lost through a save.
//
// Nested unknown keys are consequently not preserved and do not need to be: reaching them requires
// a schema version that is already refused for editing. That boundary is asserted by tests rather
// than assumed.

struct CloudProjection: Codable, Equatable, Sendable {

    // MARK: Envelope

    var schemaVersion: Int
    var configId: UUID
    var revision: Int
    var generatedAt: Date
    /// True when the source configuration carried top-level keys this build does not model (H5).
    /// Those keys are preserved on the Mac and NEVER projected, so a `true` here tells the cloud its
    /// view is deliberately partial rather than authoritative.
    var sourceHadUnknownFields: Bool

    // MARK: Payload

    var identity: Identity
    var professional: Professional
    var communication: Communication
    var vocabulary: Vocabulary
    var briefing: Briefing
    var calendar: [Calendar]
    var features: Features
    var approvals: Approvals
    var providers: Providers
    var secrets: Secrets

    struct Identity: Codable, Equatable, Sendable {
        var fullName: String?
        var preferredName: String?
        var pronouns: OwnerConfig.Identity.Pronouns
        var roleTitle: String?
        var organization: String?
        var signOffName: String?
        /// Only signatures referenced by a cloud-eligible register.
        var signatures: [OwnerConfig.Identity.Signature]
        var timeZone: String
        var locale: String?
        var dateFormat: OwnerConfig.Identity.DateFormatStyle
        var timeFormat: OwnerConfig.Identity.TimeFormatStyle
        var workingHours: [OwnerConfig.Identity.DayWindow]
        var outOfHoursPolicy: OwnerConfig.Identity.OutOfHoursPolicy
    }

    struct Professional: Codable, Equatable, Sendable {
        var summaryLine: String?
        var expertiseAreas: [String]
        var industries: [String]
        var categories: [String]
    }

    struct Communication: Codable, Equatable, Sendable {
        var globalRules: [String]
        var defaultRegister: OwnerConfig.Communication.RegisterKey
        /// Cloud-eligible registers only. `personal` is excluded by default.
        var registers: [String: OwnerConfig.Communication.Register]
    }

    struct Vocabulary: Codable, Equatable, Sendable {
        var namespace: String
        var terms: [String: String]
        var milestoneTypes: [OwnerConfig.Vocabulary.MilestoneType]
        var statusVocabulary: [String]
    }

    struct Briefing: Codable, Equatable, Sendable {
        var enabled: Bool
        var topics: [String]
        var sections: [String]
        var sendLocalTime: String?
    }

    /// Calendar BEHAVIOUR only — provider, role, and whether writes are permitted. No credentials.
    struct Calendar: Codable, Equatable, Sendable {
        var provider: OwnerConfig.Systems.CalendarProvider
        var role: OwnerConfig.Namespace
        var writeAllowed: Bool
    }

    /// Cloud-relevant features only. Screen capture, computer control, shell, and the local learning
    /// toggles have no cloud meaning and are never sent.
    struct Features: Codable, Equatable, Sendable {
        var telegram: Bool
        var morningBriefing: Bool
        var routineExecution: Bool
        var liveLocation: Bool
    }

    /// The subset of actions the cloud can actually attempt.
    struct Approvals: Codable, Equatable, Sendable {
        var policies: [String: OwnerConfig.ApprovalPolicy]
        var neverAllowed: [String]
        var requireRecipientDisplay: Bool
        var duplicateActionWindowSec: Int
    }

    struct Providers: Codable, Equatable, Sendable {
        var chain: [String]
        var models: [String: String]
    }

    /// References only — the cloud resolves these from its own environment.
    struct Secrets: Codable, Equatable, Sendable {
        var cloudBotToken: SecretRef?
        var cloudOwnerId: SecretRef?
    }

    /// Actions the cloud runtime can perform; everything else is Mac-only and is not projected.
    static let cloudActions: [OwnerConfig.ApprovalAction] = [
        .read, .summarize, .draft, .saveDraft,
        .createCalendarEvent, .modifyCalendarEvent, .bulkCalendarDelete,
        .sendEmail, .sendMessage, .createTask, .modifyTask,
    ]
}

// MARK: - Generation

extension CloudProjection {

    enum GenerationError: Error, LocalizedError, Equatable {
        /// A field exists in the configuration but no projection decision covers it.
        case unclassifiedField(path: String)
        case invalidConfiguration([String])

        var errorDescription: String? {
            switch self {
            case let .unclassifiedField(path):
                return "Configuration field \"\(path)\" has no cloud-projection decision. Add it to CloudProjection.FieldRegistry as .include or .exclude before it can be projected."
            case let .invalidConfiguration(paths):
                return "Configuration is not valid; cannot project. Offending fields: \(paths.joined(separator: ", "))"
            }
        }
    }

    /// Build the cloud subset.
    ///
    /// - Throws: `unclassifiedField` when the configuration contains a path the registry does not
    ///   classify. This is the mechanism that makes a forgotten field a build/test failure instead
    ///   of a leak.
    static func generate(from config: OwnerConfig) throws -> CloudProjection {
        try assertEveryFieldClassified(in: config)
        let hadUnknown = !(config.unknownFields ?? [:]).isEmpty

        // Registers: cloud-eligible only.
        let eligible = config.communication.registers.filter { $0.value.cloudEligible }
        var registers: [String: OwnerConfig.Communication.Register] = [:]
        for (key, value) in eligible { registers[key.rawValue] = value }

        // Signatures: only those an eligible register actually references, so an unused personal
        // signature never travels.
        let referenced = Set(eligible.values.compactMap(\.signatureId))
        let signatures = config.identity.signatures.filter { referenced.contains($0.id) }

        var policies: [String: OwnerConfig.ApprovalPolicy] = [:]
        for action in cloudActions { policies[action.rawValue] = config.approvals.policy(for: action) }

        return CloudProjection(
            schemaVersion: config.schemaVersion,
            configId: config.configId,
            revision: config.revision,
            generatedAt: Date(),
            sourceHadUnknownFields: hadUnknown,
            identity: .init(
                fullName: config.identity.fullName,
                preferredName: config.identity.preferredName,
                pronouns: config.identity.pronouns,
                roleTitle: config.identity.roleTitle,
                organization: config.identity.organization,
                signOffName: config.identity.signOffName,
                signatures: signatures,
                timeZone: config.identity.timeZone,
                locale: config.identity.locale,
                dateFormat: config.identity.dateFormat,
                timeFormat: config.identity.timeFormat,
                workingHours: config.identity.workingHours,
                outOfHoursPolicy: config.identity.outOfHoursPolicy
            ),
            professional: .init(
                summaryLine: config.professional.summaryLine,
                expertiseAreas: config.professional.expertiseAreas,
                industries: config.professional.industries,
                categories: config.professional.categories
            ),
            communication: .init(
                globalRules: config.communication.global.rules,
                defaultRegister: config.communication.global.defaultRegister,
                registers: registers
            ),
            vocabulary: .init(
                namespace: config.vocabulary.namespace,
                terms: config.vocabulary.terms,
                milestoneTypes: config.vocabulary.milestoneTypes,
                statusVocabulary: config.vocabulary.statusVocabulary
            ),
            briefing: .init(
                enabled: config.features.morningBriefing.enabled,
                topics: config.features.morningBriefing.topics,
                sections: config.features.morningBriefing.sections,
                sendLocalTime: config.features.morningBriefing.sendLocalTime
            ),
            calendar: config.systems.calendar.map {
                Calendar(provider: $0.provider, role: $0.role, writeAllowed: $0.writeAllowed)
            },
            features: .init(
                telegram: config.features.telegram.enabled,
                morningBriefing: config.features.morningBriefing.enabled,
                routineExecution: config.features.routineExecution.enabled,
                liveLocation: config.features.liveLocation.enabled
            ),
            approvals: .init(
                policies: policies,
                neverAllowed: config.approvals.neverAllowed
                    .filter { cloudActions.contains($0) }.map(\.rawValue).sorted(),
                requireRecipientDisplay: config.approvals.requireRecipientDisplay,
                duplicateActionWindowSec: config.approvals.duplicateActionWindowSec
            ),
            providers: .init(chain: config.providers.chain, models: config.providers.models),
            secrets: .init(cloudBotToken: config.secrets.cloudBotToken,
                           cloudOwnerId: config.secrets.cloudOwnerId)
        )
    }

    /// Walk the encoded configuration and require a registry decision for every leaf.
    ///
    /// Unknown TOP-LEVEL keys are skipped rather than resolved (H5, Option A): they are preserved in
    /// the canonical file but are unconditionally excluded from the cloud, so demanding a registry
    /// entry for a field this build does not understand would only make the configuration
    /// unsavable — which is exactly the deadlock this replaces. Everything else must be classified.
    static func assertEveryFieldClassified(in config: OwnerConfig) throws {
        let tree = try JSONValue.from(config)
        try assertEveryPathClassified(tree.leafPaths(),
                                      unknownRoots: Set((config.unknownFields ?? [:]).keys))
    }

    /// Path-level check, split out so a test can feed synthetic paths and prove that a genuinely new
    /// field fails closed — something no test can express through `OwnerConfig` itself, because
    /// adding a property to the schema is a compile-time act.
    static func assertEveryPathClassified(_ paths: [String], unknownRoots: Set<String>) throws {
        for path in paths {
            let root = String(path.prefix(while: { $0 != "." }))
            if unknownRoots.contains(root) { continue }   // preserved locally, never projected
            guard FieldRegistry.disposition(for: path) != nil else {
                throw GenerationError.unclassifiedField(path: path)
            }
        }
    }

    func encoded(pretty: Bool = true) throws -> Data {
        try OwnerConfig.makeEncoder(pretty: pretty).encode(self)
    }
}

// MARK: - FieldRegistry

extension CloudProjection {

    /// The explicit include/exclude decision for every configuration field path.
    ///
    /// # What is classified (the rule)
    ///
    /// Classification operates on **runtime leaf paths** — the paths produced by walking an ACTUALLY
    /// ENCODED configuration (`JSONValue.leafPaths`). A "leaf" is a scalar, an array, or an EMPTY
    /// container. That last clause is the one that matters: an all-`nil` struct such as `secrets`
    /// encodes as `{}` and therefore appears as the leaf `"secrets"`, distinct from `"secrets.<name>"`.
    /// Container paths are consequently first-class entries here, not an afterthought — the previous
    /// design classified only children and made every default configuration unprojectable (C1).
    ///
    /// # Four kinds of entry
    ///
    /// * `includeExact`   — this path only. Descendants are NOT covered.
    /// * `excludeExact`   — this path only (usually a container that can encode empty).
    /// * `includeSubtree` — this path and everything beneath it.
    /// * `excludeSubtree` — this path and everything beneath it.
    ///
    /// # The asymmetry that keeps this safe
    ///
    /// `includeSubtree` is the only dangerous kind: it lets a field that does not exist yet be sent
    /// to the cloud without anyone deciding. It is therefore permitted ONLY for containers with
    /// DYNAMIC KEYS, where per-path enumeration is impossible (`vocabulary.terms`,
    /// `providers.models`, `approvals.policies`, `communication.registers`, and the two cloud secret
    /// refs whose `environmentRef` child is generated by `SecretRef`'s own encoding). Every such use
    /// is justified inline below.
    ///
    /// `excludeSubtree` is blanket-safe: its failure mode is "a new field stays local", so whole
    /// local-only domains (`roots`, `governance`) use it deliberately.
    ///
    /// Fixed structs are enumerated field by field with `includeExact`/`excludeExact`, so adding a
    /// property to one of them yields an unclassified path and fails generation — which is the
    /// invariant this table exists to enforce.
    ///
    /// Unknown top-level keys are NOT resolved here at all; see `generate(from:)` and the H5 policy.
    enum FieldRegistry {
        enum Disposition: Equatable { case include, exclude }

        // MARK: Exact entries (fixed struct fields and empty-able containers)

        static let includeExact: [String] = [
            // Envelope — lets the cloud detect drift against the Mac.
            "schemaVersion", "configId", "revision", "updatedAt", "updatedBy",
            // Identity: uniformly cloud-safe, but enumerated so a NEW identity field must be decided.
            "identity.fullName", "identity.preferredName", "identity.pronouns",
            "identity.pronouns.subject", "identity.pronouns.object", "identity.pronouns.possessive",
            "identity.roleTitle", "identity.organization", "identity.signOffName",
            "identity.signatures", "identity.timeZone", "identity.timeZoneConfirmed",
            "identity.locale", "identity.dateFormat", "identity.timeFormat",
            "identity.workingHours", "identity.outOfHoursPolicy",
            // Professional: only the outward-facing summary travels.
            "professional.summaryLine", "professional.expertiseAreas",
            "professional.industries", "professional.categories",
            // Communication.
            "communication.global", "communication.global.rules",
            "communication.global.defaultRegister",
            "communication.voice", "communication.voice.mode",
            // Vocabulary.
            "vocabulary", "vocabulary.namespace", "vocabulary.milestoneTypes",
            "vocabulary.statusVocabulary", "vocabulary.approvalStages",
            // Approvals the cloud can act on.
            "approvals", "approvals.neverAllowed", "approvals.requireRecipientDisplay",
            "approvals.duplicateActionWindowSec",
            // Features with a cloud meaning.
            "features", "features.telegram", "features.telegram.enabled",
            "features.morningBriefing", "features.morningBriefing.enabled",
            "features.morningBriefing.topics", "features.morningBriefing.sections",
            "features.morningBriefing.sendLocalTime",
            "features.routineExecution", "features.routineExecution.enabled",
            "features.liveLocation", "features.liveLocation.enabled",
            // Providers.
            "providers", "providers.chain",
            // Calendar BEHAVIOUR (provider/role/writeAllowed); credentials are separate refs.
            "systems", "systems.calendar",
        ]

        static let excludeExact: [String] = [
            // The `secrets` CONTAINER itself. Encodes as `{}` when nothing is configured — the exact
            // case that made every default configuration unsavable (C1). Excluding the container
            // without excluding its subtree keeps each child individually accountable, so a NEW
            // secret slot is unclassified and fails closed rather than being silently dropped.
            "secrets",
            // Professional detail that stays on the Mac.
            "professional.authority", "professional.authority.canCommitBudget",
            "professional.authority.canApproveArtwork",
            "professional.authority.canSignOffProduction",
            "professional.authority.canCommitDates",
            "professional.responsibilities", "professional.team",
            "professional.terminology", "professional.disciplines",
            // Local-only voice corpus and its switch.
            "communication.voice.exemplars", "communication.voice.learnFromSent",
            // Local automation state.
            "systems.email", "systems.fileStorage", "systems.applications",
            "systems.researchSources", "systems.messagingChannels", "systems.rhino",
            "systems.adobe", "systems.adobe.illustrator", "systems.adobe.photoshop",
            "systems.adobe.indesign", "systems.adobe.acrobat",
            "systems.projectManagement", "systems.projectManagement.kind",
            // Local-only approval detail.
            "approvals.restrictedRecipients",
            // Local model routing policy.
            "providers.localOnlyFor",
            // Mac-only feature switches.
            "features.screenCapture", "features.screenCapture.enabled",
            "features.screenCapture.excludedApps",
            "features.screenContext", "features.screenContext.enabled",
            "features.writingStyleLearning", "features.writingStyleLearning.enabled",
            "features.memoryExtraction", "features.memoryExtraction.enabled",
            "features.relationshipLearning", "features.relationshipLearning.enabled",
            "features.projectDetection", "features.projectDetection.enabled",
            "features.proactiveSuggestions", "features.proactiveSuggestions.enabled",
            "features.imessageBot", "features.imessageBot.enabled",
            "features.computerControl", "features.computerControl.enabled",
            "features.shellExecution", "features.shellExecution.enabled",
        ]

        // MARK: Subtree entries

        /// Dynamic-key containers whose entire contents are cloud-safe by construction. Each of these
        /// is a map the owner extends at will, so per-path enumeration is impossible.
        static let includeSubtree: [String] = [
            // Enum-keyed: OwnerConfig.ApprovalAction -> ApprovalPolicy. Both sides are closed enums.
            "approvals.policies",
            // Enum-keyed registers; `generate` filters to cloudEligible before emitting.
            "communication.registers",
            // Owner-authored vocabulary; free-form keys, values are labels.
            "vocabulary.terms",
            // Provider id -> model id.
            "providers.models",
            // SecretRef encodes as a single-key object, so the ref's child key must be covered.
            // These two are the ONLY refs the cloud resolves; both carry a pointer, never a value.
            "secrets.cloudBotToken", "secrets.cloudOwnerId",
        ]

        /// Whole domains that must never leave the Mac. Blanket exclusion is deliberate: the failure
        /// mode for a future field is "stays local", which is the safe direction.
        static let excludeSubtree: [String] = [
            "roots",                      // every filesystem path, unconditionally
            "governance",                 // classifications, retention, namespace policy
            "approvals.perApplication",   // bundle identifiers
            // Local migration provenance: which identity fields were carried over from the previous
            // owner and still need confirming. Purely a Mac-side bookkeeping record — the cloud has
            // no use for it and it names the previous setup.
            "migrationSeeded",
            // Mac-only secret references. Subtree so each ref's `keychainRef`/`environmentRef` child
            // is covered too.
            "secrets.telegramBotToken", "secrets.telegramOwnerId",
            "secrets.mailPrimary", "secrets.calendarPrimary",
        ]

        // MARK: Resolution

        /// Longest match wins; at equal length an exact entry beats a subtree entry. Returns nil when
        /// the path is unclassified, which `generate` turns into a hard failure.
        static func disposition(for path: String) -> Disposition? {
            var best: (length: Int, exact: Bool, disposition: Disposition)?

            func consider(_ entry: String, _ disposition: Disposition, exact: Bool) {
                let matched = exact ? (path == entry) : (path == entry || path.hasPrefix(entry + "."))
                guard matched else { return }
                if let current = best {
                    guard entry.count > current.length
                        || (entry.count == current.length && exact && !current.exact) else { return }
                }
                best = (entry.count, exact, disposition)
            }

            for entry in includeExact { consider(entry, .include, exact: true) }
            for entry in excludeExact { consider(entry, .exclude, exact: true) }
            for entry in includeSubtree { consider(entry, .include, exact: false) }
            for entry in excludeSubtree { consider(entry, .exclude, exact: false) }
            return best?.disposition
        }
    }

    /// Guard used by the validator: proves the registry never marks a filesystem root for the cloud.
    static var registryIncludesAnyRootPath: Bool {
        FieldRegistry.disposition(for: "roots") == .include
    }
}

// MARK: - PromptFieldPolicy

/// Which configuration paths may appear in a model prompt (OCS §10).
///
/// Allow-list, not deny-list. Anything not named here is invisible to the prompt builder, so a new
/// field is silent by default rather than accidentally rendered.
enum PromptFieldPolicy {

    /// Paths (or prefixes) the persona renderer is permitted to read.
    static let promptEligible: [String] = [
        "identity.fullName", "identity.preferredName", "identity.pronouns",
        "identity.roleTitle", "identity.organization", "identity.signOffName",
        "identity.timeZone", "identity.locale", "identity.dateFormat", "identity.timeFormat",
        "identity.workingHours", "identity.signatures",
        "professional.summaryLine", "professional.expertiseAreas", "professional.industries",
        "professional.categories", "professional.responsibilities", "professional.disciplines",
        "professional.terminology",
        "communication.global.rules", "communication.registers",
        "communication.voice.exemplars",     // drafting prompts only
        "vocabulary.terms", "vocabulary.milestoneTypes", "vocabulary.statusVocabulary",
    ]

    /// Never in a prompt, at any priority: approval policy is enforced in code and must not be
    /// negotiable with a model; roots and secrets are leaks; governance internals are noise.
    static let promptForbidden: [String] = [
        "roots", "secrets", "approvals", "governance", "providers", "systems",
        "professional.authority", "professional.team",
        "schemaVersion", "configId", "revision", "updatedAt", "updatedBy", "unknownFields",
    ]

    static func isPromptEligible(_ path: String) -> Bool {
        if promptForbidden.contains(where: { path == $0 || path.hasPrefix($0 + ".") }) { return false }
        return promptEligible.contains { path == $0 || path.hasPrefix($0 + ".") }
    }
}
