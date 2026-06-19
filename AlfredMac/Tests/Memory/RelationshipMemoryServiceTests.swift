import XCTest
@testable import Alfred

final class RelationshipMemoryServiceTests: XCTestCase {
    var mockStore: MockRelationshipMemoryStore!
    var service: RelationshipMemoryService!

    override func setUp() {
        super.setUp()
        mockStore = MockRelationshipMemoryStore()
        service = RelationshipMemoryService(store: mockStore)
    }

    func testInitialState() {
        XCTAssertTrue(service.relationshipMemories().isEmpty)
    }

    func testForceSaveAddsMemory() {
        service.forceSave("Test goal", category: .goals, source: "test")
        let mems = service.relationshipMemories()
        XCTAssertEqual(mems.count, 1)
        // forceSave normalizes content (trims + lowercases), see testForceSaveNormalizesContent.
        XCTAssertEqual(mems.first?.content, "test goal")
        XCTAssertEqual(mems.first?.category, .goals)
    }

    func testForceSaveNormalizesContent() {
        service.forceSave("  Hello World  ", category: .preferences, source: "test")
        let mem = service.relationshipMemories().first
        XCTAssertEqual(mem?.content, "hello world")
    }

    func testForceSaveDeduplicates() {
        service.forceSave("same content", category: .goals, source: "test")
        service.forceSave("same content", category: .goals, source: "test")
        XCTAssertEqual(service.relationshipMemories().count, 1)
    }

    func testConsiderMentionWithLowFrequencyDoesNotSave() {
        service.considerMention("random thought", category: .preferences, source: "test")
        XCTAssertTrue(service.relationshipMemories().isEmpty)
    }

    func testMemoryById() {
        let id = UUID()
        service.forceSave("test", category: .goals, source: "test", importance: 0.5)
        let saved = service.relationshipMemories().first!
        let fetched = service.memory(by: saved.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, saved.id)
    }

    func testMemoryByIdNotFound() {
        XCTAssertNil(service.memory(by: UUID()))
    }

