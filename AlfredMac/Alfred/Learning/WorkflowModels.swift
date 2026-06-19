import Foundation

enum WorkflowStepType: String, Codable, CaseIterable {
    case query
    case execute
    case wait
    case notify
    case confirm
}

struct WorkflowStep: Identifiable, Codable, Equatable {
    let id: UUID
    let type: WorkflowStepType
    let title: String
    let details: String

    init(id: UUID = UUID(), type: WorkflowStepType, title: String, details: String = "") {
        self.id = id
        self.type = type
        self.title = title
        self.details = details
    }
}

struct Workflow: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var steps: [WorkflowStep]
    var createdAt: Date
    var lastUsed: Date
    var useCount: Int
    var sourceMemoryIds: [UUID]
    var archived: Bool

    init(id: UUID = UUID(), title: String, steps: [WorkflowStep], sourceMemoryIds: [UUID] = []) {
        self.id = id
        self.title = title
        self.steps = steps
        self.createdAt = Date()
        self.lastUsed = Date()
        self.useCount = 0
        self.sourceMemoryIds = sourceMemoryIds
        self.archived = false
    }
}

protocol WorkflowStoreProtocol {
    func load() -> [Workflow]
    func save(_ workflows: [Workflow]) throws
}

final class WorkflowStore: WorkflowStoreProtocol {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(fileURL: home.appending(path: ".alfred/workflows.json", directoryHint: .notDirectory))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [Workflow] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return []
        }
        guard let workflows = try? decoder.decode([Workflow].self, from: data) else { return [] }
        return workflows
    }

    func save(_ workflows: [Workflow]) throws {
        let data = try encoder.encode(workflows)
        try data.write(to: fileURL, options: .atomic)
    }
}
