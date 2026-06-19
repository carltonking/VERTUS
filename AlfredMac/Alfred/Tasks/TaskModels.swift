import Foundation
import GRDB

// MARK: - Schedule types

enum TaskScheduleType: String, Codable, CaseIterable {
    case manual
    case daily
    case weekly
    case custom
}

// MARK: - Task step

struct TaskStep: Codable, Equatable {
    let actionType: String
    var parameters: [String: String]

    static func systemCommand(_ command: String) -> TaskStep {
        TaskStep(
            actionType: "system_command",
            parameters: ["command": command]
        )
    }

    static func openApplication(_ name: String) -> TaskStep {
        TaskStep(
            actionType: "open_application",
            parameters: ["application": name]
        )
    }

    static func sendMessage(recipient: String, subject: String, body: String) -> TaskStep {
        TaskStep(
            actionType: "send_message",
            parameters: ["recipient": recipient, "subject": subject, "body": body]
        )
    }

    static func queryMemory(_ query: String) -> TaskStep {
        TaskStep(
            actionType: "query_memory",
            parameters: ["query": query]
        )
    }

    static func searchFiles(_ pattern: String) -> TaskStep {
        TaskStep(
            actionType: "search_files",
            parameters: ["pattern": pattern]
        )
    }

    static func customAction(_ type: String, params: [String: String]) -> TaskStep {
        TaskStep(actionType: type, parameters: params)
    }
}

// MARK: - Task definition (GRDB record)

struct TaskDefinitionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_definitions"

    var id: Int64?
    var name: String
    var taskDescription: String
    var scheduleType: String
    var stepsJSON: String
    var lastRun: Double?
    var enabled: Bool
    var createdAt: Double
}

struct TaskDefinition {
    let id: Int64?
    let name: String
    let description: String
    let scheduleType: TaskScheduleType
    let steps: [TaskStep]
    let lastRun: Date?
    let enabled: Bool
    let createdAt: Date

    init(record: TaskDefinitionRecord) {
        self.id = record.id
        self.name = record.name
        self.description = record.taskDescription
        self.scheduleType = TaskScheduleType(rawValue: record.scheduleType) ?? .manual
        let data = record.stepsJSON.data(using: .utf8) ?? Data()
        self.steps = (try? JSONDecoder().decode([TaskStep].self, from: data)) ?? []
        self.lastRun = record.lastRun.map { Date(timeIntervalSince1970: $0) }
        self.enabled = record.enabled
        self.createdAt = Date(timeIntervalSince1970: record.createdAt)
    }

    init(
        id: Int64? = nil,
        name: String,
        description: String,
        scheduleType: TaskScheduleType,
        steps: [TaskStep],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.scheduleType = scheduleType
        self.steps = steps
        self.lastRun = nil
        self.enabled = enabled
        self.createdAt = Date()
    }
}

// MARK: - Task run (GRDB record)

struct TaskRunRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "task_runs"

    var id: Int64?
    var taskId: Int64
    var timestamp: Double
    var status: String
    var outputJSON: String
}

enum TaskRunStatus: String, Codable {
    case running
    case success
    case failure
    case cancelled
}

struct TaskRun {
    let id: Int64?
    let taskId: Int64
    let timestamp: Date
    let status: TaskRunStatus
    let output: [String: String]

    init(record: TaskRunRecord) {
        self.id = record.id
        self.taskId = record.taskId
        self.timestamp = Date(timeIntervalSince1970: record.timestamp)
        self.status = TaskRunStatus(rawValue: record.status) ?? .failure
        let data = record.outputJSON.data(using: .utf8) ?? Data()
        self.output = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    init(
        taskId: Int64,
        status: TaskRunStatus,
        output: [String: String]
    ) {
        self.id = nil
        self.taskId = taskId
        self.timestamp = Date()
        self.status = status
        self.output = output
    }
}
