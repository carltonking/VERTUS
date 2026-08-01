import Foundation
import AppKit

final class RelationshipMemoryService {
    private let store: RelationshipMemoryStoreProtocol
    private var memories: [RelationshipMemory]
    weak var memoryLinkService: MemoryLinkService?

    init() {
        store = RelationshipMemoryStore()
        memories = store.load()
    }

    init(store: RelationshipMemoryStoreProtocol) {
        self.store = store
        memories = store.load()
    }

    // MARK: - Public API

    func relationshipMemories() -> [RelationshipMemory] {
        decayIfNeeded()
        return memories
            .filter { !$0.isArchived }
            .sorted { $0.effectiveImportance > $1.effectiveImportance }
    }

    func allMemoriesForAnalysis() -> [RelationshipMemory] {
        memories
    }

    func allMemoriesIncludingArchived() -> [RelationshipMemory] {
        decayIfNeeded()
        return memories.sorted { $0.effectiveImportance > $1.effectiveImportance }
    }

    func memory(by id: UUID) -> RelationshipMemory? {
        memories.first { $0.id == id }
    }

    func topGoals(limit: Int = 3) -> [RelationshipMemory] {
        top(category: .goals, limit: limit)
    }

    func topProjects(limit: Int = 3) -> [RelationshipMemory] {
        top(category: .projects, limit: limit)
    }

    func topPreferences(limit: Int = 3) -> [RelationshipMemory] {
        top(category: .preferences, limit: limit)
    }

    func topRecurringProblems(limit: Int = 2) -> [RelationshipMemory] {
        top(category: .recurringProblems, limit: limit)
    }

    func memoriesMentioningTool(_ tool: String) -> [RelationshipMemory] {
        decayIfNeeded()
        let lowered = tool.lowercased()
        return memories
            .filter { !$0.isArchived && $0.content.lowercased().contains(lowered) }
            .sorted { $0.importance > $1.importance }
    }

    func memoriesReferencedBetween(since: Date, until: Date = .distantFuture) -> [RelationshipMemory] {
        decayIfNeeded()
        return memories
            .filter { !$0.isArchived && $0.lastReferenced >= since && $0.lastReferenced <= until }
            .sorted { $0.importance > $1.importance }
    }

    func relevantMemories(for keyword: String, limit: Int = 3) -> [RelationshipMemory] {
        decayIfNeeded()
        let lowered = keyword.lowercased()
        var matches = memories
            .filter { !$0.isArchived && $0.content.lowercased().contains(lowered) }
            .sorted { $0.importance > $1.importance }

        if let linkService = memoryLinkService {
            let directMatches = matches
            var linkedIds = Set<UUID>()
            for match in directMatches {
                let linked = linkService.linkedMemoryIds(for: match.id, minStrength: 0.2)
                for lid in linked {
                    guard !linkedIds.contains(lid) else { continue }
                    linkedIds.insert(lid)
                    if let link = linkService.links(for: match.id).first(where: { $0.fromId == lid || $0.toId == lid }) {
                        let linkedMem = memory(by: lid)
                        if let mem = linkedMem, !mem.isArchived, !matches.contains(where: { $0.id == lid }) {
                            var weighted = mem
                            weighted.importance = mem.importance * link.strength
                            matches.append(weighted)
                        }
                    }
                }
            }
            matches.sort { $0.importance > $1.importance }
        }

        return Array(matches.prefix(limit))
    }

    func getLinkedMemories(to id: UUID, maxDepth: Int = 1, minStrength: Double = 0.2) -> [RelationshipMemory] {
        guard maxDepth >= 1, let linkService = memoryLinkService else { return [] }
        var visited = Set<UUID>([id])
        var result: [RelationshipMemory] = []

        var currentLevel = [id]
        for _ in 0..<maxDepth {
            var nextLevel = [UUID]()
            for mid in currentLevel {
                let linked = linkService.linkedMemoryIds(for: mid, minStrength: minStrength)
                for lid in linked {
                    guard !visited.contains(lid), let mem = memory(by: lid), !mem.isArchived else { continue }
                    visited.insert(lid)
                    result.append(mem)
                    nextLevel.append(lid)
                }
            }
            currentLevel = nextLevel
        }

        return result.sorted { $0.importance > $1.importance }
    }

