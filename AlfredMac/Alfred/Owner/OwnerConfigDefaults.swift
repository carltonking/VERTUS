import Foundation

// MARK: - OwnerConfigDefaults (OCS §2)
//
// Every default here is the least-capable, least-exposed setting that still leaves the assistant
// useful for reading and drafting. The rule: an unanswered question DISABLES a capability, it never
// enables one with a guess.
//
// Two things these defaults deliberately do NOT do:
//  • They do not change current runtime behaviour. Approvals and feature flags are MODELLED in this
//    package but are not yet consulted by any capability (that wiring is a later package), so a
//    `never` here does not silently switch off something that works today.
//  • They do not invent owner facts. Unknown identity, roles, folders, and contacts stay `nil` and
//    surface as named validation errors rather than placeholder text.

enum OwnerConfigDefaults {

    /// Current schema major. A runtime rejects a config whose major it does not know.
    static let schemaVersion = 1

    /// Carried over from the existing cloud default so nothing silently shifts time zone. Marked
    /// UNCONFIRMED — a guessed zone corrupts every calendar event it writes, so the UI must ask.
    static let provisionalTimeZone = "America/New_York"

    /// The ONLY field paths the one-time legacy migration may seed, and therefore the only paths
    /// that can legitimately still contain the previous owner's name after migration.
    ///
    /// The validator rejects a `migrationSeeded` record naming anything else, so provenance cannot
    /// be used to launder an exemption onto an unrelated field.
    static let allowedMigrationSeedPaths: Set<String> = [
        "identity.fullName",
        "identity.preferredName",
        "identity.signOffName",
    ]

    /// Mirrors `ScreenTextMonitor.defaultExcluded` so adopting the config cannot weaken the existing
    /// password-manager protection. Kept as a literal list (not a reference) so the config file is
    /// self-describing when read on another machine.
    static let screenCaptureExcludedApps = [
        "1password", "keychain", "lastpass", "bitwarden", "dashlane",
    ]

    // MARK: - Approval floors
    //
    // The MINIMUM restrictiveness the code permits. Configuration may tighten any of these; the
    // validator rejects any attempt to go below one. Floors are policy, not preference — they exist
    // so a hand-edited or imported config cannot quietly unlock a dangerous path.

    static let approvalFloors: [OwnerConfig.ApprovalAction: OwnerConfig.ApprovalPolicy] = [
        .read: .auto,
        .summarize: .auto,
        .draft: .auto,
        .saveDraft: .auto,
        .createTask: .userInitiated,
        .modifyTask: .userInitiated,
        .createCalendarEvent: .userInitiated,
        .modifyCalendarEvent: .confirm,
        .bulkCalendarDelete: .doubleConfirm,
        .sendEmail: .confirm,
        .sendMessage: .confirm,
        .moveFile: .confirm,
        .renameFile: .confirm,
        .deleteFile: .confirm,
        .modifySourceArtwork: .doubleConfirm,
        .runIllustratorScript: .preview,
        .runPhotoshopAutomation: .preview,
        .runRhinoAutomation: .doubleConfirm,
        .useComputerControl: .preview,
        .runShellCommand: .confirm,
        .uploadFileExternally: .doubleConfirm,
        .shareConfidentialInformation: .never,
    ]

    /// Shipped defaults — at or above every floor, and `never` for anything irreversible or
    /// outward-facing that has no preview/undo path today.
    static let approvalDefaults: [OwnerConfig.ApprovalAction: OwnerConfig.ApprovalPolicy] = [
        .read: .auto,
        .summarize: .auto,
        .draft: .auto,
        .saveDraft: .auto,
        .createTask: .confirm,
        .modifyTask: .confirm,
        .createCalendarEvent: .confirm,
        .modifyCalendarEvent: .confirm,
        .bulkCalendarDelete: .never,
        .sendEmail: .confirm,
        .sendMessage: .confirm,
        .moveFile: .confirm,
        .renameFile: .confirm,
        .deleteFile: .doubleConfirm,
        .modifySourceArtwork: .never,
        .runIllustratorScript: .never,
        .runPhotoshopAutomation: .never,
        .runRhinoAutomation: .never,
        .useComputerControl: .never,
        .runShellCommand: .never,
        .uploadFileExternally: .never,
        .shareConfidentialInformation: .never,
    ]

    /// Approval presets offered during onboarding. Each writes the full policy table, so the owner
    /// never has to reason about 22 actions to get started.
    enum ApprovalPreset: String, CaseIterable, Sendable {
        case cautious, balanced, fast

        var label: String {
            switch self {
            case .cautious: return "Cautious — confirm nearly everything"
            case .balanced: return "Balanced — confirm anything outward-facing or destructive"
            case .fast:     return "Fast — confirm only destructive and outward-facing actions"
            }
        }

        var detail: String {
            switch self {
            case .cautious: return "Tasks, calendar entries, files, and messages all ask first."
            case .balanced: return "Reading and drafting run freely; sending and file changes ask."
            case .fast:     return "Adds automatic task and calendar creation. Sending still asks."
            }
        }

        /// Never returns anything below a floor — `max` with the floor is applied per action.
        var policies: [OwnerConfig.ApprovalAction: OwnerConfig.ApprovalPolicy] {
            var table = approvalDefaults
            switch self {
            case .cautious:
                table[.createTask] = .confirm
                table[.modifyTask] = .confirm
                table[.createCalendarEvent] = .confirm
                table[.moveFile] = .confirm
                table[.renameFile] = .confirm
                table[.deleteFile] = .doubleConfirm
            case .balanced:
                break // the shipped defaults are the balanced preset
            case .fast:
                table[.createTask] = .userInitiated
                table[.modifyTask] = .userInitiated
                table[.createCalendarEvent] = .userInitiated
                table[.renameFile] = .confirm
            }
            for (action, policy) in table {
                let floor = approvalFloors[action] ?? .never
                if policy < floor { table[action] = floor }
            }
            return table
        }
    }

