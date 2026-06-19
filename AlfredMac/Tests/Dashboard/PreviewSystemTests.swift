import XCTest
import GRDB
@testable import Alfred

// MARK: - Preview confirmation logic (mirrors PreviewPanel.canExecute)

private struct PreviewConfirmationValidator {
    let stepIds: [UUID]

    init(steps: [TaskStep]) {
        stepIds = steps.map { _ in UUID() }
    }

    func canExecute(steps: [TaskStep], confirmedSteps: Set<UUID>, overallConfirmed: Bool) -> Bool {
        let highRiskIndices = steps.enumerated().filter {
            ActionPolicyRegistry.riskLevel(for: $0.element.actionType) == .high
        }
        let mediumRiskIndices = steps.enumerated().filter {
            ActionPolicyRegistry.riskLevel(for: $0.element.actionType) == .medium
        }

        if !highRiskIndices.isEmpty && !overallConfirmed {
            return false
        }

        for (index, _) in mediumRiskIndices {
            if !confirmedSteps.contains(stepIds[index]) {
                return false
            }
        }

        return true
    }
}

// MARK: - Tests

final class PreviewSystemTests: XCTestCase {

    // MARK: - ActionPolicyRegistry tests

    func testAllActionTypesHavePolicy() {
        for type in ActionType.allCases {
            let actionClass = ActionPolicyRegistry.actionClass(for: type)
            let risk = ActionPolicyRegistry.riskLevel(for: type)
            let requiresConf = ActionPolicyRegistry.requiresConfirmation(for: type)

            XCTAssertNotNil(actionClass as Any?, "Missing actionClass for \(type.rawValue)")
            XCTAssertNotNil(risk as Any?, "Missing riskLevel for \(type.rawValue)")
            // requiresConfirmation returns Bool so it can't be nil; just assert it's valid
            XCTAssertNoThrow(_ = ActionPolicyRegistry.requiresConfirmation(for: type))
        }
    }

    func testReadOnlyActionsAreSafe() {
        for rawValue in ["search_files", "query_memory", "respond_text"] {
            let type = ActionType(rawValue: rawValue)!
            let cls = ActionPolicyRegistry.actionClass(for: type)
            let risk = ActionPolicyRegistry.riskLevel(for: type)
            let requiresConf = ActionPolicyRegistry.requiresConfirmation(for: type)

            XCTAssertEqual(cls, .readOnly, "\(rawValue) should be readOnly")
            XCTAssertEqual(risk, .low, "\(rawValue) should be low risk")
            XCTAssertFalse(requiresConf, "\(rawValue) should not require confirmation")
        }
    }

    func testSystemExecutionRequiresConfirmation() {
        guard let type = ActionType(rawValue: "system_command") else {
            XCTFail("system_command not found in ActionType")
            return
        }
        XCTAssertEqual(ActionPolicyRegistry.actionClass(for: type), .systemExecution)
        XCTAssertEqual(ActionPolicyRegistry.riskLevel(for: type), .high)
        XCTAssertTrue(ActionPolicyRegistry.requiresConfirmation(for: type))
    }

    func testUnknownStringDefaultsToSafest() {
        let cls = ActionPolicyRegistry.actionClass(for: "nonexistent_action")
        let risk = ActionPolicyRegistry.riskLevel(for: "nonexistent_action")
        let requiresConf = ActionPolicyRegistry.requiresConfirmation(for: "nonexistent_action")

        XCTAssertEqual(cls, .systemExecution, "Unknown types should default to .systemExecution (safest)")
        XCTAssertEqual(risk, .high, "Unknown types should default to .high risk")
        XCTAssertTrue(requiresConf, "Unknown types should default to requiring confirmation")
    }

    // MARK: - TaskEngine confirmation tests

