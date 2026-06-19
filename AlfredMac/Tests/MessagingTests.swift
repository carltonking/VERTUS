import XCTest
@testable import Alfred

@MainActor
final class MessagingTests: XCTestCase {

    func testDetectsTextWithoutMessage() {
        XCTAssertEqual(MessagingCapability.detect(in: "text Bob"), .init(name: "Bob", message: nil))
        XCTAssertEqual(MessagingCapability.detect(in: "send a text to John Smith"),
                       .init(name: "John Smith", message: nil))
    }

    func testDetectsTextWithInlineMessage() {
        XCTAssertEqual(MessagingCapability.detect(in: "text Bob saying running late"),
                       .init(name: "Bob", message: "running late"))
        XCTAssertEqual(MessagingCapability.detect(in: "text Mom: happy birthday"),
                       .init(name: "Mom", message: "happy birthday"))
    }

    func testDetectsCommaSplit() {
        XCTAssertEqual(MessagingCapability.detect(in: "text carlton, hey"),
                       .init(name: "carlton", message: "hey"))
        XCTAssertEqual(MessagingCapability.detect(in: "text Bob, running late see you soon"),
                       .init(name: "Bob", message: "running late see you soon"))
    }

    func testIgnoresNonTextQueries() {
        XCTAssertNil(MessagingCapability.detect(in: "what is the weather"))
        XCTAssertNil(MessagingCapability.detect(in: "summarize this article"))
        XCTAssertNil(MessagingCapability.detect(in: "text"))   // no recipient
    }

    func testSplitNameMessage() {
        XCTAssertEqual(MessagingCapability.splitNameMessage("Bob").name, "Bob")
        XCTAssertNil(MessagingCapability.splitNameMessage("Bob").message)

        let withMsg = MessagingCapability.splitNameMessage("Bob saying hi there")
        XCTAssertEqual(withMsg.name, "Bob")
        XCTAssertEqual(withMsg.message, "hi there")
    }
}
