import Combine
import Foundation

// MARK: - Fine-tune manager

/// The closed loop: capture accepted conversations, periodically fine-tune
/// the local model, reload it. This class is the Swift orchestrator only —
/// the Python side (prepare_finetune_dataset.py, and a finetune.py or
/// equivalent) is assumed to exist and is invoked as subprocesses.
///
/// Nothing here blocks the app: the schedule timer fires on the main run
/// loop, and each run's heavy work (subprocess, I/O) happens inside a
/// detached Task. A failed run logs, sets a 24-hour retry, and never crashes
/// the app.
final class FineTuneManager: ObservableObject {

    static let shared = FineTuneManager()

    // MARK: Tuning knobs

    /// Minimum accepted captures before a run is worth doing.
    static let minAcceptedCaptures = 50
    /// Minimum gap between runs — fine-tuning daily at most.
    static let runCooldown: TimeInterval = 24 * 3600
    /// Hard ceiling for one training run (dataset + finetune).
    static let runDeadline: TimeInterval = 6 * 3600

    private enum Keys {
        static let lastRun = "alfred.last_finetune"
    }

    /// The directories / scripts the pipeline uses. Injectable for tests and
    /// user overrides; defaults are the project's real layout.
    private let projectDir: URL
    private let scriptsDir: URL
    private let datasetDir: URL
    private let capturesDir: URL
    private var prepareScriptURL: URL { scriptsDir.appendingPathComponent("prepare_finetune_dataset.py") }
    /// The finetune entry point. Resolved against the project's `Fine Tune/`
    /// layout (where the real trainers live): a general `finetune.py` wins,
    /// then the known router trainer. Nil when neither exists — the run then
    /// fails fast and distinctly rather than spawning a nonexistent script.
    private var finetuneScriptURL: URL? {
        let fineTuneDir = projectDir.appendingPathComponent("Fine Tune")
        let candidates = [
            fineTuneDir.appendingPathComponent("finetune.py"),
            fineTuneDir.appendingPathComponent("Llama 3.2 1B/train_router.py"),
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: Observable state

    /// True while a run is in flight — UI feedback.
    @Published private(set) var isFinetuning = false
    /// Human-readable outcome of the last run (or check).
    @Published private(set) var lastStatus = ""

    private let store: ConversationStore
    private var timer: Timer?
    private var runTask: Task<Void, Never>?

    init(projectDir: URL? = nil,
         scriptsDir: URL? = nil,
         datasetDir: URL? = nil,
         capturesDir: URL? = nil,
         store: ConversationStore? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let project = projectDir ?? home.appendingPathComponent("01 - PROJECTS/ALFRED")
        self.projectDir = project
        self.scriptsDir = scriptsDir ?? project.appendingPathComponent("AlfredMac/scripts")
        self.datasetDir = datasetDir
            ?? home.appendingPathComponent(".alfred/finetune/dataset")
        self.capturesDir = capturesDir
            ?? home.appendingPathComponent(".alfred/finetuning")
        self.store = store ?? .shared
        restoreStatus()
    }

    // MARK: - Scheduling

    /// Begin the hourly check. Idempotent.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, self.canFineTune() else { return }
            self.scheduleFineTune()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Also check once shortly after launch (first run may be due).
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, self.canFineTune() else { return }
            self.scheduleFineTune()
        }
        NSLog("[finetune] scheduled (hourly check, first run in 90s if due)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        runTask?.cancel()
        runTask = nil
    }

    /// Check the gates without starting anything: enough accepted captures
    /// and the cooldown since the last run has elapsed.
    func canFineTune() -> Bool {
        guard !isFinetuning else { return false }
        let accepted = store.recentAccepted(limit: Self.minAcceptedCaptures).count
        guard accepted >= Self.minAcceptedCaptures else { return false }

        let last = UserDefaults.standard.object(forKey: Keys.lastRun) as? Date
        if let last, Date().timeIntervalSince(last) < Self.runCooldown {
            return false
        }
        return true
    }

    /// Fire a run asynchronously (called by the timer, or on demand).
    func scheduleFineTune() {
        guard runTask == nil else { return }
        NSLog("[finetune] run due — starting")
        runTask = Task { [weak self] in
            await self?.runFineTune()
            self?.runTask = nil
        }
    }

    // MARK: - The run

    /// The heavy lifting. Steps:
    ///   1. Pull accepted captures from the store.
    ///   2. Write them as a JSONL dataset next to the DB-derived one.
    ///   3. Run prepare_finetune_dataset.py (DB history → train/valid).
    ///   4. Merge the captured conversations into the dataset.
    ///   5. Run the finetune script against it.
    ///   6. Reload the model server.
    /// Never throws to the caller — every failure is logged and retried.
    func runFineTune() async {
        await MainActor.run { isFinetuning = true }
        defer { Task { @MainActor in self.isFinetuning = false } }

        let captures = store.recentAccepted(limit: 100)
        guard captures.count >= Self.minAcceptedCaptures else {
            await MainActor.run { lastStatus = "needs \(Self.minAcceptedCaptures) accepted captures (have \(captures.count))" }
            NSLog("[finetune] skipped: only \(captures.count) accepted captures")
            return
        }

        do {
            // 2 — captured conversations, deduped, sanitized (store already
            // sanitizes at write time; belt-and-braces here).
            let capturesJSONL = try Self.capturesJSONL(captures)
            try capturesJSONL.write(
                to: capturesDir.appendingPathComponent("captures.jsonl"),
                options: .atomic)

            // 3 — DB history via the existing pipeline.
            try await Self.runSubprocess(
                executable: "/usr/bin/python3",
                arguments: [prepareScriptURL.path],
                logPrefix: "[finetune:prep]")

            // 4 — merge: captured exchanges belong in the training file too.
            let trainURL = datasetDir.appendingPathComponent("train.jsonl")
            try Self.mergeCaptures(into: trainURL, capturesJSONL: capturesJSONL)
            NSLog("[finetune] dataset ready at %@", trainURL.path)

            // 5 — the finetune script. Failure to find one is distinct and
            // quiet: the dataset is still valuable, and a trainer can be added
            // later without touching this code.
            guard let finetuneScript = finetuneScriptURL else {
                throw NSError(domain: "FineTuneManager", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "no finetune script found in \(projectDir.path)/Fine Tune — add finetune.py or a trainer there"])
            }
            try await Self.runSubprocess(
                executable: "/usr/bin/python3",
                arguments: [finetuneScript.path],
                logPrefix: "[finetune:train]")

            // 6 — reload: restart the Hermes session so the new weights are
            // picked up by the next turn.
            await reloadModelServer()
            UserDefaults.standard.set(Date(), forKey: Keys.lastRun)
            await MainActor.run { lastStatus = "fine-tuned \(captures.count) exchanges" }
            NSLog("[finetune] done — \(captures.count) exchanges, model reloaded")
        } catch {
            // Failure: log, don't crash. Write lastRun anyway so the 24h
            // cooldown throttles retries — a broken config must not become
            // an hourly subprocess storm.
            UserDefaults.standard.set(Date(), forKey: Keys.lastRun)
            NSLog("[finetune] run failed: %@ — retrying in \(Int(Self.runCooldown / 3600))h", error.localizedDescription)
            await MainActor.run { lastStatus = "failed: \(error.localizedDescription)" }
        }
    }

