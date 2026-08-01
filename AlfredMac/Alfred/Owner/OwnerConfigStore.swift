import Foundation
import OSLog

// MARK: - OwnerConfigStore (OCS §4, §5, §12)
//
// Canonical storage for the owner configuration, with atomic writes and a revision history.
//
// Layout (deliberately OUTSIDE db/ and profile/, so a memory reset can never take configuration
// with it — that separation is the whole point of authored-vs-learned):
//
//   ~/.alfred/owner/owner.config.json      canonical
//   ~/.alfred/owner/history/<revision>.json  previous revisions
//   ~/.alfred/owner/cloud.projection.json   generated cloud subset
//
// Every path is injectable. Tests pass a temporary directory and never touch the developer's real
// `~/.alfred`.

final class OwnerConfigStore: @unchecked Sendable {

    // MARK: Paths

    struct Paths: Sendable, Equatable {
        let directory: URL
        var configFile: URL { directory.appending(path: "owner.config.json") }
        var historyDirectory: URL { directory.appending(path: "history", directoryHint: .isDirectory) }
        var projectionFile: URL { directory.appending(path: "cloud.projection.json") }
        /// Corrupt canonical files are moved here by explicit recovery. Never written automatically.
        var quarantineDirectory: URL { directory.appending(path: "quarantine", directoryHint: .isDirectory) }

        init(directory: URL) { self.directory = directory }

