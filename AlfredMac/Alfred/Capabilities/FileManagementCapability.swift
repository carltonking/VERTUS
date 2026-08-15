import Foundation
import AlfredCore

// MARK: - Errors

enum FileManagementError: LocalizedError {
    /// The source path doesn't exist.
    case missing(String)
    /// The destination already exists — never silently replace.
    case destinationExists(String)
    /// The destination is inside the source (a folder moved into itself).
    case invalidMove
    /// Deletion requires explicit user approval; the caller must surface the
    /// question and call again with `confirmed: true`.
    case needsConfirmation(String)
    /// The operation failed at the filesystem layer.
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let p): return "Nothing at \(p)."
        case .destinationExists(let p): return "\(p) already exists. Alfred never replaces files without asking — pick a different name or move it first."
        case .invalidMove: return "That move would put the destination inside the source. Pick a destination outside the folder."
        case .needsConfirmation(let p): return "Deleting \(p) can't be undone. Reply confirming the delete — naming the file — and Alfred will remove it."
        case .operationFailed(let m): return m
        }
    }
}

// MARK: - Capability

/// File organization operations — move, copy, delete, create, list — with
/// Alfred's guardrails built in:
///
///   * **Never auto-delete.** `deleteFile` throws `needsConfirmation` unless the
///     caller proves the user explicitly approved this path.
///   * **Never silently replace.** Any operation whose destination already
///     exists fails with a clear error instead of clobbering.
///   * **Everything is audited.** Every successful change is logged to the
///     memory journal (best-effort; a missing vault never fails the op).
///
/// The tool layer calls these only when the user's intent names real paths —
/// "move this file to", "organize my Downloads" — never on guessed targets.
struct FileManagementCapability {

    // MARK: - Operations

    /// Move a file or folder. Creates missing parent directories at the
    /// destination; refuses to replace an existing destination.
    @discardableResult
    func moveFile(from source: URL, to destination: URL) throws -> String {
        try ensureExists(source)
        try ensureDestinationFree(destination)
        try ensureNotSelfMove(source, destination)
        try prepareParent(of: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        logAudit(.move, from: source, to: destination)
        return "Moved \(Self.describe(source)) to \(Self.describe(destination))."
    }

    /// Copy a file or folder, leaving the original in place.
    @discardableResult
    func copyFile(from source: URL, to destination: URL) throws -> String {
        try ensureExists(source)
        try ensureDestinationFree(destination)
        try prepareParent(of: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        logAudit(.copy, from: source, to: destination)
        return "Copied \(Self.describe(source)) to \(Self.describe(destination))."
    }

    /// Delete a file or folder. `confirmed` must be true — set by the caller
    /// only after the user explicitly approved the deletion in their own words.
    @discardableResult
    func deleteFile(at target: URL, confirmed: Bool) throws -> String {
        try ensureExists(target)
        guard confirmed else { throw FileManagementError.needsConfirmation(Self.describe(target)) }
        try FileManager.default.removeItem(at: target)
        logAudit(.delete, from: target, to: nil)
        return "Deleted \(Self.describe(target))."
    }

    /// Create a folder (and any missing parents).
    @discardableResult
    func createFolder(at url: URL) throws -> String {
        if FileManager.default.fileExists(atPath: url.path) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard isDirectory.boolValue else {
                throw FileManagementError.destinationExists(Self.describe(url))
            }
            return "\(Self.describe(url)) already exists."
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        logAudit(.createFolder, from: nil, to: url)
        return "Created \(Self.describe(url))."
    }

    /// List the contents of a folder, sorted by name. Recursive listing walks
    /// the whole subtree with `enumerator`.
    func listFolder(at url: URL, recursive: Bool = false) throws -> [URL] {
        try ensureExists(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw FileManagementError.operationFailed("\(Self.describe(url)) is not a folder.") }

        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil) else { return [] }
            return enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Audit

    private enum Action {
        case move, copy, delete, createFolder
        var verb: String { switch self {
        case .move: return "moved"
        case .copy: return "copied"
        case .delete: return "deleted"
        case .createFolder: return "created folder"
        } }
    }

    /// The one-line audit record, e.g. "moved ~/Downloads/report.pdf to ~/Projects/Q1".
    /// Pure, so it's testable and stable across app versions.
    static func auditMessage(action: String, from fromPath: String?, to toPath: String?) -> String {
        switch (fromPath, toPath) {
        case (let f?, let t?): return "\(action) \(f) to \(t)"
        case (let f?, nil):   return "\(action) \(f)"
        case (nil, let t?):   return "\(action) \(t)"
        case (nil, nil):      return "\(action) <unknown>"
        }
    }

    /// Write the audit line into the memory journal (vault log). Best-effort:
    /// if the vault isn't configured the operation still succeeded.
    private func logAudit(_ action: Action, from source: URL?, to destination: URL?) {
        let message = Self.auditMessage(
            action: action.verb,
            from: source.map(Self.describe),
            to: destination.map(Self.describe))
        MemoryStore.shared.logActivity(message, source: "files", importance: 3)
    }

    // MARK: - Helpers

    /// A path for humans and audit logs: `~/Downloads/report.pdf`, not
    /// `/Users/carltonking/Downloads/report.pdf`.
    static func describe(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func ensureExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileManagementError.missing(Self.describe(url))
        }
    }

    private func ensureDestinationFree(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileManagementError.destinationExists(Self.describe(url))
        }
    }

    private func ensureNotSelfMove(_ source: URL, _ destination: URL) throws {
        let dst = destination.standardizedFileURL.path
        let src = source.standardizedFileURL.path
        if dst.hasPrefix(src + "/") {
            throw FileManagementError.invalidMove
        }
    }

    /// Create the destination's parent directory so "move to ~/Projects/Q1"
    /// works even when Q1 doesn't exist yet.
    private func prepareParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
