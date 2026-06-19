import Foundation

enum FocusSensitivity: String, CaseIterable {
    case low
    case medium
    case high

    var displayName: String {
        rawValue.capitalized
    }
}

@MainActor
final class FocusSessionManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var status = "Focus session is off."
    @Published var sensitivity: FocusSensitivity = .medium

    private let notificationManager: NotificationManager
    private var focusGoal = ""
    private var lastEvaluationAt: Date?
    private var lastNudgeAt: Date?
    private var consecutiveOffTaskSignals = 0
    private var recentObservations: [String] = []

    private let evaluationInterval: TimeInterval = 60
    private let nudgeCooldown: TimeInterval = 10 * 60

    init(notificationManager: NotificationManager = .shared) {
        self.notificationManager = notificationManager
    }

    var currentGoal: String {
        focusGoal
    }

    func start(goal: String) {
        focusGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !focusGoal.isEmpty else { return }

        isActive = true
        isPaused = false
        lastEvaluationAt = nil
        lastNudgeAt = nil
        consecutiveOffTaskSignals = 0
        recentObservations.removeAll()
        status = "Focus session active: \(focusGoal)"
    }

    func end() {
        isActive = false
        isPaused = false
        focusGoal = ""
        lastEvaluationAt = nil
        lastNudgeAt = nil
        consecutiveOffTaskSignals = 0
        recentObservations.removeAll()
        status = "Focus session ended."
    }

    func pause() {
        guard isActive else { return }
        isPaused = true
        status = "Focus session paused."
    }

    func resume() {
        guard isActive else { return }
        isPaused = false
        lastEvaluationAt = nil
        status = "Focus session resumed: \(focusGoal)"
    }

    func observe(context: AppContext?) {
        guard isActive, !isPaused, let context else { return }

        let now = Date()
        if let lastEvaluationAt, now.timeIntervalSince(lastEvaluationAt) < evaluationInterval {
            return
        }
        lastEvaluationAt = now

        let observation = [
            context.appName,
            context.windowTitle ?? "",
            context.browserTitle ?? "",
            context.browserURL ?? "",
        ]
            .joined(separator: " ")
            .lowercased()

        recentObservations.append(observation)
        recentObservations = Array(recentObservations.suffix(5))

        if appearsOffTask(observation) {
            consecutiveOffTaskSignals += 1
        } else {
            consecutiveOffTaskSignals = 0
        }

        guard shouldNudge(now: now) else {
            status = "Focus session active: \(focusGoal)"
            return
        }

        lastNudgeAt = now
        consecutiveOffTaskSignals = 0
        Task {
            _ = try? await notificationManager.send(
                title: "Alfred Focus",
                body: "Might I suggest returning to: \(focusGoal)",
                identifier: "alfred.focus.nudge"
            )
        }
        status = "Focus nudge sent. Still on duty, discreetly."
    }

    private func shouldNudge(now: Date) -> Bool {
        let requiredSignals: Int
        switch sensitivity {
        case .low:
            requiredSignals = 3
        case .medium:
            requiredSignals = 2
        case .high:
            requiredSignals = 1
        }

        guard consecutiveOffTaskSignals >= requiredSignals else { return false }
        if let lastNudgeAt, now.timeIntervalSince(lastNudgeAt) < nudgeCooldown {
            return false
        }
        return true
    }

    private func appearsOffTask(_ observation: String) -> Bool {
        let focusTokens = tokenSet(focusGoal)
        let overlap = focusTokens.contains { observation.contains($0) }
        if overlap { return false }

        let obviousDistractors = [
            "youtube",
            "netflix",
            "hulu",
            "tiktok",
            "instagram",
            "reddit",
            "x.com",
            "twitter",
            "facebook",
            "game",
            "steam",
            "shopping",
            "amazon",
        ]
        let hasDistractor = obviousDistractors.contains { observation.contains($0) }

        switch sensitivity {
        case .low:
            return hasDistractor
        case .medium:
            return hasDistractor || (isBrowserLike(observation) && !overlap)
        case .high:
            return !overlap
        }
    }

    private func isBrowserLike(_ observation: String) -> Bool {
        ["safari", "chrome", "brave", "edge", "firefox", "arc"].contains {
            observation.contains($0)
        }
    }

    private func tokenSet(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "work", "working", "on", "in", "to", "a", "an", "of", "my",
        ]
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }
}
