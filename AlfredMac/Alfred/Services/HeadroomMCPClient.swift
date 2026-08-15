//
//  HeadroomMCPClient.swift
//  Alfred
//
//  Token compression for Hermes' context, via Headroom
//  (headroomlabs-ai/headroom). Headroom compresses tool outputs, file
//  listings, logs and JSON before they reach the model — 15-20% fewer tokens
//  for code, 60-95% for JSON — and stores the originals locally so the model
//  can retrieve them on demand (CCR). Everything runs on this Mac; nothing
//  leaves it.
//
//  Two roles:
//
//   1. MCP server for Hermes. Alfred registers `headroom mcp serve` in
//      ~/.alfred/agent-servers.json — the same mechanism that injects
//      odysseus, graphiti, prime-agent and the rest. Every Hermes session
//      then carries headroom_compress / headroom_retrieve / headroom_stats,
//      so the agent itself decides when a big tool result (a directory
//      listing, a grep, a diff) is worth shrinking before it eats context
//      window space.
//
//   2. Client for Alfred's own prompts. Alfred's orchestration embeds real
//      content into model prompts (the mail copilot sends email bodies); the
//      client below shrinks those before they go in. User-facing copy is
//      never touched — only what is sent *to the model*.
//
//  Everything degrades gracefully: if the `headroom` binary isn't installed,
//  the feature is disabled, or a call fails, the original content passes
//  through unchanged and a single log line explains why. Compression never
//  blocks Alfred — a wedged server is killed and skipped, not awaited
//  forever.
//
//  Install (one-time, on the Mac):
//      uv tool install --python 3.13 "headroom-ai[all]"
//  The client discovers the binary on PATH / ~/.local/bin; registering in
//  agent-servers.json applies on the next Hermes session spawn.

import Foundation

// MARK: - Settings

/// How aggressively Alfred bothers to compress before a model call.
///
/// Headroom itself routes content by type (SmartCrusher for JSON, AST-aware
/// for code, Kompress for prose) — there is no per-call strength knob in the
/// MCP tool. This dial controls *when Alfred compresses*: aggressive drops
/// the floor much lower, so more content gets sent through Headroom even when
/// the expected savings are small.
enum HeadroomCompressionLevel: String, CaseIterable {
    case moderate
    case aggressive

    /// Content shorter than this is left alone — the round-trip costs more
    /// than the savings are worth.
    var minimumCompressibleLength: Int {
        switch self {
        case .moderate: return 1500
        case .aggressive: return 400
        }
    }

    var displayName: String {
        switch self {
        case .moderate: return "Moderate"
        case .aggressive: return "Aggressive"
        }
    }
}

// MARK: - Client

/// Owns Headroom's integration with Alfred: registration of the MCP server
/// Hermes spawns, plus a local stdio MCP client for Alfred's own prompts.
final class HeadroomMCPClient {

    static let shared = HeadroomMCPClient()

    // MARK: Persisted settings

    private let enabledKey = "alfred.headroomEnabled"
    private let levelKey = "alfred.headroomLevel"

    /// Master switch. Off means nothing is registered and no content is
    /// compressed. Defaults ON — the user asked for token compression by
    /// default, and the feature no-ops cleanly when Headroom is absent.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    var compressionLevel: HeadroomCompressionLevel {
        get {
            UserDefaults.standard.string(forKey: levelKey)
                .flatMap(HeadroomCompressionLevel.init(rawValue:)) ?? .moderate
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        // Registration follows the switch immediately: turning it on wires the
        // server in for the next session spawn, turning it off pulls it out.
        _ = enabled ? ensureRegisteredIfEnabled() : unregister()
    }

    // MARK: Binary discovery

    /// The absolute path to the `headroom` binary, or nil if not installed.
    /// Cached because shell probing is slow; `refreshBinary()` re-probes when
    /// the user installs Headroom while Alfred is running.
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

