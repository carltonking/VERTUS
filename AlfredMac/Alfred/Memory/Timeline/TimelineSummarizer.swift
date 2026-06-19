import Foundation

struct TimelineSummarizer {

    func summarize(_ events: [ActivityEvent]) -> String {
        guard !events.isEmpty else {
            return "No activity recorded yet."
        }

        var lines: [String] = []
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        let todayEvents = events.filter { $0.timestamp >= todayStart }
        let todayCount = todayEvents.count
        lines.append("Today: \(todayCount) event\(todayCount == 1 ? "" : "s").")

        // Time spent per app (based on appFocused events)
        let appFocusTimes = focusTimeByApp(events: todayEvents)
        if let top = appFocusTimes.first {
            lines.append("Most time in \(top.app).")
        }

        // App switch frequency
        let focusEvents = todayEvents.filter { $0.eventType == .appFocused }
        if focusEvents.count > 3 {
            lines.append("Switched apps \(focusEvents.count) times.")
        }

        // App launches
        let launches = todayEvents.filter { $0.eventType == .appOpened }
        if !launches.isEmpty {
            let appNames = Set(launches.map(\.applicationName)).sorted()
            if appNames.count <= 3 {
                lines.append("Launched: \(appNames.joined(separator: ", ")).")
            } else {
                lines.append("Launched \(appNames.count) different apps.")
            }
        }

        // Document activity
        let docsOpened = todayEvents.filter { $0.eventType == .documentOpened }.count
        let docsCreated = todayEvents.filter { $0.eventType == .fileCreate }.count
        let totalDocs = docsOpened + docsCreated
        if totalDocs > 0 {
            lines.append("Opened or created \(totalDocs) document\(totalDocs == 1 ? "" : "s").")
        }

        // Workflow executions
        let workflows = todayEvents.filter { $0.eventType == .workflowExecuted }
        if !workflows.isEmpty {
            lines.append("Ran \(workflows.count) workflow\(workflows.count == 1 ? "" : "s").")
        }

        // Browser navigation
        let browsers = todayEvents.filter { $0.eventType == .browserNavigation }
        if !browsers.isEmpty {
            lines.append("\(browsers.count) browser navigation\(browsers.count == 1 ? "" : "s").")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - App focus time estimation

    struct AppFocusTime {
        let app: String
        let estimatedMinutes: Int
    }

    func focusTimeByApp(events: [ActivityEvent]) -> [AppFocusTime] {
        let sorted = events
            .filter { $0.eventType == .appFocused }
            .sorted { $0.timestamp < $1.timestamp }

        guard sorted.count >= 2 else {
            if let single = sorted.first {
                return [AppFocusTime(app: single.applicationName, estimatedMinutes: 0)]
            }
            return []
        }

        var appDurations: [String: TimeInterval] = [:]
        for i in 0..<(sorted.count - 1) {
            let duration = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp)
            let app = sorted[i].applicationName
            appDurations[app, default: 0] += duration
        }

        let total = appDurations.values.reduce(0, +)
        guard total > 0 else { return [] }

        let scale = Double(sorted.count) / 6.0
        var results: [AppFocusTime] = []
        for (app, duration) in appDurations {
            let ratio = duration / total
            let minutes = Int(ratio * scale)
            results.append(AppFocusTime(app: app, estimatedMinutes: minutes))
        }
        return results.sorted { $0.estimatedMinutes > $1.estimatedMinutes }
    }

    // MARK: - Event counts by app

    func eventCountsByApplication(_ events: [ActivityEvent]) -> [(application: String, count: Int)] {
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.applicationName, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}
