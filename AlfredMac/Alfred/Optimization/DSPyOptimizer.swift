// MARK: - DSPyOptimizer
//
// Alfred's self-optimization loop. Hermes is normally prompted the same way
// every time; this layer lets Alfred learn what actually works for *this*
// user — their codebase, their recipients, their taste — and feed those
// learned directives back into the prompt automatically.
//
// The loop, end to end:
//
//   1. Every AI output the user rates (1–5, via the iOS feedback view or the
//      socket) lands in OptimizationStore as a FeedbackEntry.
//   2. Weekly (or monthly / manual), `compile()` gathers the past week's
//      ratings and learns: the real-DSPy Python bridge proposes rules when it
//      can, otherwise the deterministic OptimizationHeuristics learner
//      extracts "good outputs use X more than bad ones" signals.
//   3. Learned rules become active and ride along in
//      HermesSession.groundedPrompt as a bracketed injection, exactly like the
//      writing-style and behavior injections.
//   4. The next compile measures whether the change helped; a regression past
//      `confidenceThreshold` auto-rolls back to the previous rule set.
//
// DSPy is Python, so it runs out-of-process (a subprocess JSON exchange, not a
// long-lived REST server — a weekly offline job has no business holding a port
// open). When python3 or the `dspy` package isn't installed, the bridge
// reports "unavailable" and the Swift heuristic takes over, so the feature
// never depends on the Python toolchain.

import Foundation

final class DSPyOptimizer {

    static let shared = DSPyOptimizer()

    private let store: OptimizationStore

    private let storageKey = "alfred.optimization_settings"
    private let lock = NSLock()
    private var storedSettings: OptimizationSettings
    private var scheduler: Timer?

    private init(store: OptimizationStore = .shared) {
        self.store = store
        storedSettings = Self.load() ?? .default
    }

    /// Test seam: an optimizer backed by a throwaway database, so unit tests
    /// never write to the real `~/.alfred/db/optimization.db`.
    static func makeForTesting(databasePath: String) -> DSPyOptimizer {
        DSPyOptimizer(store: OptimizationStore(databasePath: databasePath))
    }

    // MARK: - Settings

    private func readSettings() -> OptimizationSettings {
        lock.lock()
        defer { lock.unlock() }
        return storedSettings
    }

