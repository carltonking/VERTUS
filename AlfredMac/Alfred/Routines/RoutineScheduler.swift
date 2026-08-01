import Foundation

extension Notification.Name {
    /// Posted (object = routine id as Int64) when a routine run finishes — success, failure, or
    /// blocked — so an open panel can refresh its rows + output live.
    static let alfredRoutineRunDidFinish = Notification.Name("alfredRoutineRunDidFinish")
}

private struct RoutineTimeout: Error {}

/// The single sanctioned background scheduler (Blueprint v1 §6).
///
/// Ticks every 60s, finds ALL due routines, and executes read-only ones headless through the same
/// engine as AlfredBar. SAFETY: this is the ONE allowed autonomous timer. It lives outside the
/// classes `SafetyAuditEngine` scans (TaskEngine / TaskDashboardService / ActionSelectionEngine) by
/// design. A routine that resolves to a WRITE is NEVER executed unattended: it is run headless too
/// (producing a DRAFT with all side effects disabled) and surfaced as an actionable "Run now"
/// notification — the write happens only when the owner taps it (`confirmAndRun`, attended).
/// AssistantCore.process with `headless: true` hard-disables every UI / side-effecting path
/// (NSSavePanel file write, calendar create, app-opening tool, text insertion) regardless of how the
/// prompt is classified, so the autonomous tick can never perform a side effect.
@MainActor
final class RoutineScheduler {
    private let store: MemoryStore
    private let core: AssistantCore
    private let appState: AppState
    private let router: LLMRouter
    private let dispatcher = Dispatcher()

    /// Hard cap on a single headless run so one stalled provider can't wedge the scheduler. Bumped
    /// to 180s now that a research routine may run query-generation + several web searches + synthesis.
    private static let runTimeout: TimeInterval = 180

    private var timer: Timer?
    private var isExecuting = false
    private var runTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    /// App-Nap suppression: held while the scheduler runs so timers fire on time and in-flight
    /// network/LLM calls aren't throttled when no window is open.
    private var napAssertion: NSObjectProtocol?
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
        // Keep the app OUT of App Nap while the scheduler runs. Otherwise, once no window is open,
        // macOS throttles the 60s tick (so a 0600 routine silently never fires) and suspends in-flight
        // network/LLM calls (so a run started from the panel times out the instant the window closes).
        // `.userInitiatedAllowingIdleSystemSleep` blocks App Nap yet still lets the Mac sleep normally.
        napAssertion = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Alfred routine scheduler")
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()

        // Catch-up: the 60s tick only fires for the CURRENT minute, so a routine whose scheduled time
        // passed while the Mac was off/asleep/closed is otherwise silently skipped. Shortly after
        // launch — giving the network a moment to come back — run any overdue schedule-type routine
        // once. recordRoutineRun then advances last_run_at so a later relaunch won't replay it.
        catchUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.catchUpMissedRuns()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        runTask?.cancel()
        runTask = nil
        catchUpTask?.cancel()
        catchUpTask = nil
        if let napAssertion {
            ProcessInfo.processInfo.endActivity(napAssertion)
            self.napAssertion = nil
        }
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

    // MARK: - Catch-up (missed while the Mac was off/asleep/closed)

    /// Runs each schedule-type routine whose most recent scheduled occurrence was missed because the
    /// app wasn't running at the time. Fires each overdue routine ONCE.
    private func catchUpMissedRuns() {
        let now = Date()
        for routine in store.enabledRoutines() {
            guard routine.trigger_type == "schedule", routine.id != nil else { continue }
            guard let cron = CronSchedule(routine.schedule_cron) else { continue }
            let tz = TimeZone(identifier: routine.timezone) ?? .current
            // First scheduled occurrence AFTER the last run (or after creation if it never ran). If
            // that occurrence is already in the past — beyond a 90s grace so we don't race the live
            // tick for a fire happening right now — the routine was missed, so run it.
            let anchor = Date(timeIntervalSince1970: routine.last_run_at ?? routine.created_at)
            guard let missedFire = cron.nextDate(after: anchor, in: tz) else { continue }
            guard missedFire <= now.addingTimeInterval(-90) else { continue }
            runNow(routine)
        }
    }

    // MARK: - Tick

    // Parsed cron schedules are deterministic per cron string, so memoize them across 60s ticks
    // instead of re-parsing every enabled routine each tick. An edited routine's cron is a new key.
    private var scheduleCache: [String: CronSchedule] = [:]