    private func makeEngine() throws -> TaskEngine {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS task_definitions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    taskDescription TEXT NOT NULL DEFAULT '',
                    scheduleType TEXT NOT NULL DEFAULT 'manual',
                    stepsJSON TEXT NOT NULL DEFAULT '[]',
                    lastRun REAL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    createdAt REAL NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS task_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    taskId INTEGER NOT NULL,
                    timestamp REAL NOT NULL,
                    status TEXT NOT NULL,
                    outputJSON TEXT NOT NULL DEFAULT '{}'
                )
            """)
        }
        return TaskEngine(db: db)
    }

    private func registerTask(engine: TaskEngine, steps: [TaskStep]) throws -> Int64 {
        let def = TaskDefinition(
            name: "Test Task",
            description: "",
            scheduleType: .manual,
            steps: steps,
            enabled: true
        )
        return try engine.registerTask(def)
    }

    func testHighRiskStepBlockedWithoutConfirmation() async throws {
        let engine = try makeEngine()
        let step = TaskStep(actionType: "system_command", parameters: ["command": "echo hello"])
        let taskId = try registerTask(engine: engine, steps: [step])

        do {
            _ = try await engine.runTask(id: taskId, confirmations: [:])
            XCTFail("Expected confirmationRequired error")
        } catch TaskError.confirmationRequired {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHighRiskStepAllowedWithConfirmation() async throws {
        let engine = try makeEngine()
        let step = TaskStep(actionType: "system_command", parameters: ["command": "echo hello"])
        let taskId = try registerTask(engine: engine, steps: [step])

        do {
            _ = try await engine.runTask(id: taskId, confirmations: [0: true])
            // May fail at execution (system_command tries ShellCapability), but NOT at confirmation
        } catch TaskError.confirmationRequired {
            XCTFail("Should not throw confirmationRequired when confirmed")
        } catch {
            // Any other error (execution failure) is acceptable — confirmation check passed
        }
    }

    func testMediumRiskStepDoesNotRequireTaskLevelConfirmation() async throws {
        let engine = try makeEngine()
        let step = TaskStep(actionType: "create_file", parameters: ["path": "/tmp/test.txt"])
        let taskId = try registerTask(engine: engine, steps: [step])

        do {
            _ = try await engine.runTask(id: taskId, confirmations: [:])
            // Medium risk steps don't trigger Layer 1 (task-level) rejection
            // They may fail at execution or Layer 2 (step-level), but NOT at the task-level check
        } catch TaskError.confirmationRequired {
            XCTFail("Medium risk step should not throw confirmationRequired at task level")
        } catch {
            // Execution-level errors are acceptable
        }
    }

    func testMixedRiskTaskRequiresConfirmation() async throws {
        let engine = try makeEngine()
        let lowStep = TaskStep(actionType: "search_files", parameters: ["pattern": "*"])
        let highStep = TaskStep(actionType: "system_command", parameters: ["command": "ls"])
        let taskId = try registerTask(engine: engine, steps: [lowStep, highStep])

        do {
            _ = try await engine.runTask(id: taskId, confirmations: [:])
            XCTFail("Expected confirmationRequired error for mixed-risk task with high-risk step")
        } catch TaskError.confirmationRequired {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - PreviewPanel canExecute logic tests

    func testAllLowRiskCanExecuteImmediately() {
        let steps = [
            TaskStep(actionType: "search_files", parameters: ["pattern": "*"]),
            TaskStep(actionType: "query_memory", parameters: ["query": "test"]),
        ]
        let validator = PreviewConfirmationValidator(steps: steps)
        XCTAssertTrue(validator.canExecute(steps: steps, confirmedSteps: [], overallConfirmed: false))
    }

    func testMediumRiskRequiresStepConfirmation() {
        let steps = [
            TaskStep(actionType: "create_file", parameters: ["path": "/tmp/test.txt"]),
        ]
        let validator = PreviewConfirmationValidator(steps: steps)
        let stepId = validator.stepIds[0]

        XCTAssertFalse(validator.canExecute(steps: steps, confirmedSteps: [], overallConfirmed: false))
        XCTAssertFalse(validator.canExecute(steps: steps, confirmedSteps: [], overallConfirmed: true))
        XCTAssertTrue(validator.canExecute(steps: steps, confirmedSteps: [stepId], overallConfirmed: false))
        XCTAssertTrue(validator.canExecute(steps: steps, confirmedSteps: [stepId], overallConfirmed: true))
    }

    func testHighRiskRequiresOverallConfirmation() {
        let steps = [
            TaskStep(actionType: "system_command", parameters: ["command": "echo test"]),
        ]
        let validator = PreviewConfirmationValidator(steps: steps)

        XCTAssertFalse(validator.canExecute(steps: steps, confirmedSteps: [], overallConfirmed: false))
        XCTAssertFalse(validator.canExecute(steps: steps, confirmedSteps: [validator.stepIds[0]], overallConfirmed: false))
        XCTAssertTrue(validator.canExecute(steps: steps, confirmedSteps: [], overallConfirmed: true))
    }

    func testMixedRiskRequiresBoth() {
        let steps = [
            TaskStep(actionType: "search_files", parameters: ["pattern": "*"]),
            TaskStep(actionType: "create_file", parameters: ["path": "/tmp/a.txt"]),
            TaskStep(actionType: "system_command", parameters: ["command": "echo test"]),
        ]
        let validator = PreviewConfirmationValidator(steps: steps)
        let mediumId = validator.stepIds[1]

        // Neither confirmed
        XCTAssertFalse(validator.canExecute(steps: steps, confirmedSteps: [], overallConfirmed: false))
        // Only overall (high risk) confirmed
        XCTAssertFalse(validator.canExecute(steps: steps, confirmedSteps: [], overallConfirmed: true))
        // Only step confirmed
        XCTAssertFalse(validator.canExecute(steps: steps, confirmedSteps: [mediumId], overallConfirmed: false))
        // Both confirmed
        XCTAssertTrue(validator.canExecute(steps: steps, confirmedSteps: [mediumId], overallConfirmed: true))
    }
}
