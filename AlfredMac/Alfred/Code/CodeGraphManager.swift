import Foundation

// MARK: - Code graph (CodeGraph)
//
// CodeGraph (colbymchenry/codegraph) pre-indexes a project into a queryable
// knowledge graph — every symbol, call edge and dependency — so a coding agent
// answers structural questions ("where are the database queries?", "what calls
// this?") from one surgical payload instead of crawling files with grep/read.
// 100% local (SQLite in the project's .codegraph/), native FSEvents auto-sync.
//
// Alfred uses it two ways:
//
//   1. MCP server for the coding agent. Each code session spawns Hermes with
//      `workingDirectory: projectPath`, so a `codegraph serve --mcp` entry on
//      that session's mcpServers inherits the project cwd and serves the right
//      graph (codegraph_explore / codegraph_search / codegraph_callers /
//      codegraph_impact). This is per-session, deliberately NOT in
//      agent-servers.json: a global registration would serve whatever
//      directory Hermes happens to run in, which is wrong for the bar session.
//
//   2. Context injection. Before the agent starts, Alfred asks the graph for
//      a context package about the user's task (`codegraph context "<prompt>"`)
//      and prepends a bounded copy to the system prompt — the "don't explore
//      blindly" win. Capped: the graph's payloads are dense, and the README's
//      own benchmarks note they keep resident context high, so injection is
//      short and the MCP tools carry the deep queries.
//
// Everything degrades gracefully: binary missing, feature disabled, a project
// that never got indexed, or any CLI failure → the session runs exactly as
// before (no MCP entry, no context block) and a single log line explains why.
//
// Install (one-time, on the Mac):
//     curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh
//   or: npm i -g @colbymchenry/codegraph

@MainActor
final class CodeGraphManager {

    static let shared = CodeGraphManager()

    // MARK: Persisted settings

    private let enabledKey = "alfred.codeGraphEnabled"
    private let indexOnLoadKey = "alfred.codeGraphIndexOnLoad"

