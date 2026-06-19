import Foundation
@testable import Alfred

final class MockRelationshipMemoryStore: RelationshipMemoryStoreProtocol {
    var memories: [RelationshipMemory] = []
    var loadCallCount = 0
    var saveCallCount = 0

    func load() -> [RelationshipMemory] {
        loadCallCount += 1
        return memories
    }

    func save(_ memories: [RelationshipMemory]) throws {
        saveCallCount += 1
        self.memories = memories
    }
}

final class MockReflectionStore: ReflectionStoreProtocol {
    var reflections: [Reflection] = []
    var loadCallCount = 0
    var saveCallCount = 0

    func load() -> [Reflection] {
        loadCallCount += 1
        return reflections
    }

    func save(_ reflections: [Reflection]) throws {
        saveCallCount += 1
        self.reflections = reflections
    }
}

final class MockWorkflowStore: WorkflowStoreProtocol {
    var workflows: [Workflow] = []
    var loadCallCount = 0
    var saveCallCount = 0

    func load() -> [Workflow] {
        loadCallCount += 1
        return workflows
    }

    func save(_ workflows: [Workflow]) throws {
        saveCallCount += 1
        self.workflows = workflows
    }
}

final class MockMemorySuggestionStore: MemorySuggestionStoreProtocol {
    var suggestions: [MemorySuggestion] = []
    var loadCallCount = 0
    var saveCallCount = 0

    func load() -> [MemorySuggestion] {
        loadCallCount += 1
        return suggestions
    }

    func save(_ suggestions: [MemorySuggestion]) throws {
        saveCallCount += 1
        self.suggestions = suggestions
    }
}

final class MockSuggestionBlocklistStore: SuggestionBlocklistStoreProtocol {
    var blockedIds: Set<String> = []
    var loadCallCount = 0
    var saveCallCount = 0

    func load() -> Set<String> {
        loadCallCount += 1
        return blockedIds
    }

    func save(_ items: Set<String>) throws {
        saveCallCount += 1
        self.blockedIds = items
    }
}

final class MockMemoryGraphStore: MemoryGraphStoreProtocol {
    var links: [MemoryLink] = []
    var loadCallCount = 0
    var saveCallCount = 0

    func load() -> [MemoryLink] {
        loadCallCount += 1
        return links
    }

    func save(_ links: [MemoryLink]) throws {
        saveCallCount += 1
        self.links = links
    }
}
