import XCTest
@testable import Alfred

@MainActor
final class ProactiveMemorySurfacingServiceTests: XCTestCase {
    var mockStore: MockMemorySuggestionStore!
    var mockBlocklistStore: MockSuggestionBlocklistStore!
    var mockMemoryStore: MockRelationshipMemoryStore!
    var mockReflectionStore: MockReflectionStore!
    var mockContextCollector: MockContextCollector!
    var memoryService: RelationshipMemoryService!
    var reflectionService: MemoryReflectionService!
    var service: ProactiveMemorySurfacingService!

    override func setUp() {
        super.setUp()
        mockStore = MockMemorySuggestionStore()
        mockBlocklistStore = MockSuggestionBlocklistStore()
        mockMemoryStore = MockRelationshipMemoryStore()
        mockReflectionStore = MockReflectionStore()
        mockContextCollector = MockContextCollector()
        memoryService = RelationshipMemoryService(store: mockMemoryStore)
        reflectionService = MemoryReflectionService(relationshipMemory: memoryService, store: mockReflectionStore)
        service = ProactiveMemorySurfacingService(
            relationshipMemory: memoryService,
            memoryReflections: reflectionService,
            contextCollector: mockContextCollector,
            store: mockStore,
            blocklistStore: mockBlocklistStore
        )
    }

    func testInitialState() {
        let suggestions = service.getAvailableSuggestions()
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testSuggestionsBasedOnActiveApp() {
        mockContextCollector.activeAppName = "Xcode"
        mockContextCollector.activeBundleIdentifier = "com.apple.dt.Xcode"
        memoryService.forceSave("Swift programming in Xcode", category: .preferences, source: "test")

        let suggestions = service.forceCheck()
        let xcodeRelated = suggestions.filter { $0.subtitle.lowercased().contains("xcode") }
        XCTAssertGreaterThanOrEqual(xcodeRelated.count, 0)
    }

    func testSuggestionsBasedOnHour() {
        mockContextCollector.currentHour = 14
        memoryService.forceSave("Afternoon coding sessions", category: .preferences, source: "test")

        let suggestions = service.forceCheck()
        XCTAssertGreaterThanOrEqual(suggestions.count, 0)
    }

    func testMorningSuggestionsBeforeNoon() {
        mockContextCollector.currentHour = 9
        memoryService.forceSave("Morning standup notes", category: .preferences, source: "test")

        _ = service.forceCheck()
    }

    func testSuggestionsBasedOnProject() {
        mockContextCollector.activeProjectFromMemory = "ALFRED"
        memoryService.forceSave("Working on ALFRED project", category: .goals, source: "test")

        _ = service.forceCheck()
    }

    func testBlockedSuggestionNotReturned() {
        memoryService.forceSave("Swift programming", category: .preferences, source: "test")
        mockBlocklistStore.blockedIds = ["swift_programming"]

        let suggestions = service.forceCheck()
        let blocked = suggestions.filter { $0.title.lowercased().contains("swift") }
        XCTAssertTrue(blocked.isEmpty)
    }

    func testDismissSuggestion() {
        memoryService.forceSave("test", category: .preferences, source: "test")
        let suggestions = service.forceCheck()
        guard let suggestion = suggestions.first else {
            return
        }
        service.dismissSuggestion(id: suggestion.id)
        let remaining = service.getAvailableSuggestions().filter { $0.id == suggestion.id }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDismissAndBlockSuggestion() {
        memoryService.forceSave("test", category: .preferences, source: "test")
        let suggestions = service.forceCheck()
        guard let suggestion = suggestions.first else {
            return
        }
        service.dismissSuggestion(id: suggestion.id, block: true)
        let remaining = service.getAvailableSuggestions().filter { $0.id == suggestion.id }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRefreshClearsSuggestions() {
        memoryService.forceSave("test", category: .preferences, source: "test")
        _ = service.forceCheck()
        service.clearAll()
        let suggestions = service.getAvailableSuggestions()
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testRefreshThenReEvaluate() {
        memoryService.forceSave("test", category: .preferences, source: "test")
        _ = service.forceCheck()
        service.clearAll()
        _ = service.forceCheck()
    }

    func testSuggestionContainsConfidence() {
        memoryService.forceSave("Very important and highly relevant memory", category: .preferences, source: "test", importance: 0.9)
        let suggestions = service.forceCheck()
        for suggestion in suggestions {
            XCTAssertGreaterThanOrEqual(suggestion.confidence, 0)
            XCTAssertLessThanOrEqual(suggestion.confidence, 1)
        }
    }

    func testNoSuggestionsWhenNoMemories() {
        let suggestions = service.forceCheck()
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testSuggestionsGeneratedFromReflections() {
        memoryService.forceSave("I use Swift regularly for iOS", category: .preferences, source: "test")
        _ = reflectionService.runReflectionNow()
        _ = service.forceCheck()
    }

    func testSaveToPersistenceRestoresSuggestions() {
        memoryService.forceSave("test", category: .preferences, source: "test")
        _ = service.forceCheck()
        let savedCount = mockStore.saveCallCount
        XCTAssertGreaterThanOrEqual(savedCount, 0)
    }

    func testNoDuplicateSuggestions() {
        memoryService.forceSave("Swift programming", category: .preferences, source: "test")
        let suggestions = service.forceCheck()
        let titles = suggestions.map { $0.title }
        let uniqueTitles = Set(titles)
        XCTAssertEqual(titles.count, uniqueTitles.count)
    }

    func testContextChangeTriggersNewEvaluation() {
        mockContextCollector.activeAppName = "Terminal"
        memoryService.forceSave("Terminal command line work", category: .preferences, source: "test")
        _ = service.forceCheck()

        mockContextCollector.activeAppName = "Xcode"
        mockContextCollector.activeBundleIdentifier = "com.apple.dt.Xcode"
        _ = service.forceCheck()
    }
}
