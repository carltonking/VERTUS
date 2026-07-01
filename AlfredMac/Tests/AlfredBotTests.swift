import GRDB
import XCTest
@testable import Alfred

/// Covers the iMessage bot's testable pieces: self-chat detection on a synthetic chat.db, cursor
/// idempotency, trigger parsing + loop-safety, and the confirmation state machine. The live poll
/// loop / AppleScript send / AssistantCore.process aren't unit-tested.
@MainActor
final class AlfredBotTests: XCTestCase {

    // Synthetic chat.db mirroring the real join schema.
    private func makeChatDB(owner: String) throws -> String {
        let path = NSTemporaryDirectory() + "alfred-bot-\(UUID().uuidString).sqlite"
        let db = try DatabaseQueue(path: path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
            try db.execute(sql: "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT)")
            try db.execute(sql: "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)")
            try db.execute(sql: "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
            try db.execute(sql: """
                CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB,
                    is_from_me INTEGER NOT NULL, associated_message_type INTEGER NOT NULL, handle_id INTEGER)
                """)
            // handle 1 = owner (self), handle 2 = someone else
            try db.execute(sql: "INSERT INTO handle (ROWID, id) VALUES (1, ?), (2, 'sarah@example.com')", arguments: [owner])
            // chat 1 = self-chat (only the owner), chat 2 = a 1:1 with Sarah
            try db.execute(sql: "INSERT INTO chat (ROWID, chat_identifier) VALUES (1, ?), (2, 'sarah@example.com')", arguments: [owner])
            try db.execute(sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1), (2, 2)")
            try db.execute(sql: """
                INSERT INTO message (ROWID, text, is_from_me, associated_message_type) VALUES
                (10, 'alfred status', 1, 0),
                (11, 'hey how are you', 1, 0),
                (12, 'a received message', 0, 0),
                (13, 'alfred what time is it', 1, 0),
                (14, 'tapback', 1, 2000),
                (15, 'Sent to Sarah.', 1, 0)
                """)
            try db.execute(sql: """
                INSERT INTO chat_message_join (chat_id, message_id) VALUES
                (1, 10), (2, 11), (1, 12), (1, 13), (1, 14), (1, 15)
                """)
        }
        return path
    }

    func testSelfChatReturnsOnlyOwnerSelfChatRealMessages() throws {
        let owner = "owner@icloud.com"
        let path = try makeChatDB(owner: owner)
        let msgs = MessagesReadCapability.selfChatMessages(ownerHandle: owner, afterRowID: 0, limit: 100, dbPath: path)
        // 10, 13, 15 (self-chat, is_from_me=1, real). Excludes 11 (other chat), 12 (received), 14 (tapback).
        XCTAssertEqual(msgs.map(\.rowid), [10, 13, 15])
    }

    func testIgnoresGroupChatContainingOwner() throws {
        // A group chat that also contains the owner must NOT be treated as the self-chat.
        let owner = "owner@icloud.com"
        let path = try makeChatDB(owner: owner)
        let db = try DatabaseQueue(path: path)
        try db.write { db in
            try db.execute(sql: "INSERT INTO chat (ROWID, chat_identifier) VALUES (3, 'group')")
            try db.execute(sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (3, 1), (3, 2)")  // owner + sarah
            try db.execute(sql: "INSERT INTO message (ROWID, text, is_from_me, associated_message_type) VALUES (20, 'alfred group cmd', 1, 0)")
            try db.execute(sql: "INSERT INTO chat_message_join (chat_id, message_id) VALUES (3, 20)")
        }
        let msgs = MessagesReadCapability.selfChatMessages(ownerHandle: owner, afterRowID: 0, limit: 100, dbPath: path)
        XCTAssertFalse(msgs.map(\.rowid).contains(20), "group chat with the owner isn't the self-chat")
    }

    func testCursorIdempotency() throws {
        let owner = "owner@icloud.com"
        let path = try makeChatDB(owner: owner)
        let first = MessagesReadCapability.selfChatMessages(ownerHandle: owner, afterRowID: 0, limit: 100, dbPath: path)
        let maxRow = first.map(\.rowid).max() ?? 0
        XCTAssertTrue(MessagesReadCapability.selfChatMessages(ownerHandle: owner, afterRowID: maxRow, limit: 100, dbPath: path).isEmpty,
                      "re-running past the cursor reprocesses nothing")
    }

    // MARK: - Trigger parsing + loop-safety

    func testTriggerParsing() {
        XCTAssertEqual(AlfredBotWatcher.parseCommand("alfred status", trigger: "alfred"), "status")
        XCTAssertEqual(AlfredBotWatcher.parseCommand("Alfred, what time is it", trigger: "alfred"), "what time is it")
        XCTAssertEqual(AlfredBotWatcher.parseCommand("alfred", trigger: "alfred"), "")   // trigger only
        XCTAssertNil(AlfredBotWatcher.parseCommand("hey there", trigger: "alfred"))
    }

    func testReplyShapedMessageIsNotACommand() {
        // Alfred's own replies don't carry the trigger → never reprocessed as commands (loop-safety).
        XCTAssertNil(AlfredBotWatcher.parseCommand("Sent to Sarah.", trigger: "alfred"))
        XCTAssertNil(AlfredBotWatcher.parseCommand("About to email Sarah: \"hi\" — reply 'yes' to send.", trigger: "alfred"))
    }

    // MARK: - Confirmation state machine

    func testDestructiveCommandsAreOutward() {
        XCTAssertTrue(AlfredBotWatcher.isOutwardAction("email sarah saying I'll be late"))
        XCTAssertTrue(AlfredBotWatcher.isOutwardAction("text bob saying on my way"))
        XCTAssertFalse(AlfredBotWatcher.isOutwardAction("what time is it in tokyo"))
        XCTAssertFalse(AlfredBotWatcher.isOutwardAction("summarize my last note"))
    }

    func testAffirmativeExecutesOthersCancel() {
        XCTAssertTrue(AlfredBotWatcher.isAffirmative("yes"))
        XCTAssertTrue(AlfredBotWatcher.isAffirmative("send it"))
        XCTAssertTrue(AlfredBotWatcher.isAffirmative("YES"))
        XCTAssertFalse(AlfredBotWatcher.isAffirmative("no"))
        XCTAssertFalse(AlfredBotWatcher.isAffirmative("maybe later"))
        XCTAssertFalse(AlfredBotWatcher.isAffirmative("actually hold off"))
    }
}
