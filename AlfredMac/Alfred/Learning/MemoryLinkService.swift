import Foundation
import OSLog

private let logger = Logger(subsystem: "com.alfred.app", category: "MemoryLink")

final class MemoryLinkService {
    private let store: MemoryGraphStoreProtocol
    private let relationshipMemory: RelationshipMemoryService
    private var links: [MemoryLink]
    private let linkQueue = DispatchQueue(label: "com.alfred.memorylink", qos: .utility)
    private var lastBuildAt: Date?

    private let buildCooldown: TimeInterval = 12 * 3600
    private let minMemoriesForLinking = 10
    private let maxBuildDuration: TimeInterval = 10
    private let jaccardThreshold = 0.25
    private let temporalThreshold: TimeInterval = 30 * 60
    private let intraSessionThreshold: TimeInterval = 5 * 60
    private let maxMemoriesForFullBuild = 500
    private let recentCutoff: TimeInterval = 90 * 86400
    private let archiveDecayRate: Double = 0.02
    private let unreferencedDecayRate: Double = 0.1
    private let unreferencedDecayThreshold: TimeInterval = 60 * 86400
    private let linkDeleteThreshold: Double = 0.1

    private let categoryWeights: [MemoryCategory: [MemoryCategory: Double]] = [
        .goals: [.projects: 0.7, .skills: 0.5, .recurringProblems: 0.3],
        .projects: [.goals: 0.7, .skills: 0.5, .preferences: 0.3],
        .preferences: [.goals: 0.4, .projects: 0.3, .workflows: 0.4],
        .skills: [.goals: 0.5, .projects: 0.5, .longTermInterests: 0.5],
        .workflows: [.recurringProblems: 0.6, .preferences: 0.4],
        .recurringProblems: [.workflows: 0.6, .goals: 0.3],
        .longTermInterests: [.skills: 0.5, .goals: 0.4],
    ]

