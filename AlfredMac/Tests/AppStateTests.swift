import XCTest
@testable import Alfred

final class AppStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.alfred.app")
    }

    func testDefaultProvider() {
        let state = AppState()
        // M8 retired the bundled "local" Qwen provider; default is now groq.
        XCTAssertEqual(state.selectedProvider, "groq")
    }

    func testDefaultOwnerName() {
        let state = AppState()
        XCTAssertEqual(state.ownerName, "")
    }

    func testDefaultOnboardingComplete() {
        let state = AppState()
        XCTAssertFalse(state.isOnboardingComplete)
    }

    func testDefaultProactiveSuggestions() {
        let state = AppState()
        XCTAssertFalse(state.proactiveSuggestionsEnabled)
    }

    func testDefaultShellExecution() {
        let state = AppState()
        XCTAssertFalse(state.shellExecutionEnabled)
    }

    func testDefaultScreenContext() {
        let state = AppState()
        XCTAssertTrue(state.screenContextEnabled)
    }

    func testDefaultScreenMonitoring() {
        let state = AppState()
        XCTAssertFalse(state.screenMonitoringEnabled)
    }

    func testDefaultFocusSensitivity() {
        let state = AppState()
        XCTAssertEqual(state.focusSensitivity, "medium")
    }

    func testDefaultMemoryExtraction() {
        let state = AppState()
        XCTAssertFalse(state.memoryExtractionEnabled)
    }

    func testDefaultConversationHistory() {
        let state = AppState()
        XCTAssertTrue(state.conversationHistoryEnabled)
        XCTAssertEqual(state.memoryRetentionDays, 90)
    }

    func testDefaultProviderModels() {
        let state = AppState()
        XCTAssertEqual(state.providerModels["local"], "alfred")
        XCTAssertEqual(state.providerModels["ollama"], "phi3:mini")
        XCTAssertEqual(state.providerModels["gemini"], "gemini-2.0-flash")
        XCTAssertEqual(state.providerModels["groq"], "llama-3.3-70b-versatile")
    }

    func testSelectedModelDefaults() {
        let state = AppState()
        // No persisted model and a non-removed default provider → empty until chosen.
        XCTAssertEqual(state.selectedModel, "")
    }
}
