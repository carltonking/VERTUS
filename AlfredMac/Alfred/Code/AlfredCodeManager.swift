import Foundation

// MARK: - Remote coding sessions (AlfredCode)
//
// AlfredCode is the phone's window into agentic coding on the Mac. A session
// pairs a user request with a project folder; the manager spawns a real coding
// agent (opencode or freebuff, both ACP-over-stdio) pointed at that folder,
// streams the agent's output to the phone in real time, and offers git + test
// operations against the project without ever auto-executing the generated
// code — the phone must tap "Run Tests" or "Commit" first.
//
// The wire shapes here are the shared contract with the iOS app — the phone's
// `CodeSessionSummary` / `CodeTestResultPayload` / `CodeGitStatusPayload`
// mirror them exactly (see Alfred/Alfred/Models/CodeSession.swift).

// MARK: - Models

/// What kind of project a folder is. Detected from manifest files so the
/// right test command can be offered.
enum ProjectType: String, Codable, Equatable {
    case node, python, swift, rust, go, ruby, java, other

    /// Look at the usual manifest files in `path` and name the project type.
    static func detect(at path: String) -> ProjectType {
        let fm = FileManager.default
        func has(_ name: String) -> Bool {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent(name))
        }
        if has("package.json") { return .node }
        if has("Package.swift") { return .swift }
        if has("Cargo.toml") { return .rust }
        if has("go.mod") { return .go }
        if has("pom.xml") || has("build.gradle") || has("build.gradle.kts") { return .java }
        if has("Gemfile") { return .ruby }
        if has("requirements.txt") || has("pyproject.toml") || has("setup.py") { return .python }
        return .other
    }

    /// The standard test command for this project type, or nil if there isn't
    /// an obvious one. Always run in the project directory.
    func testCommand() -> String? {
        switch self {
        case .node: return "npm test"
        case .python: return "python3 -m pytest -q"
        case .swift: return "swift test"
        case .rust: return "cargo test"
        case .go: return "go test ./..."
        case .ruby: return "bundle exec rspec"
        case .java: return "mvn test"
        case .other: return nil
        }
    }
}

/// Where a session is in its life cycle.
enum SessionStatus: String, Codable, Equatable {
    case idle
    case generating
    case paused
    case completed
    case error
}

/// The git state of a session's project: current branch and how dirty the
/// working tree is.
struct GitStatus: Codable, Equatable {
    var currentBranch: String
    var uncommittedChanges: Int
    var unstagedFiles: [String]
}

/// The outcome of one test run.
struct TestResult: Codable, Equatable {
    var success: Bool
    var output: String
    var duration: TimeInterval
    var command: String
}

/// A remote coding session. Persisted to `~/.alfred/code_sessions.json`
/// between launches; the running agent process itself is not.
struct CodeSession: Codable, Equatable, Identifiable {
    var sessionId: UUID
    var prompt: String
    var projectPath: String
    var projectType: ProjectType
    var status: SessionStatus
    /// Everything the agent has produced this session, appended chunk by chunk
    /// as it streams. What the phone shows and can copy.
    var generatedCode: String
    var gitStatus: GitStatus?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastTestResult: TestResult?

    var id: UUID { sessionId }
}

// MARK: - Manager

/// Owns remote code sessions end to end: spawn a coding agent per session,
/// stream its output to phones, and run git/test operations against the
/// project on demand. Sessions are kept in memory for the app lifetime and
/// persisted (minus running processes) to `~/.alfred/code_sessions.json`.
@MainActor
final class AlfredCodeManager {

    static let shared = AlfredCodeManager()

    /// Broadcast hooks, wired by the socket server to push `code.chunk` /
    /// `code.status` / `code.test_result` / `code.git_status` to phones.
    var onCodeChunk: ((UUID, String) -> Void)?
    var onSessionStatus: ((UUID, SessionStatus) -> Void)?
    var onTestResult: ((UUID, TestResult) -> Void)?
    var onGitStatus: ((UUID, GitStatus) -> Void)?

    /// How long a code generation may run before the agent session restarts.
    /// Coding turns are longer than a chat turn; a 10-minute ceiling covers a
    /// big generation without letting a wedged agent hold the Mac hostage.
    static let generationTimeout: TimeInterval = 600

    private var sessions: [CodeSession] = []
    /// The live agent per session. Sessions without one (completed, or never
    /// started) aren't in here.
    private var agents: [UUID: HermesSession] = [:]
    /// In-flight generation task per session — one at a time, cancelled on
    /// pause/stop/refine.
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonic lineage counter per session: bumped on every beginGeneration
    /// so a superseded turn can tell it's stale (see generate's guard).
    private var generationCounter: [UUID: Int] = [:]

