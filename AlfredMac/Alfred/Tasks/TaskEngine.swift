import Foundation
import GRDB
import OSLog
import Combine

// MARK: - Event types

enum TaskEngineEventType: String {
    case created
    case updated
    case deleted
    case runUpdated
}

struct TaskEngineEvent {
    let type: TaskEngineEventType
    let taskId: Int64
    let run: TaskRun?
    let sequence: Int
}

struct TaskSnapshot {
    let tasks: [TaskDefinition]
    let runsByTask: [Int64: [TaskRun]]
    let sequence: Int
}

final class TaskEngine {
    private let db: DatabaseQueue
    private let logger = Logger(subsystem: "com.alfred.tasks", category: "engine")

    private let eventSubject = PassthroughSubject<TaskEngineEvent, Never>()
    var events: AnyPublisher<TaskEngineEvent, Never> { eventSubject.eraseToAnyPublisher() }
    private let sequenceLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Registration

    func registerTask(_ definition: TaskDefinition) throws -> Int64 {
        let stepsData = try JSONEncoder().encode(definition.steps)
        let stepsJSON = String(data: stepsData, encoding: .utf8) ?? "[]"
        let now = Date().timeIntervalSince1970

        let record = TaskDefinitionRecord(
            id: definition.id,
            name: definition.name,
            taskDescription: definition.description,
            scheduleType: definition.scheduleType.rawValue,
            stepsJSON: stepsJSON,
            lastRun: nil,
            enabled: definition.enabled,
            createdAt: now
        )

        var savedId: Int64?
        try db.write { db in
            try record.insert(db)
            savedId = db.lastInsertedRowID
        }
        logger.info("Registered task '\(definition.name)' (id: \(savedId ?? 0))")
        if let savedId {
            let seq = nextSequence()
            eventSubject.send(TaskEngineEvent(type: .created, taskId: savedId, run: nil, sequence: seq))
        }
        return savedId ?? 0
    }

    func updateTask(_ id: Int64, name: String? = nil, description: String? = nil, enabled: Bool? = nil) throws {
        try db.write { db in
            if let name { try db.execute(sql: "UPDATE task_definitions SET name = ? WHERE id = ?", arguments: [name, id]) }
            if let description { try db.execute(sql: "UPDATE task_definitions SET taskDescription = ? WHERE id = ?", arguments: [description, id]) }
            if let enabled { try db.execute(sql: "UPDATE task_definitions SET enabled = ? WHERE id = ?", arguments: [enabled, id]) }
        }
        let seq = nextSequence()
        eventSubject.send(TaskEngineEvent(type: .updated, taskId: id, run: nil, sequence: seq))
    }