    func testTopGoalsReturnsCorrectCategory() {
        service.forceSave("Goal 1", category: .goals, source: "test")
        service.forceSave("Skill 1", category: .skills, source: "test")
        let goals = service.topGoals(limit: 5)
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals.first?.category, .goals)
    }

    func testTopGoalsReturnsLimited() {
        for i in 1...5 {
            service.forceSave("Goal \(i)", category: .goals, source: "test")
        }
        XCTAssertEqual(service.topGoals(limit: 3).count, 3)
    }

    func testRelevantMemoriesByKeyword() {
        service.forceSave("Swift programming", category: .skills, source: "test")
        service.forceSave("Python scripting", category: .skills, source: "test")
        let relevant = service.relevantMemories(for: "swift", limit: 5)
        XCTAssertEqual(relevant.count, 1)
        XCTAssertTrue(relevant.first?.content.lowercased().contains("swift") ?? false)
    }

    func testRelevantMemoriesEmptyForNoMatch() {
        service.forceSave("Swift programming", category: .skills, source: "test")
        let relevant = service.relevantMemories(for: "ruby", limit: 5)
        XCTAssertTrue(relevant.isEmpty)
    }

    func testArchiveMemory() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.archiveMemory(id: mem.id)
        XCTAssertTrue(service.relationshipMemories().isEmpty)
        XCTAssertEqual(service.allMemoriesIncludingArchived().count, 1)
    }

    func testRestoreMemory() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.archiveMemory(id: mem.id)
        service.restoreMemory(id: mem.id)
        XCTAssertEqual(service.relationshipMemories().count, 1)
    }

    func testDeleteMemory() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.forgetMemory(id: mem.id)
        XCTAssertTrue(service.allMemoriesForAnalysis().isEmpty)
    }

    func testBulkDelete() {
        service.forceSave("a", category: .goals, source: "test")
        service.forceSave("b", category: .goals, source: "test")
        let ids = service.relationshipMemories().map { $0.id }
        service.bulkDelete(ids: ids)
        XCTAssertTrue(service.relationshipMemories().isEmpty)
    }

    func testForgetCategory() {
        service.forceSave("goal", category: .goals, source: "test")
        service.forceSave("skill", category: .skills, source: "test")
        service.forgetCategory(.goals)
        let mems = service.allMemoriesForAnalysis()
        XCTAssertEqual(mems.count, 1)
        XCTAssertEqual(mems.first?.category, .skills)
    }

    func testSetManualImportance() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.setManualImportance(id: mem.id, value: 0.9)
        let updated = service.memory(by: mem.id)
        XCTAssertEqual(updated?.effectiveImportance, 0.9)
        XCTAssertTrue(updated?.manualOverride ?? false)
    }

    func testAdjustManualImportance() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.adjustManualImportance(id: mem.id, delta: 0.2)
        let updated = service.memory(by: mem.id)
        XCTAssertGreaterThan(updated?.effectiveImportance ?? 0, 0.5)
    }

    func testResetManualOverride() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.setManualImportance(id: mem.id, value: 0.9)
        service.resetManualOverride(id: mem.id)
        let updated = service.memory(by: mem.id)
        XCTAssertFalse(updated?.manualOverride ?? true)
    }

    func testRecordCorrection() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        let oldImportance = mem.importance
        service.recordCorrection(for: mem.id)
        let updated = service.memory(by: mem.id)
        XCTAssertGreaterThan(updated?.importance ?? 0, oldImportance)
        XCTAssertNotNil(updated?.correctedAt)
    }

    func testRecordReference() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.recordReference(to: mem.id)
        let updated = service.memory(by: mem.id)
        XCTAssertEqual(updated?.mentionCount, 2)
    }

    func testMemoriesMentioningTool() {
        service.forceSave("Working with Xcode", category: .preferences, source: "test")
        service.forceSave("Python in VSCode", category: .preferences, source: "test")
        let xcodeMems = service.memoriesMentioningTool("xcode")
        XCTAssertEqual(xcodeMems.count, 1)
    }

    func testExportToJSON() {
        service.forceSave("test", category: .goals, source: "test")
        let json = service.exportToJSON()
        XCTAssertNotNil(json)
        XCTAssertTrue(json?.contains("test") ?? false)
    }

    func testImportFromJSON() {
        service.forceSave("existing", category: .goals, source: "test")
        let json = service.exportToJSON()!
        let newService = RelationshipMemoryService(store: MockRelationshipMemoryStore())
        let success = newService.importFromJSON(json)
        XCTAssertTrue(success)
        XCTAssertEqual(newService.relationshipMemories().count, 1)
    }

    func testImportFromJSONInvalid() {
        let success = service.importFromJSON("not json")
        XCTAssertFalse(success)
    }

    func testResetRelationshipMemory() {
        service.forceSave("test", category: .goals, source: "test")
        service.resetRelationshipMemory()
        XCTAssertTrue(service.allMemoriesForAnalysis().isEmpty)
    }

    func testUpdateMemoryContent() {
        service.forceSave("original", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.updateMemoryContent(id: mem.id, content: "updated")
        let updated = service.memory(by: mem.id)
        XCTAssertEqual(updated?.content, "updated")
    }

    func testUpdateMemoryCategory() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.updateMemoryCategory(id: mem.id, category: .skills)
        let updated = service.memory(by: mem.id)
        XCTAssertEqual(updated?.category, .skills)
    }

    func testPromptInjection() {
        service.forceSave("important goal", category: .goals, source: "test", importance: 0.9)
        let prompt = service.promptInjection()
        XCTAssertTrue(prompt.contains("WHAT I KNOW ABOUT YOU"))
        XCTAssertTrue(prompt.contains("important goal"))
    }

    func testPromptInjectionEmptyForNoMemories() {
        let prompt = service.promptInjection()
        XCTAssertEqual(prompt, "")
    }

    func testMemoriesReferencedBetween() {
        let oldDate = Date().addingTimeInterval(-86400 * 10)
        let mem = TestFactories.makeMemory(createdAt: oldDate, lastReferenced: oldDate)
        mockStore.memories = [mem]
        service = RelationshipMemoryService(store: mockStore)

        let recent = service.memoriesReferencedBetween(since: Date().addingTimeInterval(-86400 * 2))
        XCTAssertTrue(recent.isEmpty)

        let old = service.memoriesReferencedBetween(since: Date().addingTimeInterval(-86400 * 20), until: Date())
        XCTAssertEqual(old.count, 1)
    }

    func testSaveCalledOnForceSave() {
        XCTAssertEqual(mockStore.saveCallCount, 0)
        service.forceSave("test", category: .goals, source: "test")
        XCTAssertGreaterThanOrEqual(mockStore.saveCallCount, 1)
    }

    func testLoadCalledOnInit() {
        XCTAssertEqual(mockStore.loadCallCount, 1)
    }

    func testAllMemoriesIncludingArchived() {
        service.forceSave("active", category: .goals, source: "test")
        service.forceSave("archived", category: .goals, source: "test")
        let archived = service.relationshipMemories().last!
        service.archiveMemory(id: archived.id)
        let all = service.allMemoriesIncludingArchived()
        XCTAssertEqual(all.count, 2)
    }

    func testBulkArchive() {
        service.forceSave("a", category: .goals, source: "test")
        service.forceSave("b", category: .goals, source: "test")
        let ids = service.relationshipMemories().map { $0.id }
        service.bulkArchive(ids: ids)
        XCTAssertTrue(service.relationshipMemories().isEmpty)
    }

    func testExportArchivedToJSON() {
        service.forceSave("test", category: .goals, source: "test")
        let mem = service.relationshipMemories().first!
        service.archiveMemory(id: mem.id)
        let json = service.exportArchivedToJSON()
        XCTAssertNotNil(json)
        XCTAssertTrue(json?.contains("test") ?? false)
    }
}
