import GRDB
import XCTest
@testable import Alfred

/// Covers the sent-iMessage read path against a synthetic in-memory chat.db (message schema:
/// ROWID, text, attributedBody, is_from_me, associated_message_type).
final class SentMessagesTests: XCTestCase {

    private func makeChatDB() throws -> String {
        let path = NSTemporaryDirectory() + "alfred-chatdb-\(UUID().uuidString).sqlite"
        let db = try DatabaseQueue(path: path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE message (
                    ROWID INTEGER PRIMARY KEY,
                    text TEXT,
                    attributedBody BLOB,
                    is_from_me INTEGER NOT NULL,
                    associated_message_type INTEGER NOT NULL
                )
                """)
        }
        return path   // DatabaseQueue closes on deinit; sentMessages opens its own read-only handle
    }

    /// Minimal typedstream blob that `decodeAttributedBody` can parse: "NSString" + '+' + len + utf8.
    private func attributedBodyBlob(_ text: String) -> Data {
        var bytes = Array("NSString".utf8)
        bytes.append(0x2b)                  // '+'
        let utf8 = Array(text.utf8)
        bytes.append(UInt8(utf8.count))     // single-byte length (text < 128 bytes)
        bytes.append(contentsOf: utf8)
        return Data(bytes)
    }

    private func insert(_ path: String, rowid: Int64, text: String?, blob: Data? = nil,
                        isFromMe: Int, type: Int = 0) throws {
        let db = try DatabaseQueue(path: path)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO message (ROWID, text, attributedBody, is_from_me, associated_message_type)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [rowid, text, blob, isFromMe, type])
        }
    }

    func testReturnsOnlySubstantiveSentRowsAndDecodesBlob() throws {
        let path = try makeChatDB()
        try insert(path, rowid: 1, text: "Received hi how are you doing today", isFromMe: 0)             // received → excluded
        try insert(path, rowid: 2, text: "Sounds great, see you at 6 tonight!", isFromMe: 1)             // sent → included
        try insert(path, rowid: 3, text: "tapback love", isFromMe: 1, type: 2000)                        // reaction → excluded
        try insert(path, rowid: 4, text: nil, isFromMe: 1)                                               // empty → excluded
        try insert(path, rowid: 5, text: nil, blob: attributedBodyBlob("Decoded from the attributedBody blob"), isFromMe: 1)  // text null → decoded

        let sent = MessagesReadCapability.sentMessages(afterRowID: 0, limit: 100, dbPath: path)
        let texts = sent.map(\.text)

        XCTAssertEqual(sent.count, 2, "only the two substantive sent rows")
        XCTAssertTrue(texts.contains("Sounds great, see you at 6 tonight!"))
        XCTAssertTrue(texts.contains("Decoded from the attributedBody blob"), "decodes attributedBody when text is null")
        XCTAssertFalse(texts.contains { $0.hasPrefix("Received") }, "received messages excluded")
        XCTAssertFalse(texts.contains("tapback love"), "tapbacks/reactions excluded")
    }

    func testRespectsLimit() throws {
        let path = try makeChatDB()
        for i in 1...5 {
            try insert(path, rowid: Int64(i), text: "Sent message number \(i) with enough words here", isFromMe: 1)
        }
        XCTAssertEqual(MessagesReadCapability.sentMessages(afterRowID: 0, limit: 3, dbPath: path).count, 3,
                       "respects the LIMIT")
    }

    func testWatermarkIdempotency() throws {
        let path = try makeChatDB()
        for i in 1...4 {
            try insert(path, rowid: Int64(i * 10), text: "Sent message number \(i) with enough words", isFromMe: 1)
        }
        let first = MessagesReadCapability.sentMessages(afterRowID: 0, limit: 100, dbPath: path)
        let watermark = first.map(\.rowid).max() ?? 0
        XCTAssertEqual(watermark, 40)

        let again = MessagesReadCapability.sentMessages(afterRowID: watermark, limit: 100, dbPath: path)
        XCTAssertTrue(again.isEmpty, "re-running past the watermark imports nothing new")
    }
}
