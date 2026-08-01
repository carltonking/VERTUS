import Foundation

// MARK: - OwnerConfigSnapshot (OCS §6, §12)
//
// An immutable, validated view of the configuration at one instant.
//
// The point is temporal safety. A long-running operation — a routine, a drafting session, a
// multi-step control loop — must not observe the configuration changing underneath it: approvals
// evaluated at the start and executed at the end have to agree. A task therefore captures a snapshot
// and carries it to completion, while the store is free to move on to later revisions.
//
// Value semantics do the work: a snapshot is a `struct` holding a `struct`, so a later `save` on the
// store cannot mutate one that a task already holds.

struct OwnerConfigSnapshot: Equatable, Sendable {
    let configId: UUID
    let revision: Int
    let config: OwnerConfig
    let takenAt: Date
    /// Validation result at capture time, so consumers can ask "may drafting run?" without
    /// re-validating on every turn.
    let validation: OwnerConfigValidation

    init(config: OwnerConfig, validation: OwnerConfigValidation, takenAt: Date = Date()) {
        self.configId = config.configId
        self.revision = config.revision
        self.config = config
        self.validation = validation
        self.takenAt = takenAt
    }

    /// Whether a feature may run under this snapshot.
    func allows(_ feature: OwnerConfigIssue.Feature) -> Bool { !validation.isDisabled(feature) }

    /// Short, non-sensitive identifier for audit lines and diagnostics: `<configId-prefix>@<revision>`.
    var auditLabel: String { "\(configId.uuidString.prefix(8))@\(revision)" }

    // MARK: Convenience accessors used by prompt rendering
    //
    // Deliberately narrow. Anything reachable through these is prompt-eligible by design; everything
    // else stays behind `config`, which the persona renderer does not touch directly.

    var preferredName: String? { config.identity.preferredName?.nilIfEmptyOwnerValue }
    var fullName: String? { config.identity.fullName?.nilIfEmptyOwnerValue }
    var signOffName: String? { config.identity.signOffName?.nilIfEmptyOwnerValue }
    var pronouns: OwnerConfig.Identity.Pronouns { config.identity.pronouns }
    var timeZone: TimeZone { TimeZone(identifier: config.identity.timeZone) ?? .current }

    /// The register to use when nothing more specific applies, with global fallbacks filled in.
    var defaultRegister: OwnerConfig.Communication.Register? {
        config.communication.registers[config.communication.global.defaultRegister]
    }
}
