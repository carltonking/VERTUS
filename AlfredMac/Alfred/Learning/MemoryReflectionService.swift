import Foundation

final class MemoryReflectionService {
    private let relationshipMemory: RelationshipMemoryService
    private let store: ReflectionStoreProtocol
    private var reflections: [Reflection]
    private var lastRunAt: Date?
    weak var memoryLinkService: MemoryLinkService?

    private let reflectionCooldown: TimeInterval = 6 * 3600
    private let minMemoriesForReflection = 5
    private let maxReflectionsPerMemory = 3
    private var isMinimalMode = false

    init(relationshipMemory: RelationshipMemoryService) {
        self.relationshipMemory = relationshipMemory
        store = ReflectionStore()
        reflections = store.load()
    }

    init(relationshipMemory: RelationshipMemoryService, store: ReflectionStoreProtocol) {
        self.relationshipMemory = relationshipMemory
        self.store = store
        reflections = store.load()
    }

    // MARK: - Privacy

    func setMinimalMode(_ enabled: Bool) {
        isMinimalMode = enabled
        if enabled {
            lastRunAt = nil
        }
    }

    func handleMemoryRemoved(id: UUID) {
        for i in reflections.indices {
            reflections[i].supportingMemoryIds.removeAll { $0 == id }
        }
        reflections.removeAll { $0.supportingMemoryIds.isEmpty }
        try? store.save(reflections)
        postReflectionsUpdated()
    }

    func resetAll() {
        reflections.removeAll()
        lastRunAt = nil
        try? store.save(reflections)
        postReflectionsUpdated()
    }

    // MARK: - Public API

