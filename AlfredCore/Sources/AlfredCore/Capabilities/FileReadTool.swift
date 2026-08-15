import Foundation

// MARK: - FileReadTool

/// Reads a text file from an allowed root. The requested path is
/// standardized (symlinks resolved, `..` collapsed) and must land inside an
/// allowed root; anything else is refused, so a model that hallucinates a
/// path can never reach arbitrary files on the machine. Allowed roots are
/// the vault and the project work directory (`$ALFRED_WORKDIR`), so both
/// vault notes and project files are readable. Relative paths resolve
/// against the work directory. Files over 1MB are refused too, so a huge
/// note can't flood the model's context window.
// All stored properties are immutable lets; the one non-Sendable value
// (`parameters` is a JSON-schema [String: Any]) never mutates after init, so
// the Sendable conformance is sound.
public final class FileReadTool: LLMTool, Capability, @unchecked Sendable {

    public let id = "file-read"
    public let displayName = "Read File"
    public let requiresPermission = false

    public let name = "read_file"
    public let description = "Read allowed text file"

    public let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute path to a text file inside the vault, e.g. /Users/me/.alfred/vault/My Life/Projects/note.md",
            ],
        ],
        "required": ["path"],
    ]

    /// Roots the tool may read from. Defaults to the configured vault root
    /// and the project work directory so `read_file` works for both vault
    /// notes and project files; callers can pass extra roots (tests, a second
    /// vault) but never remove the defaults.
    public let allowedRoots: [URL]

    /// Relative paths resolve against this directory. Defaults to
    /// `$ALFRED_WORKDIR` (the macOS project root), falling back to the
    /// derived home project path so it works without the env var.
    public let workdir: URL

    /// Upper bound on file size the tool will read.
    public static let maxReadBytes = 1_048_576

    /// - Parameter vaultPath: the vault root; defaults to AlfredConfig's resolution.
    /// - Parameter workdir: project work directory for relative paths and a
    ///   second allowed root; defaults to `$ALFRED_WORKDIR` (falls back to
    ///   `~/01 - PROJECTS/ALFRED/AlfredMac`).
    public init(vaultPath: String = AlfredConfig.vaultPath(),
                extraRoots: [URL] = [],
                workdir: String = ProcessInfo.processInfo.environment["ALFRED_WORKDIR"]
                    ?? "\(NSHomeDirectory())/01 - PROJECTS/ALFRED/AlfredMac") {
        let wd = URL(fileURLWithPath: workdir, isDirectory: true)
        var roots = [URL(fileURLWithPath: vaultPath, isDirectory: true), wd]
        roots.append(contentsOf: extraRoots)
        self.allowedRoots = roots
        self.workdir = wd
    }

    /// - Parameter vault: an existing `Vault` instance; its root becomes the allowed root.
    public convenience init(vault: Vault) {
        self.init(vaultPath: vault.root.path)
    }

    // MARK: - LLMTool

    public func execute(arguments: String) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPath = json["path"] as? String, !rawPath.isEmpty
        else {
            throw LLMError.inferenceFailed("read_file: missing or invalid 'path' argument")
        }

        let expanded = (rawPath as NSString).expandingTildeInPath
        // Relative paths resolve against the project work directory
        // (ALFRED_WORKDIR), so "README.md" means the project's README, not a
        // vault-relative guess.
        let requested: URL
        if expanded.hasPrefix("/") {
            requested = URL(fileURLWithPath: expanded)
        } else {
            requested = workdir.appendingPathComponent(expanded)
        }
        // Standardize before checking containment so `..` and symlinks can't
        // smuggle a path outside the allowed roots.
        let target = requested.standardizedFileURL.resolvingSymlinksInPath()

        guard isAllowed(target) else {
            throw LLMError.inferenceFailed("read_file: path is outside the allowed vault — refused: \(expanded)")
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw LLMError.inferenceFailed("read_file: file not found at \(target.path)")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        if (attributes[.type] as? FileAttributeType) == .typeDirectory {
            throw LLMError.inferenceFailed("read_file: \(expanded) is a directory, not a file")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxReadBytes else {
            throw LLMError.inferenceFailed("read_file: \(expanded) is \(size) bytes — exceeds the 1MB limit")
        }

        return try String(contentsOf: target, encoding: .utf8)
    }

    // MARK: - Path containment

    /// True when `candidate` (already standardized) sits inside one of the
    /// allowed roots (also standardized), or is one of the roots itself.
    private func isAllowed(_ candidate: URL) -> Bool {
        let candidatePath = candidate.path
        for root in allowedRoots {
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            if candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") {
                return true
            }
        }
        return false
    }
}
