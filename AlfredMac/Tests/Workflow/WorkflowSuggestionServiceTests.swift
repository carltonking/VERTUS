import XCTest
@testable import Alfred

@MainActor
final class WorkflowSuggestionServiceTests: XCTestCase {
    var mockStore: MockWorkflowStore!
    var mockMemoryStore: MockRelationshipMemoryStore!
    var mockContextCollector: MockContextCollector!
    var memoryService: RelationshipMemoryService!
    var detectionService: WorkflowDetectionService!
    var service: WorkflowSuggestionService!

    override func setUp() {
        super.setUp()
        mockStore = MockWorkflowStore()
        mockMemoryStore = MockRelationshipMemoryStore()
        mockContextCollector = MockContextCollector()
        memoryService = RelationshipMemoryService(store: mockMemoryStore)
        detectionService = WorkflowDetectionService(
            contextCollector: mockContextCollector,
            relationshipMemory: memoryService,
            store: mockStore
        )
        service = WorkflowSuggestionService(
            detectionService: detectionService,
            contextCollector: mockContextCollector,
            relationshipMemory: memoryService
        )
    }

    func testInitialNoWorkflows() {
        XCTAssertTrue(service.availableWorkflows.isEmpty)
    }

    func testRunDetectionEmpty() {
        let detected = service.runDetection()
        XCTAssertTrue(detected.isEmpty)
    }

    func testRunDetectionFromQueries() {
        mockContextCollector.recentQueryHistory = [
            "research Swift",
            "find documentation",
            "look up API",
            "search for patterns"
        ]
        let detected = service.runDetection()
        XCTAssertFalse(detected.isEmpty)
    }

    func testAvailableWorkflowsIncludesDetected() {
        mockContextCollector.recentQueryHistory = [
            "research Swift",
            "find documentation",
            "look up API"
        ]
        _ = service.runDetection()
        XCTAssertFalse(service.availableWorkflows.isEmpty)
    }

    func testGenerateWorkflowSuggestionsWithAppMatch() {
        mockContextCollector.activeAppName = "Xcode"
        let wf = TestFactories.makeWorkflow(title: "Xcode Build and Run")
        detectionService.addWorkflow(wf)

        let suggestions = service.generateWorkflowSuggestions()
        let matching = suggestions.filter { $0.title.contains("Xcode") }
        XCTAssertFalse(matching.isEmpty)
    }

    func testGenerateWorkflowSuggestionsWithQueryMatch() {
        mockContextCollector.recentQueryHistory = ["build", "compile"]
        let wf = TestFactories.makeWorkflow(title: "Build Project")
        detectionService.addWorkflow(wf)

        let suggestions = service.generateWorkflowSuggestions()
        let matching = suggestions.filter { $0.title.contains("Build Project") }
        XCTAssertFalse(matching.isEmpty)
    }

    func testNoSuggestionsWithoutMatch() {
        mockContextCollector.activeAppName = "Terminal"
        let wf = TestFactories.makeWorkflow(title: "Xcode Build")
        detectionService.addWorkflow(wf)

        let suggestions = service.generateWorkflowSuggestions()
        let xcodeSuggestions = suggestions.filter { $0.title.contains("Xcode") }
        XCTAssertTrue(xcodeSuggestions.isEmpty)
    }

    func testSuggestFromQuery() {
        let wf = TestFactories.makeWorkflow(title: "Research Topic")
        detectionService.addWorkflow(wf)

        let suggested = service.suggestFromQuery("research swift")
        XCTAssertNotNil(suggested)
        XCTAssertEqual(suggested?.title, "Research Topic")
    }

    func testSuggestFromQueryNoMatch() {
        let wf = TestFactories.makeWorkflow(title: "Research Topic")
        detectionService.addWorkflow(wf)

        let suggested = service.suggestFromQuery("build project")
        XCTAssertNil(suggested)
    }

    func testSuggestFromQueryRanksByUseCount() {
        let wf1 = TestFactories.makeWorkflow(title: "Research Topic")
        let wf2 = TestFactories.makeWorkflow(title: "Research Topic")
        detectionService.addWorkflow(wf1)
        detectionService.addWorkflow(wf2)
        detectionService.recordUsage(id: wf2.id)

        let suggested = service.suggestFromQuery("research topic")
        XCTAssertNotNil(suggested)
        XCTAssertEqual(suggested?.id, wf2.id)
    }

    func testRecordWorkflowUsed() {
        let wf = TestFactories.makeWorkflow()
        detectionService.addWorkflow(wf)
        let oldCount = detectionService.workflow(by: wf.id)?.useCount ?? 0
        service.recordWorkflowUsed(wf.id)
        let newCount = detectionService.workflow(by: wf.id)?.useCount ?? 0
        XCTAssertEqual(newCount, oldCount + 1)
    }

    func testSuggestionConfidenceScalesWithUseCount() {
        let wf1 = TestFactories.makeWorkflow(title: "Build Xcode")
        let wf2 = TestFactories.makeWorkflow(title: "Build Xcode")
        detectionService.addWorkflow(wf1)
        detectionService.addWorkflow(wf2)
        for _ in 0..<5 {
            detectionService.recordUsage(id: wf2.id)
        }

        mockContextCollector.activeAppName = "Xcode"
        let suggestions = service.generateWorkflowSuggestions()
        let wf2Suggestion = suggestions.first { $0.action == .runWorkflow(wf2.id.uuidString) }
        let wf1Suggestion = suggestions.first { $0.action == .runWorkflow(wf1.id.uuidString) }

        if let s2 = wf2Suggestion, let s1 = wf1Suggestion {
            XCTAssertGreaterThan(s2.confidence, s1.confidence)
        }
    }

    func testSuggestionTypeIsAction() {
        mockContextCollector.activeAppName = "Xcode"
        let wf = TestFactories.makeWorkflow(title: "Xcode Build")
        detectionService.addWorkflow(wf)

        let suggestions = service.generateWorkflowSuggestions()
        for suggestion in suggestions {
            XCTAssertEqual(suggestion.type, .action)
        }
    }
}
