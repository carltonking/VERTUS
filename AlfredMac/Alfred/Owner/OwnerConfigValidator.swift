import Foundation

// MARK: - Validation result types (OCS §3)

/// One problem with a configuration. Carries enough for a UI to point at the exact field and for a
/// caller to decide whether the affected capability may start.
struct OwnerConfigIssue: Equatable, Sendable, CustomStringConvertible {
    enum Severity: String, Sendable, Comparable {
        /// Configuration cannot be saved or used.
        case error
        /// Usable, but something is missing or risky and the owner should see it.
        case warning
        var rank: Int { self == .error ? 1 : 0 }
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    /// Dotted path to the offending field, e.g. `identity.signOffName`.
    let path: String
    /// Machine-readable, stable across wording changes. Tests assert on this, never on `message`.
    let code: Code
    let message: String
    let severity: Severity
    /// Feature that must not start while this issue stands. nil = no feature-level consequence.
    let disablesFeature: Feature?

    enum Code: String, Sendable {
        case missingRequired, invalidEnum, tooLong, tooManyItems, invalidUUID
        case invalidTimeZone, invalidDate, invalidRevision, unsupportedSchemaVersion
        case danglingReference, duplicateIdentifier, invalidNamespace, invalidRootPath
        case invalidSecretRefShape, disallowedKeychainService, invalidEnvironmentName
        case secretValueInConfig, secretMarkedPromptEligible
        case rootInCloudProjection, confidentialMarkedCloudEligible
        case approvalBelowFloor, unknownApprovalAction, restrictedRootWritable
        case legacyOwnerNameRetained, registerInheritanceCycle, invalidRange, invalidFormat
        /// Top-level keys this build does not model. Preserved locally, never projected (H5).
        case unknownFieldsPreserved
        /// A value the legacy migration carried across that the owner has not confirmed yet.
        case migrationValueAwaitingConfirmation
        /// `migrationSeeded` names a field migration is not permitted to seed, or is empty.
        case invalidMigrationProvenance
    }

    /// Capability gated by an issue. Deliberately coarse — a missing sign-off blocks drafting, it
    /// does not block chat.
    enum Feature: String, Sendable {
        case emailDrafting, calendarWrites, cloudProjection, ownerProfileBlock, allOwnerConfig
    }

    var description: String { "[\(severity.rawValue)] \(path): \(message) (\(code.rawValue))" }
}

/// The full outcome of one validation pass. Always contains EVERY detected problem — validation never
/// stops at the first error, because a config with four missing fields should produce one round of
/// corrections rather than four.
struct OwnerConfigValidation: Equatable, Sendable {
    let issues: [OwnerConfigIssue]

    var errors: [OwnerConfigIssue] { issues.filter { $0.severity == .error } }
    var warnings: [OwnerConfigIssue] { issues.filter { $0.severity == .warning } }
    var isValid: Bool { errors.isEmpty }

    /// Features that must not start given these issues.
    var disabledFeatures: Set<OwnerConfigIssue.Feature> {
        Set(errors.compactMap(\.disablesFeature))
    }

    func isDisabled(_ feature: OwnerConfigIssue.Feature) -> Bool {
        disabledFeatures.contains(feature) || disabledFeatures.contains(.allOwnerConfig)
    }

    static let clean = OwnerConfigValidation(issues: [])
}

// MARK: - OwnerConfigValidator

/// Three layers, run in order, results merged (OCS §3):
///   1. Schema     — types, enums, lengths, formats.
///   2. Referential — do the ids actually resolve?
///   3. Policy     — invariants that exist to keep the system safe, not merely well-formed.
///
/// Pure and synchronous: no filesystem, no Keychain, no network. Root-path EXISTENCE is deliberately
/// not checked here so validation stays deterministic in tests and on a machine where a volume is
/// temporarily unmounted; shape and overbreadth are checked.
struct OwnerConfigValidator {

