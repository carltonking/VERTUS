import Foundation

// MARK: - Owner Configuration (OCS §5)
//
// The single canonical, HUMAN-AUTHORED description of who the assistant works for. Everything the
// owner deliberately decided lives here; everything the assistant merely observed lives in the
// learned stores and may never contradict this file (OCS §4, tiers T1 vs T2/T3).
//
// Design notes that matter when editing this file:
//  • Optionality IS the incompleteness model. There is no "REQUIRES_USER_INPUT" sentinel stored on
//    disk — an unanswered question is `nil`, and the validator turns it into a named error. Sentinel
//    strings would eventually be rendered into a prompt as if they were the owner's real name.
//  • Enums, not free strings, wherever the schema fixes the allowed values, so a typo fails at
//    decode time instead of silently changing behaviour.
//  • Deterministic encoding (sorted keys) so two revisions can be diffed and asserted in tests.
//  • Unknown TOP-LEVEL keys survive a decode/encode round-trip, so a newer build's config isn't
//    destroyed by an older one. Unknown keys nested inside a known domain are not preserved — see
//    `unknownFields` for the boundary.

struct OwnerConfig: Codable, Equatable, Sendable {

    // MARK: Envelope

    /// Major version drives compatibility: a runtime rejects a major it does not know (OCS §12).
    var schemaVersion: Int
    /// Stable identity of this configuration across revisions; also stamped into the cloud projection.
    var configId: UUID
    /// Monotonic. Restoring an old revision writes a NEW revision — the counter never rewinds.
    var revision: Int
    var updatedAt: Date
    var updatedBy: UpdateSource

    enum UpdateSource: String, Codable, Sendable, CaseIterable {
        case user, onboarding, migration, restore, recovery
    }

    /// Provenance for values the one-time legacy migration carried across, and which the owner has
    /// not yet confirmed. Present only between migration and confirmation.
    ///
    /// This replaces the previous approach of exempting a hardcoded list of field PATHS from the
    /// previous-owner-name check. That list drifted out of step with what migration actually seeds —
    /// the correction package added `signOffName` to the seeding without adding it here, so in
    /// production (where the validator is constructed with the real legacy name) the seeded sign-off
    /// was reported as illegal retention and migration failed. Provenance is recorded by the
    /// operation that creates it, so the two cannot disagree.
    var migrationSeeded: MigrationSeed?

    struct MigrationSeed: Codable, Equatable, Sendable {
        /// Field paths seeded by migration and still awaiting confirmation. Constrained by the
        /// validator to `OwnerConfigDefaults.allowedMigrationSeedPaths`; anything else is an error.
        var fields: [String]
        var seededAt: Date

        init(fields: [String], seededAt: Date) {
            self.fields = fields.sorted()      // deterministic encoding
            self.seededAt = seededAt
        }

        func contains(_ path: String) -> Bool { fields.contains(path) }

        /// Drop a field once the owner confirms it. When nothing is left, the caller clears the
        /// whole record so the configuration carries no lingering migration state.
        func confirming(_ path: String) -> MigrationSeed? {
            let remaining = fields.filter { $0 != path }
            return remaining.isEmpty ? nil : MigrationSeed(fields: remaining, seededAt: seededAt)
        }
    }

    // MARK: Domains

    var identity: Identity
    var professional: Professional
    var communication: Communication
    var systems: Systems
    var roots: Roots
    var vocabulary: Vocabulary
    var approvals: Approvals
    var governance: Governance
    var features: Features
    var providers: Providers
    var secrets: Secrets

    /// Top-level keys written by a newer schema version that this build does not model. Carried
    /// through unchanged so a downgrade-then-upgrade cycle is lossless.
    var unknownFields: [String: JSONValue]?

    // MARK: - A. Identity

    struct Identity: Codable, Equatable, Sendable {
        var fullName: String?
        var preferredName: String?
        var pronouns: Pronouns
        var roleTitle: String?
        var organization: String?
        /// Blocks email drafting while nil — the assistant must never guess how to sign for someone.
        var signOffName: String?
        var signatures: [Signature]
        var timeZone: String
        /// True until the owner explicitly confirms the zone. The default is a carried-over guess, and
        /// a guessed time zone silently corrupts every event it writes.
        var timeZoneConfirmed: Bool
        var locale: String?
        var dateFormat: DateFormatStyle
        var timeFormat: TimeFormatStyle
        var workingHours: [DayWindow]
        var outOfHoursPolicy: OutOfHoursPolicy

