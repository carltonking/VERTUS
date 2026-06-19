import Foundation

extension Notification.Name {
    /// Posted (object = routine id as Int64) when a routine run finishes — success, failure, or
    /// blocked — so an open panel can refresh its rows + output live.
    static let alfredRoutineRunDidFinish = Notification.Name("alfredRoutineRunDidFinish")
}

private struct RoutineTimeout: Error {}

/// The single sanctioned background scheduler (Blueprint v1 §6).
///
/// Ticks every 60s, finds ALL due routines, and executes `unattended-safe` ones headless
/// through the same engine as AlfredBar. SAFETY: this is the ONE allowed autonomous timer. It
/// lives outside the classes `SafetyAuditEngine` scans (TaskEngine / TaskDashboardService /
/// ActionSelectionEngine) by design, and only runs routines the dispatcher classifies
/// read-only; anything else is blocked and surfaced as a notification rather than executed.
/// AssistantCore.process is called with `headless: true`, which hard-disables every UI /
/// side-effecting path (NSSavePanel file write, calendar create, app-opening tool, text
/// insertion) regardless of how the prompt is classified.
@MainActor
final class RoutineScheduler {
    private let store: MemoryStore
    private let core: AssistantCore
    private let appState: AppState
    private let router: LLMRouter
    private let dispatcher = Dispatcher()

    /// Hard cap on a single headless run so one stalled provider can't wedge the scheduler.
    private static let runTimeout: TimeInterval = 120

    private var timer: Timer?
    private var isExecuting = false
    private var runTask: Task<Void, Never>?
    /// routineId → last fired wall-clock-minute key. Keyed on wall-clock components (not epoch)
    /// so a DST fall-back repeated minute fires once, not twice. Bounded by routine count.
    private var lastFiredKey: [Int64: String] = [:]

    init(store: MemoryStore, core: AssistantCore, appState: AppState, router: LLMRouter) {
        self.store = store
        self.core = core
        self.appState = appState
        self.router = router
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        runTask?.cancel()
        runTask = nil
    }

    /// Runs a routine immediately (panel "Run now"), bypassing the schedule but using the same
    /// headless gate + audit + notification path. Safe to overlap with scheduled runs.
    func runNow(_ routine: RoutineRecord) {
        let core = self.core
        let store = self.store
        let dispatcher = self.dispatcher
        let providerIsCloud = router.isActiveProviderCloud
        let ownerName = appState.ownerName
        let retentionDays = appState.memoryRetentionDays
        Task.detached(priority: .userInitiated) {
            await Self.runRoutine(
                routine, core: core, store: store, dispatcher: dispatcher,
                providerIsCloud: providerIsCloud, ownerName: ownerName, retentionDays: retentionDays
            )
        }
    }

    /// External-trigger entry (the `alfred://run?routine=<id>` URL scheme). Loads the routine and
    /// runs it through the same headless gate + audit + notification path as Run-now.
    func runRoutine(byId id: Int64) {
        guard let routine = store.routine(id: id), routine.enabled else { return }
        runNow(routine)
    }

    // MARK: - Tick

    private func tick() {
        guard !isExecuting else { return }
        let now = Date()

        var due: [RoutineRecord] = []
        for routine in store.enabledRoutines() {
            // Only schedule-type routines auto-fire; manual/api routines run on demand only.
            guard routine.trigger_type == "schedule" else { continue }
            guard let id = routine.id,
                  let cron = CronSchedule(routine.schedule_cron) else { continue }
            let tz = TimeZone(identifier: routine.timezone) ?? .current
            guard cron.matches(now, in: tz) else { continue }
            let key = Self.wallClockKey(id: id, date: now, tz: tz)
            guard lastFiredKey[id] != key else { continue }
            lastFiredKey[id] = key
            due.append(routine)
        }
        guard !due.isEmpty else { return }

        isExecuting = true
        let core = self.core
        let store = self.store
        let dispatcher = self.dispatcher
        let providerIsCloud = router.isActiveProviderCloud
        let ownerName = appState.ownerName
        let retentionDays = appState.memoryRetentionDays

        // Run off the main actor so synchronous SQLite writes don't block the UI. isExecuting
        // is reset back on the MainActor after the whole batch completes.
        runTask = Task.detached(priority: .utility) { [weak self] in
            // Guarantee the single-flight flag is cleared on ANY exit (completion, throw,
            // cancellation) so a stopped/cancelled batch can never wedge the tick loop.
            defer { Task { @MainActor in self?.isExecuting = false } }
            for routine in due {
                if Task.isCancelled { break }
                await Self.runRoutine(
                    routine, core: core, store: store, dispatcher: dispatcher,
                    providerIsCloud: providerIsCloud, ownerName: ownerName, retentionDays: retentionDays
                )
            }
        }
    }