    private func tick() {
        guard !isExecuting else { return }
        let now = Date()

        var due: [RoutineRecord] = []
        for routine in store.enabledRoutines() {
            // Only schedule-type routines auto-fire; manual/api routines run on demand only.
            guard routine.trigger_type == "schedule" else { continue }
            guard let id = routine.id else { continue }
            let cron: CronSchedule
            if let cached = scheduleCache[routine.schedule_cron] {
                cron = cached
            } else if let parsed = CronSchedule(routine.schedule_cron) {
                scheduleCache[routine.schedule_cron] = parsed
                cron = parsed
            } else {
                continue
            }
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

        // Safety gate (Blueprint §6): the scheduler NEVER performs a side effect unattended. A
        // routine that resolves to a WRITE is still run headless — which produces a DRAFT with every
        // side-effecting path disabled — and surfaced as an actionable notification. The write only
        // happens if the owner taps "Run now" (→ confirmAndRun), i.e. attended.
        if decision.commandClass != .readOnly {
            await draftForConfirmation(routine, id: id, prompt: prompt, decision: decision,
                                       nextRun: nextRun, core: core, store: store,
                                       ownerName: ownerName, retentionDays: retentionDays)
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
                               status: status, summary: status == "failed" ? (errorText ?? "unknown error") : summary)
        await notify(
            title: status == "success" ? "Routine done: \(routine.title)" : "Routine failed: \(routine.title)",
            body: status == "success" ? summary : (errorText ?? "Unknown error")
        )
        // Text the full result to Telegram (Alfred delivering your briefings first).
        if status == "success" {
            await TelegramNotifier.send("📋 \(routine.title)\n\n\(output)")
        } else {
            await TelegramNotifier.send("⚠️ Routine “\(routine.title)” failed: \(errorText ?? "unknown error")")
        }
        await postFinished(id)
    }

    /// Runs a WRITE-class routine headless (no side effects) to produce a draft/preview, records it
    /// as awaiting confirmation, and posts an actionable "Run now / Dismiss" notification. The actual
    /// write only happens if the owner taps Run now (→ confirmAndRun). Text-only by construction, so
    /// the autonomous tick keeps its "no unattended side effects" guarantee.
    private static func draftForConfirmation(
        _ routine: RoutineRecord, id: Int64, prompt: String, decision: DispatchDecision,
        nextRun: Double?, core: AssistantCore, store: MemoryStore,
        ownerName: String, retentionDays: Int
    ) async {
        let runId = store.startRun(source: "routine", prompt: prompt, routineId: id)
        var draft = ""
        var failure: String?
        do {
            draft = try await withTimeout(Self.runTimeout) {
                try await runWithRetry(core: core, prompt: prompt, ownerName: ownerName, retentionDays: retentionDays)
            }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = "(no preview)" }
        } catch is RoutineTimeout {
            failure = "Timed out after \(Int(Self.runTimeout))s"
        } catch {
            failure = error.localizedDescription
        }

        // Couldn't even draft (provider down / timeout) → record + plain notification, nothing to confirm.
        if let failure {
            if let runId {
                store.completeRun(id: runId, status: "failed", routeReason: decision.routeReason,
                                  commandClass: decision.commandClass.rawValue, errorText: failure)
            }
            store.recordRoutineRun(id: id, ranAt: Date().timeIntervalSince1970, nextRunAt: nextRun,
                                   status: "failed", summary: failure)
            await notify(title: "Routine couldn’t draft: \(routine.title)", body: failure)
            await postFinished(id)
            return
        }

        let preview = String(draft.prefix(200))
        if let runId {
            store.completeRun(id: runId, status: "pending_confirm", routeReason: decision.routeReason,
                              commandClass: decision.commandClass.rawValue,
                              outputFull: draft, outputSummary: preview)
        }
        store.recordRoutineRun(id: id, ranAt: Date().timeIntervalSince1970, nextRunAt: nextRun,
                               status: "awaiting_confirm", summary: preview)

        // Actionable notification: tapping "Run now" performs the drafted write (confirmAndRun).
        var info: [String: String] = ["kind": "routine_confirm", "routineId": String(id)]
        if let runId { info["runId"] = String(runId) }
        let body = "Draft: \(String(draft.prefix(160)))\n\nTap “Run now” to do it."
        _ = try? await NotificationManager.shared.sendActionable(
            title: "Confirm: \(routine.title)", body: body,
            userInfo: info, categoryID: NotificationManager.routineConfirmCategoryID)

        // Telegram can't host a one-tap Run button here, so send the full draft for review.
        await TelegramNotifier.send("📝 Drafted “\(routine.title)” — needs your OK:\n\n\(draft)\n\nOpen Alfred’s notification and tap “Run now” to do it.")
        await postFinished(id)
    }

    // MARK: - Confirm & run (attended — a human tapped "Run now")