        struct Pronouns: Codable, Equatable, Sendable {
            var subject: String
            var object: String
            var possessive: String

            /// Neutral until stated. A name never implies pronouns, and a wrong guess misgenders a
            /// real person in a way this default cannot.
            static let neutral = Pronouns(subject: "they", object: "them", possessive: "their")
        }

        struct Signature: Codable, Equatable, Sendable, Identifiable {
            var id: String
            var label: String?
            var body: String
        }

        struct DayWindow: Codable, Equatable, Sendable {
            var day: Weekday
            /// "HH:mm", 24-hour.
            var start: String
            var end: String
        }

        enum Weekday: String, Codable, Sendable, CaseIterable {
            case monday, tuesday, wednesday, thursday, friday, saturday, sunday
        }

        enum DateFormatStyle: String, Codable, Sendable, CaseIterable { case iso, us, eu, long }
        enum TimeFormatStyle: String, Codable, Sendable, CaseIterable { case h24, h12
            /// Encoded as "24h"/"12h" to match the specification's wire format.
            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                switch raw {
                case "24h": self = .h24
                case "12h": self = .h12
                default: throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "timeFormat must be \"24h\" or \"12h\", got \"\(raw)\"."))
                }
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                try c.encode(self == .h24 ? "24h" : "12h")
            }
            var promptLabel: String { self == .h24 ? "24-hour (14:30)" : "12-hour (2:30 PM)" }
        }

        enum OutOfHoursPolicy: String, Codable, Sendable, CaseIterable { case queue, notify, silent }
    }

    // MARK: - B. Professional

    struct Professional: Codable, Equatable, Sendable {
        /// One sentence describing the owner's work. Replaces the hardcoded biography that currently
        /// lives in the cloud briefing prompt.
        var summaryLine: String?
        var expertiseAreas: [String]
        var industries: [String]
        var categories: [String]
        var responsibilities: [String]
        var authority: Authority
        var team: [TeamMember]
        var terminology: [Term]
        var disciplines: [String]

        struct Authority: Codable, Equatable, Sendable {
            var canCommitBudget: AuthorityLevel
            var canApproveArtwork: AuthorityLevel
            var canSignOffProduction: AuthorityLevel
            var canCommitDates: AuthorityLevel
        }

        enum AuthorityLevel: String, Codable, Sendable, CaseIterable { case yes, no, withApproval }

        struct TeamMember: Codable, Equatable, Sendable {
            var contactRef: String
            var relationship: Relationship
        }

        enum Relationship: String, Codable, Sendable, CaseIterable {
            case manager, peer, report, dotted, external
        }

        struct Term: Codable, Equatable, Sendable {
            var term: String
            var definition: String
            var aliases: [String]?
        }
    }

    // MARK: - C. Communication

    struct Communication: Codable, Equatable, Sendable {
        var global: Global
        var voice: Voice
        var registers: [RegisterKey: Register]

        struct Global: Codable, Equatable, Sendable {
            /// Authored formatting rules. The learned equivalent (ResponseStylePreferenceStore) stays
            /// separate and sits BELOW this in the prompt.
            var rules: [String]
            var defaultRegister: RegisterKey
        }

        struct Voice: Codable, Equatable, Sendable {
            var mode: VoiceMode
            /// Owner-approved sample messages. Local only — never projected to the cloud.
            var exemplars: [String]
            var learnFromSent: Bool
        }

        enum VoiceMode: String, Codable, Sendable, CaseIterable { case curated, learned, off }

        enum RegisterKey: String, Codable, Sendable, CaseIterable, Comparable {
            case internalPeer, directReport, executive, client
            case vendor, printerFactory, recruiterCandidate, personal
            static func < (a: RegisterKey, b: RegisterKey) -> Bool { a.rawValue < b.rawValue }
        }

        /// One audience's voice. Every field is optional so a register can specify only what differs
        /// from the global default — exactly one level of inheritance, no chains (OCS P12).
        struct Register: Codable, Equatable, Sendable {
            var tone: String?
            var formality: Int?
            var typicalLength: Length?
            var greeting: String?
            var signOff: String?
            var signatureId: String?
            var directness: Int?
            var useBullets: BulletUsage?
            var technicalDetail: TechnicalDetail?
            var avoidPhrases: [String]
            var avoidClaims: [String]
            /// May only TIGHTEN the global approval policy for this audience.
            var approvalOverride: ApprovalPolicy?
            /// False keeps this register out of the cloud projection entirely.
            var cloudEligible: Bool

            init(tone: String? = nil, formality: Int? = nil, typicalLength: Length? = nil,
                 greeting: String? = nil, signOff: String? = nil, signatureId: String? = nil,
                 directness: Int? = nil, useBullets: BulletUsage? = nil,
                 technicalDetail: TechnicalDetail? = nil, avoidPhrases: [String] = [],
                 avoidClaims: [String] = [], approvalOverride: ApprovalPolicy? = nil,
                 cloudEligible: Bool = true) {
                self.tone = tone; self.formality = formality; self.typicalLength = typicalLength
                self.greeting = greeting; self.signOff = signOff; self.signatureId = signatureId
                self.directness = directness; self.useBullets = useBullets
                self.technicalDetail = technicalDetail; self.avoidPhrases = avoidPhrases
                self.avoidClaims = avoidClaims; self.approvalOverride = approvalOverride
                self.cloudEligible = cloudEligible
            }
        }

        enum Length: String, Codable, Sendable, CaseIterable { case oneLine, short, medium, long }
        enum BulletUsage: String, Codable, Sendable, CaseIterable { case never, whenListing, freely }
        enum TechnicalDetail: String, Codable, Sendable, CaseIterable { case minimal, working, deep }
    }

    // MARK: - D. Systems

    struct Systems: Codable, Equatable, Sendable {
        var email: [MailAccount]
        var calendar: [CalendarAccount]
        var projectManagement: ProjectManagement
        var fileStorage: [FileStore]
        var applications: [Application]
        var adobe: Adobe
        var rhino: InstallState
        var researchSources: [ResearchSource]
        var messagingChannels: [MessagingChannel]

        struct MailAccount: Codable, Equatable, Sendable {
            var provider: MailProvider
            var accountRef: SecretRef?
            var role: Namespace
            var capabilities: [MailCapability]
        }
        enum MailProvider: String, Codable, Sendable, CaseIterable {
            case appleMail, gmail, outlook, imap
        }
        enum MailCapability: String, Codable, Sendable, CaseIterable { case read, draft, send }

        struct CalendarAccount: Codable, Equatable, Sendable {
            var provider: CalendarProvider
            var calendarRef: SecretRef?
            var role: Namespace
            /// Defaults false. Guards the CalDAV PUT/DELETE paths once approvals are wired.
            var writeAllowed: Bool
        }
        enum CalendarProvider: String, Codable, Sendable, CaseIterable {
            case appleCalendar, caldav, google, outlook
        }

        struct ProjectManagement: Codable, Equatable, Sendable {
            var kind: PMKind
            var workspaceRef: SecretRef?
        }
        enum PMKind: String, Codable, Sendable, CaseIterable { case none, asana, other }

        struct FileStore: Codable, Equatable, Sendable {
            var provider: String
            var mountPath: String
            var role: Namespace
        }

        struct Application: Codable, Equatable, Sendable {
            var name: String
            var bundleId: String?
            /// `none` keeps an app out of any future computer-control allowlist.
            var automation: AutomationLevel
        }
        enum AutomationLevel: String, Codable, Sendable, CaseIterable { case none, inspect, control }

        struct Adobe: Codable, Equatable, Sendable {
            var illustrator: InstallState
            var photoshop: InstallState
            var indesign: InstallState
            var acrobat: InstallState
        }
        enum InstallState: String, Codable, Sendable, CaseIterable {
            case absent, installed, scriptingEnabled
        }

        struct ResearchSource: Codable, Equatable, Sendable {
            var name: String
            var kind: String
            var credentialRef: SecretRef?
        }

        struct MessagingChannel: Codable, Equatable, Sendable {
            var kind: ChannelKind
            var enabled: Bool
            var ownerRef: SecretRef?
        }
        enum ChannelKind: String, Codable, Sendable, CaseIterable { case telegram, imessage, slack }
    }

    /// Namespace tag. Personal and work never mix unless `governance.crossNamespaceReads` says so.
    enum Namespace: String, Codable, Equatable, Sendable, CaseIterable { case work, personal }

    // MARK: - E. Roots
    //
    // Local filesystem scopes. NEVER projected to the cloud and NEVER placed in a prompt: a path is
    // both an information leak and an instruction-injection surface.

    struct Roots: Codable, Equatable, Sendable {
        var projectRoots: [Root]
        var artworkArchive: Root?
        var brandLibrary: Root?
        var productionTemplates: Root?
        var printerSpecs: Root?
        var research: Root?
        var output: Root?
        var personal: [Root]
        var restricted: [Root]
        var localModelOnly: [Root]
        var cloudPermitted: [Root]

        struct Root: Codable, Equatable, Sendable {
            var path: String
            var label: String?
            var classification: String
            var namespace: Namespace
            var readable: Bool
            var writable: Bool

            init(path: String, label: String? = nil, classification: String = "internal",
                 namespace: Namespace = .work, readable: Bool = true, writable: Bool = false) {
                self.path = path; self.label = label; self.classification = classification
                self.namespace = namespace; self.readable = readable; self.writable = writable
            }
        }

        /// Every root in one sequence, for validation and leak tests.
        var all: [Root] {
            projectRoots + personal + restricted + localModelOnly + cloudPermitted
                + [artworkArchive, brandLibrary, productionTemplates, printerSpecs, research, output]
                    .compactMap { $0 }
        }
    }

    // MARK: - F. Vocabulary

    struct Vocabulary: Codable, Equatable, Sendable {
        /// URL-scheme segment for tagged calendar items. Replaces the hardcoded "school" namespace.
        var namespace: String
        var terms: [String: String]
        var milestoneTypes: [MilestoneType]
        var statusVocabulary: [String]
        var approvalStages: [ApprovalStage]

        struct MilestoneType: Codable, Equatable, Sendable {
            var id: String
            var label: String
            var defaultLeadDays: Int?
        }

        struct ApprovalStage: Codable, Equatable, Sendable {
            var id: String
            var label: String
            var blocksRelease: Bool
        }

        /// Keys the UI and prompts expect in `terms`. Values are owner-authored, never assumed.
        static let termKeys = ["project", "brand", "program", "sku", "variant",
                               "mechanical", "dieline", "productionFile", "release"]
    }

    // MARK: - G. Approvals

    struct Approvals: Codable, Equatable, Sendable {
        var policies: [ApprovalAction: ApprovalPolicy]
        var neverAllowed: [ApprovalAction]
        var perApplication: [String: ApprovalPolicy]
        var restrictedRecipients: [String]
        var requireRecipientDisplay: Bool
        var duplicateActionWindowSec: Int

        /// Effective policy: an explicit deny wins, then the table, then fail closed.
        func policy(for action: ApprovalAction) -> ApprovalPolicy {
            if neverAllowed.contains(action) { return .never }
            return policies[action] ?? .never
        }
    }

    /// Every consequential action the assistant can take. Unknown actions fail closed by construction:
    /// there is no `default` case, so adding a capability forces a policy decision at compile time.
    enum ApprovalAction: String, Codable, Sendable, CaseIterable, Comparable {
        case read, summarize, draft, saveDraft
        case createTask, modifyTask
        case createCalendarEvent, modifyCalendarEvent, bulkCalendarDelete
        case sendEmail, sendMessage
        case moveFile, renameFile, deleteFile
        case modifySourceArtwork
        case runIllustratorScript, runPhotoshopAutomation, runRhinoAutomation
        case useComputerControl, runShellCommand
        case uploadFileExternally, shareConfidentialInformation
        static func < (a: ApprovalAction, b: ApprovalAction) -> Bool { a.rawValue < b.rawValue }
    }

    /// Ordered from most permissive to most restrictive. `rank` powers the "config may tighten but
    /// never loosen below the code floor" invariant.
    enum ApprovalPolicy: String, Codable, Sendable, CaseIterable, Comparable {
        case auto, userInitiated, preview, confirm, doubleConfirm, never

        var rank: Int {
            switch self {
            case .auto: return 0
            case .userInitiated: return 1
            case .preview: return 2
            case .confirm: return 3
            case .doubleConfirm: return 4
            case .never: return 5
            }
        }
        static func < (a: ApprovalPolicy, b: ApprovalPolicy) -> Bool { a.rank < b.rank }
    }

    // MARK: - H. Governance

    struct Governance: Codable, Equatable, Sendable {
        var classifications: [Classification]
        var provenanceRequired: Bool
        var memoryApproval: MemoryApproval
        var namespaces: [Namespace]
        var crossNamespaceReads: [NamespaceEdge]
        var retention: [String: Int?]
        var deletionCascades: Bool

        struct Classification: Codable, Equatable, Sendable {
            var id: String
            var label: String
            var cloudEligible: Bool
            /// nil = keep forever; the validator requires that to be a deliberate choice.
            var retentionDays: Int?
        }

        struct NamespaceEdge: Codable, Equatable, Sendable {
            var from: Namespace
            var to: Namespace
        }

        /// Classification ids that must never be cloud-eligible.
        static let alwaysLocalClassifications: Set<String> = ["confidential", "regulated"]
    }

    enum MemoryApproval: String, Codable, Sendable, CaseIterable {
        case always, batchReview, never
    }

    // MARK: - I. Features

    struct Features: Codable, Equatable, Sendable {
        var screenCapture: ScreenCapture
        var screenContext: Toggle
        var writingStyleLearning: Toggle
        var memoryExtraction: Toggle
        var relationshipLearning: Toggle
        var projectDetection: Toggle
        var proactiveSuggestions: Toggle
        var telegram: Toggle
        var imessageBot: Toggle
        var computerControl: Toggle
        var shellExecution: Toggle
        var liveLocation: Toggle
        var morningBriefing: MorningBriefing
        var routineExecution: Toggle

        struct Toggle: Codable, Equatable, Sendable {
            var enabled: Bool
            init(_ enabled: Bool) { self.enabled = enabled }
        }

        struct ScreenCapture: Codable, Equatable, Sendable {
            var enabled: Bool
            /// Bundle-id / app-name substrings never captured. Seeded from the existing
            /// ScreenTextMonitor exclusions so the current protection is preserved.
            var excludedApps: [String]
        }

        struct MorningBriefing: Codable, Equatable, Sendable {
            var enabled: Bool
            var topics: [String]
            var sections: [String]
            /// "HH:mm" local. nil while unconfigured — the feature stays off.
            var sendLocalTime: String?
        }
    }

    // MARK: - Providers

    struct Providers: Codable, Equatable, Sendable {
        var chain: [String]
        var models: [String: String]
        /// Classification ids that must be answered by a local model only.
        var localOnlyFor: [String]
    }

    // MARK: - Secrets (references only)

    struct Secrets: Codable, Equatable, Sendable {
        var telegramBotToken: SecretRef?
        var telegramOwnerId: SecretRef?
        var cloudBotToken: SecretRef?
        var cloudOwnerId: SecretRef?
        var mailPrimary: SecretRef?
        var calendarPrimary: SecretRef?

        var all: [(path: String, ref: SecretRef)] {
            [("telegramBotToken", telegramBotToken), ("telegramOwnerId", telegramOwnerId),
             ("cloudBotToken", cloudBotToken), ("cloudOwnerId", cloudOwnerId),
             ("mailPrimary", mailPrimary), ("calendarPrimary", calendarPrimary)]
                .compactMap { name, ref in ref.map { (path: "secrets.\(name)", ref: $0) } }
        }
    }

    // MARK: - Forward-compatible coding

    /// Internal (not private) so `knownTopLevelKeys` can enumerate it for unknown-key preservation.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, configId, revision, updatedAt, updatedBy, migrationSeeded
        case identity, professional, communication, systems, roots, vocabulary
        case approvals, governance, features, providers, secrets
    }

    /// Every key this build models. Anything else found at the top level is preserved verbatim.
    static let knownTopLevelKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        configId      = try c.decode(UUID.self, forKey: .configId)
        revision      = try c.decode(Int.self, forKey: .revision)
        updatedAt     = try c.decode(Date.self, forKey: .updatedAt)
        updatedBy     = try c.decode(UpdateSource.self, forKey: .updatedBy)
        migrationSeeded = try c.decodeIfPresent(MigrationSeed.self, forKey: .migrationSeeded)

        let d = OwnerConfigDefaults.blank
        identity      = try c.decodeIfPresent(Identity.self,      forKey: .identity)      ?? d.identity
        professional  = try c.decodeIfPresent(Professional.self,  forKey: .professional)  ?? d.professional
        communication = try c.decodeIfPresent(Communication.self, forKey: .communication) ?? d.communication
        systems       = try c.decodeIfPresent(Systems.self,       forKey: .systems)       ?? d.systems
        roots         = try c.decodeIfPresent(Roots.self,         forKey: .roots)         ?? d.roots
        vocabulary    = try c.decodeIfPresent(Vocabulary.self,    forKey: .vocabulary)    ?? d.vocabulary
        approvals     = try c.decodeIfPresent(Approvals.self,     forKey: .approvals)     ?? d.approvals
        governance    = try c.decodeIfPresent(Governance.self,    forKey: .governance)    ?? d.governance
        features      = try c.decodeIfPresent(Features.self,      forKey: .features)      ?? d.features
        providers     = try c.decodeIfPresent(Providers.self,     forKey: .providers)     ?? d.providers
        secrets       = try c.decodeIfPresent(Secrets.self,       forKey: .secrets)       ?? d.secrets

        // Preserve top-level keys a newer schema added, so an older build can't silently drop them.
        let raw = try decoder.singleValueContainer().decode(JSONValue.self)
        if case let .object(fields) = raw {
            let extras = fields.filter { !Self.knownTopLevelKeys.contains($0.key) }
            unknownFields = extras.isEmpty ? nil : extras
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(configId, forKey: .configId)
        try c.encode(revision, forKey: .revision)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
        try c.encodeIfPresent(migrationSeeded, forKey: .migrationSeeded)
        try c.encode(identity, forKey: .identity)
        try c.encode(professional, forKey: .professional)
        try c.encode(communication, forKey: .communication)
        try c.encode(systems, forKey: .systems)
        try c.encode(roots, forKey: .roots)
        try c.encode(vocabulary, forKey: .vocabulary)
        try c.encode(approvals, forKey: .approvals)
        try c.encode(governance, forKey: .governance)
        try c.encode(features, forKey: .features)
        try c.encode(providers, forKey: .providers)
        try c.encode(secrets, forKey: .secrets)

        // Unknown top-level keys are re-emitted alongside the modelled ones.
        if let unknownFields, !unknownFields.isEmpty {
            var dyn = encoder.container(keyedBy: JSONValue.DynamicKey.self)
            for (key, value) in unknownFields.sorted(by: { $0.key < $1.key }) {
                guard let k = JSONValue.DynamicKey(stringValue: key) else { continue }
                try dyn.encode(value, forKey: k)
            }
        }
    }

    /// Memberwise init (Codable conformance above suppresses the synthesized one).
    init(schemaVersion: Int, configId: UUID, revision: Int, updatedAt: Date, updatedBy: UpdateSource,
         migrationSeeded: MigrationSeed? = nil,
         identity: Identity, professional: Professional, communication: Communication,
         systems: Systems, roots: Roots, vocabulary: Vocabulary, approvals: Approvals,
         governance: Governance, features: Features, providers: Providers, secrets: Secrets,
         unknownFields: [String: JSONValue]? = nil) {
        self.schemaVersion = schemaVersion; self.configId = configId; self.revision = revision
        self.updatedAt = updatedAt; self.updatedBy = updatedBy
        self.migrationSeeded = migrationSeeded
        self.identity = identity; self.professional = professional
        self.communication = communication; self.systems = systems; self.roots = roots
        self.vocabulary = vocabulary; self.approvals = approvals; self.governance = governance
        self.features = features; self.providers = providers; self.secrets = secrets
        self.unknownFields = unknownFields
    }
}