    func deleteTask(_ id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM task_runs WHERE taskId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM task_definitions WHERE id = ?", arguments: [id])
        }
        logger.info("Deleted task \(id)")
        let seq = nextSequence()
        eventSubject.send(TaskEngineEvent(type: .deleted, taskId: id, run: nil, sequence: seq))
    }

    // MARK: - Listing

    func listTasks() -> [TaskDefinition] {
        do {
            let records = try db.read { db in
                try TaskDefinitionRecord.order(Column("createdAt").desc).fetchAll(db)
            }
            return records.map(TaskDefinition.init)
        } catch {
            logger.error("Failed to list tasks: \(error.localizedDescription)")
            return []
        }
    }

    func getTask(_ id: Int64) -> TaskDefinition? {
        do {
            guard let record = try db.read({ db in
                try TaskDefinitionRecord.fetchOne(db, key: id)
            }) else { return nil }
            return TaskDefinition(record: record)
        } catch {
            logger.error("Failed to get task \(id): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Execution

    struct StepExecutionPlan {
        let step: TaskStep
        let index: Int
        let needsConfirmation: Bool
    }

    func prepareExecutionPlan(taskId: Int64) -> [StepExecutionPlan] {
        guard let task = getTask(taskId), task.enabled else { return [] }
        return task.steps.enumerated().map { index, step in
            StepExecutionPlan(
                step: step,
                index: index,
                needsConfirmation: ActionPolicyRegistry.requiresConfirmation(for: step.actionType)
            )
        }
    }

    func runTask(id: Int64, confirmations: [Int: Bool] = [:]) async throws -> TaskRun {
        guard let task = getTask(id) else {
            throw TaskError.notFound
        }
        guard task.enabled else {
            throw TaskError.disabled
        }

        let plan = prepareExecutionPlan(taskId: id)
        guard !plan.isEmpty else {
            throw TaskError.noSteps
        }

        // Layer 1: Fast rejection — reject immediately if any step is
        // high-risk and the caller did not provide explicit confirmation.
        for step in plan {
            let risk = ActionPolicyRegistry.riskLevel(for: step.step.actionType)
            if risk == .high && confirmations[step.index] != true {
                throw TaskError.confirmationRequired(step.step.actionType)
            }
        }

        // Track which steps were explicitly confirmed by the caller
        var explicitConfirmations: Set<Int> = []

        // Check all required confirmations are granted
        for step in plan where step.needsConfirmation {
            guard confirmations[step.index] == true else {
                let run = TaskRun(taskId: id, status: .cancelled, output: ["reason": "Confirmation denied for step \(step.index): \(step.step.actionType)"])
                try persistRun(run)
                let seq = nextSequence()
                eventSubject.send(TaskEngineEvent(type: .runUpdated, taskId: id, run: run, sequence: seq))
                return run
            }
            explicitConfirmations.insert(step.index)
        }

        var outputs: [String: String] = [:]
        var overallStatus: TaskRunStatus = .success

        for step in plan {
            do {
                let isConfirmed = explicitConfirmations.contains(step.index)
                let result = try await executeStep(step.step, confirmed: isConfirmed)
                outputs["step_\(step.index)"] = result
            } catch {
                outputs["step_\(step.index)"] = "Error: \(error.localizedDescription)"
                overallStatus = .failure
                break
            }
        }

        let run = TaskRun(taskId: id, status: overallStatus, output: outputs)
        try persistRun(run)
        try markLastRun(id: id)
        let seq = nextSequence()
        eventSubject.send(TaskEngineEvent(type: .runUpdated, taskId: id, run: run, sequence: seq))

        return run
    }

    // MARK: - Step execution

    private func executeStep(_ step: TaskStep, confirmed: Bool) async throws -> String {
        // Safety guard: high-risk actions require explicit confirmation
        let stepRisk = ActionPolicyRegistry.riskLevel(for: step.actionType)
        if stepRisk == .high && !confirmed {
            throw TaskError.confirmationRequired(step.actionType)
        }

        switch step.actionType {
        case "open_application":
            guard let app = step.parameters["application"] else {
                throw TaskError.invalidParameter("application")
            }
            let query = "open \(app)"
            let capability = AppControlCapability()
            return try await capability.handle(query: query, lowered: query.lowercased()) ?? "Opened \(app)"

        case "system_command":
            guard let command = step.parameters["command"] else {
                throw TaskError.invalidParameter("command")
            }
            let shell = ShellCapability()
            return try await shell.run(command: command)

        case "query_memory":
            guard let query = step.parameters["query"] else {
                throw TaskError.invalidParameter("query")
            }
            // Memory access will be wired through AssistantCore at runtime
            return "query_memory:\(query)"

        case "search_files":
            let pattern = step.parameters["pattern"] ?? "*"
            return "search_files:\(pattern)"

        case "send_message":
            return "send_message requires user confirmation"

        default:
            throw TaskError.unsupportedAction(step.actionType)
        }
    }

    // MARK: - Validation

    func validateSteps(_ steps: [TaskStep]) -> [String] {
        var errors: [String] = []
        for (i, step) in steps.enumerated() {
            if step.actionType.isEmpty {
                errors.append("Step \(i): action type is empty")
            }
            let requiresConfirmation = ActionPolicyRegistry.requiresConfirmation(for: step.actionType)
            if !requiresConfirmation {
                let risk = ActionPolicyRegistry.riskLevel(for: step.actionType)
                if risk == .high {
                    errors.append("Step \(i): \(step.actionType) must require confirmation")
                }
            }
        }
        return errors
    }

    // MARK: - History

    func getTaskHistory(taskId: Int64, limit: Int = 20) -> [TaskRun] {
        do {
            let records = try db.read { db in
                try TaskRunRecord
                    .filter(Column("taskId") == taskId)
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.map(TaskRun.init)
        } catch {
            logger.error("Failed to get history for task \(taskId): \(error.localizedDescription)")
            return []
        }
    }

    func getRecentRuns(limit: Int = 10) -> [TaskRun] {
        do {
            let records = try db.read { db in
                try TaskRunRecord
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.map(TaskRun.init)
        } catch {
            logger.error("Failed to get recent runs: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Snapshot

    // MARK: - Sequence

    private func nextSequence() -> Int {
        sequenceLock.withLock { seq in
            seq += 1
            return seq
        }
    }

    func getCurrentSequence() -> Int {
        sequenceLock.withLock { $0 }
    }

    func getSnapshot() -> TaskSnapshot {
        let tasks = listTasks()
        // Fetch all runs once (timestamp desc) and group in memory, capping each task at 100, instead
        // of one getTaskHistory read per task (N+1). Order + per-task cap match getTaskHistory exactly.
        var runsByTask: [Int64: [TaskRun]] = [:]
        for task in tasks {
            if let id = task.id { runsByTask[id] = [] }
        }
        do {
            let records = try db.read { db in
                try TaskRunRecord.order(Column("timestamp").desc).fetchAll(db)
            }
            for record in records {
                guard var runs = runsByTask[record.taskId], runs.count < 100 else { continue }
                runs.append(TaskRun(record: record))
                runsByTask[record.taskId] = runs
            }
        } catch {
            logger.error("Failed to fetch task runs for snapshot: \(error.localizedDescription)")
        }
        return TaskSnapshot(tasks: tasks, runsByTask: runsByTask, sequence: getCurrentSequence())
    }

    // MARK: - Dashboard hooks

    var taskCount: Int {
        // SELECT COUNT(*) — no row materialization/decode (listTasks() has no filter, so same count).
        (try? db.read { db in try TaskDefinitionRecord.fetchCount(db) }) ?? 0
    }

    func tasksDueForSchedule() -> [TaskDefinition] {
        let all = listTasks().filter { $0.enabled && $0.scheduleType != .manual }
        return all.filter { task in
            guard let lastRun = task.lastRun else { return true }
            let calendar = Calendar.current
            switch task.scheduleType {
            case .daily:
                return !calendar.isDateInToday(lastRun)
            case .weekly:
                let daysSince = calendar.dateComponents([.day], from: lastRun, to: Date()).day ?? 0
                return daysSince >= 7
            case .custom:
                return true
            case .manual:
                return false
            }
        }
    }

    // MARK: - Private

    private func persistRun(_ run: TaskRun) throws {
        let outputData = try JSONEncoder().encode(run.output)
        let outputJSON = String(data: outputData, encoding: .utf8) ?? "{}"
        let record = TaskRunRecord(
            id: run.id,
            taskId: run.taskId,
            timestamp: run.timestamp.timeIntervalSince1970,
            status: run.status.rawValue,
            outputJSON: outputJSON
        )
        try db.write { db in
            try record.insert(db)
        }
    }

    private func markLastRun(id: Int64) throws {
        let now = Date().timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: "UPDATE task_definitions SET lastRun = ? WHERE id = ?", arguments: [now, id])
        }
    }

}

// MARK: - Errors

enum TaskError: LocalizedError {
    case notFound
    case disabled
    case noSteps
    case invalidParameter(String)
    case unsupportedAction(String)
    case confirmationRequired(String)

    var errorDescription: String? {
        switch self {
        case .notFound:                     return "Task not found"
        case .disabled:                     return "Task is disabled"
        case .noSteps:                      return "Task has no steps"
        case .invalidParameter(let p):      return "Missing parameter: \(p)"
        case .unsupportedAction(let a):     return "Unsupported action: \(a)"
        case .confirmationRequired(let a):  return "Confirmation required for high-risk action: \(a)"
        }
    }
}
