import Foundation

enum LearningEventType: String, Codable, Equatable {
    case suggestionAccepted
    case suggestionDismissed
    case projectDetected
    case profileUpdated
    case interestLearned
    case projectForgotten
    case interestForgotten
    case profileReset
    case modeChanged

    var label: String {
        switch self {
        case .suggestionAccepted: return "Accepted"
        case .suggestionDismissed: return "Dismissed"
        case .projectDetected: return "Project Detected"
        case .profileUpdated: return "Profile Updated"
        case .interestLearned: return "Interest Learned"
        case .projectForgotten: return "Project Forgotten"
        case .interestForgotten: return "Interest Forgotten"
        case .profileReset: return "Profile Reset"
        case .modeChanged: return "Mode Changed"
        }
    }
}

struct LearningEvent: Identifiable, Equatable {
    let id: UUID
    let type: LearningEventType
    let category: String
    let detail: String
    let timestamp: Date
}

final class LearningEventLog: ObservableObject {
    @Published private(set) var events: [LearningEvent] = []

    private let maxAgeDays: Int = 30
    private let pruneInterval: TimeInterval = 3600
    private var lastPrune: Date = .distantPast

    func record(type: LearningEventType, category: String = "", detail: String = "") {
        let event = LearningEvent(
            id: UUID(),
            type: type,
            category: category,
            detail: detail,
            timestamp: Date()
        )
        events.append(event)
        pruneIfNeeded()
    }

    func recent(days: Int = 7) -> [LearningEvent] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return events.filter { $0.timestamp >= cutoff }
    }

    func all() -> [LearningEvent] {
        events
    }

    func clear() {
        events.removeAll()
        lastPrune = Date()
    }

    private func pruneIfNeeded() {
        guard Date().timeIntervalSince(lastPrune) > pruneInterval else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date()
        events = events.filter { $0.timestamp >= cutoff }
        lastPrune = Date()
    }
}
