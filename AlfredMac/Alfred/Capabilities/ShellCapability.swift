import Foundation

struct ShellCapability {
    private let timeoutSeconds: Double

    init(timeout: Double = 30) {
        self.timeoutSeconds = timeout
    }

    func run(command: String, workingDirectory: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]

            if let wd = workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: wd)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let finishGate = FinishGate()

            // Watchdog timer
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                guard finishGate.tryFinish() else { return }
                process.terminate()
                timer.cancel()
                continuation.resume(throwing: LLMError.networkError("Command timed out after \(Int(self.timeoutSeconds))s"))
            }

            process.terminationHandler = { proc in
                guard finishGate.tryFinish() else { return }
                timer.cancel()

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                var output = ""
                if let out = String(data: outData, encoding: .utf8), !out.isEmpty {
                    output += out
                }
                if let err = String(data: errData, encoding: .utf8), !err.isEmpty {
                    if !output.isEmpty { output += "\n" }
                    output += err
                }

                continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            do {
                try process.run()
                timer.resume()
            } catch {
                guard finishGate.tryFinish() else { return }
                timer.cancel()
                continuation.resume(throwing: LLMError.networkError("Failed to launch process: \(error.localizedDescription)"))
            }
        }
    }
}

private final class FinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