    // MARK: - Governance

    static let classifications: [OwnerConfig.Governance.Classification] = [
        .init(id: "public",       label: "Public",       cloudEligible: true,  retentionDays: nil),
        .init(id: "internal",     label: "Internal",     cloudEligible: true,  retentionDays: 365),
        .init(id: "confidential", label: "Confidential", cloudEligible: false, retentionDays: 90),
        .init(id: "regulated",    label: "Regulated",    cloudEligible: false, retentionDays: 90),
    ]

    /// Per-store retention in days. `nil` means "keep forever" and must be a deliberate choice —
    /// `memories` is nil today because pruning long-term memory is a separate product decision.
    static let retention: [String: Int?] = [
        "conversationHistory": 90,
        "screenTextLog": 30,
        "memories": nil,
        "runs": 730,
        "learningTelemetry": 30,
    ]

    // MARK: - Registers

    /// All eight audiences exist from the start with `nil` style fields, so the UI can show the full
    /// set and the owner fills in only what they care about. `personal` is the one register that is
    /// NOT cloud-eligible by default — personal voice should not leave the Mac without a decision.
    static var registers: [OwnerConfig.Communication.RegisterKey: OwnerConfig.Communication.Register] {
        var out: [OwnerConfig.Communication.RegisterKey: OwnerConfig.Communication.Register] = [:]
        for key in OwnerConfig.Communication.RegisterKey.allCases {
            out[key] = OwnerConfig.Communication.Register(cloudEligible: key != .personal)
        }
        return out
    }

    // MARK: - Blank configuration

    /// A structurally complete configuration with no owner facts in it. This is what a fresh install
    /// starts from; it will FAIL validation on the required identity fields, which is the intended
    /// signal that onboarding has not finished.
    static var blank: OwnerConfig {
        OwnerConfig(
            schemaVersion: schemaVersion,
            configId: UUID(),
            revision: 1,
            updatedAt: Date(),
            updatedBy: .onboarding,
            identity: .init(
                fullName: nil,
                preferredName: nil,
                pronouns: .neutral,
                roleTitle: nil,
                organization: nil,
                signOffName: nil,
                signatures: [],
                timeZone: provisionalTimeZone,
                timeZoneConfirmed: false,
                locale: nil,
                dateFormat: .iso,
                timeFormat: .h24,
                workingHours: [],
                outOfHoursPolicy: .queue
            ),
            professional: .init(
                summaryLine: nil,
                expertiseAreas: [], industries: [], categories: [], responsibilities: [],
                authority: .init(canCommitBudget: .no, canApproveArtwork: .no,
                                 canSignOffProduction: .no, canCommitDates: .no),
                team: [], terminology: [], disciplines: []
            ),
            communication: .init(
                global: .init(rules: [], defaultRegister: .internalPeer),
                voice: .init(mode: .curated, exemplars: [], learnFromSent: false),
                registers: registers
            ),
            systems: .init(
                email: [], calendar: [],
                projectManagement: .init(kind: .none, workspaceRef: nil),
                fileStorage: [], applications: [],
                adobe: .init(illustrator: .absent, photoshop: .absent,
                             indesign: .absent, acrobat: .absent),
                rhino: .absent, researchSources: [], messagingChannels: []
            ),
            roots: .init(
                projectRoots: [], artworkArchive: nil, brandLibrary: nil,
                productionTemplates: nil, printerSpecs: nil, research: nil, output: nil,
                personal: [], restricted: [], localModelOnly: [], cloudPermitted: []
            ),
            vocabulary: .init(
                namespace: "work", terms: [:], milestoneTypes: [],
                statusVocabulary: [], approvalStages: []
            ),
            approvals: .init(
                policies: approvalDefaults,
                neverAllowed: [],
                perApplication: [:],
                restrictedRecipients: [],
                requireRecipientDisplay: true,
                duplicateActionWindowSec: 300
            ),
            governance: .init(
                classifications: classifications,
                provenanceRequired: true,
                memoryApproval: .batchReview,
                namespaces: [.work, .personal],
                crossNamespaceReads: [],
                retention: retention,
                deletionCascades: true
            ),
            features: .init(
                screenCapture: .init(enabled: false, excludedApps: screenCaptureExcludedApps),
                screenContext: .init(true),          // on-demand only; matches today's behaviour
                writingStyleLearning: .init(false),
                memoryExtraction: .init(false),
                relationshipLearning: .init(false),
                projectDetection: .init(false),
                proactiveSuggestions: .init(false),
                telegram: .init(false),
                imessageBot: .init(false),
                computerControl: .init(false),
                shellExecution: .init(false),
                liveLocation: .init(false),
                morningBriefing: .init(enabled: false, topics: [], sections: [], sendLocalTime: nil),
                routineExecution: .init(true)        // preserves the existing scheduler
            ),
            providers: .init(
                chain: ["groq", "gemini", "openrouter", "ollama"],
                models: [
                    "groq": "llama-3.3-70b-versatile",
                    "gemini": "gemini-2.5-flash-lite",
                    "openrouter": "meta-llama/llama-3.3-70b-instruct:free",
                    "ollama": "llama3.1:8b",
                ],
                localOnlyFor: ["confidential", "regulated"]
            ),
            secrets: .init(
                telegramBotToken: nil, telegramOwnerId: nil,
                cloudBotToken: nil, cloudOwnerId: nil,
                mailPrimary: nil, calendarPrimary: nil
            )
        )
    }
}