    func getReflections(includeDismissed: Bool = false) -> [Reflection] {
        guard !isMinimalMode else { return [] }
        if includeDismissed {
            return reflections.sorted { $0.createdAt > $1.createdAt }
        }
        return reflections
            .filter { !$0.dismissed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func dismissReflection(id: UUID) {
        guard let idx = reflections.firstIndex(where: { $0.id == id }) else { return }
        reflections[idx].dismissed = true
        try? store.save(reflections)
        postReflectionsUpdated()
    }

    func undismissReflection(id: UUID) {
        guard let idx = reflections.firstIndex(where: { $0.id == id }) else { return }
        reflections[idx].dismissed = false
        try? store.save(reflections)
        postReflectionsUpdated()
    }

    func deleteReflection(id: UUID) {
        reflections.removeAll { $0.id == id }
        try? store.save(reflections)
        postReflectionsUpdated()
    }

    func regenerateReflection(id: UUID) -> Bool {
        guard let idx = reflections.firstIndex(where: { $0.id == id }) else { return false }
        let reflection = reflections[idx]

        let memories = relationshipMemory.allMemoriesForAnalysis()
        let supporting = memories.filter { reflection.supportingMemoryIds.contains($0.id) }

        guard supporting.count >= 2 else { return false }

        let count = supporting.count
        let dates = supporting.map { $0.lastReferenced }
        let span = (dates.max() ?? Date()).timeIntervalSince(dates.min() ?? Date())

        let newConfidence: Double
        switch reflection.type {
        case .pattern:
            newConfidence = min(0.95, Double(count) / 5.0 * 0.8 + 0.1)
        case .contradiction:
            newConfidence = min(0.85, 0.5 + Double(count) * 0.1)
        case .milestone:
            newConfidence = 0.5
        case .timeAssociation:
            newConfidence = min(0.8, 0.4 + Double(count) * 0.15)
        case .toolPreference:
            newConfidence = min(0.9, 0.4 + Double(count) * 0.1)
        }

        reflections[idx].confidence = newConfidence
        try? store.save(reflections)
        postReflectionsUpdated()
        return true
    }

    func getSupportingMemories(for reflectionId: UUID) -> [RelationshipMemory] {
        guard let reflection = reflections.first(where: { $0.id == reflectionId }) else { return [] }
        let allMemories = relationshipMemory.allMemoriesForAnalysis()
        return reflection.supportingMemoryIds.compactMap { mid in
            allMemories.first { $0.id == mid }
        }
    }

    func generateReflectionSummary() -> String {
        guard !isMinimalMode else { return "" }
        let active = reflections.filter { !$0.dismissed }
        guard !active.isEmpty else { return "" }

        var lines: [String] = []
        let high = active.filter { $0.confidence >= 0.7 }
        let medium = active.filter { $0.confidence >= 0.4 && $0.confidence < 0.7 }

        if !high.isEmpty {
            lines.append("High-confidence insights (\(high.count)):")
            for r in high.prefix(5) {
                lines.append("- [\(r.type.label)] \(r.content)")
            }
        }
        if !medium.isEmpty {
            lines.append("Medium-confidence insights (\(medium.count)):")
            for r in medium.prefix(3) {
                lines.append("- [\(r.type.label)] \(r.content)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func runReflectionNow() -> Int {
        guard !isMinimalMode else { return 0 }
        let memories = relationshipMemory.allMemoriesForAnalysis()
        guard memories.count >= minMemoriesForReflection else { return 0 }

        var newReflections: [Reflection] = []

        newReflections += detectPatterns(from: memories)
        newReflections += detectContradictions(from: memories)
        newReflections += detectMilestones(from: memories)
        newReflections += detectTimeAssociations(from: memories)
        newReflections += detectToolPreferences(from: memories)

        // Enforce max supported memories per reflection
        var memoryRefCount = countMemoryRefs()
        var deduped: [Reflection] = []
        for reflection in newReflections {
            let validIds = reflection.supportingMemoryIds.filter { mid in
                (memoryRefCount[mid] ?? 0) < maxReflectionsPerMemory
            }
            guard !validIds.isEmpty else { continue }
            if reflection.type == .pattern { guard validIds.count >= 3 else { continue } }

            let adjusted = Reflection.make(
                type: reflection.type,
                content: reflection.content,
                supportingMemoryIds: validIds,
                confidence: reflection.confidence
            )
            deduped.append(adjusted)
            for mid in validIds {
                memoryRefCount[mid, default: 0] += 1
            }
        }

        // Remove duplicates with existing reflections (same type + similar content)
        let existingSet = Set(reflections.map { "\($0.type.rawValue):\($0.content)" })
        let trulyNew = deduped.filter { !existingSet.contains("\($0.type.rawValue):\($0.content)") }

        guard !trulyNew.isEmpty else { return 0 }

        reflections.append(contentsOf: trulyNew)
        try? store.save(reflections)
        lastRunAt = Date()
        return trulyNew.count
    }

    // MARK: - Prompt Injection

    func promptInjection(activeProject: String? = nil) -> String {
        guard !isMinimalMode else { return "" }
        let undismissed = reflections.filter { !$0.dismissed && $0.confidence > 0.6 }
        guard !undismissed.isEmpty else { return "" }

        let avgTokensPerChar = 0.25
        let maxTokens = 400
        var tokenCount = 0
        var lines: [String] = []

        // Prioritize high-confidence, then relevant to project
        let sorted = undismissed.sorted { $0.confidence > $1.confidence }
        var projectMatch: [Reflection] = []
        var other: [Reflection] = []

        if let project = activeProject?.lowercased() {
            for r in sorted {
                if r.content.lowercased().contains(project) {
                    projectMatch.append(r)
                } else {
                    other.append(r)
                }
            }
        } else {
            other = Array(sorted)
        }

        let ordered = projectMatch + other

        for r in ordered.prefix(2) {
            let line = "[\(r.type.label)] \(r.content)"
            let estimatedTokens = Int(Double(line.count) * avgTokensPerChar)
            guard tokenCount + estimatedTokens <= maxTokens else { break }
            lines.append(line)
            tokenCount += estimatedTokens
            if let idx = reflections.firstIndex(where: { $0.id == r.id }) {
                reflections[idx].lastPresented = Date()
            }
        }

        guard !lines.isEmpty else { return "" }
        try? store.save(reflections)
        return "INSIGHTS:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Reflection Algorithm

    private let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with",
        "by", "from", "up", "about", "into", "over", "after", "before", "between", "under",
        "above", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "will", "would", "can", "could", "should", "may", "might",
        "shall", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us",
        "them", "my", "your", "his", "its", "our", "their", "mine", "yours", "its", "ours",
        "theirs", "this", "that", "these", "those", "some", "any", "each", "every", "all",
        "both", "few", "more", "most", "other", "no", "nor", "not", "only", "own", "same",
        "so", "than", "too", "very", "just", "because", "as", "until", "while", "if", "when",
        "where", "how", "what", "which", "who", "whom", "why", "here", "there", "then",
        "also", "now", "get", "got", "use", "using", "used", "make", "made", "go", "going",
        "went", "take", "took", "see", "know", "think", "come", "came", "want", "need",
        "like", "work", "working", "try", "trying"
    ]

    private let positiveWords: Set<String> = [
        "love", "prefer", "great", "good", "amazing", "enjoy", "fantastic", "helpful",
        "useful", "important", "wonderful", "excellent", "awesome", "productive",
        "efficient", "reliable", "fast", "easy", "intuitive", "beautiful", "clean",
        "powerful", "flexible", "simple", "best"
    ]

    private let negativeWords: Set<String> = [
        "hate", "dislike", "terrible", "bad", "awful", "horrible", "annoying", "frustrating",
        "slow", "difficult", "complicated", "ugly", "messy", "unreliable", "broken",
        "confusing", "painful", "useless", "waste", "hated", "worst"
    ]

    private let milestoneWords: Set<String> = [
        "started", "finished", "completed", "launched", "released", "began", "begun",
        "shipped", "deployed", "achieved", "accomplished", "milestone", "version",
        "submitted", "published", "announced", "delivered", "finalized"
    ]

    private let timePatterns: [(pattern: String, label: String)] = [
        ("every morning", "mornings"),
        ("every day", "daily"),
        ("every week", "weekly"),
        ("every month", "monthly"),
        ("every friday", "Fridays"),
        ("every monday", "Mondays"),
        ("every tuesday", "Tuesdays"),
        ("every wednesday", "Wednesdays"),
        ("every thursday", "Thursdays"),
        ("every saturday", "Saturdays"),
        ("every sunday", "Sundays"),
        ("in the morning", "mornings"),
        ("in the afternoon", "afternoons"),
        ("in the evening", "evenings"),
        ("at night", "nights"),
        ("on friday", "Fridays"),
        ("on monday", "Mondays"),
        ("on tuesday", "Tuesdays"),
        ("on wednesday", "Wednesdays"),
        ("on thursday", "Thursdays"),
        ("on saturday", "Saturdays"),
        ("on sunday", "Sundays"),
        ("daily", "daily"),
        ("weekly", "weekly"),
        ("monthly", "monthly"),
        ("nightly", "nightly"),
        ("each week", "weekly"),
        ("each day", "daily"),
    ]

    private let toolNames: Set<String> = [
        "xcode", "terminal", "safari", "chrome", "firefox", "vscode", "vs code",
        "cursor", "windsurf", "python", "swift", "javascript", "typescript", "go",
        "rust", "ruby", "docker", "git", "github", "figma", "sketch", "notion",
        "obsidian", "slack", "teams", "discord", "spotify", "iterm", "iterm2",
        "alfred", "raycast", "1password", "postman", "tableplus", "sequelpro",
        "transmit", "cyberduck", "tower", "sourcetree", "kaleidoscope",
        "things", "todoist", "omnifocus", "bear", "ulysses", "ia writer",
        "terminal", "neovim", "vim", "emacs", "sublime", "android studio",
        "unity", "unreal", "blender", "photoshop", "illustrator", "indesign",
        "final cut", "logic pro", "ableton", "procreate", "affinity",
        "excel", "numbers", "pages", "word", "powerpoint", "keynote",
        "outlook", "mail", "calendar", "reminders", "notes",
        "zettlr", "logseq", "roam", "capacities", "anytype",
        "linear", "jira", "asana", "trello", "notion", "clickup",
        "zed", "helix", "kakoune"
    ]

    private func detectPatterns(from memories: [RelationshipMemory]) -> [Reflection] {
        var keywordMap: [String: [RelationshipMemory]] = [:]

        for memory in memories {
            let keywords = extractKeywords(from: memory.content)
            for kw in keywords {
                keywordMap[kw, default: []].append(memory)
            }
        }

        var result: [Reflection] = []
        for (keyword, group) in keywordMap {
            let unique = uniqMemories(group)
            guard unique.count >= 3 else { continue }

            let dates = unique.map { $0.lastReferenced }
            guard let first = dates.min(), let last = dates.max() else { continue }
            let span = last.timeIntervalSince(first)
            guard span > 7 * 86400 else { continue }

            let count = unique.count
            var confidence = min(0.95, Double(count) / 5.0 * 0.8 + 0.1)
            guard confidence >= 0.4 else { continue }

            if let linkService = memoryLinkService {
                let ids = unique.map { $0.id }
                var linkCount = 0
                for i in 0..<ids.count {
                    for j in (i + 1)..<ids.count {
                        let linked = linkService.linkedMemoryIds(for: ids[i], minStrength: 0.2)
                        if linked.contains(ids[j]) {
                            linkCount += 1
                        }
                    }
                }
                if linkCount > 0 {
                    let boost = min(0.15, Double(linkCount) * 0.05)
                    confidence = min(0.95, confidence + boost)
                }
            }

            let content = "You've mentioned \"\(keyword)\" \(count) times over the past \(Int(span / 86400)) days"
            result.append(Reflection.make(
                type: .pattern,
                content: content,
                supportingMemoryIds: unique.map { $0.id },
                confidence: confidence
            ))
        }

        return result
    }

    private func detectContradictions(from memories: [RelationshipMemory]) -> [Reflection] {
        let grouped = Dictionary(grouping: memories) { $0.category }

        var result: [Reflection] = []
        for (_, group) in grouped {
            guard group.count >= 2 else { continue }

            let positive: [RelationshipMemory] = group.filter {
                positiveWords.contains(where: $0.content.lowercased().contains)
            }
            let negative: [RelationshipMemory] = group.filter {
                negativeWords.contains(where: $0.content.lowercased().contains)
            }

            guard !positive.isEmpty && !negative.isEmpty else { continue }

            for pos in positive {
                let posKeywords = extractKeywords(from: pos.content)
                for neg in negative {
                    let negKeywords = extractKeywords(from: neg.content)
                    let shared = posKeywords.intersection(negKeywords)
                    guard !shared.isEmpty else { continue }

                    var confidence = min(0.85, 0.5 + Double(shared.count) * 0.1)

                    if let linkService = memoryLinkService {
                        let linked = linkService.links(for: pos.id)
                        if linked.contains(where: { $0.type == .contradictory && ($0.fromId == neg.id || $0.toId == neg.id) }) {
                            confidence = min(0.95, confidence + 0.1)
                        }
                    }

                    let topic = shared.first!
                    let p = pos.content.prefix(60)
                    let n = neg.content.prefix(60)
                    let content = "Mixed feelings about \"\(topic)\": positive (\"\(p)\") but also negative (\"\(n)\")"
                    result.append(Reflection.make(
                        type: .contradiction,
                        content: content,
                        supportingMemoryIds: [pos.id, neg.id],
                        confidence: confidence
                    ))
                }
            }
        }

        return result
    }

    private func detectMilestones(from memories: [RelationshipMemory]) -> [Reflection] {
        let relevant = memories.filter {
            milestoneWords.contains(where: $0.content.lowercased().contains)
        }

        // Group by project category
        let projectMemories = relevant.filter { $0.category == .projects }
        let otherRelevant = relevant.filter { $0.category != .projects }

        var result: [Reflection] = []
        var seenProjects = Set<String>()

        for memory in projectMemories {
            let lowered = memory.content.lowercased()
            for mw in milestoneWords where lowered.contains(mw) {
                let project = memory.content
                guard !seenProjects.contains(project) else { continue }
                seenProjects.insert(project)

                let confidence = 0.5
                let content = "Milestone noted: \"\(project)\""
                result.append(Reflection.make(
                    type: .milestone,
                    content: content,
                    supportingMemoryIds: [memory.id],
                    confidence: confidence
                ))
            }
        }

        // Also check non-project memories that mention milestones
        for memory in otherRelevant {
            let lowered = memory.content.lowercased()
            for mw in milestoneWords where lowered.contains(mw) {
                let context = String(memory.content.prefix(80))
                let content = "Notable progress: \"\(context)\""
                result.append(Reflection.make(
                    type: .milestone,
                    content: content,
                    supportingMemoryIds: [memory.id],
                    confidence: 0.4
                ))
                break
            }
        }

        return result
    }

    private func detectTimeAssociations(from memories: [RelationshipMemory]) -> [Reflection] {
        var timeLabels: [String: [RelationshipMemory]] = [:]

        for memory in memories {
            let lowered = memory.content.lowercased()
            for (pattern, label) in timePatterns where lowered.contains(pattern) {
                timeLabels[label, default: []].append(memory)
            }
        }

        var result: [Reflection] = []
        for (label, group) in timeLabels {
            let unique = uniqMemories(group)
            guard unique.count >= 2 else { continue }

            let confidence = min(0.8, 0.4 + Double(unique.count) * 0.15)
            let topics = extractKeywords(from: unique.map { $0.content }.joined(separator: " "))
                .prefix(2).joined(separator: ", ")
            let content = "You tend to work on \(topics) during \(label)"
            result.append(Reflection.make(
                type: .timeAssociation,
                content: content,
                supportingMemoryIds: unique.map { $0.id },
                confidence: confidence
            ))
        }

        return result
    }

    private func detectToolPreferences(from memories: [RelationshipMemory]) -> [Reflection] {
        var toolMap: [String: [RelationshipMemory]] = [:]

        for memory in memories {
            let lowered = memory.content.lowercased()
            for tool in toolNames where lowered.contains(tool) {
                toolMap[tool, default: []].append(memory)
            }
        }

        var result: [Reflection] = []
        for (tool, group) in toolMap {
            let unique = uniqMemories(group)
            guard unique.count >= 2 else { continue }

            let confidence = min(0.9, 0.4 + Double(unique.count) * 0.1)
            let categories = Set(unique.map { $0.category.label.lowercased() }).sorted()
            let contexts = categories.joined(separator: ", ")
            let content = "You regularly use \(tool) for \(contexts) (mentioned \(unique.count) times)"
            result.append(Reflection.make(
                type: .toolPreference,
                content: content,
                supportingMemoryIds: unique.map { $0.id },
                confidence: confidence
            ))
        }

        return result
    }

    // MARK: - Helpers

    private func extractKeywords(from text: String) -> Set<String> {
        let lowered = text.lowercased()
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let cleaned = lowered.components(separatedBy: punctuation).joined()
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines)
        return Set(words.filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    private func uniqMemories(_ memories: [RelationshipMemory]) -> [RelationshipMemory] {
        var seen = Set<UUID>()
        return memories.filter { seen.insert($0.id).inserted }
    }

    private func countMemoryRefs() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for r in reflections {
            for mid in r.supportingMemoryIds {
                counts[mid, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Cooldown

    func shouldRunReflection() -> Bool {
        guard !isMinimalMode else { return false }
        let memories = relationshipMemory.allMemoriesForAnalysis()
        guard memories.count >= minMemoriesForReflection else { return false }
        guard let last = lastRunAt else { return true }
        return Date().timeIntervalSince(last) >= reflectionCooldown
    }

    // MARK: - Notifications

    private func postReflectionsUpdated() {
        NotificationCenter.default.post(name: .reflectionsUpdated, object: nil)
    }
}
