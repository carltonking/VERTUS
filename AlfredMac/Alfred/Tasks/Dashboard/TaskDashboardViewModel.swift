import Foundation

struct TaskDashboardViewModel: Identifiable {
    let id: Int64
    let name: String
    let description: String
    let scheduleType: TaskScheduleType
    let stepsCount: Int
    let enabled: Bool

    let lastRunAgo: String
    let nextRunDue: String?
    let successRate: Double
    let totalRuns: Int
    let successfulRuns: Int
    let failedRuns: Int
    let isOverdue: Bool
    let statusLabel: String

    init(task: TaskDefinition, runs: [TaskRun]) {
        self.id = task.id ?? 0
        self.name = task.name
        self.description = task.description
        self.scheduleType = task.scheduleType
        self.stepsCount = task.steps.count
        self.enabled = task.enabled

        // Run statistics
        self.totalRuns = runs.count
        self.successfulRuns = runs.filter { $0.status == .success }.count
        self.failedRuns = runs.filter { $0.status == .failure }.count
        self.successRate = totalRuns > 0 ? Double(successfulRuns) / Double(totalRuns) : 0.0

        // Last run
        if let lastRun = task.lastRun {
            self.lastRunAgo = Self.relativeTime(from: lastRun)
        } else {
            self.lastRunAgo = "never"
        }

        // Schedule-based computation
        if task.enabled && task.scheduleType != .manual {
            let nextDue = Self.nextRunDate(lastRun: task.lastRun, schedule: task.scheduleType)
            if let due = nextDue {
                self.nextRunDue = Self.relativeTime(from: due)
                self.isOverdue = due < Date()
            } else {
                self.nextRunDue = nil
                self.isOverdue = false
            }
        } else {
            self.nextRunDue = nil
            self.isOverdue = false
        }

        // Status label
        if !task.enabled {
            self.statusLabel = "disabled"
        } else if task.scheduleType == .manual {
            self.statusLabel = "manual"
        } else if isOverdue {
            self.statusLabel = "overdue"
        } else if task.lastRun == nil {
            self.statusLabel = "ready"
        } else {
            self.statusLabel = "scheduled"
        }
    }

    var scheduleLabel: String {
        switch scheduleType {
        case .manual:  return "Manual"
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .custom:  return "Custom"
        }
    }

    var successRateLabel: String {
        guard totalRuns > 0 else { return "—" }
        return "\(Int(successRate * 100))%"
    }

    // MARK: - Private helpers

    private static func relativeTime(from date: Date) -> String {
        let interval = abs(date.timeIntervalSinceNow)
        switch interval {
        case ..<60:          return "just now"
        case ..<3600:        return "\(Int(interval / 60))m ago"
        case ..<86400:       return "\(Int(interval / 3600))h ago"
        case ..<604800:      return "\(Int(interval / 86400))d ago"
        default:             return "\(Int(interval / 604800))w ago"
        }
    }

    private static func nextRunDate(lastRun: Date?, schedule: TaskScheduleType) -> Date? {
        guard schedule != .manual else { return nil }
        let calendar = Calendar.current
        let now = Date()

        switch schedule {
        case .daily:
            guard let last = lastRun else { return now }
            return calendar.date(byAdding: .day, value: 1, to: last)
        case .weekly:
            guard let last = lastRun else { return now }
            return calendar.date(byAdding: .day, value: 7, to: last)
        case .custom:
            return lastRun
        default:
            return nil
        }
    }
}
