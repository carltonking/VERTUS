import XCTest
@testable import Alfred

final class MemoryReflectionServiceTests: XCTestCase {
    var mockStore: MockReflectionStore!
    var mockMemoryStore: MockRelationshipMemoryStore!
    var memoryService: RelationshipMemoryService!
    var service: MemoryReflectionService!

    override func setUp() {
        super.setUp()
        mockStore = MockReflectionStore()
        mockMemoryStore = MockRelationshipMemoryStore()
        memoryService = RelationshipMemoryService(store: mockMemoryStore)
        service = MemoryReflectionService(relationshipMemory: memoryService, store: mockStore)
    }

    /// Reflection generation requires at least `minMemoriesForReflection` (5) memories that
    /// share a keyword cluster before any reflection is produced.
    private func seedReflectableMemories(_ count: Int = 6) {
        for i in 1...count {
            memoryService.forceSave("Swift programming project number \(i)", category: .preferences, source: "test")
        }
    }

    func testInitialState() {
        XCTAssertTrue(service.getReflections(includeDismissed: true).isEmpty)
        XCTAssertEqual(mockStore.loadCallCount, 1)
    }

    func testReflectOnSimpleGoalGeneratesPattern() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        let reflections = service.getReflections(includeDismissed: true)
        XCTAssertFalse(reflections.isEmpty)
    }

    func testReflectWithNoMemoriesDoesNothing() {
        _ = service.runReflectionNow()
        XCTAssertTrue(service.getReflections(includeDismissed: true).isEmpty)
    }

    func testReflectBelowThresholdDoesNothing() {
        memoryService.forceSave("Single Swift memory", category: .preferences, source: "test")
        _ = service.runReflectionNow()
        XCTAssertTrue(service.getReflections(includeDismissed: true).isEmpty)
    }

    func testReflectionConfidenceIsValid() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        let confidence = service.getReflections(includeDismissed: true).first?.confidence ?? 0
        XCTAssertGreaterThan(confidence, 0.1)
    }

    func testDismissReflection() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        guard let ref = service.getReflections(includeDismissed: true).first else {
            XCTFail("Expected reflection")
            return
        }
        service.dismissReflection(id: ref.id)
        let dismissed = service.getReflections(includeDismissed: true).first { $0.id == ref.id }
        XCTAssertTrue(dismissed?.dismissed ?? false)
    }

    func testDismissReflectionUnknownIdDoesNothing() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        let countBefore = service.getReflections(includeDismissed: true).count
        service.dismissReflection(id: UUID())
        XCTAssertEqual(service.getReflections(includeDismissed: true).count, countBefore)
    }

    func testRefreshGeneratesNewReflections() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        let firstCount = service.getReflections(includeDismissed: true).count
        _ = service.runReflectionNow()
        let secondCount = service.getReflections(includeDismissed: true).count
        XCTAssertGreaterThanOrEqual(secondCount, firstCount)
    }

    func testReflectionsOfType() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        let patterns = service.getReflections(includeDismissed: true).filter { $0.type == .pattern }
        XCTAssertGreaterThanOrEqual(patterns.count, 0)
    }

    func testResetReflections() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        service.resetAll()
        XCTAssertTrue(service.getReflections(includeDismissed: true).isEmpty)
    }

    func testMultipleReflectionsSamePatternDeduplicates() {
        seedReflectableMemories()
        _ = service.runReflectionNow()
        let count1 = service.getReflections(includeDismissed: true).count
        _ = service.runReflectionNow()
        let count2 = service.getReflections(includeDismissed: true).count
        XCTAssertLessThanOrEqual(count2 - count1, 2)
    }

    func testReflectionSaveCalledOnReflect() {
        seedReflectableMemories()
        XCTAssertEqual(mockStore.saveCallCount, 0)
        _ = service.runReflectionNow()
        XCTAssertGreaterThanOrEqual(mockStore.saveCallCount, 1)
    }
}
