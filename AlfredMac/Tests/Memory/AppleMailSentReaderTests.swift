import XCTest
@testable import Alfred

/// Covers the pure pieces of the Apple Mail sent-mail reader: the delimited-output parser, the
/// Gmail-account skip predicate, and the seen-set de-dup. The live Mail/osascript call isn't tested.
final class AppleMailSentReaderTests: XCTestCase {

    private let US = AppleMailSentReader.unitSep
    private let RS = AppleMailSentReader.recordSep

    // MARK: - Parser

    func testParsesWellFormedRecords() {
        let out = "a@icloud.com\(US)id-1\(US)Hello there, hope you are well.\(RS)"
                + "a@icloud.com\(US)id-2\(US)Second message body here.\(RS)"
        let recs = AppleMailSentReader.parse(out)
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0], .init(accountEmail: "a@icloud.com", id: "id-1",
                                      body: "Hello there, hope you are well."))
        XCTAssertEqual(recs[1].id, "id-2")
    }

    func testPreservesNewlinesInBody() {
        let recs = AppleMailSentReader.parse("a@icloud.com\(US)id-1\(US)Line one.\nLine two.\(RS)")
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].body, "Line one.\nLine two.")
    }

    func testSkipsMalformedRecords() {
        let out = "onlytwo\(US)fields\(RS)"               // 2 fields → skip
                + "a@x.com\(US)\(US)empty id body\(RS)"    // empty id → skip
                + "a@x.com\(US)id-3\(US)good body\(RS)"    // valid
        XCTAssertEqual(AppleMailSentReader.parse(out).map(\.id), ["id-3"])
    }

    // MARK: - Gmail skip predicate

    func testGmailSkipPredicate() {
        XCTAssertTrue(AppleMailSentReader.isGmailAccount(email: "carlton@gmail.com"))
        XCTAssertTrue(AppleMailSentReader.isGmailAccount(email: "Carlton@GMAIL.com"))
        XCTAssertTrue(AppleMailSentReader.isGmailAccount(email: "x@googlemail.com"))
        XCTAssertFalse(AppleMailSentReader.isGmailAccount(email: "carlton@icloud.com"))
        XCTAssertFalse(AppleMailSentReader.isGmailAccount(email: "carlton@company.com"))
    }

    // MARK: - Seen-set de-dup

    func testFilterUnseenDedup() {
        let recs = [
            AppleMailSentReader.Record(accountEmail: "a@icloud.com", id: "id-1", body: "b1"),
            AppleMailSentReader.Record(accountEmail: "a@icloud.com", id: "id-2", body: "b2"),
        ]
        XCTAssertEqual(AppleMailSentReader.filterUnseen(recs, seen: []).count, 2)
        XCTAssertEqual(AppleMailSentReader.filterUnseen(recs, seen: ["id-1"]).map(\.id), ["id-2"])
        XCTAssertTrue(AppleMailSentReader.filterUnseen(recs, seen: ["id-1", "id-2"]).isEmpty,
                      "re-run imports nothing new")
    }
}
