import Foundation
import Combine
import OSLog

private struct DashboardInternalState {
    var tasks: [TaskDefinition]
    var runsByTask: [Int64: [(TaskRun, Int, String)]]
    var sequenceWatermark: Int
}

final class TaskDashboardService {
    private let engine: TaskEngine
    private let logger = Logger(subsystem: "com.alfred.tasks", category: "dashboard")
    private var internalState: DashboardInternalState?
    private var isRebuilding: Bool = false
    private var drainInProgress: Bool = false
    private var drainIterationCount: Int = 0
    private let maxDrainIterations = 10
    private var pendingEvents: [TaskEngineEvent] = []
    private var eventCancellable: AnyCancellable?

    // MARK: - Event publisher (for view model observation)

    let eventPublisher = PassthroughSubject<TaskEngineEvent, Never>()

    // MARK: - Raw accessors

    var tasks: [TaskDefinition] { internalState?.tasks ?? [] }
    var taskEngine: TaskEngine { engine }
    var allRuns: [TaskRun] {
        guard let state = internalState else { return [] }
        return state.runsByTask.values.flatMap { $0.map(\.0) }
    }

    init(engine: TaskEngine) {
        self.engine = engine
    }

    private func trimPendingEvents() {
        guard pendingEvents.count > 100 else { return }
        logger.warning("Pending event buffer exceeded 100 — dropping \(self.pendingEvents.count - 100) oldest events")
        pendingEvents.sort { $0.sequence < $1.sequence }
        pendingEvents = Array(pendingEvents.suffix(100))
    }

    private func recoverFromDrainLimit() {
        let before = pendingEvents.count
        logger.error("Drain convergence limit reached — preserving \(before) events")
        let snapshot = engine.getSnapshot()
        let staging = buildStaging(snapshot: snapshot)
        internalState = staging
        let watermark = staging.sequenceWatermark
        pendingEvents = pendingEvents.filter { $0.sequence > watermark }
        pendingEvents.sort { $0.sequence < $1.sequence }
        let skipped = before - pendingEvents.count
        if skipped > 0 {
            logger.debug("Filtered \(skipped) stale events with sequence ≤ \(watermark)")
        }
        trimPendingEvents()
    }

    private func drainPendingEvents() {
        guard !drainInProgress else { return }
        drainInProgress = true
        drainIterationCount = 0

        while true {
            if drainIterationCount >= maxDrainIterations {
                logger.warning("Drain convergence limit reached — forcing stabilization")
                recoverFromDrainLimit()
                break
            }

            drainIterationCount += 1

            guard !pendingEvents.isEmpty else { break }

            let batch = pendingEvents.sorted { $0.sequence < $1.sequence }
            pendingEvents.removeAll()
            for event in batch {
                guard var state = internalState else {
                    logger.error("State missing during drain — dropping event seq=\(event.sequence)")
                    continue
                }
                guard event.sequence > state.sequenceWatermark else {
                    logger.debug("Dropped stale event during drain seq=\(event.sequence) ≤ watermark=\(state.sequenceWatermark)")
                    continue
                }
                guard applyEvent(event, to: &state) else {
                    logger.debug("Skipped no-op event during drain \(event.type.rawValue) seq=\(event.sequence)")
                    continue
                }
                internalState = state
                logger.debug("Drained \(event.type.rawValue) task=\(event.taskId) seq=\(event.sequence)")
            }
        }

        drainInProgress = false
        drainIterationCount = 0
    }

    private func canonicalRunKey(_ run: TaskRun) -> String {
        if let id = run.id { return "id:\(id)" }
        let ts = Int(run.timestamp.timeIntervalSince1970)
        return "\(run.taskId)-\(ts)-fallback"
    }

    private func assignSnapshotSequences(runs: [TaskRun], baseSequence: Int) -> [(TaskRun, Int, String)] {
        runs.enumerated().map { index, run in
            (run, baseSequence - (index + 1), canonicalRunKey(run))
        }
    }

    private func buildStaging(snapshot: TaskSnapshot) -> DashboardInternalState {
        DashboardInternalState(
            tasks: snapshot.tasks,
            runsByTask: snapshot.runsByTask.mapValues { runs in
                assignSnapshotSequences(runs: runs, baseSequence: snapshot.sequence)
            },
            sequenceWatermark: snapshot.sequence
        )
    }

    // MARK: - Subscription

    func subscribe() {
        isRebuilding = true
        let snapshot = engine.getSnapshot()
        let staging = buildStaging(snapshot: snapshot)
        internalState = staging
        logger.debug("Initialized from snapshot seq=\(staging.sequenceWatermark) tasks=\(staging.tasks.count)")
        isRebuilding = false
        drainPendingEvents()

        eventCancellable = engine.events.sink { [weak self] event in
            guard let self else { return }

            if self.isRebuilding || self.drainInProgress {
                self.pendingEvents.append(event)
                self.trimPendingEvents()
                self.logger.debug("Buffered \(event.type.rawValue) task=\(event.taskId) seq=\(event.sequence)")
                return
            }

            let watermark = self.internalState?.sequenceWatermark ?? 0

            guard event.sequence > watermark else {
                self.logger.debug("Dropped duplicate/out-of-order event \(event.type.rawValue) seq=\(event.sequence)")
                return
            }

            if event.sequence > watermark + 1 {
                self.pendingEvents.append(event)
                self.trimPendingEvents()
                self.logger.debug("Buffered out-of-order event \(event.type.rawValue) seq=\(event.sequence) (expected \(watermark + 1))")
                return
            }

            guard var state = self.internalState ?? self.rebuildState() else {
                self.logger.error("Cannot apply event — internal state unavailable and rebuild failed")
                return
            }

            guard self.applyEvent(event, to: &state) else {
                self.logger.debug("Skipped no-op event \(event.type.rawValue) seq=\(event.sequence)")
                return
            }
            self.internalState = state
            self.logger.debug("Applied \(event.type.rawValue) task=\(event.taskId) seq=\(event.sequence)")

            self.eventPublisher.send(event)

            self.drainPendingEvents()
        }
    }