    /// Search the places `uv tool install` and friends put executables, then
    /// fall back to a login shell's PATH (uv update-shell appends ~/.local/bin
    /// there). Returns an absolute path the registration can point at — the
    /// MCP server Hermes spawns must not depend on a guessed PATH.
    static func resolveBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/headroom",
            "/usr/local/bin/headroom",
            "/opt/homebrew/bin/headroom",
            "\(home)/Library/Python/3.13/bin/headroom",
            "\(home)/Library/Python/3.12/bin/headroom",
            "\(home)/Library/Python/3.11/bin/headroom",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Login shell probe: respects the user's actual PATH (homebrew,
        // uv tool dirs, pyenv shims).
        guard let output = Self.runCapture(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v headroom"],
            timeout: 5),
            let line = output.split(separator: "\n").first
        else { return nil }
        let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: Registration (~/.alfred/agent-servers.json)

    private static let agentServersPath = "\(NSHomeDirectory())/.alfred/agent-servers.json"

    /// Register `headroom mcp serve` so every Hermes session Alfred starts can
    /// compress its own tool outputs. Idempotent: preserves the other servers
    /// and their order, replaces an existing headroom entry, writes a backup
    /// first. No-op (returns false) when disabled or the binary is missing.
    @discardableResult
    func ensureRegisteredIfEnabled() -> Bool {
        guard isEnabled else { return unregister() }
        guard let binary = binaryPath ?? Self.resolveBinary() else {
            didProbeBinary = true   // cache the miss — don't re-probe every call
            logUnavailableOnce()
            return false
        }
        binaryPath = binary
        didProbeBinary = true
        return Self.setAgentServer(name: "headroom", command: binary, args: ["mcp", "serve"])
    }

    /// Pull the headroom entry out of agent-servers.json, leaving everything
    /// else intact.
    @discardableResult
    func unregister() -> Bool {
        Self.setAgentServer(name: "headroom", command: nil, args: nil)
    }

    /// Merge (or remove, when `command` is nil) one server entry into the live
    /// config. Preserves order and all unrelated entries; writes a timestamped
    /// backup before touching the file, like scripts/merge_agent_servers.py.
    private static func setAgentServer(name: String, command: String?, args: [String]?) -> Bool {
        guard let data = FileManager.default.contents(atPath: agentServersPath),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // A missing or corrupt config can't be edited safely — Alfred keeps
            // its own registration out of it rather than clobbering a file the
            // user (or setup.sh) owns.
            NSLog("[headroom] agent-servers.json unreadable — not registering")
            return false
        }

        var servers = (json["servers"] as? [[String: Any]]) ?? []
        let current = servers.first { ($0["name"] as? String) == name }

        // Build the desired entry (nil means "absent").
        let desired: [String: Any]?
        if let command, !command.isEmpty {
            var entry: [String: Any] = ["name": name, "command": command]
            entry["args"] = args ?? []
            entry["env"] = []
            desired = entry
        } else {
            desired = nil
        }

        // Already in the exact state asked for? Don't touch the file at all —
        // launch calls this every boot, and a rewritten file churns the
        // user-editable config plus a .bak per launch for nothing.
        let matches = (desired == nil && current == nil)
            || (desired != nil && current != nil
                && NSDictionary(dictionary: desired!).isEqual(to: current!))
        if matches { return true }

