import Foundation

struct LearningLoopAnalytics {

    func compute(_ suggestions: [TrainingSuggestion], events: [LoopEvent]) -> AnalyticsResult {
        let total = suggestions.count
        guard total > 0 else {
            return AnalyticsResult(
                totalSuggestions: 0,
                acceptanceRate: 0,
                rejectionRate: 0,
                editRate: 0,
                topAcceptedWorkflows: [],
                topRejectedWorkflows: []
            )
        }

        let accepted = suggestions.filter(\.accepted).count
        let rejected = suggestions.filter(\.rejected).count
        let edited = suggestions.filter(\.edited).count

        let workflowEvents = events.filter { $0.type == .workflowCompleted || $0.type == .workflowCancelled }
        let workflowAccepted = workflowEvents.filter { $0.type == .workflowCompleted }
        let workflowRejected = workflowEvents.filter { $0.type == .workflowCancelled }

        return AnalyticsResult(
            totalSuggestions: total,
            acceptanceRate: Double(accepted) / Double(total),
            rejectionRate: Double(rejected) / Double(total),
            editRate: Double(edited) / Double(total),
            topAcceptedWorkflows: topWorkflowNames(from: workflowAccepted),
            topRejectedWorkflows: topWorkflowNames(from: workflowRejected)
        )
    }

    private func topWorkflowNames(from events: [LoopEvent], limit: Int = 5) -> [String] {
        var counts: [String: Int] = [:]
        for event in events {
            if let name = event.metadata?["workflowName"] {
                counts[name, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
}

struct AnalyticsResult {
    let totalSuggestions: Int
    let acceptanceRate: Double
    let rejectionRate: Double
    let editRate: Double
    let topAcceptedWorkflows: [String]
    let topRejectedWorkflows: [String]

    var summary: String {
        guard totalSuggestions > 0 else { return "No learning data yet." }

        var lines: [String] = []
        lines.append("Learning signals:")
        lines.append("  • \(Int(acceptanceRate * 100))% acceptance rate (\(totalSuggestions) total)")
        if editRate > 0 {
            lines.append("  • \(Int(editRate * 100))% edit rate")
        }
        if rejectionRate > 0 {
            lines.append("  • \(Int(rejectionRate * 100))% rejection rate")
        }
        if !topAcceptedWorkflows.isEmpty {
            let acc = topAcceptedWorkflows.joined(separator: ", ")
            lines.append("  • Frequent accepted workflows: \(acc)")
        }
        if !topRejectedWorkflows.isEmpty {
            let rej = topRejectedWorkflows.joined(separator: ", ")
            lines.append("  • Frequent rejected workflows: \(rej)")
        }
        return lines.joined(separator: "\n")
    }
}
