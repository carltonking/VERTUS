import Foundation
import OSLog

private let logger = Logger(subsystem: "com.alfred.app", category: "WorkflowSuggestion")

@MainActor
final class WorkflowSuggestionService {
    private let detectionService: WorkflowDetectionService
    private let contextCollector: ContextCollectorProtocol
    private let relationshipMemory: RelationshipMemoryService

    init(
        detectionService: WorkflowDetectionService,
        contextCollector: ContextCollectorProtocol,
        relationshipMemory: RelationshipMemoryService
    ) {
        self.detectionService = detectionService
        self.contextCollector = contextCollector
        self.relationshipMemory = relationshipMemory
    }

    func runDetection() -> [Workflow] {
        detectionService.detectWorkflows()
    }

    var availableWorkflows: [Workflow] {
        detectionService.allWorkflows
    }

    // MARK: - Proactive Suggestion Generation

    func generateWorkflowSuggestions() -> [MemorySuggestion] {
        let appName = contextCollector.getActiveAppName()?.lowercased() ?? ""
        let recentQueries = contextCollector.getRecentQueryHistory(limit: 10)
        var results: [MemorySuggestion] = []

        let workflows = detectionService.allWorkflows

        for workflow in workflows {
            let titleMatch = workflow.title.lowercased()
            let appMatch = !appName.isEmpty && titleMatch.contains(appName)
            let queryMatch = recentQueries.contains { q in
                let lowered = q.lowercased()
                return titleMatch.split(separator: " ").contains { lowered.contains($0) }
            }

            guard appMatch || queryMatch else { continue }

            let stepCount = workflow.steps.count
            let confidence = min(0.85, 0.5 + Double(workflow.useCount) * 0.05 + Double(stepCount) * 0.02)

            results.append(MemorySuggestion.make(
                type: .action,
                title: "Run workflow: \(workflow.title)",
                subtitle: "\(stepCount) step(s), used \(workflow.useCount) time(s)",
                action: .runWorkflow(workflow.id.uuidString),
                confidence: confidence
            ))
        }

        return results
    }

    // MARK: - Suggest from query

    func suggestFromQuery(_ query: String) -> Workflow? {
        let lowered = query.lowercased()
        let workflows = detectionService.allWorkflows

        let ranked = workflows.compactMap { w -> (Workflow, Double)? in
            let titleWords = w.title.lowercased().split(separator: " ")
            let matchCount = titleWords.filter { lowered.contains($0) }.count
            guard matchCount > 0 else { return nil }
            let score = Double(matchCount) / Double(titleWords.count) * Double(w.useCount + 1)
            return (w, score)
        }.sorted { $0.1 > $1.1 }

        return ranked.first?.0
    }

    func recordWorkflowUsed(_ id: UUID) {
        detectionService.recordUsage(id: id)
    }
}
