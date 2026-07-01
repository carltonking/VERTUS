import XCTest
@testable import Alfred

/// Covers the Telegram bot's pure pieces: getUpdates JSON parsing, owner-only filtering, offset
/// advancement, and reply splitting. Live network calls aren't unit-tested.
@MainActor
final class TelegramBotTests: XCTestCase {

    private let sampleJSON = """
    {
      "ok": true,
      "result": [
        { "update_id": 100, "message": { "text": "what time is it", "chat": { "id": 555 } } },
        { "update_id": 101, "message": { "text": "email sarah saying hi", "chat": { "id": 555 } } },
        { "update_id": 102, "message": { "text": "spam from a stranger", "chat": { "id": 999 } } },
        { "update_id": 103, "edited_message": { "text": "no message key", "chat": { "id": 555 } } }
      ]
    }
    """.data(using: .utf8)!

    func testDecodeAndOwnerFilter() {
        let updates = TelegramBotService.decodeUpdates(sampleJSON)
        XCTAssertEqual(updates?.count, 4)

        let owner = TelegramBotService.ownerMessages(from: updates!, ownerChatID: "555")
        // 100 & 101 (owner text messages). 102 is another chat; 103 has no `message` (edited_message).
        XCTAssertEqual(owner.map(\.updateId), [100, 101])
        XCTAssertEqual(owner.map(\.text), ["what time is it", "email sarah saying hi"])
    }

    func testNonOwnerIgnored() {
        let updates = TelegramBotService.decodeUpdates(sampleJSON)!
        XCTAssertEqual(TelegramBotService.ownerMessages(from: updates, ownerChatID: "999").map(\.text),
                       ["spam from a stranger"])
        XCTAssertTrue(TelegramBotService.ownerMessages(from: updates, ownerChatID: "123").isEmpty,
                      "no updates from an unknown chat")
    }

    func testOffsetAdvances() {
        let updates = TelegramBotService.decodeUpdates(sampleJSON)!
        // max(update_id) + 1, regardless of owner filtering (all updates are ack'd).
        XCTAssertEqual(TelegramBotService.nextOffset(from: updates, current: 100), 104)
        // Idempotency: with no new updates the offset holds, so a restart won't reprocess.
        XCTAssertEqual(TelegramBotService.nextOffset(from: [], current: 104), 104)
    }

    func testSplitReply() {
        XCTAssertEqual(TelegramBotService.splitReply(""), [])
        XCTAssertEqual(TelegramBotService.splitReply("short reply"), ["short reply"])

        let long = String(repeating: "a", count: 9001)   // no break points → hard splits
        let chunks = TelegramBotService.splitReply(long)
        XCTAssertTrue(chunks.count >= 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 4000 }, "each chunk within Telegram's limit")
        XCTAssertEqual(chunks.joined().count, 9001, "no content lost")
    }
}