    /// The previous owner's name, read from legacy `UserDefaults` at construction. Passed in rather
    /// than hardcoded so no prior-owner literal ever appears in this subsystem's source.
    let legacyOwnerName: String?

    init(legacyOwnerName: String? = nil) {
        self.legacyOwnerName = legacyOwnerName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyOwnerValue
    }

    func validate(_ config: OwnerConfig) -> OwnerConfigValidation {
        var issues: [OwnerConfigIssue] = []
        issues += schemaIssues(config)
        issues += referentialIssues(config)
        issues += policyIssues(config)
        return OwnerConfigValidation(issues: issues)
    }

    // MARK: - Layer 1: schema

    private func schemaIssues(_ c: OwnerConfig) -> [OwnerConfigIssue] {
        var out: [OwnerConfigIssue] = []

        if c.schemaVersion != OwnerConfigDefaults.schemaVersion {
            out.append(.init(path: "schemaVersion", code: .unsupportedSchemaVersion,
                             message: "Schema version \(c.schemaVersion) is not supported by this build (expected \(OwnerConfigDefaults.schemaVersion)).",
                             severity: .error, disablesFeature: .allOwnerConfig))
        }
        if c.revision < 1 {
            out.append(.init(path: "revision", code: .invalidRevision,
                             message: "Revision must be 1 or greater.", severity: .error,
                             disablesFeature: .allOwnerConfig))
        }
        if c.updatedAt.timeIntervalSince1970 <= 0 {
            out.append(.init(path: "updatedAt", code: .invalidDate,
                             message: "Update timestamp is missing or invalid.", severity: .error,
                             disablesFeature: nil))
        }

        // Identity ------------------------------------------------------------------
        out += required(c.identity.fullName, "identity.fullName", max: 120,
                        disables: .ownerProfileBlock,
                        note: "The assistant needs a name before it can speak for anyone.")
        out += required(c.identity.preferredName, "identity.preferredName", max: 60,
                        disables: .ownerProfileBlock,
                        note: "What the assistant should call you.")
        out += required(c.identity.signOffName, "identity.signOffName", max: 60,
                        disables: .emailDrafting,
                        note: "Outgoing mail cannot be signed without this. Drafting stays disabled until it is set.")

        for (label, value) in [("subject", c.identity.pronouns.subject),
                               ("object", c.identity.pronouns.object),
                               ("possessive", c.identity.pronouns.possessive)] {
            let path = "identity.pronouns.\(label)"
            if value.trimmed.isEmpty {
                out.append(.init(path: path, code: .missingRequired,
                                 message: "Pronoun is required.", severity: .error,
                                 disablesFeature: .ownerProfileBlock))
            } else if value.count > 20 {
                out.append(.init(path: path, code: .tooLong,
                                 message: "Pronoun must be 20 characters or fewer.",
                                 severity: .error, disablesFeature: nil))
            }
        }

        out += optionalLength(c.identity.roleTitle, "identity.roleTitle", max: 120)
        out += optionalLength(c.identity.organization, "identity.organization", max: 120)

        if TimeZone(identifier: c.identity.timeZone) == nil {
            out.append(.init(path: "identity.timeZone", code: .invalidTimeZone,
                             message: "\"\(c.identity.timeZone)\" is not a recognized IANA time zone identifier.",
                             severity: .error, disablesFeature: .calendarWrites))
        } else if !c.identity.timeZoneConfirmed {
            out.append(.init(path: "identity.timeZone", code: .missingRequired,
                             message: "Time zone is a carried-over default and has not been confirmed. Calendar times depend on it.",
                             severity: .warning, disablesFeature: nil))
        }

        if let locale = c.identity.locale, Locale.identifier(.bcp47, from: locale).isEmpty {
            out.append(.init(path: "identity.locale", code: .invalidFormat,
                             message: "Locale must be a BCP-47 identifier.", severity: .error,
                             disablesFeature: nil))
        }

        if c.identity.signatures.count > 10 {
            out.append(.init(path: "identity.signatures", code: .tooManyItems,
                             message: "At most 10 signatures.", severity: .error, disablesFeature: nil))
        }
        for (i, sig) in c.identity.signatures.enumerated() {
            if sig.id.trimmed.isEmpty {
                out.append(.init(path: "identity.signatures[\(i)].id", code: .missingRequired,
                                 message: "Signature id is required.", severity: .error, disablesFeature: nil))
            }
            if sig.body.count > 1000 {
                out.append(.init(path: "identity.signatures[\(i)].body", code: .tooLong,
                                 message: "Signature body must be 1000 characters or fewer.",
                                 severity: .error, disablesFeature: nil))
            }
        }
        let sigIds = c.identity.signatures.map(\.id)
        if Set(sigIds).count != sigIds.count {
            out.append(.init(path: "identity.signatures", code: .duplicateIdentifier,
                             message: "Signature ids must be unique.", severity: .error, disablesFeature: nil))
        }

        for (i, w) in c.identity.workingHours.enumerated() {
            if !Self.isHHmm(w.start) || !Self.isHHmm(w.end) {
                out.append(.init(path: "identity.workingHours[\(i)]", code: .invalidFormat,
                                 message: "Working hours must use 24-hour HH:mm.", severity: .error,
                                 disablesFeature: nil))
            } else if w.start >= w.end {
                out.append(.init(path: "identity.workingHours[\(i)]", code: .invalidRange,
                                 message: "Start must be before end.", severity: .error, disablesFeature: nil))
            }
        }

        // Professional --------------------------------------------------------------
        out += optionalLength(c.professional.summaryLine, "professional.summaryLine", max: 240)
        out += limit(c.professional.expertiseAreas, "professional.expertiseAreas", maxItems: 20, maxEach: 60)
        out += limit(c.professional.industries, "professional.industries", maxItems: 10, maxEach: 60)
        out += limit(c.professional.categories, "professional.categories", maxItems: 20, maxEach: 60)
        out += limit(c.professional.responsibilities, "professional.responsibilities", maxItems: 20, maxEach: 200)
        out += limit(c.professional.disciplines, "professional.disciplines", maxItems: 15, maxEach: 60)

        // Communication -------------------------------------------------------------
        out += limit(c.communication.global.rules, "communication.global.rules", maxItems: 10, maxEach: 160)
        out += limit(c.communication.voice.exemplars, "communication.voice.exemplars", maxItems: 12, maxEach: 600)

        for (key, reg) in c.communication.registers.sorted(by: { $0.key < $1.key }) {
            let base = "communication.registers.\(key.rawValue)"
            if let f = reg.formality, !(1...5).contains(f) {
                out.append(.init(path: "\(base).formality", code: .invalidRange,
                                 message: "Formality must be 1–5.", severity: .error, disablesFeature: nil))
            }
            if let d = reg.directness, !(1...5).contains(d) {
                out.append(.init(path: "\(base).directness", code: .invalidRange,
                                 message: "Directness must be 1–5.", severity: .error, disablesFeature: nil))
            }
            out += limit(reg.avoidPhrases, "\(base).avoidPhrases", maxItems: 20, maxEach: 120)
            out += limit(reg.avoidClaims, "\(base).avoidClaims", maxItems: 20, maxEach: 200)
        }

        // Vocabulary ----------------------------------------------------------------
        if !Self.isSlug(c.vocabulary.namespace, maxLength: 16) {
            out.append(.init(path: "vocabulary.namespace", code: .invalidNamespace,
                             message: "Namespace must be a lowercase slug of 16 characters or fewer.",
                             severity: .error, disablesFeature: nil))
        }
        for (k, v) in c.vocabulary.terms where v.count > 40 {
            out.append(.init(path: "vocabulary.terms.\(k)", code: .tooLong,
                             message: "Term must be 40 characters or fewer.", severity: .error,
                             disablesFeature: nil))
        }

        // Approvals -----------------------------------------------------------------
        if !(0...3600).contains(c.approvals.duplicateActionWindowSec) {
            out.append(.init(path: "approvals.duplicateActionWindowSec", code: .invalidRange,
                             message: "Duplicate-action window must be 0–3600 seconds.",
                             severity: .error, disablesFeature: nil))
        }

        // Secret reference shapes ---------------------------------------------------
        for (path, ref) in c.secrets.all { out += secretRefIssues(ref, at: path) }
        for (i, acct) in c.systems.email.enumerated() {
            if let r = acct.accountRef { out += secretRefIssues(r, at: "systems.email[\(i)].accountRef") }
        }
        for (i, cal) in c.systems.calendar.enumerated() {
            if let r = cal.calendarRef { out += secretRefIssues(r, at: "systems.calendar[\(i)].calendarRef") }
        }
        if let r = c.systems.projectManagement.workspaceRef {
            out += secretRefIssues(r, at: "systems.projectManagement.workspaceRef")
        }
        for (i, ch) in c.systems.messagingChannels.enumerated() {
            if let r = ch.ownerRef { out += secretRefIssues(r, at: "systems.messagingChannels[\(i)].ownerRef") }
        }
        for (i, s) in c.systems.researchSources.enumerated() {
            if let r = s.credentialRef { out += secretRefIssues(r, at: "systems.researchSources[\(i)].credentialRef") }
        }

        return out
    }