    // MARK: - Ingestion

    func considerMention(_ content: String, category: MemoryCategory, source: String) {
        let normalized = normalizeContent(content)

        // 1. Check if an existing unarchived memory already covers this
        if let idx = findExistingIndex(for: normalized, category: category) {
            updateExisting(at: idx)
            return
        }

        // 2. Check for near-duplicate within last 7 days (promotion candidate)
        if canPromote(normalized, category: category) {
            promote(normalized, category: category, source: source)
        }
        // else: single mention, don't save
    }

    func forceSave(_ content: String, category: MemoryCategory, source: String,
                   importance: Double = 0.5, reasonSaved: String = "User explicitly stated")
    {
        let normalized = normalizeContent(content)
        if let idx = findExistingIndex(for: normalized, category: category) {
            updateExisting(at: idx)
            return
        }
        let memory = RelationshipMemory.make(
            category: category,
            content: normalized,
            source: source,
            importance: importance,
            reasonSaved: reasonSaved
        )
        memories.append(memory)
        save()
    }

    func recordCorrection(for id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].correctedAt = Date()
        memories[idx].importance = min(1.0, memories[idx].importance + 0.15)
        memories[idx].reasonSaved = "User corrected this"
        save()
    }

    func recordReference(to id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].lastReferenced = Date()
        memories[idx].mentionCount += 1
        save()
    }

    // MARK: - Injection for prompts

    func promptInjection(activeProject: String? = nil, suggestionCategory: String? = nil) -> String {
        decayIfNeeded()
        var result: [String] = []
        var tokenCount = 0
        let maxTokens = 300
        let avgTokensPerChar = 0.25

        // Top 3 most important memories
        let top = relationshipMemories().prefix(3)
        for memory in top {
            let line = "- \(memory.category.label): \(memory.content)"
            let estimatedTokens = Int(Double(line.count) * avgTokensPerChar)
            guard tokenCount + estimatedTokens <= maxTokens else { break }
            result.append(line)
            tokenCount += estimatedTokens
        }

        // Up to 3 relevant to active project
        if let project = activeProject, !project.isEmpty {
            let relevant = relevantMemories(for: project, limit: 3)
            for memory in relevant where !result.contains(where: { $0.contains(memory.content) }) {
                let line = "- \(memory.category.label): \(memory.content)"
                let estimatedTokens = Int(Double(line.count) * avgTokensPerChar)
                guard tokenCount + estimatedTokens <= maxTokens else { break }
                result.append(line)
                tokenCount += estimatedTokens
            }
        }

        // Up to 2 relevant to suggestion category
        if let category = suggestionCategory, !category.isEmpty {
            let relevant = relevantMemories(for: category, limit: 2)
            for memory in relevant where !result.contains(where: { $0.contains(memory.content) }) {
                let line = "- \(memory.category.label): \(memory.content)"
                let estimatedTokens = Int(Double(line.count) * avgTokensPerChar)
                guard tokenCount + estimatedTokens <= maxTokens else { break }
                result.append(line)
                tokenCount += estimatedTokens
            }
        }

        guard !result.isEmpty else { return "" }
        return "WHAT I KNOW ABOUT YOU:\n" + result.joined(separator: "\n")
    }

    // MARK: - Manual Importance

    func setManualImportance(id: UUID, value: Double) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].manualOverride = true
        memories[idx].manualImportance = min(1.0, max(0.0, value))
        save()
        postUpdated()
    }

    func adjustManualImportance(id: UUID, delta: Double) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        let current = memories[idx].manualImportance ?? memories[idx].importance
        memories[idx].manualOverride = true
        memories[idx].manualImportance = min(1.0, max(0.0, current + delta))
        save()
        postUpdated()
    }

    func resetManualOverride(id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].manualOverride = false
        memories[idx].manualImportance = nil
        memories[idx].importance = recalculateImportance(for: memories[idx])
        save()
        postUpdated()
    }

    // MARK: - Edit & Archive

    func updateMemoryContent(id: UUID, content: String) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].content = content
        save()
        postUpdated()
    }

    func updateMemoryCategory(id: UUID, category: MemoryCategory) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].category = category
        save()
        postUpdated()
    }

    func archiveMemory(id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].archivedAt = Date()
        save()
        memoryLinkService?.handleMemoryArchived(id: id)
        postUpdated()
    }

    func restoreMemory(id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].archivedAt = nil
        memories[idx].lastReferenced = Date()
        save()
        postUpdated()
    }

    func bulkArchive(ids: [UUID]) {
        let now = Date()
        var changed = false
        for id in ids {
            if let idx = memories.firstIndex(where: { $0.id == id }) {
                memories[idx].archivedAt = now
                memoryLinkService?.handleMemoryArchived(id: id)
                changed = true
            }
        }
        if changed { save(); postUpdated() }
    }

    func bulkDelete(ids: [UUID]) {
        let set = Set(ids)
        for id in ids {
            memoryLinkService?.handleMemoryDeleted(id: id)
        }
        memories.removeAll { set.contains($0.id) }
        save()
        postUpdated()
    }

    // MARK: - Privacy

    func forgetMemory(id: UUID) {
        memoryLinkService?.handleMemoryDeleted(id: id)
        memories.removeAll { $0.id == id }
        save()
    }

    func forgetCategory(_ category: MemoryCategory) {
        let ids = memories.filter { $0.category == category }.map { $0.id }
        for id in ids { memoryLinkService?.handleMemoryDeleted(id: id) }
        memories.removeAll { $0.category == category }
        save()
    }

    func forgetCategories(_ categories: [MemoryCategory]) {
        let set = Set(categories)
        let ids = memories.filter { set.contains($0.category) }.map { $0.id }
        for id in ids { memoryLinkService?.handleMemoryDeleted(id: id) }
        memories.removeAll { set.contains($0.category) }
        save()
    }

    func resetRelationshipMemory(deleteBackups: Bool = false) {
        let ids = memories.map { $0.id }
        for id in ids { memoryLinkService?.handleMemoryDeleted(id: id) }
        memories.removeAll()
        save()
        if deleteBackups {
            DispatchQueue.main.async {
                let delegate = NSApp.delegate as? AppDelegate
                delegate?.backupService?.deleteAllBackups()
            }
        }
    }

    // MARK: - Export / Import

    func exportToJSON(includeArchived: Bool = false) -> String? {
        let target = includeArchived ? memories : memories.filter { !$0.isArchived }
        guard let data = try? JSONEncoder().encode(target) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportArchivedToJSON() -> String? {
        let archived = memories.filter { $0.isArchived }
        guard let data = try? JSONEncoder().encode(archived) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func importFromJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let imported = try? JSONDecoder().decode([RelationshipMemory].self, from: data)
        else { return false }

        var added = 0
        for mem in imported {
            let exists = memories.contains { existing in
                existing.content == mem.content &&
                existing.category == mem.category &&
                existing.id == mem.id
            }
            guard !exists else { continue }

            if let existingIdx = memories.firstIndex(where: {
                $0.content == mem.content && $0.category == mem.category
            }) {
                if mem.lastReferenced > memories[existingIdx].lastReferenced {
                    memories[existingIdx].lastReferenced = mem.lastReferenced
                    memories[existingIdx].mentionCount = max(memories[existingIdx].mentionCount, mem.mentionCount)
                }
            } else {
                memories.append(mem)
                added += 1
            }
        }

        if added > 0 { save(); postUpdated() }
        return added > 0
    }

    func deleteAllMemories(includeArchived: Bool = true) {
        let ids = memories.map { $0.id }
        for id in ids { memoryLinkService?.handleMemoryDeleted(id: id) }
        if includeArchived {
            memories.removeAll()
        } else {
            memories.removeAll { !$0.isArchived }
        }
        save()
        postUpdated()
    }

    // MARK: - Notifications

    private func postUpdated() {
        NotificationCenter.default.post(name: .relationshipMemoryUpdated, object: nil)
    }

    // MARK: - Scoring Algorithm

    private func recalculateImportance(for memory: RelationshipMemory) -> Double {
        if memory.manualOverride, let mi = memory.manualImportance {
            return mi
        }

        var score = 0.0

        // Mention frequency: up to 0.40
        score += min(0.40, Double(memory.mentionCount) * 0.08)

        // Recency bonus: up to 0.25 (decays over 60 days)
        let recencyDays = memory.daysSinceLastReferenced
        let recencyScore = exp(-recencyDays / 30.0) * 0.25
        score += recencyScore

        // User correction bonus: +0.15 if corrected
        if memory.correctedAt != nil {
            score += 0.15
        }

        // Base presence: 0.05 for existing memory
        score += 0.05

        return max(0.0, min(1.0, score))
    }

    // MARK: - Promotion Algorithm

    private func canPromote(_ content: String, category: MemoryCategory) -> Bool {
        let normalized = normalizeContent(content)
        let recent = memories.filter { !$0.isArchived && $0.category == category }

        // Count mentions of the same normalized content within last 7 days
        let mentionsInWindow = recent.filter {
            $0.daysSinceLastReferenced <= 7 &&
            normalizeContent($0.content) == normalized
        }

        return mentionsInWindow.count >= 1
    }

    private func promote(_ content: String, category: MemoryCategory, source: String) {
        let normalizedTarget = normalizeContent(content)
        let existing = memories.filter { !$0.isArchived && $0.category == category }
        let similar = existing.filter { normalizeContent($0.content) == normalizedTarget }

        if let match = similar.first, let idx = memories.firstIndex(where: { $0.id == match.id }) {
            updateExisting(at: idx)
            return
        }

        let memory = RelationshipMemory.make(
            category: category,
            content: content,
            source: source,
            importance: 0.30,
            reasonSaved: "Promoted from repeated mentions"
        )
        memories.append(memory)
        save()
    }

    // MARK: - Decay Algorithm

    private var lastDecayRun: Date?

    private func decayIfNeeded() {
        let now = Date()
        // Decay math is a function of whole-day granularity, so sub-minute repeats are identical.
        // This is called several times to build one prompt and ~6x per 60s surfacing tick — throttle
        // to at most once per 45s. Always runs on the first call (lastDecayRun starts nil).
        if let last = lastDecayRun, now.timeIntervalSince(last) < 45 { return }
        lastDecayRun = now

        var changed = false

        for i in memories.indices {
            let memory = memories[i]
            guard !memory.isArchived else { continue }

            // Skip decay for manually overridden memories
            if memory.manualOverride { continue }

            var score = recalculateImportance(for: memory)
            let daysSinceRef = memory.daysSinceLastReferenced

            // Low importance + long inactivity: gradual decay
            if score < 0.2 && daysSinceRef > 30 {
                let decayDays = daysSinceRef - 30
                let decay = Double(decayDays) * 0.05
                score = max(0.0, score - decay)
            }

            memories[i].importance = score

            // Don't immediately delete. Archive at < 0.1 and > 60 days idle
            if score < 0.1 && daysSinceRef > 60 && memories[i].archivedAt == nil {
                memories[i].archivedAt = now
                changed = true
            }

            // Permanently remove only after 90+ days archived at < 0.1
            if let archived = memories[i].archivedAt, score < 0.1 {
                let daysSinceArchived = -archived.timeIntervalSinceNow / 86400
                if daysSinceArchived > 90 {
                    // Will be removed on next save
                    changed = true
                }
            }
        }

        // Permanently remove expired memories
        memories.removeAll { m in
            guard let archived = m.archivedAt else { return false }
            let score = recalculateImportance(for: m)
            let daysSinceArchived = -archived.timeIntervalSinceNow / 86400
            return score < 0.1 && daysSinceArchived > 90
        }

        if changed { save() }
    }

    // MARK: - Helpers

    private func top(category: MemoryCategory, limit: Int) -> [RelationshipMemory] {
        decayIfNeeded()
        return memories
            .filter { !$0.isArchived && $0.category == category }
            .sorted { $0.importance > $1.importance }
            .prefix(limit)
            .map { $0 }
    }

    private func findExistingIndex(for content: String, category: MemoryCategory) -> Int? {
        let normalized = normalizeContent(content)
        return memories.firstIndex {
            !$0.isArchived &&
            $0.category == category &&
            normalizeContent($0.content) == normalized
        }
    }

    private func updateExisting(at idx: Int) {
        memories[idx].lastReferenced = Date()
        memories[idx].mentionCount += 1
        let newImportance = recalculateImportance(for: memories[idx])
        memories[idx].importance = newImportance
        save()
        postUpdated()
    }

    private func normalizeContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func save() {
        try? store.save(memories)
    }
}