    private func rebuildState() -> DashboardInternalState? {
        isRebuilding = true
        let snapshot = engine.getSnapshot()
        let staging = buildStaging(snapshot: snapshot)
        internalState = staging
        isRebuilding = false
        drainPendingEvents()
        logger.warning("Internal state was nil — rebuilt from snapshot seq=\(staging.sequenceWatermark)")
        return internalState
    }

    // MARK: - Event patching

    private func applyEvent(_ event: TaskEngineEvent, to state: inout DashboardInternalState) -> Bool {
        switch event.type {
        case .created:
            guard let task = engine.getTask(event.taskId) else { return false }
            state.tasks.append(task)
            state.runsByTask[event.taskId] = []

        case .updated:
            guard let task = engine.getTask(event.taskId) else { return false }
            if let idx = state.tasks.firstIndex(where: { $0.id == event.taskId }) {
                state.tasks[idx] = task
            } else {
                state.tasks.append(task)
            }

        case .deleted:
            state.tasks.removeAll { $0.id == event.taskId }
            state.runsByTask.removeValue(forKey: event.taskId)

        case .runUpdated:
            guard let run = event.run else { return false }
            let key = canonicalRunKey(run)
            var runs = state.runsByTask[event.taskId] ?? []
            guard !runs.contains(where: { $0.2 == key }) else { return false }
            runs.append((run, event.sequence, key))
            runs.sort { $0.1 > $1.1 }
            var deduped: [(TaskRun, Int, String)] = []
            var seen: Set<String> = []
            for entry in runs {
                guard seen.insert(entry.2).inserted else { continue }
                deduped.append(entry)
            }
            if deduped.count > 100 { deduped = Array(deduped.prefix(100)) }
            state.runsByTask[event.taskId] = deduped
        }
        state.sequenceWatermark = event.sequence
        return true
    }

    // MARK: - Execution delegation

    func runTask(id: Int64, confirmations: [Int: Bool] = [:]) async throws -> TaskRun {
        try await engine.runTask(id: id, confirmations: confirmations)
    }

    // MARK: - Fetch

    func fetchTasks() -> [TaskDashboardViewModel] {
        guard let state = internalState else { return [] }
        return buildViewModels(from: state)
    }

    func fetchRuns(taskId: Int64) -> [TaskRun] {
        guard let state = internalState else { return [] }
        return (state.runsByTask[taskId] ?? []).map(\.0)
    }

    func fetchState() -> TaskDashboardState {
        guard let state = internalState else { return .empty }
        return buildState(from: state)
    }

    private func buildViewModels(from state: DashboardInternalState) -> [TaskDashboardViewModel] {
        state.tasks.map { task in
            let runs = (state.runsByTask[task.id ?? 0] ?? []).map(\.0)
            return TaskDashboardViewModel(task: task, runs: runs)
        }
    }

    private func buildState(from state: DashboardInternalState) -> TaskDashboardState {
        let viewModels = buildViewModels(from: state)
        return TaskDashboardState.from(viewModels: viewModels)
    }

    // MARK: - Summary

    var summary: String {
        guard let state = internalState else { return "Task Dashboard: no state" }
        let total = state.tasks.count
        let enabled = state.tasks.filter(\.enabled).count
        let scheduled = state.tasks.filter { $0.enabled && $0.scheduleType != .manual }.count
        let manual = state.tasks.filter { $0.enabled && $0.scheduleType == .manual }.count
        let allRuns = state.runsByTask.values.flatMap { $0 }
        let recentRuns = Array(allRuns.sorted { $0.1 > $1.1 }.prefix(5)).map(\.0)

        var lines: [String] = []
        lines.append("Task Dashboard:")
        lines.append("  • \(total) total tasks (\(enabled) enabled)")
        if scheduled > 0 { lines.append("  • \(scheduled) scheduled") }
        if manual > 0 { lines.append("  • \(manual) manual") }
        if !recentRuns.isEmpty {
            let success = recentRuns.filter { $0.status == .success }.count
            lines.append("  • \(recentRuns.count) recent runs (\(success) succeeded)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Consistency validation

    func validateStateConsistency() -> Bool {
        guard let state = internalState else { return true }

        // All tasks referenced in runsByTask must exist in tasks
        let taskIds = Set(state.tasks.compactMap(\.id))
        let runTaskIds = Set(state.runsByTask.keys)
        let orphanRunTasks = runTaskIds.subtracting(taskIds)
        if !orphanRunTasks.isEmpty {
            logger.warning("State inconsistency: runs reference deleted tasks \(orphanRunTasks)")
            return false
        }

        // Watermark must be >= the max sequence across all stored runs
        let maxRunSequence = state.runsByTask.values
            .flatMap { $0 }
            .map(\.1)
            .max() ?? 0
        if state.sequenceWatermark < maxRunSequence {
            logger.warning("State inconsistency: watermark \(state.sequenceWatermark) < max run sequence \(maxRunSequence)")
            return false
        }

        return true
    }
}