    private let causeEffectMarkers: Set<String> = [
        "because of", "due to", "led to", "resulted in", "caused by",
        "triggered by", "as a result of", "stemming from", "originating from",
        "since", "therefore", "consequently", "thus", "hence",
    ]

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
        "like", "work", "working", "try", "trying", "always", "never", "sometimes",
    ]

    private let positiveWords: Set<String> = [
        "love", "prefer", "great", "good", "amazing", "enjoy", "fantastic", "helpful",
        "useful", "important", "wonderful", "excellent", "awesome", "productive",
        "efficient", "reliable", "fast", "easy", "intuitive", "beautiful", "clean",
        "powerful", "flexible", "simple", "best",
    ]

    private let negativeWords: Set<String> = [
        "hate", "dislike", "terrible", "bad", "awful", "horrible", "annoying", "frustrating",
        "slow", "difficult", "complicated", "ugly", "messy", "unreliable", "broken",
        "confusing", "painful", "useless", "waste", "hated", "worst",
    ]

    init(relationshipMemory: RelationshipMemoryService) {
        self.relationshipMemory = relationshipMemory
        store = MemoryGraphStore()
        links = store.load()
    }

    init(relationshipMemory: RelationshipMemoryService, store: MemoryGraphStoreProtocol) {
        self.relationshipMemory = relationshipMemory
        self.store = store
        links = store.load()
    }

    // MARK: - Public API

    func getAllLinks() -> [MemoryLink] {
        links
    }

    func links(for memoryId: UUID) -> [MemoryLink] {
        links.filter { ($0.fromId == memoryId || $0.toId == memoryId) && !$0.isDecayed && !$0.userRejected }
    }

    func linkedMemoryIds(for memoryId: UUID, minStrength: Double = 0.0) -> [UUID] {
        links.filter { link in
            guard !link.isDecayed && !link.userRejected && link.strength >= minStrength else { return false }
            return link.fromId == memoryId || link.toId == memoryId
        }.map { link in
            link.fromId == memoryId ? link.toId : link.fromId
        }
    }

    func confirmLink(id: UUID) {
        guard let idx = links.firstIndex(where: { $0.id == id }) else { return }
        links[idx].userConfirmed = true
        links[idx].userRejected = false
        links[idx].strength = 0.7
        links[idx].lastReferencedAt = Date()
        save()
    }

    func rejectLink(id: UUID) {
        guard let idx = links.firstIndex(where: { $0.id == id }) else { return }
        links[idx].userRejected = true
        links[idx].userConfirmed = false
        save()
    }

    func undoRejectLink(id: UUID) {
        guard let idx = links.firstIndex(where: { $0.id == id }) else { return }
        links[idx].userRejected = false
        save()
    }

    func addLink(_ link: MemoryLink) {
        guard !links.contains(where: { $0.id == link.id }) else { return }
        links.append(link)
        save()
    }

    func createManualLink(from: UUID, to: UUID, type: LinkType) {
        let normalized = normalizePair(from: from, to: to)
        if let existing = links.first(where: {
            ($0.fromId == normalized.from && $0.toId == normalized.to && !$0.userRejected)
        }) {
            confirmLink(id: existing.id)
            return
        }
        let link = MemoryLink.make(from: normalized.from, to: normalized.to, type: type, strength: 0.7, userConfirmed: true)
        links.append(link)
        save()
    }

    func deleteLinks(for memoryId: UUID) {
        links.removeAll { $0.fromId == memoryId || $0.toId == memoryId }
        save()
    }

    func removeLink(id: UUID) {
        links.removeAll { $0.id == id }
        save()
    }

    // MARK: - Initialization

    func initialize() {
        lastBuildAt = nil
        linkQueue.async { [weak self] in
            _ = self?.buildLinksIfNeeded()
        }
    }

    // MARK: - Link Building (Background)

    func shouldBuildLinks() -> Bool {
        let memories = relationshipMemory.allMemoriesForAnalysis()
        guard memories.count >= minMemoriesForLinking else { return false }
        guard let last = lastBuildAt else { return true }
        return Date().timeIntervalSince(last) >= buildCooldown
    }

    func buildLinksIfNeeded() -> Int {
        guard shouldBuildLinks() else { return 0 }

        var count = 0
        let start = CFAbsoluteTimeGetCurrent()

        linkQueue.async { [weak self] in
            guard let self else { return }
            let memories = self.memoriesForLinking()
            guard memories.count >= self.minMemoriesForLinking else { return }

            var newLinks: [MemoryLink] = []
            let existingPairs = Set(self.links.compactMap { l -> String? in
                guard !l.userRejected else { return nil }
                return "\(l.fromId.uuidString):\(l.toId.uuidString):\(l.type.rawValue)"
            })

            let userConfirmedIds = Set(self.links.filter { $0.userConfirmed }.flatMap { [$0.fromId, $0.toId] })

            for i in 0..<memories.count {
                guard CFAbsoluteTimeGetCurrent() - start < self.maxBuildDuration else { break }
                let memA = memories[i]
                guard !userConfirmedIds.contains(memA.id) else { continue }

                for j in (i + 1)..<memories.count {
                    guard CFAbsoluteTimeGetCurrent() - start < self.maxBuildDuration else { break }
                    let memB = memories[j]
                    guard !userConfirmedIds.contains(memB.id) else { continue }

                    let pair = self.normalizePair(from: memA.id, to: memB.id)
                    let skipExisting = { (type: LinkType) -> Bool in
                        let key = "\(pair.from.uuidString):\(pair.to.uuidString):\(type.rawValue)"
                        return existingPairs.contains(key)
                    }

                    if !skipExisting(.keywordOverlap) {
                        let kwStrength = self.keywordOverlapStrength(memA, memB)
                        if kwStrength >= self.jaccardThreshold {
                            newLinks.append(MemoryLink.make(from: pair.from, to: pair.to, type: .keywordOverlap, strength: kwStrength))
                        }
                    }

                    if !skipExisting(.temporalProximity) {
                        let tempStrength = self.temporalProximityStrength(memA, memB)
                        if tempStrength > 0 {
                            newLinks.append(MemoryLink.make(from: pair.from, to: pair.to, type: .temporalProximity, strength: tempStrength))
                        }
                    }

                    if !skipExisting(.categoryRelationship) {
                        let catStrength = self.categoryRelationshipStrength(memA, memB)
                        if catStrength > 0 {
                            newLinks.append(MemoryLink.make(from: pair.from, to: pair.to, type: .categoryRelationship, strength: catStrength))
                        }
                    }

                    if !skipExisting(.contradictory) {
                        let conStrength = self.contradictionStrength(memA, memB)
                        if conStrength > 0 {
                            newLinks.append(MemoryLink.make(from: pair.from, to: pair.to, type: .contradictory, strength: conStrength))
                        }
                    }

                    if !skipExisting(.causeEffect) {
                        let ceStrength = self.causeEffectStrength(memA, memB)
                        if ceStrength > 0 {
                            newLinks.append(MemoryLink.make(from: pair.from, to: pair.to, type: .causeEffect, strength: ceStrength))
                        }
                    }
                }
            }

            self.links.append(contentsOf: newLinks)
            self.decayIfNeeded()
            self.save()
            self.lastBuildAt = Date()
            count = newLinks.count

            if count > 0 {
                logger.info("Memory linking built \(count) new link(s)")
            }
        }

        return count
    }

    // MARK: - Memory Retrieval for Linking

    private func memoriesForLinking() -> [RelationshipMemory] {
        let all = relationshipMemory.allMemoriesForAnalysis()
        if all.count > maxMemoriesForFullBuild {
            let cutoff = Date().addingTimeInterval(-recentCutoff)
            let recent = all.filter { $0.lastReferenced >= cutoff }
            if recent.count >= minMemoriesForLinking {
                return recent
            }
        }
        return all
    }

    // MARK: - Detection Algorithms

    private func keywordOverlapStrength(_ a: RelationshipMemory, _ b: RelationshipMemory) -> Double {
        let kwA = extractKeywords(from: a.content)
        let kwB = extractKeywords(from: b.content)
        guard !kwA.isEmpty && !kwB.isEmpty else { return 0 }
        let intersection = kwA.intersection(kwB)
        let union = kwA.union(kwB)
        return Double(intersection.count) / Double(union.count)
    }

    private func temporalProximityStrength(_ a: RelationshipMemory, _ b: RelationshipMemory) -> Double {
        let timeA = a.lastReferenced
        let timeB = b.lastReferenced
        let gap = abs(timeA.timeIntervalSince(timeB))

        if gap <= intraSessionThreshold {
            return 0.6
        }
        if gap <= temporalThreshold {
            return 0.3
        }
        return 0
    }

    private func categoryRelationshipStrength(_ a: RelationshipMemory, _ b: RelationshipMemory) -> Double {
        let fromWeights = categoryWeights[a.category] ?? [:]
        return fromWeights[b.category] ?? 0
    }

    private func contradictionStrength(_ a: RelationshipMemory, _ b: RelationshipMemory) -> Double {
        let loweredA = a.content.lowercased()
        let loweredB = b.content.lowercased()

        let aHasPos = positiveWords.contains { loweredA.contains($0) }
        let aHasNeg = negativeWords.contains { loweredA.contains($0) }
        let bHasPos = positiveWords.contains { loweredB.contains($0) }
        let bHasNeg = negativeWords.contains { loweredB.contains($0) }

        let oppositeSentiment = (aHasPos && bHasNeg) || (aHasNeg && bHasPos)
        guard oppositeSentiment else { return 0 }

        let kwA = extractKeywords(from: a.content)
        let kwB = extractKeywords(from: b.content)
        let shared = kwA.intersection(kwB)
        guard !shared.isEmpty else { return 0 }

        return min(0.85, 0.5 + Double(shared.count) * 0.1)
    }

    private func causeEffectStrength(_ a: RelationshipMemory, _ b: RelationshipMemory) -> Double {
        let loweredA = a.content.lowercased()
        let loweredB = b.content.lowercased()

        let aIsCause = causeEffectMarkers.contains { loweredA.contains($0) }
        let bIsEffect = causeEffectMarkers.contains { loweredB.contains($0) }

        guard aIsCause || bIsEffect else { return 0 }

        let kwA = extractKeywords(from: a.content)
        let kwB = extractKeywords(from: b.content)
        let shared = kwA.intersection(kwB)
        guard !shared.isEmpty else { return 0 }

        var strength = 0.4
        if a.lastReferenced < b.lastReferenced {
            strength += 0.1
        }

        return min(0.7, strength + Double(shared.count) * 0.05)
    }

    // MARK: - Decay

    private func decayIfNeeded() {
        let now = Date()
        var changed = false

        for i in links.indices {
            let link = links[i]
            guard !link.userConfirmed else { continue }

            var strength = link.strength

            let memA = relationshipMemory.memory(by: link.fromId)
            let memB = relationshipMemory.memory(by: link.toId)

            if memA?.isArchived == true || memB?.isArchived == true {
                let daysArchived = (max(
                    -(memA?.archivedAt ?? .distantPast).timeIntervalSinceNow,
                    -(memB?.archivedAt ?? .distantPast).timeIntervalSinceNow
                ) / 86400)
                strength = max(0, strength - Double(daysArchived) * archiveDecayRate)
            }

            let daysSinceRef = -link.lastVerifiedAt.timeIntervalSinceNow / 86400
            if daysSinceRef > 60 {
                let monthsPast = (daysSinceRef - 60) / 30
                strength = max(0, strength - monthsPast * unreferencedDecayRate)
            }

            links[i].strength = strength
            links[i].lastVerifiedAt = now

            if strength < 0.1 {
                changed = true
            }
        }

        links.removeAll { $0.isDecayed && !$0.userConfirmed }

        if changed { save() }
    }

    // MARK: - Event Hooks

    func handleMemoryDeleted(id: UUID) {
        deleteLinks(for: id)
    }

    func handleMemoryArchived(id: UUID) {
        for i in links.indices {
            if links[i].fromId == id || links[i].toId == id {
                guard !links[i].userConfirmed else { continue }
                links[i].strength = max(0, links[i].strength - archiveDecayRate)
            }
        }
        save()
    }

    func handleMemoryReferenced(id: UUID) {
        for i in links.indices {
            if links[i].fromId == id || links[i].toId == id {
                links[i].lastReferencedAt = Date()
                if links[i].strength < 0.3 && !links[i].userConfirmed {
                    links[i].strength = min(0.3, links[i].strength + 0.05)
                }
            }
        }
    }

    // MARK: - Helpers

    private func extractKeywords(from text: String) -> Set<String> {
        let lowered = text.lowercased()
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let cleaned = lowered.components(separatedBy: punctuation).joined()
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines)
        return Set(words.filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    private func normalizePair(from: UUID, to: UUID) -> (from: UUID, to: UUID) {
        from.uuidString < to.uuidString ? (from, to) : (to, from)
    }

    private func save() {
        try? store.save(links)
    }
}