    private let fileURL: URL

    private init() {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred") as NSString
        try? FileManager.default.createDirectory(atPath: dir as String, withIntermediateDirectories: true)
        fileURL = URL(fileURLWithPath: dir.appendingPathComponent("code_sessions.json"))
        load()
    }

    // MARK: - Query

    func listSessions() -> [CodeSession] { sessions }

    func session(id: UUID) -> CodeSession? {
        sessions.first { $0.sessionId == id }
    }

    // MARK: - Session lifecycle

    /// Start a coding session: detect the project type, spawn the agent in ACP
    /// mode at the project folder, and begin streaming. Throws on a bad path
    /// or an agent that can't launch; once the turn is running it reports via
    /// the broadcast hooks.
    func startSession(prompt: String, projectPath: String, agent engine: AgentEngine = .opencode) async throws -> CodeSession {
        let expanded = (projectPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CodeError.badPath("That folder doesn't exist on the Mac.")
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CodeError.emptyPrompt }

        let now = Date().timeIntervalSince1970
        let session = CodeSession(
            sessionId: UUID(),
            prompt: trimmed,
            projectPath: expanded,
            projectType: .detect(at: expanded),
            status: .idle,
            generatedCode: "",
            gitStatus: nil,
            createdAt: now,
            updatedAt: now)
        sessions.insert(session, at: 0)
        save()

        // The agent is created lazily per session so multiple sessions can run
        // independently and a crash in one never takes the app down.
        let agent = HermesSession(
            engine: engine,
            workingDirectory: expanded,
            turnDeadline: Self.generationTimeout)
        agents[session.sessionId] = agent

        beginGeneration(session.sessionId, prompt: trimmed, agent: agent)
        return session
    }

    /// Freeze a session's agent process. The agent stays alive (model context
    /// intact) but stops consuming CPU — generation halts mid-stream.
    ///
    /// If the agent process hasn't spawned yet (startSession just kicked off,
    /// the spawn is lazy inside the first prompt), suspending is a no-op — the
    /// status must not claim paused when nothing was frozen, or the UI would
    /// show Paused while generation streams underneath it.
    func pauseSession(id: UUID) async {
        guard let agent = agents[id] else { return }
        if let task = generationTasks[id], task.isCancelled { return }
        guard await agent.isProcessRunning() else { return }
        await agent.suspend()
        setStatus(id, .paused)
    }

    /// Unfreeze a paused session and let generation continue.
    func resumeSession(id: UUID) async {
        guard let agent = agents[id] else { return }
        await agent.resume()
        setStatus(id, .generating)
    }

    /// Kill a session's agent process and keep the transcript. The session
    /// record stays so the phone can copy what was produced or start over.
    func stopSession(id: UUID) async {
        generationTasks[id]?.cancel()
        generationTasks[id] = nil
        if let agent = agents.removeValue(forKey: id) {
            await agent.shutdown()
        }
        setStatus(id, .completed)
    }

    /// Delete a session's record entirely.
    func deleteSession(id: UUID) async {
        generationTasks[id]?.cancel()
        generationTasks[id] = nil
        if let agent = agents.removeValue(forKey: id) {
            await agent.shutdown()
        }
        sessions.removeAll { $0.sessionId == id }
        save()
    }

