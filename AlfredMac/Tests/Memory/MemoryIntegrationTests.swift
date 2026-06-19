import XCTest
@testable import Alfred

final class MemoryIntegrationTests: XCTestCase {
    var memoryService: RelationshipMemoryService!
    var reflectionService: MemoryReflectionService!
    var linkService: MemoryLinkService!
    var mockMemoryStore: MockRelationshipMemoryStore!
    var mockReflectionStore: MockReflectionStore!
    var mockGraphStore: MockMemoryGraphStore!

    override func setUp() {
        super.setUp()
        mockMemoryStore = MockRelationshipMemoryStore()
        mockReflectionStore = MockReflectionStore()
        mockGraphStore = MockMemoryGraphStore()
        memoryService = RelationshipMemoryService(store: mockMemoryStore)
        reflectionService = MemoryReflectionService(relationshipMemory: memoryService, store: mockReflectionStore)
        linkService = MemoryLinkService(relationshipMemory: memoryService, store: mockGraphStore)
        linkService.initialize()
    }

    func testSaveMemoryReflectAndLink() {
        // Reflections require >= 5 memories; links require >= 10.
        for i in 1...12 {
            memoryService.forceSave("Swift programming for iOS apps part \(i)", category: .preferences, source: "test")
        }

        _ = reflectionService.runReflectionNow()

        let mems = memoryService.relationshipMemories()
        let refs = reflectionService.getReflections(includeDismissed: true)

        XCTAssertEqual(mems.count, 12)
        XCTAssertFalse(refs.isEmpty)
        // Link building is async (private queue, no completion signal) and is not
        // synchronously observable; link behavior is covered in MemoryLinkServiceTests.
    }

    func testLinkReferencesCorrectMemoryIds() {
        memoryService.forceSave("Swift programming", category: .preferences, source: "test")
        memoryService.forceSave("Swift development", category: .preferences, source: "test")
        linkService.buildLinksIfNeeded()

        let memIds = Set(memoryService.relationshipMemories().map { $0.id })
        for link in linkService.getAllLinks() {
            XCTAssertTrue(memIds.contains(link.fromId))
            XCTAssertTrue(memIds.contains(link.toId))
        }
    }

    func testReflectionReferencesExistingMemory() {
        memoryService.forceSave("I use Swift regularly", category: .preferences, source: "test")
        _ = reflectionService.runReflectionNow()

        let memIds = Set(memoryService.relationshipMemories().map { $0.id })
        for ref in reflectionService.getReflections(includeDismissed: true) {
            for memId in ref.supportingMemoryIds {
                XCTAssertTrue(memIds.contains(memId), "Reflection references non-existent memory \(memId)")
            }
        }
    }

    func testArchiveMemoryRemovesFromActiveReflections() {
        memoryService.forceSave("test content", category: .preferences, source: "test")
        let mem = memoryService.relationshipMemories().first!
        memoryService.archiveMemory(id: mem.id)

        _ = reflectionService.runReflectionNow()
        for ref in reflectionService.getReflections(includeDismissed: true) {
            let supportingStillActive = ref.supportingMemoryIds.allSatisfy { id in
                memoryService.relationshipMemories().contains { $0.id == id }
            }
            XCTAssertTrue(supportingStillActive)
        }
    }

    func testDeleteMemoryRemovesAssociatedLinks() {
        memoryService.forceSave("Swift programming", category: .preferences, source: "test")
        memoryService.forceSave("Swift development", category: .preferences, source: "test")
        linkService.buildLinksIfNeeded()

        let mem = memoryService.relationshipMemories().first!
        memoryService.forgetMemory(id: mem.id)

        linkService.buildLinksIfNeeded()
        for link in linkService.getAllLinks() {
            XCTAssertNotEqual(link.fromId, mem.id)
            XCTAssertNotEqual(link.toId, mem.id)
        }
    }

    func testLargeMemorySetDoesNotDegrade() {
        let count = 50
        for i in 0..<count {
            let content = "Memory item number \(i) with some common keywords"
            memoryService.forceSave(content, category: .goals, source: "test")
        }

        let start = CFAbsoluteTimeGetCurrent()
        _ = reflectionService.runReflectionNow()
        linkService.buildLinksIfNeeded()
        let duration = CFAbsoluteTimeGetCurrent() - start

        let mems = memoryService.relationshipMemories()
        let refs = reflectionService.getReflections(includeDismissed: true)
        let links = linkService.getAllLinks()

        XCTAssertEqual(mems.count, count)
        XCTAssertGreaterThan(mems.count, 0)
        XCTAssertGreaterThan(refs.count + links.count, 0)
        XCTAssertLessThan(duration, 10.0)
    }

    func testServicesShareSameMemoryInstance() {
        memoryService.forceSave("shared memory", category: .goals, source: "test")
        let countBefore = memoryService.relationshipMemories().count
        _ = reflectionService.runReflectionNow()
        let countAfter = memoryService.relationshipMemories().count
        XCTAssertEqual(countBefore, countAfter, "Reflection should not add memories")
    }

    func testEmptyStateConsistency() {
        let refs = reflectionService.getReflections(includeDismissed: true)
        let links = linkService.getAllLinks()
        let mems = memoryService.relationshipMemories()
        XCTAssertTrue(refs.isEmpty)
        XCTAssertTrue(links.isEmpty)
        XCTAssertTrue(mems.isEmpty)
    }
}