    private func mutateSettings(_ change: (inout OptimizationSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var updated = storedSettings
        change(&updated)
        guard updated != storedSettings else { return }
        storedSettings = updated
        persist()
    }

    var settings: OptimizationSettings {
        get { readSettings() }
        set { mutateSettings { $0 = newValue } }
    }

    // MARK: - Scheduler

    /// Arm the weekly/monthly compile check. Idempotent. Ticks every 30
    /// minutes; `compileIfDue` decides whether now is a compile moment, so a
    /// sleep/wake can't skip a Sunday-night run.
    func start() {
        guard scheduler == nil else { return }
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.compileIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduler = timer
        compileIfDue()
        NSLog("[optimization] scheduler armed — \\(readSettings().frequency.rawValue) compile")
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }

    /// Whether the loop is due to compile right now, honoring the frequency
    /// setting and a 6-day quiet period so a manual run doesn't double-fire.
    func isCompileDue(at date: Date = Date()) -> Bool {
        let settings = readSettings()
        guard settings.frequency != .manual else { return false }
        if let last = settings.lastCompiledAt, date.timeIntervalSince1970 - last < 6 * 86_400 {
            return false
        }
        let cal = Calendar(identifier: .gregorian)
        switch settings.frequency {
        case .weekly:
            // Sunday, late evening (after the day's work is done).
            return cal.component(.weekday, from: date) == 1
                && cal.component(.hour, from: date) >= 21
        case .monthly:
            return cal.component(.day, from: date) == 1
        case .manual:
            return false
        }
    }

    func compileIfDue() {
        guard isCompileDue() else { return }
        Task.detached(priority: .utility) {
            _ = DSPyOptimizer.shared.compile()
        }
    }

    // MARK: - Feedback

    /// Record a rated output. Fast by design — a single INSERT, no model work,
    /// so the rating UX stays under the 100ms target.
    func recordFeedback(kind: OptimizationKind? = nil, prompt: String, output: String,
                        rating: Int, edited: Bool = false, context: String? = nil) {
        let resolvedKind = kind ?? OptimizationKind.detect(from: prompt)
        store.insertFeedback(FeedbackEntry(
            kind: resolvedKind, prompt: prompt, output: output,
            rating: rating, edited: edited, context: context))
    }

    // MARK: - Prompt injection

    /// The learned directives for the prompt's domain, bracketed for
    /// `groundedPrompt`. Empty when nothing has been learned for this kind yet.
    func promptInjection(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let kind = OptimizationKind.detect(from: text)
        let rules = store.activeRules(kind: kind)
        guard !rules.isEmpty else { return "" }
        let joined = rules.map(\.directive).joined(separator: " ")
        return "[learned \(kind.displayName.lowercased()) style: \(joined)]"
    }

    /// The active rules for a domain, exposed for the report and tests.
    func activeRules(kind: OptimizationKind) -> [OptimizationRule] {
        store.activeRules(kind: kind)
    }

    // MARK: - Compile

    /// Run one compile pass. Returns the fresh report. Safe to call from any
    /// thread — the heavy work is pure Swift + a bounded subprocess, and the
    /// store serializes its own SQLite connections.
    @discardableResult
    func compile() -> OptimizationReport {
        let now = Date().timeIntervalSince1970
        let settings = readSettings()
        let weekAgo = now - 7 * 86_400

        for kind in OptimizationKind.allCases {
            let examples = store.feedback(since: weekAgo, kind: kind)
            guard examples.count >= settings.minFeedback else { continue }

            // Close out the previous pass before installing a new one: measure
            // whether its rules helped, and roll back if they made things worse.
            closeOutPendingRun(kind: kind, settings: settings)

            // Learn. The DSPy bridge wins when it can propose rules; the
            // deterministic heuristic is the always-available fallback.
            var rules: [OptimizationRule]
            var source: String
            if let dspyRules = runPythonBridge(kind: kind, examples: examples),
               !dspyRules.isEmpty {
                rules = dspyRules
                source = "dspy"
            } else {
                rules = OptimizationHeuristics.learn(from: examples, kind: kind)
                source = "heuristic"
            }
            guard !rules.isEmpty else { continue }

            let version = store.latestVersion(kind: kind) + 1
            let before = averageRating(of: examples)
            store.installRules(rules, kind: kind, version: version, source: source)
            store.insertRun(OptimizationRunRecord(
                kind: kind.rawValue, version: version, before: before, after: 0,
                examples: examples.count, applied: true, rolledBack: false,
                source: source, createdAt: now))
        }

        mutateSettings { $0.lastCompiledAt = now }
        NSLog("[optimization] compile pass complete")
        return report()
    }

    /// Measure a kind's previous pending run and roll it back if it regressed.
    private func closeOutPendingRun(kind: OptimizationKind, settings: OptimizationSettings) {
        guard let run = store.lastRun(kind: kind),
              run.applied, !run.rolledBack, run.after == 0 else { return }

        let since = run.createdAt
        let entries = store.feedback(since: since, kind: kind)
        // Need a real sample before judging; too few ratings means "unknown",
        // and the rules stay active for another cycle.
        guard entries.count >= 3 else { return }

        let measured = averageRating(of: entries)
        store.updateRunAfter(kind: run.kind, version: run.version, after: measured)

        // A drop past the confidence threshold is a regression, not noise.
        let floor = run.before * (1 - settings.confidenceThreshold)
        if settings.autoRollback, measured < floor {
            let previous = store.previousVersion(kind: kind)
            store.rollback(kind: kind, to: previous)
            store.markRolledBack(kind: run.kind, version: run.version)
            NSLog("[optimization] %@ regressed (%.2f → %.2f) — rolled back to v%d",
                  run.kind, run.before, measured, previous)
        }
    }

    // MARK: - Rollback

    /// Manually revert a kind to its previous rule set (or baseline when there
    /// is no previous version). Returns the new active rules.
    @discardableResult
    func rollback(kind: OptimizationKind) -> [OptimizationRule] {
        let previous = store.previousVersion(kind: kind)
        store.rollback(kind: kind, to: previous)
        return store.activeRules(kind: kind)
    }

    // MARK: - Report

    /// The week-over-week trend plus the active optimizations. The numbers the
    /// briefing card and the iOS report both show.
    func report() -> OptimizationReport {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let thisWeekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let lastWeekStart = cal.date(byAdding: .day, value: -7, to: thisWeekStart) ?? now

        let thisStart = thisWeekStart.timeIntervalSince1970
        let lastStart = lastWeekStart.timeIntervalSince1970

        var perKind: [OptimizationKindScore] = []
        var currentTotal = 0.0
        var previousTotal = 0.0
        var currentCount = 0
        var previousCount = 0

        for kind in OptimizationKind.allCases {
            let current = store.aggregate(kind: kind, since: thisStart)
            let previous = store.aggregate(kind: kind, since: lastStart)
            if current.count == 0 && previous.count == 0 { continue }
            perKind.append(OptimizationKindScore(
                kind: kind.rawValue,
                displayName: kind.displayName,
                current: round(current.average),
                previous: round(previous.average),
                samples: current.count))
            if current.count > 0 {
                currentTotal += current.average
                currentCount += 1
            }
            if previous.count > 0 {
                previousTotal += previous.average
                previousCount += 1
            }
        }

        let averageRating = currentCount > 0 ? currentTotal / Double(currentCount) : 0
        let previousAverage = previousCount > 0 ? previousTotal / Double(previousCount) : 0
        let weekDelta = averageRating - previousAverage

        return OptimizationReport(
            averageRating: averageRating,
            weekDelta: round(weekDelta * 10) / 10,
            totalRatings: currentCount,
            perKind: perKind,
            activeOptimizations: store.allActiveDirectives(),
            lastCompiledAt: readSettings().lastCompiledAt,
            lastRun: store.mostRecentRun())
    }

    /// The briefing card: the report trimmed to what a daily card can carry.
    func improvementCard() -> ImprovementCard? {
        let report = report()
        guard report.totalRatings > 0 || !report.activeOptimizations.isEmpty else { return nil }
        return ImprovementCard(
            averageRating: report.averageRating,
            weekDelta: report.weekDelta,
            totalRatings: report.totalRatings,
            perKind: Array(report.perKind.prefix(3)),
            activeOptimizations: Array(report.activeOptimizations.prefix(3)))
    }

    private func averageRating(of entries: [FeedbackEntry]) -> Double {
        guard !entries.isEmpty else { return 0 }
        let total = entries.reduce(0.0) { $0 + Double($1.rating) }
        return total / Double(entries.count)
    }

    private func round(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    // MARK: - DSPy Python bridge

    /// Ask the bundled Python script to propose rules via real DSPy. Returns
    /// nil when the bridge is unavailable (no python3, no `dspy` package, or
    /// the run failed/timed out) so the caller falls back to the heuristic.
    private func runPythonBridge(kind: OptimizationKind, examples: [FeedbackEntry]) -> [OptimizationRule]? {
        guard let python = Self.pythonBinary(),
              let scriptURL = Bundle.module.url(forResource: "dspy_optimizer", withExtension: "py")
        else { return nil }

        let payload: [String: Any] = [
            "kind": kind.rawValue,
            "examples": examples.map { entry -> [String: Any] in
                [
                    "prompt": entry.prompt,
                    "output": entry.output,
                    "rating": entry.rating,
                    "edited": entry.edited,
                ]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [scriptURL.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            NSLog("[optimization] DSPy bridge failed to launch: %@", error.localizedDescription)
            return nil
        }
        stdin.fileHandleForWriting.write(data)
        try? stdin.fileHandleForWriting.close()

        // Bound the wait: a weekly job must never hang forever on a wedged
        // python import.
        let timeout: TimeInterval = 60
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            NSLog("[optimization] DSPy bridge timed out after %.0fs — falling back to heuristic", timeout)
            return nil
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let obj = (try? JSONSerialization.jsonObject(with: outData)) as? [String: Any],
              let engine = obj["engine"] as? String, engine == "dspy",
              let rawRules = obj["rules"] as? [[String: Any]]
        else { return nil }

        let version = store.latestVersion(kind: kind) + 1
        return rawRules.compactMap { dict in
            guard let rule = dict["rule"] as? String, !rule.isEmpty else { return nil }
            return OptimizationRule(
                kind: kind,
                rule: rule,
                confidence: (dict["confidence"] as? Double) ?? 0.5,
                source: "dspy",
                version: version)
        }
    }

    private static func pythonBinary() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.hermes/hermes-agent/venv/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func load() -> OptimizationSettings? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.optimization_settings"),
              let settings = try? JSONDecoder().decode(OptimizationSettings.self, from: data)
        else { return nil }
        return settings
    }

    /// Test seam: reload the persisted settings without going through the
    /// singleton's cached copy.
    static func loadForTest() -> OptimizationSettings? { load() }
}