        servers.removeAll { ($0["name"] as? String) == name }
        if let desired { servers.append(desired) }
        json["servers"] = servers

        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            // Backup before writing, so an edit gone wrong is never destructive.
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.copyItem(atPath: agentServersPath,
                                              toPath: "\(agentServersPath).bak.\(stamp)")
            try out.write(to: URL(fileURLWithPath: agentServersPath), options: .atomic)
            NSLog("[headroom] agent-servers.json updated — '%@' \(command == nil ? "removed" : "registered")",
                  name)
            return true
        } catch {
            NSLog("[headroom] could not write agent-servers.json: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: Compression API (for Alfred's own prompts)

    /// Shrink `content` before it goes into a model prompt. Returns the
    /// original when disabled, when Headroom is missing, or when compression
    /// fails or doesn't help — callers can always pass the result straight
    /// through.
    func compressForContext(_ content: String) async -> String {
        guard isEnabled else { return content }
        guard content.count >= compressionLevel.minimumCompressibleLength else { return content }
        guard let result = await compress(content) else { return content }
        // Only swap when Headroom actually shrank it. A passthrough returns the
        // same text; occasional growth (exotic encodings) must never make a
        // prompt larger on purpose.
        return result.compressedString.count < content.count ? result.compressedString : content
    }

    /// One headroom_compress call. Returns nil on any failure — the caller
    /// falls back to the original content.
    func compress(_ content: String) async -> CompressResult? {
        guard isEnabled, isAvailable else { return nil }
        guard let session = await ensureSession() else {
            logUnavailableOnce()
            return nil
        }
        guard let dict = await session.call(
            tool: "headroom_compress",
            arguments: ["content": content],
            timeout: 60) else { return nil }
        return CompressResult(dict: dict)
    }

    /// One headroom_retrieve call — the full original for a previously
    /// compressed hash. Returns nil when the store no longer has it.
    func retrieve(hash: String) async -> String? {
        guard isEnabled, isAvailable else { return nil }
        guard let session = await ensureSession() else { return nil }
        guard let dict = await session.call(
            tool: "headroom_retrieve",
            arguments: ["hash": hash],
            timeout: 30) else { return nil }
        // The server may wrap the original in JSON (original_content) or hand
        // it back as bare text (a content[0].text the decoder surfaced as
        // "text") — accept both.
        let original = dict["original_content"] as? String ?? dict["text"] as? String
        return (original?.isEmpty == false) ? original : nil
    }

    /// headroom_stats — a human-readable session summary, or nil.
    func stats() async -> String? {
        guard isEnabled, isAvailable else { return nil }
        guard let session = await ensureSession() else { return nil }
        guard let dict = await session.call(tool: "headroom_stats", arguments: [:], timeout: 30) else {
            return nil
        }
        return dict["text"] as? String
    }

    // MARK: Session plumbing

    /// One long-lived `headroom mcp serve` subprocess, reused across calls so
    /// the CCR store and model warmup survive. Created lazily and replaced if
    /// it dies.
    private var session: HeadroomMCPSession?
    private let sessionLock = NSLock()

    private func ensureSession() async -> HeadroomMCPSession? {
        if let live = currentSession(), live.isAlive { return live }

        guard let binary = binaryPath ?? Self.resolveBinary() else {
            didProbeBinary = true   // cache the miss — don't re-probe every call
            logUnavailableOnce()
            return nil
        }
        binaryPath = binary
        didProbeBinary = true

        // Spawn + handshake happen off the caller's actor: the handshake can
        // block up to 15s on a cold start, and callers (MailAIService) run on
        // the main actor. A background spawn keeps the UI alive.
        let fresh = await Task.detached(priority: .utility) {
            HeadroomMCPSession(binary: binary)
        }.value
        setSession(fresh)
        return fresh
    }

    /// Lock-guarded session access. Kept synchronous (not called from within
    /// an async body's lock region) so NSLock use stays out of async context.
    private func currentSession() -> HeadroomMCPSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session
    }

    private func setSession(_ fresh: HeadroomMCPSession?) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        session = fresh
    }

    private func logUnavailableOnce() {
        guard !loggedUnavailable else { return }
        loggedUnavailable = true
        NSLog("[headroom] binary not found — token compression is off. Install: uv tool install --python 3.13 \"headroom-ai[all]\"")
    }

    // MARK: Process helper

    /// Capture a short-lived command's stdout, with a hard timeout.
    private static func runCapture(executable: String, arguments: [String],
                                   timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // EOF on stdout means the process has exited and all its output has
        // landed — so draining *is* the completion signal. Waiting on this
        // (rather than termination) means `output` is fully written before the
        // caller reads it; no cross-thread race.
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

// MARK: - Compress result

/// What headroom_compress returns: the compressed text plus a hash that
/// retrieves the original. `compressedString` handles the JSON-array case
/// where Headroom hands back a structure rather than prose.
struct CompressResult {
    let compressed: Any?
    let hash: String
    let originalTokens: Int
    let compressedTokens: Int
    let tokensSaved: Int
    let savingsPercent: Double

    init?(dict: [String: Any]) {
        guard let hash = dict["hash"] as? String else { return nil }
        compressed = dict["compressed"]
        self.hash = hash
        originalTokens = dict["original_tokens"] as? Int ?? 0
        compressedTokens = dict["compressed_tokens"] as? Int ?? 0
        tokensSaved = dict["tokens_saved"] as? Int ?? 0
        savingsPercent = dict["savings_percent"] as? Double ?? 0
    }

    /// The compressed text as a string. Headroom may return a parsed JSON
    /// structure for array-heavy content — round-trip it through JSON so the
    /// model still sees one text block.
    var compressedString: String {
        if let string = compressed as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: compressed ?? ""),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

// MARK: - MCP session

/// Speaks MCP (JSON-RPC 2.0, newline-delimited over stdio) to one
/// `headroom mcp serve` subprocess: initialize handshake, then tools/call.
///
/// Request/response correlation is the same shape as the iOS WebSocket
/// client's pending map: every request gets an id, the reader thread routes
/// each frame to the waiting closure, and a timeout resolves nil so a wedged
/// server can never hold a prompt hostage.
///
/// Thread-safe by construction: all mutable state (buffer, id counter, the
/// pending map) is guarded by `lock`, so the reader thread, the timeout path
/// and callers can touch it concurrently. `@unchecked Sendable` records that
/// safety for the concurrency checker — the timeout closures hop across
/// threads by design.
final class HeadroomMCPSession: @unchecked Sendable {

    private let process: Process
    private let stdin: FileHandle
    private let queue = DispatchQueue(label: "com.alfred.headroom.session")
    private let lock = NSLock()

    private var buffer = Data()
    private var nextID = 1
    /// id → completion. Guarded by `lock`; the reader thread and the timeout
    /// path both mutate it.
    private var pending: [Int: ([String: Any]?) -> Void] = [:]
    private var isRunning = true

    var isAlive: Bool {
        lock.lock()
        let running = isRunning
        lock.unlock()
        return running && process.isRunning
    }

    init?(binary: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["mcp", "serve"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        do {
            try proc.run()
        } catch {
            NSLog("[headroom] failed to spawn %@: %@", binary, error.localizedDescription)
            return nil
        }

        process = proc
        stdin = inputPipe.fileHandleForWriting

        // Drain stderr on its own thread so a verbose server can never fill
        // the pipe and wedge.
        Thread {
            while true {
                let data = errorPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
            }
        }.start()

        // Reader thread: newline-delimited JSON-RPC frames. EOF means the
        // server died — resolve every waiter with nil.
        Thread { [weak self] in
            while true {
                let data = outputPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                self?.queue.async {
                    guard let self else { return }
                    self.buffer.append(data)
                    self.drainBuffer()
                }
            }
            self?.queue.async {
                guard let self else { return }
                self.failAll()
            }
        }.start()

        // Handshake. A fresh process must answer initialize before anything
        // else routes; a 15s stall means the server is unusable — kill it
        // rather than let the first compression hang a mail turn.
        let handshake = DispatchSemaphore(value: 0)
        var initialized = false
        let initFrame: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "alfred", "version": "1"],
            ],
        ]
        sendFrame(initFrame) { response in
            initialized = (response?["result"] as? [String: Any])?["protocolVersion"] != nil
            handshake.signal()
        }
        if handshake.wait(timeout: .now() + 15) != .success || !initialized {
            NSLog("[headroom] MCP initialize timed out or was rejected — server unusable")
            proc.terminate()
            return nil
        }
        // The MCP SDK expects the initialized notification before tools/call.
        sendNotification(method: "notifications/initialized")
    }

    /// One tools/call round trip. Returns the decoded tool result (the JSON
    /// dict the server embedded in content[0].text), or nil on error,
    /// timeout, or server death.
    func call(tool: String, arguments: [String: Any], timeout: TimeInterval)
        async -> [String: Any]? {
        let params: [String: Any] = ["name": tool, "arguments": arguments]
        let requestID = nextRequestID()

        return await withCheckedContinuation { continuation in
            lock.lock()
            pending[requestID] = { response in
                continuation.resume(returning: Self.decodeToolResult(response))
            }
            lock.unlock()

            var frame: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "tools/call",
                "params": params,
            ]
            writeFrame(&frame)

            // Timeout: resolve nil after `timeout` and kill the session. A
            // wedged-but-alive server would otherwise keep burning the full
            // timeout on every future call — marking it dead (and terminating
            // the process) makes ensureSession() spawn a fresh one next time.
            // If the response landed in the instant before the deadline the
            // pending entry is already gone (handler == nil) — the call
            // succeeded, so leave the server alone.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let handler = self.pending.removeValue(forKey: requestID)
                self.lock.unlock()
                if handler == nil { return }   // answered just in time
                handler?(nil)
                self.markFailed()
            }
        }
    }

    // MARK: - Writes

    /// Allocate the next request id (lock-guarded; the reader thread never
    /// allocates, only resolves).
    private func nextRequestID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    /// Register a completion under a fresh id and write the frame. The id is
    /// stamped in — callers that already know it use `call` instead.
    @discardableResult
    private func sendFrame(_ frame: [String: Any],
                           completion: @escaping ([String: Any]?) -> Void) -> Int {
        let id = nextRequestID()
        lock.lock()
        pending[id] = completion
        lock.unlock()
        var stamped = frame
        stamped["id"] = id
        writeFrame(&stamped)
        return id
    }

    /// A fire-and-forget notification: no id, no pending entry, no reply.
    private func sendNotification(method: String) {
        var frame: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": [:]]
        writeFrame(&frame)
    }

    private func writeFrame(_ frame: inout [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        var line = data
        line.append(0x0A)
        try? stdin.write(contentsOf: line)
    }

    // MARK: - Reads

    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = frame["id"] as? Int
            else { continue }
            lock.lock()
            let handler = pending.removeValue(forKey: id)
            lock.unlock()
            handler?(frame)
        }
    }

    /// The process died: every caller waiting on it gets nil, so no prompt is
    /// ever left hanging on a dead server.
    private func failAll() {
        lock.lock()
        isRunning = false
        let all = pending
        pending.removeAll()
        lock.unlock()
        for (_, handler) in all { handler(nil) }
    }

    /// Flag the session dead and tear the process down so the next call spawns
    /// a replacement. Used on timeout (wedged but still running) — the reader
    /// thread's EOF path calls `failAll` for a genuinely dead process.
    private func markFailed() {
        lock.lock()
        isRunning = false
        lock.unlock()
        process.terminate()
    }

    /// MCP tool results come back as result.content[0].text containing the
    /// JSON-encoded result dict. Errors surface as an `error` member, an
    /// `isError` result, or a non-tool envelope — all resolve to nil.
    private static func decodeToolResult(_ response: [String: Any]?) -> [String: Any]? {
        guard let response else { return nil }
        if response["error"] != nil { return nil }
        guard let result = response["result"] as? [String: Any] else { return nil }
        if (result["isError"] as? Bool) == true { return nil }
        if let content = result["content"] as? [[String: Any]],
           let first = content.first {
            if let text = first["text"] as? String {
                // Prefer a JSON-wrapped payload (headroom_compress returns a
                // dict: hash, original_tokens, …).
                if let data = text.data(using: .utf8),
                   let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    return decoded
                }
                // Otherwise surface the bare text under a stable key so
                // callers (stats, retrieve) can read it directly.
                return ["text": text]
            }
        }
        return result
    }
}
