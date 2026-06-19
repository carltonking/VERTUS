import XCTest
@testable import Alfred

final class MockProvider: LLMProvider {
    var id: String { "mock" }
    var displayName: String { "Mock" }
    var model: String = "mock-model"

    var completeCallCount = 0
    var streamCallCount = 0

    func complete(messages: [LLMMessage], system: String) async throws -> String {
        completeCallCount += 1
        return "mock response"
    }

    func stream(messages: [LLMMessage], system: String, onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        streamCallCount += 1
        onToken("mock ")
        onToken("response")
        return "mock response"
    }
}

final class LLMProviderTests: XCTestCase {
    func testCompletePromptConvenienceDelegates() async throws {
        let provider = MockProvider()
        let result = try await provider.complete(prompt: "hello")
        XCTAssertEqual(result, "mock response")
        XCTAssertEqual(provider.completeCallCount, 1)
    }

    func testCompletePromptWithSystem() async throws {
        let provider = MockProvider()
        let result = try await provider.complete(prompt: "hello", system: "be helpful")
        XCTAssertEqual(result, "mock response")
        XCTAssertEqual(provider.completeCallCount, 1)
    }

    func testStreamPromptConvenienceDelegates() async throws {
        let provider = MockProvider()
        var tokens: [String] = []
        let result = try await provider.stream(prompt: "hello") { token in
            tokens.append(token)
        }
        XCTAssertEqual(result, "mock response")
        XCTAssertEqual(tokens, ["mock ", "response"])
        XCTAssertEqual(provider.streamCallCount, 1)
    }

    func testStreamPromptWithSystem() async throws {
        let provider = MockProvider()
        var tokens: [String] = []
        let result = try await provider.stream(prompt: "hello", system: "be concise") { token in
            tokens.append(token)
        }
        XCTAssertEqual(result, "mock response")
        XCTAssertEqual(provider.streamCallCount, 1)
    }
}
