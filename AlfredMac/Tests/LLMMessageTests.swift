import XCTest
@testable import Alfred

final class LLMMessageTests: XCTestCase {
    func testUserMessage() {
        let msg = LLMMessage.user("hello")
        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "hello")
        XCTAssertNil(msg.imageBase64)
        XCTAssertNil(msg.imageMediaType)
    }

    func testAssistantMessage() {
        let msg = LLMMessage.assistant("hi there")
        XCTAssertEqual(msg.role, "assistant")
        XCTAssertEqual(msg.content, "hi there")
    }

    func testUserMessageWithImage() {
        let b64 = "aW1hZ2U="
        let msg = LLMMessage.user("image attached", imageBase64: b64, imageMediaType: "image/png")
        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "image attached")
        XCTAssertEqual(msg.imageBase64, b64)
        XCTAssertEqual(msg.imageMediaType, "image/png")
    }

    func testUserMessageWithImageDefaultsToJPEG() {
        let msg = LLMMessage.user("pic", imageBase64: "abcd")
        XCTAssertEqual(msg.imageMediaType, "image/jpeg")
    }

    func testCodableRoundTrip() throws {
        let original = LLMMessage.user("hello", imageBase64: "xyz", imageMediaType: "image/jpeg")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testCodableWithoutImage() throws {
        let original = LLMMessage.assistant("just text")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testLLMErrorInvalidKey() {
        let err = LLMError.invalidKey
        XCTAssertEqual(err.errorDescription, "Invalid or missing API key.")
        XCTAssertEqual(err.localizedDescription, "Invalid or missing API key.")
    }

    func testLLMErrorRateLimited() {
        let err = LLMError.rateLimited()
        XCTAssertEqual(err.errorDescription, "Rate limit reached. Try again shortly.")
    }

    func testLLMErrorNetworkError() {
        let err = LLMError.networkError("timeout")
        XCTAssertEqual(err.errorDescription, "Network error: timeout")
    }

    func testLLMErrorUnsupported() {
        let err = LLMError.unsupported
        XCTAssertEqual(err.errorDescription, "Operation not supported by this provider.")
    }
}
