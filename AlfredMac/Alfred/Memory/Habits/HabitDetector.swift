import Foundation

struct HabitDetector {
    private let calendar = Calendar.current
    private let minEventsForPattern = 3

    func detect(from events: [ActivityEvent]) -> [DetectedHabit] {
        var results: [DetectedHabit] = []
        results.append(contentsOf: detectAppUsageByHour(events))
        results.append(contentsOf: detectSchedulePreferences(events))
        results.append(contentsOf: detectAppTransitionPatterns(events))
        results.append(contentsOf: detectAppLaunchPatterns(events))
        return results
    }

    // MARK: - App usage by hour block

    private func detectAppUsageByHour(_ events: [ActivityEvent]) -> [DetectedHabit] {
        let focus = events.filter { $0.eventType == .appFocused }
        guard focus.count >= minEventsForPattern else { return [] }

        var hourAppCount: [Int: [String: Int]] = [:]
        for event in focus {
            let hour = calendar.component(.hour, from: event.timestamp)
            hourAppCount[hour, default: [:]][event.applicationName, default: 0] += 1
        }

        var results: [DetectedHabit] = []

        for (hour, apps) in hourAppCount {
            guard let top = apps.max(by: { $0.value < $1.value }) else { continue }
            let total = apps.values.reduce(0, +)
            let ratio = Double(top.value) / Double(total)
            guard ratio >= 0.4, top.value >= minEventsForPattern else { continue }

            let period = periodName(for: hour)
            let freqScore = min(Double(top.value) / 20.0, 0.35)
            let ratioScore = ratio * 0.3
            let confidence = min(0.15 + freqScore + ratioScore, 1.0)

            results.append(DetectedHabit(
                name: "Uses \(top.key) in the \(period)",
                type: .application_usage,
                confidence: confidence,
                metadata: [
                    "application": top.key,
                    "hour": "\(hour)",
                    "period": period,
                    "frequency": "\(top.value)",
                ]
            ))
        }

        return results
    }

    // MARK: - Schedule preferences by time block

    private func detectSchedulePreferences(_ events: [ActivityEvent]) -> [DetectedHabit] {
        guard events.count >= minEventsForPattern else { return [] }
        let focus = events.filter { $0.eventType == .appFocused }
        guard !focus.isEmpty else { return [] }

        var hourCount: [Int: Int] = [:]
        for event in focus {
            let hour = calendar.component(.hour, from: event.timestamp)
            hourCount[hour, default: 0] += 1
        }

        let total = hourCount.values.reduce(0, +)
        guard total > 0 else { return [] }

        let blocks: [(name: String, range: Range<Int>, type: HabitType)] = [
            ("morning", 6..<12, .work_schedule),
            ("afternoon", 12..<18, .work_schedule),
            ("evening", 18..<22, .study_schedule),
            ("night", 22..<24, .study_schedule),
            ("early morning", 0..<6, .productivity_pattern),
        ]

        var results: [DetectedHabit] = []
        for block in blocks {
            let count = block.range.reduce(0) { $0 + (hourCount[$1] ?? 0) }
            let ratio = Double(count) / Double(total)
            guard ratio >= 0.25, count >= minEventsForPattern else { continue }

            let confidence = min(0.3 + (ratio * 0.4) + min(Double(count) / 50.0, 0.3), 1.0)
            results.append(DetectedHabit(
                name: "Active in the \(block.name)",
                type: block.type,
                confidence: confidence,
                metadata: [
                    "period": block.name,
                    "eventCount": "\(count)",
                    "ratio": String(format: "%.2f", ratio),
                ]
            ))
        }

        return results
    }

    // MARK: - App transition patterns

    private func detectAppTransitionPatterns(_ events: [ActivityEvent]) -> [DetectedHabit] {
        let focus = events.filter { $0.eventType == .appFocused }.sorted { $0.timestamp < $1.timestamp }
        guard focus.count >= 5 else { return [] }

        var transitions: [(from: String, to: String)] = []
        for i in 0..<(focus.count - 1) {
            transitions.append((focus[i].applicationName, focus[i + 1].applicationName))
        }

        var transitionCount: [String: Int] = [:]
        for t in transitions {
            let key = "\(t.from) → \(t.to)"
            transitionCount[key, default: 0] += 1
        }

        let total = transitions.count
        var results: [DetectedHabit] = []

        for (key, count) in transitionCount where count >= 2 {
            let ratio = Double(count) / Double(total)
            guard ratio >= 0.05 else { continue }
            let parts = key.components(separatedBy: " → ")
            guard parts.count == 2 else { continue }

            let confidence = min(0.3 + (ratio * 0.3) + min(Double(count) / 10.0, 0.3), 1.0)
            results.append(DetectedHabit(
                name: "Switches from \(parts[0]) to \(parts[1])",
                type: .productivity_pattern,
                confidence: confidence,
                metadata: ["fromApp": parts[0], "toApp": parts[1], "count": "\(count)"]
            ))
        }

        return results
    }

    // MARK: - App launch patterns

    private func detectAppLaunchPatterns(_ events: [ActivityEvent]) -> [DetectedHabit] {
        let launches = events.filter { $0.eventType == .appOpened }.sorted { $0.timestamp < $1.timestamp }
        guard launches.count >= 3 else { return [] }

        var appHourCount: [String: Set<Int>] = [:]
        for event in launches {
            let hour = calendar.component(.hour, from: event.timestamp)
            appHourCount[event.applicationName, default: []].insert(hour)
        }

        var results: [DetectedHabit] = []
        for (app, _) in appHourCount {
            let appLaunches = launches.filter { $0.applicationName == app }
            guard appLaunches.count >= 2 else { continue }

            let mostCommonHour = mostFrequentHour(for: app, in: launches)
            let period = periodName(for: mostCommonHour)
            let uniqueDays = Set(appLaunches.map { calendar.startOfDay(for: $0.timestamp) }).count
            let consistency = uniqueDays > 1 ? min(Double(appLaunches.count) / Double(uniqueDays), 1.0) : 0.3
            let confidence = min(0.2 + (consistency * 0.4) + min(Double(appLaunches.count) / 15.0, 0.3), 1.0)

            results.append(DetectedHabit(
                name: "Opens \(app) in the \(period)",
                type: .application_usage,
                confidence: confidence,
                metadata: [
                    "application": app,
                    "typicalHour": "\(mostCommonHour)",
                    "period": period,
                    "count": "\(appLaunches.count)",
                    "uniqueDays": "\(uniqueDays)",
                ]
            ))
        }

        return results
    }

    // MARK: - Helpers

    private func periodName(for hour: Int) -> String {
        switch hour {
        case 0..<6:  return "early morning"
        case 6..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default:      return "evening"
        }
    }

    private func mostFrequentHour(for app: String, in launches: [ActivityEvent]) -> Int {
        var hourCounts: [Int: Int] = [:]
        for event in launches where event.applicationName == app {
            let hour = calendar.component(.hour, from: event.timestamp)
            hourCounts[hour, default: 0] += 1
        }
        return hourCounts.max(by: { $0.value < $1.value })?.key ?? 0
    }
}

struct DetectedHabit {
    let name: String
    let type: HabitType
    let confidence: Double
    let metadata: [String: String]
}