    /// Master switch. Off means no indexing, no MCP injection and no context
    /// blocks — code sessions run exactly as before. Defaults ON.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Index a project automatically when a session starts there. Defaults ON;
    /// the alternative is indexing on demand from the phone (code.graph_index).
    var indexOnLoad: Bool {
        UserDefaults.standard.object(forKey: indexOnLoadKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    func setIndexOnLoad(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: indexOnLoadKey)
    }

    // MARK: Binary discovery

    /// The absolute path to the `codegraph` binary, or nil if not installed.
    private(set) var binaryPath: String?
    private var didProbeBinary = false
    private var loggedUnavailable = false

    func refreshBinary() {
        binaryPath = Self.resolveBinary()
        didProbeBinary = true
    }

    var isAvailable: Bool {
        if !didProbeBinary { refreshBinary() }
        return binaryPath != nil
    }

    /// Search the places the standalone installer and npm put the binary, then
    /// fall back to a login shell's PATH (the installer appends ~/.local/bin /
    /// ~/.codegraph-bin to PATH, which a GUI launch doesn't inherit).
    nonisolated static func resolveBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.codegraph/bin/codegraph",
            "\(home)/.local/bin/codegraph",
            "/usr/local/bin/codegraph",
            "/opt/homebrew/bin/codegraph",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let output = runCapture(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v codegraph"],
            directory: nil,
            timeout: 5),
            let line = output.split(separator: "\n").first
        else { return nil }
        let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: Per-project index state

    /// Where a project's graph stands. Cached so the phone's status calls are
    /// instant after the first real check.
    enum IndexState: Equatable {
        case notInstalled       // codegraph binary missing
        case notIndexed         // no .codegraph/ yet
        case indexing           // codegraph init / index in flight
        case ready(fileCount: Int, symbolCount: Int)
        case failed(String)     // init ran but didn't produce a usable graph

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    /// Broadcast hooks, wired by the socket server to push `code.graph_status`
    /// to phones when a background index finishes.
    var onStateChange: ((String, IndexState) -> Void)?

    private var states: [String: IndexState] = [:]

    func indexState(projectPath: String) -> IndexState {
        states[projectPath] ?? .notIndexed
    }

    // MARK: Index lifecycle

    /// Make sure a project has a usable graph, then return its state. Fast path
    /// for an already-indexed project (a .codegraph/ existence check); a fresh
    /// project runs `codegraph init` (creates .codegraph/ and builds the graph
    /// in one step — the README's canonical command). Never throws; failures
    /// come back as .failed and the session proceeds without the graph.
    func ensureIndexed(projectPath: String) async -> IndexState {
        guard isEnabled else { return .notIndexed }
        guard isAvailable else { return .notInstalled }

        let expanded = (projectPath as NSString).expandingTildeInPath
        let graphDir = (expanded as NSString).appendingPathComponent(".codegraph")

        // Already indexed → refresh status quickly (the auto-sync watcher keeps
        // it current, so a full re-init is never needed on this path).
        if FileManager.default.fileExists(atPath: graphDir) {
            let refreshed = await readStatus(projectPath: expanded)
            let state: IndexState = refreshed.map {
                .ready(fileCount: $0.fileCount, symbolCount: $0.symbolCount)
            } ?? .ready(fileCount: 0, symbolCount: 0)
            states[expanded] = state
            return state
        }

        // Fresh project: index it. Run the process off the main actor so a
        // big first index can't stall session start indefinitely; the phone
        // learns the outcome through the status broadcast.
        guard let binary = binaryPath else { return .notInstalled }

        states[expanded] = .indexing
        onStateChange?(expanded, .indexing)
        NSLog("[codegraph] indexing %@…", expanded)

        let outcome = await Task.detached(priority: .utility) {
            Self.runCapture(
                executable: binary,
                arguments: ["init"],
                directory: expanded,
                timeout: 600)   // a 10k-file repo can take a while first time
        }.value

        let state: IndexState
        if FileManager.default.fileExists(atPath: graphDir) {
            let status = await readStatus(projectPath: expanded)
            state = status.map {
                .ready(fileCount: $0.fileCount, symbolCount: $0.symbolCount)
            } ?? .ready(fileCount: 0, symbolCount: 0)
            NSLog("[codegraph] indexed \(expanded) (\(outcome?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80) ?? "done"))")
        } else {
            let detail = outcome?.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200) ?? ""
            state = .failed(detail.isEmpty ? "codegraph init produced no graph" : String(detail))
            NSLog("[codegraph] init failed for \(expanded): \(state)")
        }
        states[expanded] = state
        onStateChange?(expanded, state)
        return state
    }

    /// Re-run a full index (`codegraph index --force`). Used by the phone's
    /// manual "re-index" affordance when a graph looks stale.
    func reindex(projectPath: String) async -> IndexState {
        guard isAvailable, let binary = binaryPath else { return .notInstalled }
        let expanded = (projectPath as NSString).expandingTildeInPath
        states[expanded] = .indexing
        onStateChange?(expanded, .indexing)
        _ = await Task.detached(priority: .utility) {
            Self.runCapture(
                executable: binary,
                arguments: ["index", "--force"],
                directory: expanded,
                timeout: 600)
        }.value
        return await ensureIndexed(projectPath: expanded)
    }

    // MARK: Queries (CLI)

    /// The AI-consumable context package for a task — the graph's answer to
    /// "what does this involve?", handed to the agent before it starts. Capped
    /// so a dense payload can't blow the prompt; deep queries go through the
    /// MCP tools instead. Nil when the graph isn't ready.
    func context(for task: String, projectPath: String) async -> String? {
        guard isEnabled, isAvailable, let binary = binaryPath else { return nil }
        let expanded = (projectPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent(".codegraph"))
        else { return nil }
        // Direct Process arguments — no shell layer, so a task containing
        // `$(…)`, backticks or quotes can never execute anything. codegraph
        // takes the task as a single positional argument.
        let output = await Task.detached(priority: .utility) {
            Self.runCapture(
                executable: binary,
                arguments: ["context", task],
                directory: expanded,
                timeout: 30)
        }.value
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxContextCharacters))
    }

    /// Symbol search over the graph (FTS5). Returns the raw result text — the
    /// phone shows it as-is. Nil when the graph isn't ready.
    func search(query: String, projectPath: String) async -> String? {
        guard isEnabled, isAvailable, let binary = binaryPath else { return nil }
        let expanded = (projectPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent(".codegraph"))
        else { return nil }
        let output = await Task.detached(priority: .utility) {
            Self.runCapture(
                executable: binary,
                arguments: ["query", query],
                directory: expanded,
                timeout: 15)
        }.value
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A project's graph status for the phone: indexed?, file/symbol counts,
    /// plus the raw `codegraph status` text. Never throws — a missing binary or
    /// an unindexed project are states, not errors.
    func status(projectPath: String) async -> (indexed: Bool, fileCount: Int, symbolCount: Int, text: String) {
        guard isAvailable else {
            return (indexed: false, fileCount: 0, symbolCount: 0, text: "CodeGraph isn't installed on the Mac.")
        }
        let expanded = (projectPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent(".codegraph")) else {
            return (indexed: false, fileCount: 0, symbolCount: 0, text: "This project isn't indexed yet.")
        }
        let parsed = await readStatus(projectPath: expanded)
        return (indexed: true,
                fileCount: parsed?.fileCount ?? 0,
                symbolCount: parsed?.symbolCount ?? 0,
                text: parsed?.text ?? "Indexed.")
    }

    // MARK: - Status parsing

    /// Bounded context injection — the README's own benchmarks show graph
    /// payloads keep context resident, so the prompt copy stays short and the
    /// MCP tools carry deep exploration.
    nonisolated static let maxContextCharacters = 2_500

    /// Run `codegraph status` and pull the file/symbol counts out of its report
    /// ("N nodes", "M files", "K edges" — defensively: any line mentioning a
    /// count word is matched, and a parse miss just yields zeros with the raw
    /// text intact).
    private func readStatus(projectPath: String) async -> (fileCount: Int, symbolCount: Int, text: String)? {
        guard let binary = binaryPath else { return nil }
        let output = await Task.detached(priority: .utility) {
            Self.runCapture(
                executable: binary,
                arguments: ["status"],
                directory: projectPath,
                timeout: 10)
        }.value
        guard let output, !output.isEmpty else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fileCount: Self.count(near: "files", in: text, fallback: "file"),
                symbolCount: Self.count(near: "symbols", in: text, fallback: "nodes"),
                text: text)
    }

    /// Find the first number on a line that mentions one of the keywords, or
    /// near the standalone keyword. The CLI's exact layout isn't stable API, so
    /// this is deliberately tolerant — a miss reads as zero, never a crash.
    nonisolated static func count(near keywords: String..., in text: String, fallback: String) -> Int {
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains(fallback.lowercased()) || keywords.contains(where: { lower.contains($0.lowercased()) })
            else { continue }
            let tokens = line.split(whereSeparator: { !$0.isNumber })
            if let first = tokens.compactMap({ Int($0) }).first {
                return first
            }
        }
        return 0
    }

    // MARK: - Process helper

    /// Capture a short-lived command's stdout, with a hard timeout. EOF on
    /// stdout is the completion signal (the child exiting closes its fds), so
    /// the result is fully written before the caller reads it — no cross-thread
    /// race. Combined with the zsh -lc wrapper, this is how every codegraph CLI
    /// call runs.
    nonisolated static func runCapture(executable: String, arguments: [String],
                                       directory: String?, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let drained = DispatchSemaphore(value: 0)
        var output = ""
        DispatchQueue.global().async {
            output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            drained.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        guard drained.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return output
    }
}