    /// Reload the local model: bounce the Hermes session so the freshly
    /// fine-tuned model is what the next turn uses.
    func reloadModelServer() async {
        let hermes = await MainActor.run { AppDelegate.shared?.hermes }
        guard let hermes else {
            NSLog("[finetune] no active session to reload — weights ready for next launch")
            return
        }
        await hermes.restart()
        NSLog("[finetune] Hermes session restarted — model reloaded")
    }

    // MARK: - Dataset assembly

    /// OpenAI/Fireworks JSONL rows from accepted captures: one line per
    /// exchange, sanitized, with system + user + assistant turns.
    static func capturesJSONL(_ captures: [ConversationCapture]) throws -> Data {
        var lines: [String] = []
        var seen: Set<String> = []
        let systemPrompt = "You are Alfred, a macOS AI assistant. Keep responses concise and direct."
        for cap in captures {
            let user = ConversationStore.sanitize(cap.userMessage).trimmingCharacters(in: .whitespacesAndNewlines)
            let asst = ConversationStore.sanitize(cap.assistantResponse).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !asst.isEmpty else { continue }
            // Dedupe on the user message — re-asked questions aren't new data.
            guard seen.insert(user).inserted else { continue }
            let example: [String: Any] = ["messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
                ["role": "assistant", "content": asst],
            ]]
            guard let data = try? JSONSerialization.data(withJSONObject: example),
                  let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
    }

