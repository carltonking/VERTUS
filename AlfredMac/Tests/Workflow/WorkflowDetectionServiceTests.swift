import XCTest
@testable import Alfred

@MainActor
final class WorkflowDetectionServiceTests: XCTestCase {
    var mockStore: MockWorkflowStore!
    var mockMemoryStore: MockRelationshipMemoryStore!
    var mockContextCollector: MockContextCollector!
    var memoryService: RelationshipMemoryService!
    var service: WorkflowDetectionService!

    override func setUp() {
        super.setUp()
        mockStore = MockWorkflowStore()
        mockMemoryStore = MockRelationshipMemoryStore()
        mockContextCollector = MockContextCollector()
        memoryService = RelationshipMemoryService(store: mockMemoryStore)
        service = WorkflowDetectionService(
            contextCollector: mockContextCollector,
            relationshipMemory: memoryService,
            store: mockStore
        )
    }

    func testInitialState() {
        XCTAssertTrue(service.allWorkflows.isEmpty)
        XCTAssertEqual(service.workflowCount, 0)
        XCTAssertEqual(mockStore.loadCallCount, 1)
    }

    func testDetectFromQueries() {
        mockContextCollector.recentQueryHistory = [
            "research Swift concurrency",
            "find iOS documentation",
            "look up SwiftUI patterns",
            "search for best practices"
        ]
        let detected = service.detectWorkflows()
        let research = detected.filter { $0.title == "Research then summarize" }
        XCTAssertFalse(research.isEmpty)
    }

    func testNoDetectionWithFewQueries() {
        mockContextCollector.recentQueryHistory = ["hello", "world"]
        let detected = service.detectWorkflows()
        XCTAssertTrue(detected.isEmpty)
    }

    func testNoDetectionWithEmptyQueries() {
        let detected = service.detectWorkflows()
        XCTAssertTrue(detected.isEmpty)
    }

    func testDetectFromMemories() {
        memoryService.forceSave("First create a plan\nthen execute the plan\nthen notify me", category: .workflows, source: "test")
        let detected = service.detectWorkflows()
        XCTAssertFalse(detected.isEmpty)
    }

    func testIgnoreNonWorkflowMemories() {
        memoryService.forceSave("Create a plan\nthen execute it", category: .goals, source: "test")
        let detected = service.detectWorkflows()
        let fromMemories = detected.filter { !$0.sourceMemoryIds.isEmpty }
        XCTAssertTrue(fromMemories.isEmpty)
    }

    func testDetectedWorkflowPersisted() {
        mockContextCollector.recentQueryHistory = [
            "research Swift",
            "find documentation",
            "look up API",
            "search for patterns"
        ]
        XCTAssertEqual(mockStore.saveCallCount, 0)
        _ = service.detectWorkflows()
        XCTAssertGreaterThanOrEqual(mockStore.saveCallCount, 1)
    }

    func testDetectedWorkflowIncrementsUseCountOnRepeat() {
        mockContextCollector.recentQueryHistory = ["research Swift", "find docs", "look up API"]
        _ = service.detectWorkflows()
        let firstCount = service.allWorkflows.first?.useCount ?? 0

        _ = service.detectWorkflows()
        let secondCount = service.allWorkflows.first?.useCount ?? 0
        XCTAssertGreaterThan(secondCount, firstCount)
    }

    func testAddWorkflow() {
        let workflow = TestFactories.makeWorkflow()
        service.addWorkflow(workflow)
        XCTAssertEqual(service.workflowCount, 1)
        XCTAssertEqual(mockStore.saveCallCount, 1)
    }