    // MARK: - Layer 2: referential

    private func referentialIssues(_ c: OwnerConfig) -> [OwnerConfigIssue] {
        var out: [OwnerConfigIssue] = []
        let signatureIds = Set(c.identity.signatures.map(\.id))
        let classificationIds = Set(c.governance.classifications.map(\.id))
        let namespaces = Set(c.governance.namespaces)
        let applicationBundles = Set(c.systems.applications.compactMap(\.bundleId))

        // Registers must point at real signatures, and inheritance is exactly one level: a register
        // inherits from `global`, never from another register — so there is no cycle to detect, only
        // a self-reference to reject.
        for (key, reg) in c.communication.registers.sorted(by: { $0.key < $1.key }) {
            let base = "communication.registers.\(key.rawValue)"
            if let sigId = reg.signatureId, !signatureIds.contains(sigId) {
                out.append(.init(path: "\(base).signatureId", code: .danglingReference,
                                 message: "No signature with id \"\(sigId)\".", severity: .error,
                                 disablesFeature: .emailDrafting))
            }
            if reg.tone?.trimmed == key.rawValue {
                out.append(.init(path: "\(base).tone", code: .registerInheritanceCycle,
                                 message: "A register cannot define itself as its own source.",
                                 severity: .error, disablesFeature: nil))
            }
        }
        if !c.communication.registers.keys.contains(c.communication.global.defaultRegister) {
            out.append(.init(path: "communication.global.defaultRegister", code: .danglingReference,
                             message: "Default register is not defined.", severity: .error,
                             disablesFeature: .ownerProfileBlock))
        }

        // Roots reference classifications and namespaces.
        for root in c.roots.all {
            let base = "roots[\(root.path)]"
            if !classificationIds.contains(root.classification) {
                out.append(.init(path: "\(base).classification", code: .danglingReference,
                                 message: "Unknown classification \"\(root.classification)\".",
                                 severity: .error, disablesFeature: nil))
            }
            if !namespaces.contains(root.namespace) {
                out.append(.init(path: "\(base).namespace", code: .danglingReference,
                                 message: "Namespace \"\(root.namespace.rawValue)\" is not declared.",
                                 severity: .error, disablesFeature: nil))
            }
        }

        // Providers reference classifications.
        for id in c.providers.localOnlyFor where !classificationIds.contains(id) {
            out.append(.init(path: "providers.localOnlyFor", code: .danglingReference,
                             message: "Unknown classification \"\(id)\".", severity: .error,
                             disablesFeature: nil))
        }

        // Cross-namespace edges reference declared namespaces.
        for (i, edge) in c.governance.crossNamespaceReads.enumerated() {
            if !namespaces.contains(edge.from) || !namespaces.contains(edge.to) {
                out.append(.init(path: "governance.crossNamespaceReads[\(i)]", code: .danglingReference,
                                 message: "Edge references an undeclared namespace.", severity: .error,
                                 disablesFeature: nil))
            }
        }

        // Per-application approval overrides must name a configured application. Only checked when
        // applications are configured at all — an empty list means "not set up yet", not "invalid".
        if !applicationBundles.isEmpty {
            for bundle in c.approvals.perApplication.keys where !applicationBundles.contains(bundle) {
                out.append(.init(path: "approvals.perApplication.\(bundle)", code: .danglingReference,
                                 message: "No configured application with bundle id \"\(bundle)\".",
                                 severity: .warning, disablesFeature: nil))
            }
        }

        // Team members reference contacts. Contacts are not modelled in this package, so this is a
        // shape check only — a future package adds the contact store.
        for (i, member) in c.professional.team.enumerated() where member.contactRef.trimmed.isEmpty {
            out.append(.init(path: "professional.team[\(i)].contactRef", code: .missingRequired,
                             message: "Team member needs a contact reference.", severity: .error,
                             disablesFeature: nil))
        }

        let classIds = c.governance.classifications.map(\.id)
        if Set(classIds).count != classIds.count {
            out.append(.init(path: "governance.classifications", code: .duplicateIdentifier,
                             message: "Classification ids must be unique.", severity: .error,
                             disablesFeature: nil))
        }

        return out
    }