// MARK: - Deterministic coding

extension OwnerConfig {
    /// Sorted keys + ISO8601 dates so two encodings of equal values are byte-identical. Revision
    /// diffing and snapshot tests depend on this.
    ///
    /// # Date fidelity
    ///
    /// The plain `.iso8601` strategy emits whole seconds, so a `Date` carrying sub-second precision
    /// did not survive a round-trip: `…288.8529` came back as `…288.0`, and `config == reloaded` was
    /// therefore false for every configuration ever saved. Two changes fix that together:
    ///
    ///  1. Encoding includes fractional seconds (millisecond resolution, the most ISO-8601 carries).
    ///  2. Every timestamp the store stamps is rounded to that same resolution first
    ///     (`Date.ownerConfigStoragePrecision`), so the in-memory value already equals what will be
    ///     read back. Without step 2, sub-millisecond digits would still be lost.
    ///
    /// Decoding accepts BOTH forms, so configurations written before this change still load.
    static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.iso8601Fractional.string(from: date))
        }
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Fractional first (current format), then whole-second (legacy files).
            if let date = Self.iso8601Fractional.date(from: raw) { return date }
            if let date = Self.iso8601WholeSecond.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an ISO-8601 timestamp, got \"\(raw)\"."))
        }
        return d
    }

    /// Current write format: `2026-07-27T09:00:00.123Z`.
    nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Legacy read format: `2026-07-27T09:00:00Z`.
    nonisolated(unsafe) static let iso8601WholeSecond: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func encoded(pretty: Bool = true) throws -> Data {
        try Self.makeEncoder(pretty: pretty).encode(self)
    }

    static func decoded(from data: Data) throws -> OwnerConfig {
        try makeDecoder().decode(OwnerConfig.self, from: data)
    }
}

