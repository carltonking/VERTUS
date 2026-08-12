import Foundation

/// What one `TerminalCapability.run` call produced: the command's combined
/// output, its exit code, and whether the timeout fired (in which case the exit
/// code is whatever the SIGKILL produced, typically 128+9).
struct TerminalResult {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
}

/// Runs a single shell command for the bar.
///
/// Every run is a fresh, non-interactive `/bin/zsh` process. There is no shell
/// state to leak between commands and no long-lived reading of the user's own
/// Terminal session — this is Alfred's sandbox to a command, not control of
/// their interactive terminal.
///
/// The safety model matches computer control: this capability can execute
/// arbitrary code as the user, so **this struct must never run a command on its
/// own**. AlfredToolServer holds the gate — terminal access is always enabled,
/// with a fast-fail blocklist for commands that are never OK. This file only
/// makes the command run and returns what it printed.
struct TerminalCapability {

    static let shared = TerminalCapability()

    /// Run a command and wait for it. Blocks up to `timeout` seconds; if the
    /// command is still alive then it is SIGKILLed and reported as `timedOut`.
    /// Output is combined stdout+stderr so the ordering of interleaved writes
    /// survives.
    func run(_ command: String, directory: String? = nil, timeout: TimeInterval = 30) -> TerminalResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0) }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes on reader threads. They return exactly when the
        // child exits (the OS closes its fds), which sidesteps the classic
        // pipe-deadlock of draining one side while the other fills its buffer.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let outQueue = DispatchQueue(label: "com.alfred.terminal.out")
        let errQueue = DispatchQueue(label: "com.alfred.terminal.err")
        group.enter()
        outQueue.async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQueue.async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return TerminalResult(output: "Couldn't launch: \(error.localizedDescription)",
                                  exitCode: 1, timedOut: false)
        }

        // Poll for exit; SIGKILL once the deadline passes so the bar is never
        // wedged by a hung command.
        var didTimeout = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                // SIGTERM first, then SIGKILL once the child's had a beat to
                // exit cleanly — a sandboxed command that hangs must not choke
                // the bar.
                process.terminate()
                usleep(200_000)
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                didTimeout = true
                break
            }
            usleep(50_000)
        }
        // The reader threads finish once the child exits; wait a short beat so
        // their flush lands before the result is read.
        _ = group.wait(timeout: .now() + 5)

        let output = (String(decoding: outData, as: UTF8.self)
            + "\n" + String(decoding: errData, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return TerminalResult(output: output,
                              exitCode: process.terminationStatus,
                              timedOut: didTimeout)
    }

    /// Fast-path refusal for commands that are never worth running. A blocklist,
    /// so it is necessarily incomplete — **it is not the safety control.** The
    /// human approval in AlfredToolServer is; this only avoids bothering the
    /// user with commands the assistant should never even ask about.
    static func isBlocked(_ command: String) -> Bool {
        let terms = [
            // Irreversible filesystem damage.
            "rm -rf", "rm -fr", "rm -f", "unlink ", "mv /", "chown -R", "chmod -R",
            "mkfs", "diskutil erase", "diskutil unmountDisk", "dd if=",
            // System tampering that would survive a reboot or change boot state.
            "sudo ", "sudo\n", "reboot", "shutdown", "halt", "csrutil",
            "launchctl unload", "defaults delete", "systemsetup",
            // Pipelines that fetch and run remote code.
            "curl | sh", "curl|sh", "curl |bash", "curl -sSL", "wget | sh",
            "wget -O- | sh", "| bash", "| sh",
        ]
        return terms.contains { command.contains($0) }
    }
}