    // MARK: - Layer 3: policy invariants

    private func policyIssues(_ c: OwnerConfig) -> [OwnerConfigIssue] {
        var out: [OwnerConfigIssue] = []

        // (a) No secret VALUES anywhere in ordinary configuration. Scans every string in the encoded
        //     tree, so a credential pasted into a tone field or a rule is caught too.
        if let tree = try? JSONValue.from(c) {
            for s in tree.allStrings where SecretShapeScanner.looksLikeSecret(s) {
                out.append(.init(path: "<config>", code: .secretValueInConfig,
                                 message: "A value in the configuration looks like a credential. Store a secret reference instead.",
                                 severity: .error, disablesFeature: .allOwnerConfig))
                break   // one report is enough; never echo the offending value
            }
        }

        // (b) Approvals may tighten but never fall below the code floor.
        for action in OwnerConfig.ApprovalAction.allCases {
            let floor = OwnerConfigDefaults.approvalFloors[action] ?? .never
            guard let configured = c.approvals.policies[action] else {
                out.append(.init(path: "approvals.policies.\(action.rawValue)", code: .unknownApprovalAction,
                                 message: "No policy configured; this action fails closed (never allowed).",
                                 severity: .warning, disablesFeature: nil))
                continue
            }
            if configured < floor {
                out.append(.init(path: "approvals.policies.\(action.rawValue)", code: .approvalBelowFloor,
                                 message: "Policy \"\(configured.rawValue)\" is less restrictive than the required minimum \"\(floor.rawValue)\".",
                                 severity: .error, disablesFeature: .allOwnerConfig))
            }
        }
        for (bundle, policy) in c.approvals.perApplication {
            let floor = OwnerConfigDefaults.approvalFloors[.useComputerControl] ?? .never
            if policy < floor {
                out.append(.init(path: "approvals.perApplication.\(bundle)", code: .approvalBelowFloor,
                                 message: "Per-application policy is less restrictive than the computer-control minimum.",
                                 severity: .error, disablesFeature: .allOwnerConfig))
            }
        }
        for (key, reg) in c.communication.registers.sorted(by: { $0.key < $1.key }) {
            if let override = reg.approvalOverride {
                let floor = OwnerConfigDefaults.approvalFloors[.sendEmail] ?? .never
                if override < floor {
                    out.append(.init(path: "communication.registers.\(key.rawValue).approvalOverride",
                                     code: .approvalBelowFloor,
                                     message: "A register override may only tighten the send policy.",
                                     severity: .error, disablesFeature: .allOwnerConfig))
                }
            }
        }

        // (c) Confidential and regulated data may never be cloud-eligible.
        for cls in c.governance.classifications
        where OwnerConfig.Governance.alwaysLocalClassifications.contains(cls.id) && cls.cloudEligible {
            out.append(.init(path: "governance.classifications.\(cls.id).cloudEligible",
                             code: .confidentialMarkedCloudEligible,
                             message: "\"\(cls.id)\" data must not be cloud-eligible.",
                             severity: .error, disablesFeature: .cloudProjection))
        }

        // (d) Root paths must be specific. `/`, `~`, and the home directory are all too broad to be
        //     a meaningful scope and would hand the assistant the entire machine.
        for root in c.roots.all {
            if let issue = Self.rootPathIssue(root.path) {
                out.append(.init(path: "roots[\(root.path)].path", code: .invalidRootPath,
                                 message: issue, severity: .error, disablesFeature: nil))
            }
        }
        for root in c.roots.restricted where root.writable {
            out.append(.init(path: "roots.restricted[\(root.path)].writable", code: .restrictedRootWritable,
                             message: "A restricted root cannot be writable.", severity: .error,
                             disablesFeature: nil))
        }

        // (e) No local path may be reachable by the cloud. Enforced structurally by CloudProjection's
        //     whitelist; asserted here so a bad config is reported at validation time too.
        if !c.roots.all.isEmpty, CloudProjection.registryIncludesAnyRootPath {
            out.append(.init(path: "roots", code: .rootInCloudProjection,
                             message: "The cloud projection registry would expose a filesystem root.",
                             severity: .error, disablesFeature: .cloudProjection))
        }

        // (f) Secret references are never prompt-eligible. Structural: PromptFieldPolicy has no
        //     prompt-eligible path under `secrets`, so a violation is a programming error, not a
        //     configuration one — assert it rather than trusting the table by eye.
        for (path, _) in c.secrets.all where PromptFieldPolicy.isPromptEligible(path) {
            out.append(.init(path: path, code: .secretMarkedPromptEligible,
                             message: "A secret reference is marked prompt-eligible.", severity: .error,
                             disablesFeature: .allOwnerConfig))
        }

        // (g) Unknown top-level keys are legal but noteworthy: they are preserved locally and
        //     deliberately withheld from the cloud, so the projection is a partial view (H5).
        if let unknown = c.unknownFields, !unknown.isEmpty {
            out.append(.init(path: "<unknownFields>", code: .unknownFieldsPreserved,
                             message: "Configuration contains \(unknown.count) top-level field(s) this version doesn't understand (\(unknown.keys.sorted().joined(separator: ", "))). They are preserved but never sent to the cloud.",
                             severity: .warning, disablesFeature: nil))
        }

        // (h) Migration provenance must be well-formed, and only the fields it actually seeded may
        //     legitimately still hold the previous owner's name.
        if let seed = c.migrationSeeded {
            let allowed = OwnerConfigDefaults.allowedMigrationSeedPaths
            for path in seed.fields where !allowed.contains(path) {
                out.append(.init(path: "migrationSeeded.fields", code: .invalidMigrationProvenance,
                                 message: "\"\(path)\" is not a field the legacy migration is permitted to seed.",
                                 severity: .error, disablesFeature: .allOwnerConfig))
            }
            if seed.fields.isEmpty {
                out.append(.init(path: "migrationSeeded", code: .invalidMigrationProvenance,
                                 message: "Migration provenance is present but lists no fields; clear it instead.",
                                 severity: .error, disablesFeature: nil))
            }
        }

        // (i) The previous owner's name must not survive anywhere EXCEPT in a field whose migration
        //     provenance says it was carried across and is still awaiting confirmation.
        //
        //     Provenance, not a path list. The previous version exempted a hardcoded set of two
        //     paths; when migration began seeding a third (`signOffName`), the two disagreed and
        //     production migration failed outright. `migrationSeeded` is written by the operation
        //     that does the seeding, so it cannot drift.
        //
        //     KNOWN LIMITATION (deferred): this walk reads only scalar leaves, so a name inside an
        //     array element or a dictionary KEY is not seen, and matching is substring rather than
        //     word-boundary, so a short legacy name can flag a longer unrelated one. Replacing this
        //     scanner wholesale is out of scope for this package.
        if let legacy = legacyOwnerName, let tree = try? JSONValue.from(c) {
            for path in tree.leafPaths() {
                guard let value = tree.value(at: path)?.stringValue,
                      value.localizedCaseInsensitiveContains(legacy) else { continue }

                // Exempt only when provenance covers THIS field and the value is still the carried
                // one. Once the owner edits it, the value no longer matches and no exemption is
                // needed; once they confirm it, the path leaves the seed set.
                let carriedOver = c.migrationSeeded?.contains(path) == true
                    && value.trimmed.caseInsensitiveCompare(legacy) == .orderedSame

                if carriedOver {
                    out.append(.init(path: path, code: .migrationValueAwaitingConfirmation,
                                     message: "Carried over from your previous setup during migration. Confirm or change it.",
                                     severity: .warning, disablesFeature: nil))
                } else {
                    out.append(.init(path: path, code: .legacyOwnerNameRetained,
                                     message: "Contains the previous owner's name.",
                                     severity: .error, disablesFeature: .ownerProfileBlock))
                }
            }
        }

        return out
    }