    /// Executes a previously-drafted write-class routine after the owner tapped "Run now" on the
    /// confirmation notification. ATTENDED (a human tap), so side effects are ENABLED — identical to
    /// running the same command from the AlfredBar. NEVER called by the autonomous tick; only via a
    /// notification tap routed through AppDelegate.confirmRoutineFromNotification.
    func confirmAndRun(routineId: Int64, pendingRunId: Int64?) {
        guard let routine = store.routine(id: routineId) else { return }
        let core = self.core
        let store = self.store
        let ownerName = appState.ownerName
        let retentionDays = appState.memoryRetentionDays
        let screenContextEnabled = appState.screenContextEnabled
        let shellExecutionEnabled = appState.shellExecutionEnabled
        Task.detached(priority: .userInitiated) {
            await Self.executeConfirmed(
                routine, pendingRunId: pendingRunId, core: core, store: store,
                ownerName: ownerName, retentionDays: retentionDays,
                screenContextEnabled: screenContextEnabled, shellExecutionEnabled: shellExecutionEnabled)
        }
    }

    private static func executeConfirmed(
        _ routine: RoutineRecord, pendingRunId: Int64?, core: AssistantCore, store: MemoryStore,
        ownerName: String, retentionDays: Int, screenContextEnabled: Bool, shellExecutionEnabled: Bool
    ) async {
        guard let id = routine.id else { return }
        let prompt = routine.prompt_text
        let tz = TimeZone(identifier: routine.timezone) ?? .current
        let nextRun = CronSchedule(routine.schedule_cron)?.nextDate(after: Date(), in: tz)?.timeIntervalSince1970

        // Close out the pending draft row (audit trail), then log the real execution as its own run.
        if let pendingRunId {
            store.completeRun(id: pendingRunId, status: "confirmed", routeReason: "routine",
                              commandClass: "confirmed", outputSummary: "Owner tapped Run now")
        }

        let runId = store.startRun(source: "routine_confirm", prompt: prompt, routineId: id)
        var output = ""
        var status = "success"
        var errorText: String?
        do {
            output = try await withTimeout(Self.runTimeout) {
                try await core.process(
                    query: prompt, ownerName: ownerName,
                    screenContextEnabled: screenContextEnabled,
                    shellExecutionEnabled: shellExecutionEnabled,
                    memoryExtractionEnabled: false,
                    conversationHistoryEnabled: false,
                    memoryRetentionDays: retentionDays,
                    headless: false
                ) { _ in }
            }
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "(done)" }
        } catch is RoutineTimeout {
            status = "failed"; errorText = "Timed out after \(Int(Self.runTimeout))s"
        } catch {
            status = "failed"; errorText = error.localizedDescription
        }

        let summary = String(output.prefix(200))
        if let runId {
            store.completeRun(id: runId, status: status, modelUsed: nil,
                              routeReason: "routine (confirmed)", commandClass: "confirmed-run",
                              outputFull: output, outputSummary: summary, errorText: errorText)
        }
        store.recordRoutineRun(id: id, ranAt: Date().timeIntervalSince1970, nextRunAt: nextRun,
                               status: status, summary: status == "failed" ? (errorText ?? "unknown error") : summary)
        await notify(
            title: status == "success" ? "Ran: \(routine.title)" : "Routine failed: \(routine.title)",
            body: status == "success" ? summary : (errorText ?? "Unknown error"))
        if status == "success" {
            await TelegramNotifier.send("✅ Ran “\(routine.title)”\n\n\(output)")
        } else {
            await TelegramNotifier.send("⚠️ Routine “\(routine.title)” failed: \(errorText ?? "unknown error")")
        }
        await postFinished(id)
    }

    /// Signals the UI that a run finished so an open panel can refresh live. Posted on the main
    /// actor because observers (SwiftUI views) update on the main thread.
    private static func postFinished(_ id: Int64) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .alfredRoutineRunDidFinish, object: id)
        }
    }

    /// Runs the routine prompt headless through AssistantCore, retrying on transient network errors
    /// with backoff. A single quick retry wasn't enough for a cold wake (e.g. a 06:00 routine firing
    /// right as the Mac wakes, before Wi-Fi/DNS are back); these waits stay well under runTimeout.
    private static func runWithRetry(core: AssistantCore, prompt: String,
                                     ownerName: String, retentionDays: Int) async throws -> String {
        let backoffs: [UInt64] = [15, 30]   // seconds before the 2nd and 3rd attempts
        var attempt = 0
        while true {
            do {
                return try await runOnce(core: core, prompt: prompt, ownerName: ownerName, retentionDays: retentionDays)
            } catch {
                guard isNetworkError(error), attempt < backoffs.count else { throw error }
                try? await Task.sleep(nanoseconds: backoffs[attempt] * 1_000_000_000)
                attempt += 1
            }
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
        _ = try? await NotificationManager.shared.send(title: title, body: body)
    }
}
