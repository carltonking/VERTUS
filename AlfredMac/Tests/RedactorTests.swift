import XCTest
@testable import Alfred

final class RedactorTests: XCTestCase {
    private let redactor = Redactor()

    func testRedactsLabelledPassword() {
        let result = redactor.redact("my password: hunter2 please")
        XCTAssertFalse(result.text.contains("hunter2"))
        XCTAssertTrue(result.text.contains("[REDACTED]"))
        XCTAssertTrue(result.didRedact)
    }

    func testRedactsSSN() {
        let result = redactor.redact("SSN 123-45-6789 on file")
        XCTAssertFalse(result.text.contains("123-45-6789"))
        XCTAssertEqual(result.redactionCount, 1)
    }

    func testRedactsCreditCard() {
        let result = redactor.redact("card 4111 1111 1111 1111 expires soon")
        XCTAssertFalse(result.text.contains("4111 1111 1111 1111"))
        XCTAssertTrue(result.didRedact)
    }

    func testLeavesCleanTextUntouched() {
        let result = redactor.redact("organize my Downloads folder by file type")
        XCTAssertEqual(result.redactionCount, 0)
        XCTAssertFalse(result.didRedact)
        XCTAssertEqual(result.text, "organize my Downloads folder by file type")
    }

    func testRedactsAcrossMessageBatch() {
        let messages: [LLMMessage] = [
            .user("here is my password: secret123"),
            .user("and my ssn 987-65-4321"),
        ]
        let out = redactor.redact(messages: messages, system: "you are helpful")
        XCTAssertEqual(out.count, 2)
        XCTAssertFalse(out.messages[0].content.contains("secret123"))
        XCTAssertFalse(out.messages[1].content.contains("987-65-4321"))
        XCTAssertEqual(out.system, "you are helpful")
    }
}