    // MARK: - Helpers

    private func secretRefIssues(_ ref: SecretRef, at path: String) -> [OwnerConfigIssue] {
        switch ref {
        case let .keychain(service, account):
            var out: [OwnerConfigIssue] = []
            if !SecretRef.allowedKeychainServices.contains(service) {
                out.append(.init(path: "\(path).service", code: .disallowedKeychainService,
                                 message: "Keychain service \"\(service)\" is not allowlisted.",
                                 severity: .error, disablesFeature: nil))
            }
            if !Self.matches(account, SecretRef.keychainAccountPattern) {
                out.append(.init(path: "\(path).account", code: .invalidSecretRefShape,
                                 message: "Keychain account name has an unsupported shape.",
                                 severity: .error, disablesFeature: nil))
            }
            return out
        case let .environment(name):
            guard Self.matches(name, SecretRef.environmentNamePattern) else {
                return [.init(path: path, code: .invalidEnvironmentName,
                              message: "Environment variable names must be uppercase (A–Z, 0–9, _).",
                              severity: .error, disablesFeature: nil)]
            }
            return []
        case let .secretId(id):
            guard Self.matches(id, SecretRef.secretIdPattern) else {
                return [.init(path: path, code: .invalidSecretRefShape,
                              message: "Secret id has an unsupported shape.", severity: .error,
                              disablesFeature: nil)]
            }
            return []
        }
    }