// MARK: - Storage-precision timestamps

extension Date {
    /// Rounded to the resolution the owner-configuration format stores (milliseconds).
    ///
    /// Stamping a timestamp through this makes the in-memory value identical to the value that will
    /// be read back, so `OwnerConfig: Equatable` holds across a save/load boundary. Anything that
    /// writes a date into a configuration should go through it.
    var ownerConfigStoragePrecision: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

// MARK: - Dictionary coding for enum-keyed maps
//
// Swift encodes [EnumKey: V] as a JSON ARRAY unless the key is a String/Int. These wrappers keep the
// on-disk form a readable object, which matters because a human edits this file.

extension KeyedDecodingContainer {
    func decodeEnumKeyed<K: RawRepresentable & Hashable & Decodable, V: Decodable>(
        _ keyType: K.Type, _ valueType: V.Type, forKey key: Key
    ) throws -> [K: V] where K.RawValue == String {
        let raw = try decodeIfPresent([String: V].self, forKey: key) ?? [:]
        var out: [K: V] = [:]
        for (k, v) in raw {
            guard let typed = K(rawValue: k) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self,
                    debugDescription: "Unknown key \"\(k)\" for \(K.self).")
            }
            out[typed] = v
        }
        return out
    }
}

extension KeyedEncodingContainer {
    mutating func encodeEnumKeyed<K: RawRepresentable & Hashable & Encodable, V: Encodable>(
        _ dict: [K: V], forKey key: Key
    ) throws where K.RawValue == String {
        var raw: [String: V] = [:]
        for (k, v) in dict { raw[k.rawValue] = v }
        try encode(raw, forKey: key)
    }
}