    /// Send a refinement request to the session's agent. Reuses the same
    /// process, so the agent's context from the original turn carries over.
    func refineCode(id: UUID, request: String) async throws {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CodeError.emptyPrompt }
        guard let agent = agents[id] else { throw CodeError.noAgent }
        beginGeneration(id, prompt: trimmed, agent: agent, isRefinement: true)
    }

    // MARK: - Generation

    /// Start (or restart) streaming a turn from `agent` into session `id`.
    /// A new turn supersedes any in-flight one — refine stops the old stream.
    private func beginGeneration(_ id: UUID, prompt: String, agent: HermesSession, isRefinement: Bool = false) {
        generationTasks[id]?.cancel()
        generationCounter[id, default: 0] += 1
        let generation = generationCounter[id, default: 0]
        let task = Task { [weak self] in
            guard let self else { return }
            await self.generate(id, prompt: prompt, agent: agent, generation: generation)
        }
        generationTasks[id] = task
    }

    /// `generation` is this turn's identity in the session's lineage. A turn
    /// only flips the status to completed if it's still the newest one — a
    /// superseded turn (cancelled by refine/stop) draining its stream must
    /// not clobber its replacement's `.generating` with `.completed`.
    private func generate(_ id: UUID, prompt: String, agent: HermesSession, generation: Int) async {
        // Ask the agent to work in the project. The prompt frames it as a
        // coding task, not a chat: the agent edits real files and reports back.
        let system = """
            You are AlfredCode, working in the project at the current working directory.
            The user asked: \(prompt)
            Implement it in the project. Write real code, create or edit the files that \
            need changing, and run the relevant checks if sensible. Then reply with a \
            concise summary of what you changed and why. If you wrote new code, include \
            the key parts in your reply so the phone can show them.
            """
        setStatus(id, .generating)
        var transcript = ""
        for await event in await agent.prompt(system, capture: false) {
            switch event {
            case .text(let chunk):
                transcript += chunk
                appendCode(id, chunk)
            case .failed(let message):
                appendCode(id, "\n\n⚠️ \(message)\n")
                setStatus(id, .error)
                return
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                break
            }
        }
        // A cancellation (refine/stop) ends the loop without a failure event.
        // A superseded turn's stream drains after its replacement started —
        // only the newest generation may declare the session completed, so a
        // stale turn can't hide a still-streaming refine's `.generating`.
        if let task = generationTasks[id], task.isCancelled { return }
        guard generationCounter[id] == generation else { return }
        setStatus(id, .completed)
    }

    // MARK: - Tests

    /// Run the project's test command, capture output, and report. Never
    /// throws — a failing test is a valid result, and a crashed runner comes
    /// back as a failure with the output it managed to print.
    func runTests(id: UUID) async -> TestResult {
        guard let session = session(id: id) else {
            return TestResult(success: false, output: "No such session.", duration: 0, command: "")
        }
        guard let command = session.projectType.testCommand() else {
            return TestResult(
                success: false,
                output: "No test command is defined for \(session.projectType.rawValue) projects.",
                duration: 0,
                command: "")
        }
        let started = Date()
        let result = await runProcess(
            executable: "/bin/zsh",
            arguments: ["-c", command],
            directory: session.projectPath,
            timeout: 120)
        let duration = Date().timeIntervalSince(started)
        let testResult = TestResult(
            success: result.exitCode == 0 && !result.timedOut,
            output: result.output,
            duration: duration,
            command: command)
        if let index = sessions.firstIndex(where: { $0.sessionId == id }) {
            sessions[index].lastTestResult = testResult
            sessions[index].updatedAt = Date().timeIntervalSince1970
            save()
        }
        onTestResult?(id, testResult)
        return testResult
    }

    // MARK: - Git

    func gitStatus(id: UUID) async -> GitStatus? {
        guard let session = session(id: id) else { return nil }
        let status = await readGitStatus(path: session.projectPath)
        if let index = sessions.firstIndex(where: { $0.sessionId == id }) {
            sessions[index].gitStatus = status
            sessions[index].updatedAt = Date().timeIntervalSince1970
            save()
        }
        onGitStatus?(id, status)
        return status
    }

    /// Read the current branch and working-tree dirtiness for a project.
    private func readGitStatus(path: String) async -> GitStatus {
        let branchResult = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            directory: path,
            timeout: 10)
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let porcelain = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["status", "--porcelain"],
            directory: path,
            timeout: 10)
        let lines = porcelain.output.split(separator: "\n").map(String.init)
        return GitStatus(
            currentBranch: branch.isEmpty ? "(detached)" : branch,
            uncommittedChanges: lines.count,
            unstagedFiles: lines.map { line in
                let parts = line.split(separator: " ", maxSplits: 1)
                return parts.count == 2 ? String(parts[1]) : line
            })
    }

    /// `git diff` for the session's project — what the phone's diff viewer shows.
    func gitDiff(id: UUID) async -> String {
        guard let session = session(id: id) else { return "" }
        let result = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["diff"],
            directory: session.projectPath,
            timeout: 15)
        return result.output
    }

    /// Stage everything and commit. Returns the short hash, or nil on failure.
    func gitCommit(id: UUID, message: String) async -> String? {
        guard let session = session(id: id) else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let addResult = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["add", "-A"],
            directory: session.projectPath,
            timeout: 15)
        guard addResult.exitCode == 0 else { return nil }
        let commitResult = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["commit", "-m", trimmed],
            directory: session.projectPath,
            timeout: 30)
        guard commitResult.exitCode == 0 else { return nil }
        let hashResult = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["rev-parse", "--short", "HEAD"],
            directory: session.projectPath,
            timeout: 10)
        return hashResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create a new branch (git checkout -b) and return the fresh git status.
    func gitCreateBranch(id: UUID, name: String) async -> GitStatus? {
        guard let session = session(id: id) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        _ = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["checkout", "-b", trimmed],
            directory: session.projectPath,
            timeout: 15)
        return await gitStatus(id: id)
    }

    /// Switch to an existing branch and return the fresh status.
    func gitSwitchBranch(id: UUID, name: String) async -> GitStatus? {
        guard let session = session(id: id) else { return nil }
        _ = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["checkout", name],
            directory: session.projectPath,
            timeout: 15)
        return await gitStatus(id: id)
    }

    /// Local branches (names only) for the phone's switch picker. The current
    /// branch is included so the sheet can mark it.
    func gitListBranches(id: UUID) async -> [String] {
        guard let session = session(id: id) else { return [] }
        let result = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["branch", "--list", "--format=%(refname:short)"],
            directory: session.projectPath,
            timeout: 10)
        return result.output.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Push the current branch to origin. Returns a human-readable outcome.
    func gitPush(id: UUID) async -> String {
        guard let session = session(id: id) else { return "No such session." }
        let branchResult = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            directory: session.projectPath,
            timeout: 10)
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return "No branch to push." }
        let result = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["push", "origin", branch],
            directory: session.projectPath,
            timeout: 60)
        return result.exitCode == 0 ? "Pushed \(branch)." : result.output
    }

    /// Pull the current branch from origin.
    func gitPull(id: UUID) async -> String {
        guard let session = session(id: id) else { return "No such session." }
        let result = await runProcess(
            executable: "/usr/bin/git",
            arguments: ["pull"],
            directory: session.projectPath,
            timeout: 60)
        return result.exitCode == 0 ? "Pulled latest." : result.output
    }

    // MARK: - Process helper

    private struct ProcessOutcome {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
    }

    /// A heap box for a mutable flag shared across queues; NSLock guards it.
    private final class TimeoutBox {
        var timedOut = false
    }

    /// Run a command to completion with a hard timeout. `timedOut` is true if
    /// the process had to be killed; `output` is combined stdout+stderr.
    private func runProcess(
        executable: String,
        arguments: [String],
        directory: String?,
        timeout: TimeInterval
    ) async -> ProcessOutcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory {
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
            }
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            // A lock-guarded flag shared by the timeout and the termination
            // handler, which run on different queues.
            let lock = NSLock()
            let boxed = TimeoutBox()

            // Drain both pipes on reader threads. They return exactly when the
            // child exits (the OS closes its fds), which sidesteps the classic
            // pipe-deadlock of draining one side while the other fills its
            // buffer — a chatty test suite must not wedge the run.
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            let outQueue = DispatchQueue(label: "alfred.code.out")
            let errQueue = DispatchQueue(label: "alfred.code.err")
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

            process.terminationHandler = { proc in
                // Wait a short beat so the reader threads' flush lands before
                // the result is read (mirrors TerminalCapability).
                _ = group.wait(timeout: .now() + 5)
                let output = (String(decoding: outData, as: UTF8.self)
                    + "\n" + String(decoding: errData, as: UTF8.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lock.lock()
                let timedOut = boxed.timedOut
                lock.unlock()
                continuation.resume(returning: ProcessOutcome(
                    output: output, exitCode: proc.terminationStatus, timedOut: timedOut))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessOutcome(
                    output: error.localizedDescription, exitCode: 1, timedOut: false))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    lock.lock()
                    boxed.timedOut = true
                    lock.unlock()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    // MARK: - State plumbing

    private func setStatus(_ id: UUID, _ status: SessionStatus) {
        guard let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
        sessions[index].status = status
        sessions[index].updatedAt = Date().timeIntervalSince1970
        save()
        onSessionStatus?(id, status)
    }

    private func appendCode(_ id: UUID, _ chunk: String) {
        guard let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
        sessions[index].generatedCode += chunk
        onCodeChunk?(id, chunk)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([CodeSession].self, from: data)
        else { return }
        // Agent processes don't survive a restart; any session that was mid-run
        // lands back on `.completed` with whatever it produced.
        sessions = stored.map { session in
            var s = session
            if s.status == .generating || s.status == .paused {
                s.status = .completed
            }
            return s
        }
    }
}

// MARK: - Errors

enum CodeError: LocalizedError {
    case badPath(String)
    case emptyPrompt
    case noAgent

    var errorDescription: String? {
        switch self {
        case .badPath(let message): return message
        case .emptyPrompt: return "Describe what you want built."
        case .noAgent: return "That session has no running agent."
        }
    }
}
