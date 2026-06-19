import Foundation

struct TaskDashboardGroup: Identifiable {
    let id: String
    let label: String
    let tasks: [TaskDashboardViewModel]

    var count: Int { tasks.count }
}

struct TaskDashboardState {
    var groups: [TaskDashboardGroup] = []
    var selectedTaskId: Int64?
    var isLoading: Bool = false
    var errorState: String? = nil

    var allTasks: [TaskDashboardViewModel] {
        groups.flatMap(\.tasks)
    }

    var selectedTask: TaskDashboardViewModel? {
        guard let id = selectedTaskId else { return nil }
        return allTasks.first { $0.id == id }
    }

    var manualTasks: [TaskDashboardViewModel] {
        groups.first { $0.id == "manual" }?.tasks ?? []
    }

    var scheduledTasks: [TaskDashboardViewModel] {
        groups.first { $0.id == "scheduled" }?.tasks ?? []
    }

    var disabledTasks: [TaskDashboardViewModel] {
        groups.first { $0.id == "disabled" }?.tasks ?? []
    }

    static let empty = TaskDashboardState(groups: [], selectedTaskId: nil)

    static func from(viewModels: [TaskDashboardViewModel]) -> TaskDashboardState {
        let manual = viewModels.filter { $0.scheduleType == .manual && $0.enabled }
        let scheduled = viewModels.filter { $0.scheduleType != .manual && $0.enabled }
        let disabled = viewModels.filter { !$0.enabled }

        return TaskDashboardState(groups: [
            TaskDashboardGroup(id: "scheduled", label: "Scheduled", tasks: scheduled),
            TaskDashboardGroup(id: "manual", label: "Manual", tasks: manual),
            TaskDashboardGroup(id: "disabled", label: "Disabled", tasks: disabled),
        ].filter { !$0.tasks.isEmpty })
    }
}