extension OwnerConfig.Communication {
    private enum CodingKeys: String, CodingKey { case global, voice, registers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        global = try c.decode(Global.self, forKey: .global)
        voice = try c.decode(Voice.self, forKey: .voice)
        registers = try c.decodeEnumKeyed(RegisterKey.self, Register.self, forKey: .registers)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(global, forKey: .global)
        try c.encode(voice, forKey: .voice)
        try c.encodeEnumKeyed(registers, forKey: .registers)
    }
}

extension OwnerConfig.Approvals {
    private enum CodingKeys: String, CodingKey {
        case policies, neverAllowed, perApplication, restrictedRecipients
        case requireRecipientDisplay, duplicateActionWindowSec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policies = try c.decodeEnumKeyed(OwnerConfig.ApprovalAction.self,
                                         OwnerConfig.ApprovalPolicy.self, forKey: .policies)
        neverAllowed = try c.decodeIfPresent([OwnerConfig.ApprovalAction].self, forKey: .neverAllowed) ?? []
        perApplication = try c.decodeIfPresent([String: OwnerConfig.ApprovalPolicy].self,
                                               forKey: .perApplication) ?? [:]
        restrictedRecipients = try c.decodeIfPresent([String].self, forKey: .restrictedRecipients) ?? []
        requireRecipientDisplay = try c.decodeIfPresent(Bool.self, forKey: .requireRecipientDisplay) ?? true
        duplicateActionWindowSec = try c.decodeIfPresent(Int.self, forKey: .duplicateActionWindowSec) ?? 300
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeEnumKeyed(policies, forKey: .policies)
        try c.encode(neverAllowed.sorted(), forKey: .neverAllowed)
        try c.encode(perApplication, forKey: .perApplication)
        try c.encode(restrictedRecipients, forKey: .restrictedRecipients)
        try c.encode(requireRecipientDisplay, forKey: .requireRecipientDisplay)
        try c.encode(duplicateActionWindowSec, forKey: .duplicateActionWindowSec)
    }
}
