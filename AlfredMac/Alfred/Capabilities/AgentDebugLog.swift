import Foundation

/// Appends a step-by-step trace of computer-control sessions to
/// `~/.alfred/logs/computer-control.log` so failures during real-app testing can be diagnosed
/// (what the model saw, what it proposed, what happened) without screen access. Local-only.
enum AgentDebugLog {
    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".alfred/logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "computer-control.log")
    }()

    private static let iso8601 = ISO8601DateFormatter()

    static func log(_ message: String) {
        // No argless Date() in this codebase's tooling-sensitive paths, but here in app code it's fine.
        let line = "[\(Self.iso8601.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    static var path: String { fileURL.path }
}