    func testWorkflowById() {
        let wf = TestFactories.makeWorkflow(title: "Find Me")
        service.addWorkflow(wf)
        let found = service.workflow(by: wf.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Find Me")
    }

    func testWorkflowByIdNotFound() {
        XCTAssertNil(service.workflow(by: UUID()))
    }

    func testUpdateWorkflow() {
        let wf = TestFactories.makeWorkflow(title: "Original")
        service.addWorkflow(wf)
        var updated = wf
        updated.title = "Updated"
        service.updateWorkflow(updated)
        let found = service.workflow(by: wf.id)
        XCTAssertEqual(found?.title, "Updated")
    }

    func testUpdateWorkflowUnknownId() {
        let wf = TestFactories.makeWorkflow()
        service.updateWorkflow(wf)
        XCTAssertEqual(service.workflowCount, 0)
    }

    func testDeleteWorkflow() {
        let wf = TestFactories.makeWorkflow()
        service.addWorkflow(wf)
        service.deleteWorkflow(id: wf.id)
        XCTAssertEqual(service.workflowCount, 0)
    }

    func testArchiveWorkflow() {
        let wf = TestFactories.makeWorkflow()
        service.addWorkflow(wf)
        service.archiveWorkflow(id: wf.id)
        XCTAssertTrue(service.allWorkflows.isEmpty)
        XCTAssertEqual(service.archivedWorkflows.count, 1)
    }

    func testArchiveWorkflowUnknownId() {
        service.archiveWorkflow(id: UUID())
        XCTAssertEqual(service.workflowCount, 0)
    }

    func testRestoreWorkflow() {
        let wf = TestFactories.makeWorkflow()
        service.addWorkflow(wf)
        service.archiveWorkflow(id: wf.id)
        service.restoreWorkflow(id: wf.id)
        XCTAssertFalse(service.allWorkflows.isEmpty)
        XCTAssertTrue(service.archivedWorkflows.isEmpty)
    }

    func testRestoreWorkflowUnknownId() {
        service.restoreWorkflow(id: UUID())
    }

    func testRecordUsage() {
        let wf = TestFactories.makeWorkflow()
        service.addWorkflow(wf)
        let oldCount = service.workflow(by: wf.id)?.useCount ?? 0
        service.recordUsage(id: wf.id)
        let newCount = service.workflow(by: wf.id)?.useCount ?? 0
        XCTAssertEqual(newCount, oldCount + 1)
    }

    func testRecordUsageUnknownId() {
        service.recordUsage(id: UUID())
    }

    func testAllWorkflowsExcludesArchived() {
        let wf1 = TestFactories.makeWorkflow(title: "Active")
        let wf2 = TestFactories.makeWorkflow(title: "Archived")
        service.addWorkflow(wf1)
        service.addWorkflow(wf2)
        service.archiveWorkflow(id: wf2.id)
        XCTAssertEqual(service.allWorkflows.count, 1)
        XCTAssertEqual(service.allWorkflows.first?.title, "Active")
    }

    func testArchivedWorkflows() {
        let wf = TestFactories.makeWorkflow(title: "To Archive")
        service.addWorkflow(wf)
        service.archiveWorkflow(id: wf.id)
        XCTAssertEqual(service.archivedWorkflows.count, 1)
        XCTAssertTrue(service.archivedWorkflows.first?.archived ?? false)
    }

    func testWorkflowCountMatchesTotal() {
        service.addWorkflow(TestFactories.makeWorkflow())
        service.addWorkflow(TestFactories.makeWorkflow())
        XCTAssertEqual(service.workflowCount, 2)
    }

    func testSaveCalledOnAdd() {
        service.addWorkflow(TestFactories.makeWorkflow())
        XCTAssertGreaterThanOrEqual(mockStore.saveCallCount, 1)
    }

    func testSaveCalledOnDelete() {
        let wf = TestFactories.makeWorkflow()
        service.addWorkflow(wf)
        let savesBeforeDelete = mockStore.saveCallCount
        service.deleteWorkflow(id: wf.id)
        XCTAssertGreaterThan(mockStore.saveCallCount, savesBeforeDelete)
    }

    func testEmptyStateConsistency() {
        XCTAssertTrue(service.allWorkflows.isEmpty)
        XCTAssertTrue(service.archivedWorkflows.isEmpty)
        XCTAssertEqual(service.workflowCount, 0)
    }
}
