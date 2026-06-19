import Foundation

/// Manages the lifecycle of the local fine-tuned model server process.
/// Starts the Python server on app launch, monitors it, and kills it on termination.
@MainActor
final class LocalModelServerManager {
    static let shared = LocalModelServerManager()

    private var process: Process?
    private(set) var isRunning = false

    private let serverPort = 8080
    private let healthURL: URL

    private init() {
        healthURL = URL(string: "http://localhost:\(serverPort)/health")!
    }

    /// Find the server script by checking known locations.
    private func findServerScript() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            // Installed via install.sh → ~/.alfred/app/...
            home.appendingPathComponent(".alfred")
                .appendingPathComponent("app")
                .appendingPathComponent("Fine tuned model for alfred")
                .appendingPathComponent("local_alfred_server.py"),

            // Development: check relative to source root
            URL(fileURLWithPath: "Fine tuned model for alfred/local_alfred_server.py"),

            // Development: check relative to the executable's parent
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fine tuned model for alfred")
                .appendingPathComponent("local_alfred_server.py"),

            // Possible Xcode derived data layout
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fine tuned model for alfred")
                .appendingPathComponent("local_alfred_server.py"),
        ]

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Start the server process. Returns immediately; call `waitUntilReady` to block until the server responds.
    func start() throws {
        guard !isRunning else { return }
        guard let scriptURL = findServerScript() else {
            throw ServerError.scriptNotFound
        }
        let pythonURL = try findPython()

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = [scriptURL.path, String(serverPort)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        process = proc
        isRunning = true

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
            }
        }
    }

    /// Wait for the server to respond to health checks (polls every 500ms).
    /// Throws if the server doesn't respond within `timeout` seconds.
    func waitUntilReady(timeout: TimeInterval = 30) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await isHealthy() {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ServerError.timeout
    }

    /// Quick health check against the server's `/health` endpoint.
    func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL, timeoutInterval: 2)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Terminate the server process.
    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    // MARK: - Helpers

    private func findPython() throws -> URL {
        for path in ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["python3"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }
        throw ServerError.pythonNotFound
    }
}

// MARK: - Errors

extension LocalModelServerManager {
    enum ServerError: LocalizedError {
        case scriptNotFound
        case pythonNotFound
        case timeout

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "Local model server script not found. Re-run install.sh."
            case .pythonNotFound:
                return "Python 3 not found. Install from python.org."
            case .timeout:
                return "Local model server did not start in time."
            }
        }
    }
}
