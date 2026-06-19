import AppKit
import Foundation

@MainActor
final class ProactiveMemorySurfacingService {
    let contextCollector: ContextCollectorProtocol
    private let relationshipMemory: RelationshipMemoryService
    private let memoryReflections: MemoryReflectionService?
    private let workflowSuggestions: WorkflowSuggestionService?
    weak var memoryLinkService: MemoryLinkService?
    private let store: MemorySuggestionStoreProtocol
    private let blocklistStore: SuggestionBlocklistStoreProtocol
    private var suggestions: [MemorySuggestion]
    private var blocklist: Set<String>
    private var lastSuggestionTime: Date?
    private var monitoringTimer: Timer?
    private var hasActiveSuggestion = false

    let suggestionCooldown: TimeInterval = 300
    var proactiveEnabled = false {
        didSet {
            if proactiveEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
                hasActiveSuggestion = false
            }
        }
    }
    private var isMinimalMode = false

    var onSuggestionUpdate: (([MemorySuggestion]) -> Void)?
    var onBadgeUpdate: ((Bool) -> Void)?

    init(
        relationshipMemory: RelationshipMemoryService,
        memoryReflections: MemoryReflectionService? = nil,
        contextCollector: ContextCollectorProtocol,
        workflowSuggestions: WorkflowSuggestionService? = nil,
        store: MemorySuggestionStoreProtocol? = nil,
        blocklistStore: SuggestionBlocklistStoreProtocol? = nil
    ) {
        self.relationshipMemory = relationshipMemory
        self.memoryReflections = memoryReflections
        self.contextCollector = contextCollector
        self.workflowSuggestions = workflowSuggestions
        self.store = store ?? MemorySuggestionStore()
        self.blocklistStore = blocklistStore ?? SuggestionBlocklistStore()
        suggestions = self.store.load()
        blocklist = self.blocklistStore.load()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard proactiveEnabled, !isMinimalMode, monitoringTimer == nil else { return }
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = self?.checkContext()
            }
        }
        _ = checkContext()
    }

    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    func setMinimalMode(_ enabled: Bool) {
        isMinimalMode = enabled
        if enabled {
            stopMonitoring()
            hasActiveSuggestion = false
            onBadgeUpdate?(false)
        } else if proactiveEnabled {
            startMonitoring()
        }
    }

    // MARK: - Public API

    func getAvailableSuggestions() -> [MemorySuggestion] {
        cleanupExpired()
        return suggestions
            .filter { !$0.dismissed && $0.expiresAt > Date() }
            .sorted { $0.confidence > $1.confidence }
    }

    func dismissSuggestion(id: String, block: Bool = false) {
        guard let idx = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[idx].dismissed = true
        suggestions[idx].expiresAt = Date().addingTimeInterval(30 * 86400)
        try? store.save(suggestions)

        if block, let memoryId = suggestions[idx].memoryId {
            blocklist.insert(memoryId)
            try? blocklistStore.save(blocklist)
        }

        updateBadge()
    }

    func clearAll() {
        suggestions.removeAll()
        blocklist.removeAll()
        lastSuggestionTime = nil
        hasActiveSuggestion = false
        try? store.save(suggestions)
        try? blocklistStore.save(blocklist)
        onBadgeUpdate?(false)
    }

    func forceCheck() -> [MemorySuggestion] {
        lastSuggestionTime = nil
        return checkContext()
    }

    // MARK: - Context Check

    private func checkContext() -> [MemorySuggestion] {
        guard proactiveEnabled, !isMinimalMode else { return [] }
        cleanupExpired()

        if let last = lastSuggestionTime, Date().timeIntervalSince(last) < suggestionCooldown {
            return getAvailableSuggestions()
        }

        let newSuggestions = generateSuggestions()
        guard !newSuggestions.isEmpty else {
            updateBadge()
            return getAvailableSuggestions()
        }

        let ranked = rankSuggestions(newSuggestions)
        let top = Array(ranked.prefix(3))

        for s in top {
            if let existing = suggestions.firstIndex(where: { $0.id == s.id }) {
                suggestions[existing] = s
            } else {
                suggestions.append(s)
            }
        }

        try? store.save(suggestions)
        lastSuggestionTime = Date()
        updateBadge()
        onSuggestionUpdate?(top)
        return top
    }

    // MARK: - Matching Rules

    private func generateSuggestions() -> [MemorySuggestion] {
        let appName = contextCollector.getActiveAppName()
        let hour = contextCollector.getCurrentHour()
        let queries = contextCollector.getRecentQueryHistory(limit: 5)
        let activeProject = contextCollector.getActiveProjectFromMemory()
        let recentIds = Set(suggestions.filter { !$0.dismissed }.map { "\($0.type.rawValue):\($0.title)" })

        var results: [MemorySuggestion] = []

        // Rule 1 - Project Continuation
        if let project = activeProject {
            let projectMemories = relationshipMemory.topProjects(limit: 3)
            if let match = projectMemories.first(where: { $0.content.lowercased().contains(project.lowercased()) }) {
                let hoursAgo = Int(match.daysSinceLastReferenced * 24)
                if hoursAgo < 24 {
                    let key = "continuation:Continue working on \(project)?"
                    guard !recentIds.contains(key) && !blocklist.contains(match.id.uuidString) else { return results }
                    results.append(MemorySuggestion.make(
                        type: .continuation,
                        title: "Continue working on \(project)?",
                        subtitle: "You mentioned this \(max(1, hoursAgo)) hour(s) ago",
                        action: .openQuery("Tell me about \(project)"),
                        memoryId: match.id.uuidString,
                        confidence: 0.8
                    ))
                }
            }
        }

        // Rule 2 - Time-Based Pattern (from reflections)
        if let reflections = memoryReflections {
            let timeReflections = reflections.getReflections().filter { $0.type == .timeAssociation && $0.confidence > 0.6 }
            for reflection in timeReflections {
                let key = "insight:\(String(reflection.content.prefix(40)))"
                guard !recentIds.contains(key) && !blocklist.contains(reflection.id.uuidString) else { continue }
                results.append(MemorySuggestion.make(
                    type: .insight,
                    title: String(reflection.content.prefix(60)),
                    subtitle: "You often discuss this at this time",
                    action: .showMemory(reflection.id.uuidString),
                    memoryId: reflection.id.uuidString,
                    confidence: reflection.confidence * 0.9
                ))
            }
        }

        // Rule 3 - Tool Preference
        if let app = appName?.lowercased() {
            let toolMemories = relationshipMemory.memoriesMentioningTool(app)
            let toolReflections = memoryReflections?.getReflections().filter { $0.type == .toolPreference && $0.confidence > 0.5 } ?? []

            let fromMemories = toolMemories.first.map { m -> MemorySuggestion? in
                let key = "tip:Working in \(app)"
                guard !recentIds.contains(key) && !blocklist.contains(m.id.uuidString) else { return nil }
                return MemorySuggestion.make(
                    type: .tip,
                    title: "Working in \(app)",
                    subtitle: "You previously mentioned using this for \(m.content.prefix(40))",
                    action: .openQuery("Help with \(app)"),
                    memoryId: m.id.uuidString,
                    confidence: min(0.85, m.importance + 0.1)
                )
            }.flatMap { $0 }

            let fromReflections = toolReflections.first.map { r -> MemorySuggestion? in
                let key = "tip:Working in \(app)"
                guard !recentIds.contains(key) && !blocklist.contains(r.id.uuidString) else { return nil }
                return MemorySuggestion.make(
                    type: .tip,
                    title: "Working in \(app)",
                    subtitle: String(r.content.prefix(60)),
                    action: .openQuery("Help with \(app)"),
                    memoryId: r.id.uuidString,
                    confidence: min(0.85, r.confidence + 0.1)
                )
            }.flatMap { $0 }

            if let sug = fromMemories ?? fromReflections {
                results.append(sug)
            }
        }

        // Rule 4 - Recent Query Continuation
        if let lastQuery = queries.last, Date().timeIntervalSince(lastSuggestionTime ?? .distantPast) > 120 {
            let key = "continuation:Follow up on your last question?"
            guard !recentIds.contains(key) else { return results }
            results.append(MemorySuggestion.make(
                type: .continuation,
                title: "Follow up on your last question?",
                subtitle: "You asked: \(String(lastQuery.prefix(60)))",
                action: .openQuery("\(lastQuery) (follow up)"),
                confidence: 0.65
            ))
        }

        // Rule 5 - Recurring Problem
        if hour >= 9 && hour <= 17 {
            let problems = relationshipMemory.topRecurringProblems(limit: 2)
            for problem in problems {
                let key = "reminder:Common issue: \(problem.content.prefix(40))"
                guard !recentIds.contains(key) && !blocklist.contains(problem.id.uuidString) else { continue }
                let confidence = min(0.9, 0.3 + Double(problem.mentionCount) * 0.1)
                results.append(MemorySuggestion.make(
                    type: .reminder,
                    title: "Common issue: \(String(problem.content.prefix(50)))",
                    subtitle: "You've encountered this \(problem.mentionCount) times",
                    action: .openQuery("How to fix \(problem.content.prefix(30))"),
                    memoryId: problem.id.uuidString,
                    confidence: confidence
                ))
            }
        }

        // Rule 6 - Workflow Suggestion
        if let reflections = memoryReflections {
            let workflowReflections = reflections.getReflections().filter { $0.type == .toolPreference && $0.confidence > 0.6 }
            if let app = appName?.lowercased(), let match = workflowReflections.first(where: { $0.content.lowercased().contains(app) }) {
                let key = "action:Run your workflow?"
                guard !recentIds.contains(key) && !blocklist.contains(match.id.uuidString) else { return results }
                results.append(MemorySuggestion.make(
                    type: .action,
                    title: "Run your workflow?",
                    subtitle: String(match.content.prefix(60)),
                    action: .runWorkflow(match.id.uuidString),
                    memoryId: match.id.uuidString,
                    confidence: 0.7
                ))
            }
        }

        // Rule 7 - Goal Reminder
        if let goal = relationshipMemory.topGoals(limit: 1).first, goal.importance > 0.5 {
            let daysSinceRef = goal.daysSinceLastReferenced
            if daysSinceRef > 2 && daysSinceRef < 14 {
                let key = "reminder:Goal check-in"
                guard !recentIds.contains(key) && !blocklist.contains(goal.id.uuidString) else { return results }
                results.append(MemorySuggestion.make(
                    type: .reminder,
                    title: "Goal check-in",
                    subtitle: "You wanted to \(String(goal.content.prefix(50)))",
                    action: .openQuery("Update on my goal: \(goal.content.prefix(30))"),
                    memoryId: goal.id.uuidString,
                    confidence: 0.6
                ))
            }
        }

        // Rule 8 - Preference Confirmation
        let preferences = relationshipMemory.topPreferences(limit: 3).filter { $0.importance > 0.6 }
        for pref in preferences where pref.daysSinceLastReferenced > 7 {
            let key = "insight:Remember your preference"
            guard !recentIds.contains(key) && !blocklist.contains(pref.id.uuidString) else { continue }
            results.append(MemorySuggestion.make(
                type: .insight,
                title: "Remember your preference",
                subtitle: "You prefer \(String(pref.content.prefix(50)))",
                action: .insertText(pref.content),
                memoryId: pref.id.uuidString,
                confidence: 0.55
            ))
        }

        // Rule 9 - Workflow Pattern Suggestion
        if let wss = workflowSuggestions {
            let workflowSuggestions = wss.generateWorkflowSuggestions()
            for ws in workflowSuggestions {
                let key = "action:\(ws.title)"
                guard !recentIds.contains(key) else { continue }
                results.append(ws)
            }
        }

        // Rule 10 - Linked Context
        if let linkService = memoryLinkService, let appName = appName?.lowercased() {
            let recentMemories = relationshipMemory.memoriesMentioningTool(appName)
            for mem in recentMemories.prefix(2) {
                let linkedIds = linkService.linkedMemoryIds(for: mem.id, minStrength: 0.3)
                for lid in linkedIds {
                    guard let linked = relationshipMemory.memory(by: lid), !linked.isArchived else { continue }
                    let key = "insight:linked:\(linked.id.uuidString)"
                    guard !recentIds.contains(key) && !blocklist.contains(linked.id.uuidString) else { continue }
                    results.append(MemorySuggestion.make(
                        type: .insight,
                        title: "Related: \(String(linked.content.prefix(50)))",
                        subtitle: "Connected to what you're working on in \(appName)",
                        action: .showMemory(linked.id.uuidString),
                        memoryId: linked.id.uuidString,
                        confidence: 0.5
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Ranking

    private func rankSuggestions(_ suggestions: [MemorySuggestion]) -> [MemorySuggestion] {
        let now = Date()
        return suggestions.sorted { a, b in
            let recencyA: Double = {
                if let idx = self.suggestions.firstIndex(where: { $0.id == a.id }) {
                    let elapsed = now.timeIntervalSince(self.suggestions[idx].createdAt)
                    return 1.0 - min(0.5, elapsed / 86400)
                }
                return 1.0
            }()
            let recencyB: Double = {
                if let idx = self.suggestions.firstIndex(where: { $0.id == b.id }) {
                    let elapsed = now.timeIntervalSince(self.suggestions[idx].createdAt)
                    return 1.0 - min(0.5, elapsed / 86400)
                }
                return 1.0
            }()
            return (a.confidence * recencyA) > (b.confidence * recencyB)
        }
    }

    // MARK: - Badge

    private func updateBadge() {
        let available = getAvailableSuggestions()
        let hasNew = !available.isEmpty
        if hasNew != hasActiveSuggestion {
            hasActiveSuggestion = hasNew
            onBadgeUpdate?(hasNew)
        }
    }

    // MARK: - Cleanup

    private func cleanupExpired() {
        let before = suggestions.count
        suggestions.removeAll { $0.expiresAt < Date() && $0.dismissed }
        if suggestions.count != before {
            try? store.save(suggestions)
        }
    }
}