    private func required(_ value: String?, _ path: String, max: Int,
                          disables: OwnerConfigIssue.Feature?, note: String) -> [OwnerConfigIssue] {
        guard let v = value?.trimmed, !v.isEmpty else {
            return [.init(path: path, code: .missingRequired, message: note,
                          severity: .error, disablesFeature: disables)]
        }
        if v.count > max {
            return [.init(path: path, code: .tooLong,
                          message: "Must be \(max) characters or fewer.", severity: .error,
                          disablesFeature: nil)]
        }
        return []
    }

    private func optionalLength(_ value: String?, _ path: String, max: Int) -> [OwnerConfigIssue] {
        guard let v = value, v.count > max else { return [] }
        return [.init(path: path, code: .tooLong,
                      message: "Must be \(max) characters or fewer.", severity: .error,
                      disablesFeature: nil)]
    }

    private func limit(_ items: [String], _ path: String, maxItems: Int, maxEach: Int) -> [OwnerConfigIssue] {
        var out: [OwnerConfigIssue] = []
        if items.count > maxItems {
            out.append(.init(path: path, code: .tooManyItems,
                             message: "At most \(maxItems) entries.", severity: .error, disablesFeature: nil))
        }
        for (i, item) in items.enumerated() where item.count > maxEach {
            out.append(.init(path: "\(path)[\(i)]", code: .tooLong,
                             message: "Must be \(maxEach) characters or fewer.", severity: .error,
                             disablesFeature: nil))
        }
        return out
    }

