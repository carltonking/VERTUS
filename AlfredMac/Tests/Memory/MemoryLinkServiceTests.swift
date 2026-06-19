import XCTest
@testable import Alfred

final class MemoryLinkServiceTests: XCTestCase {
    var mockGraphStore: MockMemoryGraphStore!
    var mockMemoryStore: MockRelationshipMemoryStore!
    var memoryService: RelationshipMemoryService!
    var service: MemoryLinkService!

    override func setUp() {
        super.setUp()
        mockGraphStore = MockMemoryGraphStore()
        mockMemoryStore = MockRelationshipMemoryStore()
        memoryService = RelationshipMemoryService(store: mockMemoryStore)
        service = MemoryLinkService(relationshipMemory: memoryService, store: mockGraphStore)
        service.initialize()
    }

    /// Re-creates the service with a pre-seeded set of links in the graph store. Link
    /// management (confirm/reject/query) is tested via injected links so it does not depend
    /// on the build algorithm's `minMemoriesForLinking` (10) threshold.
    private func makeServiceWithLinks(_ links: [MemoryLink]) {
        mockGraphStore.links = links
        service = MemoryLinkService(relationshipMemory: memoryService, store: mockGraphStore)
        service.initialize()
    }

    func testInitialState() {
        XCTAssertTrue(service.getAllLinks().isEmpty)
        XCTAssertEqual(mockGraphStore.loadCallCount, 1)
    }

    func testNoLinksWithFewMemories() {
        memoryService.forceSave("only one memory", category: .goals, source: "test")
        service.buildLinksIfNeeded()
        XCTAssertTrue(service.getAllLinks().isEmpty)
    }

    // NOTE: buildLinksIfNeeded() builds on a private serial queue (fire-and-forget, no
    // completion signal), so the keyword-build algorithm is not synchronously observable
    // and is not unit-tested here. Link management below is tested via injected links.

    func testNoLinksForDissimilarMemories() {
        memoryService.forceSave("Swift programming", category: .preferences, source: "test")
        memoryService.forceSave("Python data science", category: .preferences, source: "test")
        service.buildLinksIfNeeded()
        let keywordLinks = service.getAllLinks().filter { $0.type == .keywordOverlap }
        XCTAssertLessThan(keywordLinks.count, 3)
    }

    func testConfirmLink() {
        let link = TestFactories.makeLink(from: UUID(), to: UUID())
        makeServiceWithLinks([link])
        service.confirmLink(id: link.id)
        let updated = service.getAllLinks().first { $0.id == link.id }
        XCTAssertTrue(updated?.userConfirmed ?? false)
        XCTAssertEqual(updated?.strength, 0.7)
    }

    func testRejectLink() {
        let link = TestFactories.makeLink(from: UUID(), to: UUID())
        makeServiceWithLinks([link])
        service.rejectLink(id: link.id)
        let updated = service.getAllLinks().first { $0.id == link.id }
        XCTAssertTrue(updated?.userRejected ?? false)
        XCTAssertFalse(updated?.userConfirmed ?? true)
    }

    func testLinksForMemory() {
        let id1 = UUID()
        makeServiceWithLinks([TestFactories.makeLink(from: id1, to: UUID())])
        XCTAssertFalse(service.links(for: id1).isEmpty)
    }

    func testLinksForMemoryNoLinks() {
        let links = service.links(for: UUID())
        XCTAssertTrue(links.isEmpty)
    }

    func testConnectedMemories() {
        let id1 = UUID()
        let id2 = UUID()
        makeServiceWithLinks([TestFactories.makeLink(from: id1, to: id2, strength: 0.5)])
        let connected = service.linkedMemoryIds(for: id1)
        XCTAssertFalse(connected.isEmpty)
    }

    func testConnectedMemoriesReturnsEmptyForUnknown() {
        let connected = service.linkedMemoryIds(for: UUID())
        XCTAssertTrue(connected.isEmpty)
    }

    func testLinksByType() {
        makeServiceWithLinks([
            TestFactories.makeLink(from: UUID(), to: UUID(), type: .keywordOverlap),
        ])
        let keywordLinks = service.getAllLinks().filter { $0.type == .keywordOverlap }
        let temporalLinks = service.getAllLinks().filter { $0.type == .temporalProximity }
        XCTAssertFalse(keywordLinks.isEmpty)
        XCTAssertTrue(temporalLinks.isEmpty)
    }

    func testGraphEmptyAfterReset() {
        makeServiceWithLinks([TestFactories.makeLink(from: UUID(), to: UUID())])
        let newStore = MockMemoryGraphStore()
        let newService = MemoryLinkService(relationshipMemory: memoryService, store: newStore)
        newService.initialize()
        newService.buildLinksIfNeeded()
        XCTAssertTrue(newService.getAllLinks().isEmpty)
    }
}
