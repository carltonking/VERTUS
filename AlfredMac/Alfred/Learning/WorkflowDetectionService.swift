import Foundation
import OSLog

private let logger = Logger(subsystem: "com.alfred.app", category: "WorkflowDetection")

@MainActor
final class WorkflowDetectionService {
    private let contextCollector: ContextCollectorProtocol
    private let relationshipMemory: RelationshipMemoryService
    private let store: WorkflowStoreProtocol
    private var workflows: [Workflow]

    init(contextCollector: ContextCollectorProtocol, relationshipMemory: RelationshipMemoryService) {
        self.contextCollector = contextCollector
        self.relationshipMemory = relationshipMemory
        store = WorkflowStore()
        workflows = store.load()
    }

    init(contextCollector: ContextCollectorProtocol, relationshipMemory: RelationshipMemoryService, store: WorkflowStoreProtocol) {
        self.contextCollector = contextCollector
        self.relationshipMemory = relationshipMemory
        self.store = store
        workflows = store.load()
    }

    var allWorkflows: [Workflow] {
        workflows.filter { !$0.archived }.sorted { $0.lastUsed > $1.lastUsed }
    }

    var archivedWorkflows: [Workflow] {
        workflows.filter { $0.archived }.sorted { $0.createdAt > $1.createdAt }
    }

    func workflow(by id: UUID) -> Workflow? {
        workflows.first { $0.id == id }
    }

    // MARK: - Detection

    func detectWorkflows() -> [Workflow] {
        let queries = contextCollector.getRecentQueryHistory(limit: 100)
        let workflowMemories = relationshipMemory.allMemoriesForAnalysis()
            .filter { $0.category == .workflows && !$0.isArchived }
            .sorted { $0.importance > $1.importance }
            .prefix(10)
        var detected: [Workflow] = []

        detected += detectFromQueries(queries)
        detected += detectFromMemories(Array(workflowMemories))

        for w in detected {
            if let existing = workflows.firstIndex(where: { $0.title == w.title }) {
                workflows[existing].lastUsed = Date()
                workflows[existing].useCount += 1
            } else {
                workflows.append(w)
            }
        }

        try? store.save(workflows)
        return detected
    }

    private func detectFromQueries(_ queries: [String]) -> [Workflow] {
        guard queries.count >= 3 else { return [] }
        var results: [Workflow] = []

        let patterns: [(String, [String], [WorkflowStepType])] = [
            ("Research then summarize",
             ["research", "find", "look up", "search", "investigate"],
             [.query, .query, .notify]),
            ("Create and organize",
             ["create", "make", "build", "set up", "organize"],
             [.query, .execute, .notify]),
            ("Review and respond",
             ["review", "check", "read", "look at"],
             [.query, .confirm, .query]),
        ]

        for (title, triggers, stepTypes) in patterns {
            let matching = queries.filter { q in
                triggers.contains { q.lowercased().contains($0) }
            }
            guard matching.count >= 2 else { continue }

            let steps = zip(triggers, stepTypes).prefix(3).map { trigger, type in
                WorkflowStep(type: type, title: trigger.capitalized, details: "")
            }

            results.append(Workflow(title: title, steps: steps))
        }

        return results
    }

    private func detectFromMemories(_ memories: [RelationshipMemory]) -> [Workflow] {
        var results: [Workflow] = []

        for memory in memories {
            let content = memory.content.lowercased()
            let steps = extractSteps(from: content)
            guard steps.count >= 2 else { continue }

            let title: String
            if content.count > 60 {
                title = String(content.prefix(60)) + "..."
            } else {
                title = memory.content
            }

            results.append(Workflow(
                title: title,
                steps: steps,
                sourceMemoryIds: [memory.id]
            ))
        }

        return results
    }

    private func extractSteps(from content: String) -> [WorkflowStep] {
        var steps: [WorkflowStep] = []

        let lines = content.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let type: WorkflowStepType
            let lowered = trimmed.lowercased()

            if lowered.contains("wait") || lowered.contains("delay") {
                type = .wait
            } else if lowered.contains("confirm") || lowered.contains("approve") || lowered.contains("check") {
                type = .confirm
            } else if lowered.contains("notify") || lowered.contains("tell") || lowered.contains("inform") || lowered.contains("send") {
                type = .notify
            } else if lowered.contains("run") || lowered.contains("execute") || lowered.contains("do") || lowered.contains("apply") {
                type = .execute
            } else {
                type = .query
            }

            steps.append(WorkflowStep(type: type, title: trimmed, details: ""))
        }

        return steps
    }

    // MARK: - Manual Management

    func addWorkflow(_ workflow: Workflow) {
        workflows.append(workflow)
        try? store.save(workflows)
    }

    func updateWorkflow(_ workflow: Workflow) {
        guard let idx = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[idx] = workflow
        try? store.save(workflows)
    }

    func deleteWorkflow(id: UUID) {
        workflows.removeAll { $0.id == id }
        try? store.save(workflows)
    }

    func archiveWorkflow(id: UUID) {
        guard let idx = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[idx].archived = true
        try? store.save(workflows)
    }

    func restoreWorkflow(id: UUID) {
        guard let idx = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[idx].archived = false
        try? store.save(workflows)
    }

    func recordUsage(id: UUID) {
        guard let idx = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[idx].lastUsed = Date()
        workflows[idx].useCount += 1
        try? store.save(workflows)
    }

    var workflowCount: Int { workflows.count }
}