    static func rootPathIssue(_ path: String) -> String? {
        let trimmed = path.trimmed
        if trimmed.isEmpty { return "Path is empty." }
        if !trimmed.hasPrefix("/") { return "Path must be absolute." }
        let normalized = (trimmed as NSString).standardizingPath
        let home = NSHomeDirectory()
        if normalized == "/" { return "The filesystem root is too broad to be a scope." }
        if normalized == home { return "The entire home directory is too broad to be a scope." }
        let overbroad = ["/Users", "/Volumes", "/System", "/Library", "/Applications", "/private"]
        if overbroad.contains(normalized) { return "\"\(normalized)\" is too broad to be a scope." }
        if normalized.contains("..") { return "Path must not contain traversal segments." }
        return nil
    }

    static func isHHmm(_ s: String) -> Bool { matches(s, "^([01][0-9]|2[0-3]):[0-5][0-9]$") }

    static func isSlug(_ s: String, maxLength: Int) -> Bool {
        !s.isEmpty && s.count <= maxLength && matches(s, "^[a-z][a-z0-9-]*$")
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - SecretShapeScanner

/// Recognizes strings that LOOK like credentials, so one cannot be pasted into an ordinary
/// configuration field. Shape-based and deliberately conservative: it exists to catch an accident,
/// not to be an exhaustive credential detector.
enum SecretShapeScanner {
    private static let patterns = [
        "^sk-[A-Za-z0-9_-]{16,}$",          // OpenAI-style
        "^sk-ant-[A-Za-z0-9_-]{16,}$",      // Anthropic
        "^sk-or-[A-Za-z0-9_-]{16,}$",       // OpenRouter
        "^gsk_[A-Za-z0-9]{16,}$",           // Groq
        "^ghp_[A-Za-z0-9]{16,}$",           // GitHub PAT
        "^github_pat_[A-Za-z0-9_]{20,}$",
        "^AIza[A-Za-z0-9_-]{20,}$",         // Google
        "^xox[baprs]-[A-Za-z0-9-]{10,}$",   // Slack
        "^csk-[A-Za-z0-9_-]{16,}$",         // Cerebras
        "^[0-9]{6,}:[A-Za-z0-9_-]{30,}$",   // Telegram bot token
        "(?i)^bearer\\s+[A-Za-z0-9._-]{20,}$",
        "(?i)\\b(api[_ -]?key|secret|password|token)\\b\\s*[:=]\\s*\\S{8,}",
    ]

    static func looksLikeSecret(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 12 else { return false }
        return patterns.contains { OwnerConfigValidator.matches(t, $0) }
    }
}

// MARK: - Small string helpers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Treats an empty/whitespace owner value as absent.
    var nilIfEmptyOwnerValue: String? { trimmed.isEmpty ? nil : trimmed }
    /// True when the value is empty once surrounding whitespace is ignored.
    var isEmptyAfterTrim: Bool { trimmed.isEmpty }
}