        /// Production location.
        static var standard: Paths {
            Paths(directory: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".alfred/owner", directoryHint: .isDirectory))
        }
    }

    // MARK: Errors

    enum StoreError: Error, LocalizedError {
        case validationFailed(OwnerConfigValidation)
        case notFound
        case revisionNotFound(Int)
        case writeFailed(String)
        case projectionFailed(String)
        /// The canonical file exists but cannot be decoded. Every mutating path refuses rather than
        /// overwriting it, because those bytes may be the owner's only copy.
        case canonicalCorrupt(CorruptionInfo)
        /// Recovery was asked for but there is no valid historical revision to recover from.
        case noRecoverableRevision

        var errorDescription: String? {
            switch self {
            case let .validationFailed(v):
                return "Configuration is not valid: " + v.errors.map(\.description).joined(separator: "; ")
            case .notFound: return "No owner configuration exists yet."
            case let .revisionNotFound(r): return "Revision \(r) is not in the history."
            case let .writeFailed(m): return "Could not write the configuration: \(m)"
            case let .projectionFailed(m): return "Could not generate the cloud projection: \(m)"
            case let .canonicalCorrupt(info):
                return "The owner configuration file can't be read (\(info.reason)). It has been left untouched. "
                    + (info.recoverableRevision.map { "Revision \($0) in the history can be restored." }
                       ?? "No valid revision is available in the history.")
            case .noRecoverableRevision:
                return "There is no valid historical revision to recover from."
            }
        }
    }

    /// What is known about an unreadable canonical file. Deliberately carries no configuration
    /// content — only shape, so it is safe to log and display.
    struct CorruptionInfo: Equatable, Sendable {
        let byteCount: Int
        let reason: String
        /// Highest historical revision that decodes AND validates, if any.
        let recoverableRevision: Int?
        var isRecoverable: Bool { recoverableRevision != nil }
    }

    /// The four states the canonical file can be in, plus the two corruption sub-cases. Callers and
    /// a future recovery UI need to tell these apart; previously "missing" and "corrupt" were
    /// indistinguishable, which is what allowed a corrupt file to be silently replaced.
    enum LoadState: Equatable, Sendable {
        case missing
        case valid(OwnerConfigSnapshot)
        /// Decodes, but its `schemaVersion` is newer than this build understands.
        case unsupportedSchema(OwnerConfigSnapshot)
        /// Undecodable. `info.isRecoverable` distinguishes recoverable from unrecoverable.
        case corrupt(CorruptionInfo)
    }

    /// What a successful save produced.
    struct SaveResult: Sendable {
        let snapshot: OwnerConfigSnapshot
        let previousRevision: Int?
        let changedPaths: [String]
    }

    // MARK: State

    private static let logger = Logger(subsystem: "com.alfred.owner", category: "config")

    let paths: Paths
    private let validator: OwnerConfigValidator
    private let fm = FileManager.default
    private let lock = NSLock()

    /// Cached current snapshot. `buildSystem` reads this synchronously on every query, so a disk read
    /// per turn would be wasteful; the cache is refreshed by `save`/`restore`/`reload`.
    private var cached: OwnerConfigSnapshot?
    /// Last snapshot that passed validation. Kept so a config that becomes invalid on disk does not
    /// take the running assistant down with it.
    private var lastKnownGood: OwnerConfigSnapshot?

    /// How many historical revisions to retain. Conservative: configuration is small, and history is
    /// the only way to answer "what did it say last week?".
    let historyLimit: Int

    init(paths: Paths = .standard,
         validator: OwnerConfigValidator = OwnerConfigValidator(),
         historyLimit: Int = 20) {
        self.paths = paths
        self.validator = validator
        self.historyLimit = historyLimit
    }

    /// Production instance. The legacy owner name is injected so the validator can flag a leftover
    /// prior-owner value without any name literal appearing in this subsystem's source.
    static let shared = OwnerConfigStore(
        validator: OwnerConfigValidator(
            legacyOwnerName: UserDefaults.standard.string(forKey: "ownerName"))
    )

    // MARK: - Reading

    var exists: Bool { fm.fileExists(atPath: paths.configFile.path) }

    /// Current snapshot, loading from disk on first use. Returns nil when no configuration exists or
    /// the file cannot be read/decoded.
    func currentSnapshot() -> OwnerConfigSnapshot? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let snapshot = loadFromDiskLocked() else { return nil }
        cached = snapshot
        if snapshot.validation.isValid { lastKnownGood = snapshot }
        return snapshot
    }

    /// Most recent snapshot that passed validation — the fallback when the file on disk is broken.
    func lastKnownGoodSnapshot() -> OwnerConfigSnapshot? {
        lock.lock(); defer { lock.unlock() }
        if let lastKnownGood { return lastKnownGood }
        guard let snapshot = loadFromDiskLocked(), snapshot.validation.isValid else { return nil }
        lastKnownGood = snapshot
        return snapshot
    }

    /// Drop the cache and re-read.
    @discardableResult
    func reload() -> OwnerConfigSnapshot? {
        lock.lock(); cached = nil; lock.unlock()
        return currentSnapshot()
    }

    private func loadFromDiskLocked() -> OwnerConfigSnapshot? {
        if case let .valid(snapshot) = loadStateLocked() { return snapshot }
        return nil
    }

    /// Full picture of what is on disk, including the corruption cases `loadFromDiskLocked` collapses
    /// to nil. Every mutating path consults THIS, so "unreadable" is never mistaken for "absent".
    private func loadStateLocked() -> LoadState {
        guard fm.fileExists(atPath: paths.configFile.path) else { return .missing }
        guard let data = try? Data(contentsOf: paths.configFile) else {
            return .corrupt(.init(byteCount: 0, reason: "the file could not be read",
                                  recoverableRevision: latestRecoverableRevisionLocked()))
        }
        do {
            let config = try OwnerConfig.decoded(from: data)
            let snapshot = OwnerConfigSnapshot(config: config, validation: validator.validate(config))
            if config.schemaVersion != OwnerConfigDefaults.schemaVersion {
                return .unsupportedSchema(snapshot)
            }
            return .valid(snapshot)
        } catch {
            // Log the SHAPE of the failure, never the contents.
            Self.logger.error("Owner configuration is unreadable (\(data.count, privacy: .public) bytes): \(error.localizedDescription, privacy: .public)")
            return .corrupt(.init(byteCount: data.count, reason: "it isn't valid configuration data",
                                  recoverableRevision: latestRecoverableRevisionLocked()))
        }
    }

    /// Highest historical revision that both decodes and validates. Invalid or foreign entries are
    /// skipped and reported, never adopted.
    private func latestRecoverableRevisionLocked() -> Int? {
        var best: Int?
        for revision in historyRevisions() {
            guard let data = try? Data(contentsOf: paths.historyDirectory.appending(path: "\(revision).json")),
                  let config = try? OwnerConfig.decoded(from: data) else {
                Self.logger.error("History revision \(revision, privacy: .public) is unreadable; ignoring it.")
                continue
            }
            guard config.schemaVersion == OwnerConfigDefaults.schemaVersion,
                  validator.validate(config).isValid else { continue }
            if best == nil || revision > best! { best = revision }
        }
        return best
    }

    /// Highest revision number appearing anywhere trustworthy, across THREE independent sources:
    ///
    ///  1. the current canonical configuration, when it is readable;
    ///  2. every history filename — presence reserves the number even if the contents are bad,
    ///     because reusing it would overwrite an existing archive;
    ///  3. the cloud projection's `revision`.
    ///
    /// Source 3 matters specifically when the canonical file is corrupt. A revision lives in the
    /// canonical file until it is superseded — history holds only PREVIOUS revisions — so corruption
    /// destroys the only copy of the current revision NUMBER as well as its content. The projection
    /// is written on every successful save and is a separate file, so it survives and records that
    /// number. Without it, recovery would reuse a revision that already existed, silently colliding
    /// with an archive and breaking monotonicity.
    private func highestKnownRevisionLocked(canonical: OwnerConfig?) -> Int {
        var highest = canonical?.revision ?? 0
        for revision in historyRevisions() where revision > highest { highest = revision }
        if let projectionRevision = projectionRevisionLocked(), projectionRevision > highest {
            highest = projectionRevision
        }
        return highest
    }

    /// The revision recorded in the generated projection, if it is readable. Metadata only — the
    /// projection is never a source of configuration content.
    private func projectionRevisionLocked() -> Int? {
        guard let data = try? Data(contentsOf: paths.projectionFile),
              let projection = try? OwnerConfig.makeDecoder().decode(CloudProjection.self, from: data)
        else { return nil }
        return projection.revision
    }

    /// Validate without saving.
    func validate(_ config: OwnerConfig) -> OwnerConfigValidation { validator.validate(config) }

    // MARK: - Corruption and recovery
    //
    // Policy: PRESERVE IN PLACE. A canonical file that cannot be decoded is left exactly as it is;
    // saves and migration refuse until a caller explicitly invokes recovery. Nothing is moved,
    // rewritten, or deleted during ordinary startup, because an automatic repair that guesses wrong
    // destroys the only copy of something the owner authored by hand.

    /// What state the canonical file is in right now.
    func loadState() -> LoadState {
        lock.lock(); defer { lock.unlock() }
        return loadStateLocked()
    }

    /// Non-nil when the canonical file exists but cannot be read.
    func corruptionStatus() -> CorruptionInfo? {
        if case let .corrupt(info) = loadState() { return info }
        return nil
    }

    /// Highest historical revision that decodes and validates, or nil.
    func latestRecoverableRevision() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return latestRecoverableRevisionLocked()
    }

    /// Explicit recovery from a corrupt canonical file. Never runs on its own.
    ///
    /// Quarantines the corrupt bytes (never overwriting an existing quarantine), then writes the
    /// chosen historical revision forward as a NEW revision. The corrupt bytes are always kept —
    /// they are evidence, and occasionally hand-recoverable.
    @discardableResult
    func restoreAfterCorruption(revision: Int? = nil) throws -> SaveResult {
        lock.lock(); defer { lock.unlock() }

        guard case let .corrupt(info) = loadStateLocked() else {
            throw StoreError.notFound   // nothing to recover from
        }
        guard let target = revision ?? info.recoverableRevision else {
            throw StoreError.noRecoverableRevision
        }

        let url = paths.historyDirectory.appending(path: "\(target).json")
        guard let data = try? Data(contentsOf: url) else { throw StoreError.revisionNotFound(target) }
        let recovered = try OwnerConfig.decoded(from: data)
        guard validator.validate(recovered).isValid else { throw StoreError.revisionNotFound(target) }

        try ensureDirectoriesLocked()
        try quarantineCorruptCanonicalLocked(byteCount: info.byteCount)

        // The corrupt file is gone from the canonical path now, so the write is permitted.
        cached = nil
        let result = try saveLocked(recovered, updatedBy: .recovery, allowOverCorrupt: true)
        Self.logger.info("Recovered owner configuration from revision \(target, privacy: .public) as revision \(result.snapshot.revision, privacy: .public); corrupt bytes quarantined.")
        return result
    }

    /// Move the unreadable canonical file into `quarantine/` under a unique name and record a
    /// manifest beside it. Never overwrites an existing quarantine entry.
    private func quarantineCorruptCanonicalLocked(byteCount: Int) throws {
        let dir = paths.quarantineDirectory
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        // Uniqueness comes from a UUID rather than a timestamp, so two recoveries in the same second
        // cannot collide.
        let stamp = UUID().uuidString
        let target = dir.appending(path: "owner.config.corrupt-\(stamp).json")
        guard !fm.fileExists(atPath: target.path) else {
            throw StoreError.writeFailed("quarantine name collision")
        }
        try fm.moveItem(at: paths.configFile, to: target)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

        // Manifest records SHAPE only — no configuration content.
        let manifest = """
            {"quarantinedAt":"\(OwnerConfig.iso8601Fractional.string(from: Date()))",\
            "byteCount":\(byteCount),"file":"\(target.lastPathComponent)"}
            """
        try? atomicWriteLocked(Data(manifest.utf8), to: dir.appending(path: "manifest-\(stamp).json"))
    }

    // MARK: - Writing

    /// Validate → archive the previous revision → atomically replace → regenerate the projection.
    ///
    /// The incoming `revision` and `updatedAt` are ignored: the store owns the counter, so a caller
    /// cannot rewind it by hand. If any step fails, the previous configuration is left exactly as it
    /// was — the temp file is discarded and nothing is partially written.
    @discardableResult
    func save(_ config: OwnerConfig, updatedBy: OwnerConfig.UpdateSource) throws -> SaveResult {
        lock.lock(); defer { lock.unlock() }
        return try saveLocked(config, updatedBy: updatedBy)
    }

    private func saveLocked(_ config: OwnerConfig, updatedBy: OwnerConfig.UpdateSource,
                            allowOverCorrupt: Bool = false) throws -> SaveResult {
        // REFUSE to write over a canonical file we cannot read. Those bytes may be the owner's only
        // copy, and treating "unreadable" as "absent" is what previously destroyed them.
        let state = loadStateLocked()
        if case let .corrupt(info) = state, !allowOverCorrupt {
            throw StoreError.canonicalCorrupt(info)
        }

        let previous: OwnerConfigSnapshot? = {
            if let cached { return cached }
            if case let .valid(snapshot) = state { return snapshot }
            return nil
        }()

        var next = config
        // Never below any revision that already exists on disk, so a corrupt or missing canonical
        // file cannot restart the counter and orphan (or overwrite) existing history.
        next.revision = highestKnownRevisionLocked(canonical: previous?.config) + 1
        next.updatedAt = Date().ownerConfigStoragePrecision
        next.updatedBy = updatedBy
        if let previous { next.configId = previous.configId }   // identity is stable across revisions

        let validation = validator.validate(next)
        guard validation.isValid else { throw StoreError.validationFailed(validation) }

        // Refuse to write anything that cannot be projected — a config the cloud can't consume is a
        // half-migrated state, and finding out at deploy time is worse than finding out here.
        let projection: CloudProjection
        do { projection = try CloudProjection.generate(from: next) }
        catch { throw StoreError.projectionFailed(error.localizedDescription) }

        try ensureDirectoriesLocked()

        // Archive the outgoing revision BEFORE replacing it.
        if let previous {
            let data = try previous.config.encoded()
            let url = paths.historyDirectory.appending(path: "\(previous.revision).json")
            try atomicWriteLocked(data, to: url)
        }

        try atomicWriteLocked(try next.encoded(), to: paths.configFile)
        try atomicWriteLocked(try projection.encoded(), to: paths.projectionFile)
        pruneHistoryLocked()

        let snapshot = OwnerConfigSnapshot(config: next, validation: validation)
        cached = snapshot
        lastKnownGood = snapshot

        let changed = Self.changedPaths(from: previous?.config, to: next)
        Self.logger.info("Owner configuration saved: revision \(next.revision, privacy: .public), \(changed.count, privacy: .public) field(s) changed by \(updatedBy.rawValue, privacy: .public)")

        return SaveResult(snapshot: snapshot, previousRevision: previous?.revision, changedPaths: changed)
    }

    // MARK: - History

    /// Revisions available in the history directory, newest first.
    func historyRevisions() -> [Int] {
        let urls = (try? fm.contentsOfDirectory(at: paths.historyDirectory,
                                                includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            .sorted(by: >)
    }

    /// Read one archived revision.
    func configuration(atRevision revision: Int) throws -> OwnerConfig {
        let url = paths.historyDirectory.appending(path: "\(revision).json")
        guard let data = try? Data(contentsOf: url) else { throw StoreError.revisionNotFound(revision) }
        return try OwnerConfig.decoded(from: data)
    }

    /// Restore a historical revision AS A NEW REVISION. The counter never rewinds, so history stays a
    /// complete record of what was in force and when.
    @discardableResult
    func restore(revision: Int) throws -> SaveResult {
        let old = try configuration(atRevision: revision)
        return try save(old, updatedBy: .restore)
    }

    /// Field paths whose values differ between two configurations. Values are never returned — a diff
    /// of a `confidential`-sensitivity field would otherwise become a second copy of it.
    static func changedPaths(from old: OwnerConfig?, to new: OwnerConfig) -> [String] {
        guard let old else { return ["<initial>"] }
        guard let a = try? JSONValue.from(old), let b = try? JSONValue.from(new) else { return [] }
        let skip: Set<String> = ["revision", "updatedAt", "updatedBy"]
        var paths = Set(a.leafPaths()).union(b.leafPaths())
        paths.subtract(skip)
        return paths.filter { a.value(at: $0) != b.value(at: $0) }.sorted()
    }

    /// Sanitized comparison of two revisions, for the Settings history view.
    func sanitizedDiff(fromRevision old: Int, toRevision new: Int) throws -> [String] {
        let a = try configuration(atRevision: old)
        let b = try configuration(atRevision: new)
        return Self.changedPaths(from: a, to: b)
    }

    // MARK: - Projection

    /// Regenerate the projection from the current configuration without changing the revision.
    /// Generation only — deployment is out of scope for this package.
    @discardableResult
    func regenerateProjection() throws -> CloudProjection {
        guard let snapshot = currentSnapshot() else { throw StoreError.notFound }
        let projection = try CloudProjection.generate(from: snapshot.config)
        lock.lock(); defer { lock.unlock() }
        try ensureDirectoriesLocked()
        try atomicWriteLocked(try projection.encoded(), to: paths.projectionFile)
        return projection
    }

    /// Current projection as pretty JSON, for the read-only Settings preview.
    func projectionPreview() -> String? {
        guard let snapshot = currentSnapshot(),
              let projection = try? CloudProjection.generate(from: snapshot.config),
              let data = try? projection.encoded(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Current configuration as pretty JSON. Secret REFERENCES appear (they are not sensitive);
    /// no secret value can be present because none is ever stored.
    func configurationPreview() -> String? {
        guard let snapshot = currentSnapshot(),
              let data = try? snapshot.config.encoded(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - Filesystem primitives

    private func ensureDirectoriesLocked() throws {
        for dir in [paths.directory, paths.historyDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
        }
    }

    /// Temp file → fsync → atomic replace. A crash mid-write leaves the previous file intact rather
    /// than a truncated one, which is the difference between "unchanged" and "unrecoverable".
    private func atomicWriteLocked(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)

            // Force the bytes to disk before the rename, so the replace cannot expose an empty file.
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()

            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private func pruneHistoryLocked() {
        let revisions = historyRevisions()
        guard revisions.count > historyLimit else { return }
        for revision in revisions.dropFirst(historyLimit) {
            try? fm.removeItem(at: paths.historyDirectory.appending(path: "\(revision).json"))
        }
    }
}

// MARK: - One-time identity migration (OCS §11)

extension OwnerConfigStore {

    enum MigrationOutcome: Equatable, Sendable {
        /// A configuration already existed; nothing was written.
        case alreadyExists(revision: Int)
        /// A configuration was seeded from the legacy owner name.
        case seeded(revision: Int)
        /// There was no legacy owner name to seed from, so nothing was written. Not an error —
        /// onboarding supplies the fields on a fresh install.
        case skippedNoLegacyName
        /// Seeding was attempted and rejected. Nothing was written.
        case failed(String)
        /// The canonical file exists but cannot be read. Migration refuses rather than overwriting it.
        case refusedCanonicalCorrupt(recoverableRevision: Int?)
    }

    /// Create an initial configuration from the legacy `ownerName`, once.
    ///
    /// Idempotent by construction: it returns immediately when a configuration already exists, so
    /// repeated launches cannot overwrite the owner's edits or bump the revision.
    ///
    /// # What is seeded, and why sign-off is included
    ///
    /// Three identity fields: `fullName`, `preferredName`, and `signOffName`. Sign-off is required
    /// by the validator, so the earlier version — which seeded only the first two — produced a
    /// configuration that could never be saved, leaving the feature permanently inert (C2).
    ///
    /// Seeding it from the same legacy name is the safe reading: `ownerName` is what the assistant
    /// has been calling this person all along, so using it as the sign-off changes nothing about
    /// how mail would be signed relative to today's behaviour. It is a carried-over value, not a
    /// new claim, and both onboarding and Settings surface it for confirmation.
    ///
    /// # What is NOT seeded
    ///
    /// Pronouns stay neutral (a name never implies them). The time zone stays the provisional
    /// default with `timeZoneConfirmed = false`, so it keeps warning until confirmed. No signature
    /// body is invented. No learned data crosses over — writing samples, memories, relationships,
    /// projects, profile digests, style rules, feature toggles, and cloud values are all left
    /// behind, because they describe the previous owner and are not authored facts.
    ///
    /// The legacy UserDefaults value is not deleted, so turning the feature flag off restores the
    /// old behaviour exactly.
    @discardableResult
    func migrateFromLegacyIfNeeded(legacyOwnerName: String?) -> MigrationOutcome {
        // Never run migration over a file we cannot read — that is how the previous version
        // destroyed a recoverable configuration and reset the revision counter to 1.
        switch loadState() {
        case let .valid(existing):            return .alreadyExists(revision: existing.revision)
        case let .unsupportedSchema(existing): return .alreadyExists(revision: existing.revision)
        case let .corrupt(info):
            Self.logger.error("Migration refused: the owner configuration file is unreadable.")
            return .refusedCanonicalCorrupt(recoverableRevision: info.recoverableRevision)
        case .missing:                        break
        }

        // No legacy name means there is nothing to carry across. Writing a config here would only
        // produce an invalid one; onboarding is the right place to collect these fields.
        guard let legacy = legacyOwnerName?.trimmed.nilIfEmptyOwnerValue else {
            return .skippedNoLegacyName
        }

        var config = OwnerConfigDefaults.blank
        config.identity.fullName = legacy
        config.identity.preferredName = legacy
        config.identity.signOffName = legacy
        // Record WHAT was seeded, so the validator exempts exactly these fields from the
        // previous-owner check and the UI can mark them for confirmation. The set is written by the
        // operation doing the seeding, so the two can never disagree.
        config.migrationSeeded = .init(
            fields: Array(OwnerConfigDefaults.allowedMigrationSeedPaths),
            seededAt: Date().ownerConfigStoragePrecision)

        do {
            let result = try save(config, updatedBy: .migration)
            Self.logger.info("Owner configuration seeded by migration at revision \(result.snapshot.revision, privacy: .public)")
            return .seeded(revision: result.snapshot.revision)
        } catch {
            // Nothing partial is left behind: `save` validates and projects before it writes.
            Self.logger.error("Owner configuration could not be seeded: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}