    private static func wallClockKey(id: Int64, date: Date, tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return "\(id):\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)-\(c.hour ?? 0)-\(c.minute ?? 0)"
    }

    // MARK: - Execution (off the main actor)

    private static func runRoutine(
        _ routine: RoutineRecord,
        core: AssistantCore,
        store: MemoryStore,
        dispatcher: Dispatcher,
        providerIsCloud: Bool,
        ownerName: String,
        retentionDays: Int
    ) async {
        guard let id = routine.id else { return }
        let prompt = routine.prompt_text
        let decision = dispatcher.decide(query: prompt, providerIsCloud: providerIsCloud)
        let tz = TimeZone(identifier: routine.timezone) ?? .current
        let nextRun = CronSchedule(routine.schedule_cron)?.nextDate(after: Date(), in: tz)?.timeIntervalSince1970

        // Headless safety gate (Blueprint §6): only read-only routines run unattended.
        guard decision.commandClass == .readOnly else {
            let reason = "Resolves to a \(decision.commandClass.rawValue); open Alfred to run it."
            if let runId = store.startRun(source: "routine", prompt: prompt, routineId: id) {
                store.completeRun(id: runId, status: "blocked",
                                  routeReason: decision.routeReason,
                                  commandClass: decision.commandClass.rawValue,
                                  errorText: reason)
            }
            store.recordRoutineRun(id: id, ranAt: Date().timeIntervalSince1970, nextRunAt: nextRun,
                                   status: "blocked", summary: reason)
            await notify(title: "Routine blocked: \(routine.title)", body: reason)
            await postFinished(id)
            return
        }

        let runId = store.startRun(source: "routine", prompt: prompt, routineId: id)
        var output = ""
        var status = "success"
        var errorText: String?
        do {
            output = try await withTimeout(Self.runTimeout) {
                try await runWithRetry(core: core, prompt: prompt, ownerName: ownerName, retentionDays: retentionDays)
            }
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "(no response)" }
        } catch is RoutineTimeout {
            status = "failed"
            errorText = "Timed out after \(Int(Self.runTimeout))s"
        } catch {
            status = "failed"
            errorText = error.localizedDescription
        }
        let summary = String(output.prefix(200))
        if let runId {
            store.completeRun(id: runId, status: status, modelUsed: nil,
                              routeReason: "routine", commandClass: "read-only",
                              outputFull: output, outputSummary: summary, errorText: errorText)
        }
        store.recordRoutineRun(id: id, ranAt: Date().timeIntervalSince1970, nextRunAt: nextRun,
                               status: status, summary: summary)
        await notify(
            title: status == "success" ? "Routine done: \(routine.title)" : "Routine failed: \(routine.title)",
            body: status == "success" ? summary : (errorText ?? "Unknown error")
        )
        await postFinished(id)
    }

    /// Signals the UI that a run finished so an open panel can refresh live. Posted on the main
    /// actor because observers (SwiftUI views) update on the main thread.
    private static func postFinished(_ id: Int64) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .alfredRoutineRunDidFinish, object: id)
        }
    }

    /// Runs the routine prompt headless through AssistantCore, retrying once after ~10s on a
    /// network error (Blueprint §6).
    private static func runWithRetry(core: AssistantCore, prompt: String,
                                     ownerName: String, retentionDays: Int) async throws -> String {
        do {
            return try await runOnce(core: core, prompt: prompt, ownerName: ownerName, retentionDays: retentionDays)
        } catch {
            guard isNetworkError(error) else { throw error }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return try await runOnce(core: core, prompt: prompt, ownerName: ownerName, retentionDays: retentionDays)
        }
    }

    private static func runOnce(core: AssistantCore, prompt: String,
                                ownerName: String, retentionDays: Int) async throws -> String {
        try await core.process(
            query: prompt,
            ownerName: ownerName,
            screenContextEnabled: false,
            shellExecutionEnabled: false,
            memoryExtractionEnabled: false,
            conversationHistoryEnabled: false,
            memoryRetentionDays: retentionDays,
            headless: true
        ) { _ in }
    }

    /// Races an operation against a timeout. On timeout the orphaned operation is cancelled and
    /// abandoned so a stalled provider cannot wedge the scheduler permanently.
    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RoutineTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let llm = error as? LLMError, case .networkError = llm { return true }
        return false
    }

    private static func notify(title: String, body: String) async {
        try? await NotificationManager.shared.send(title: title, body: body)
    }
}