    /// Append captured-conversation rows to the pipeline's train.jsonl,
    /// skipping duplicates already present. Validates the result: every line
    /// parses, and no content field is empty.
    static func mergeCaptures(into trainURL: URL, capturesJSONL: Data) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trainURL.path) else {
            // No DB-derived file (fresh DB) — the captures alone are the dataset.
            try capturesJSONL.write(to: trainURL, options: .atomic)
            return
        }
        let existing = try String(contentsOf: trainURL, encoding: .utf8)
        var existingUsers = Set<String>()
        var kept = existing.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for line in kept {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msgs = obj["messages"] as? [[String: Any]],
                  let first = msgs.first(where: { ($0["role"] as? String) == "user" }),
                  let user = first["content"] as? String else { continue }
            existingUsers.insert(user)
        }
        let newLines = String(data: capturesJSONL, encoding: .utf8)!
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        for line in newLines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msgs = obj["messages"] as? [[String: Any]],
                  let first = msgs.first(where: { ($0["role"] as? String) == "user" }),
                  let user = first["content"] as? String,
                  !existingUsers.contains(user) else { continue }
            kept.append(line)
            existingUsers.insert(user)
        }
        // Validate: no line may have an empty user/assistant message.
        let validated = kept.filter { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msgs = obj["messages"] as? [[String: Any]] else { return false }
            return msgs.compactMap { $0["content"] as? String }
                .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let out = validated.joined(separator: "\n") + "\n"
        try out.write(to: trainURL, atomically: true, encoding: .utf8)
        NSLog("[finetune] merged %d captured exchanges → train.jsonl (%d total lines)",
              newLines.count, validated.count)
    }

    // MARK: - Subprocess

    /// Run a subprocess, streaming its stdout/stderr to NSLog with a prefix.
    /// Throws on non-zero exit or deadline. `waitUntilExit` is used after the
    /// pipes are drained via readability handlers, matching the app's other
    /// subprocess callers (EmailCapability etc.) to avoid pipe deadlocks.
    static func runSubprocess(executable: String,
                              arguments: [String],
                              logPrefix: String,
                              deadline: TimeInterval = FineTuneManager.runDeadline) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                for l in line.split(separator: "\n") {
                    NSLog("%@ %@", logPrefix, String(l))
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                for l in line.split(separator: "\n") {
                    NSLog("%@ %@", logPrefix, String(l))
                }
            }
        }

        try proc.run()
        let start = Date()
        while proc.isRunning {
            // Honour cancellation (app quit, stop()): don't swallow it and let
            // a python child run to the 6h deadline orphaned.
            if Task.isCancelled {
                proc.terminate()
                throw CancellationError()
            }
            if Date().timeIntervalSince(start) > deadline {
                proc.terminate()
                throw NSError(domain: "FineTuneManager", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "subprocess exceeded \(Int(deadline))s deadline"])
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // Drain anything still buffered.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "FineTuneManager", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(logPrefix) exited with status \(proc.terminationStatus)"])
        }
        NSLog("%@ finished in %.0fs", logPrefix, Date().timeIntervalSince(start))
    }

    // MARK: - Status

    private func restoreStatus() {
        if let last = UserDefaults.standard.object(forKey: Keys.lastRun) as? Date {
            lastStatus = "last run \(Self.dateFormatter.string(from: last))"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
