import XCTest
@testable import Alfred

@MainActor
final class MailComposeTests: XCTestCase {

    func testDraftToAddressWithSubject() {
        let intent = MailComposeCapability.detect(in: "draft an email to john@x.com about the meeting")
        XCTAssertEqual(intent, .init(recipient: "john@x.com", subject: "the meeting", body: nil, send: false))
    }

    func testEmailNameWithSubjectAndBody() {
        let intent = MailComposeCapability.detect(in: "email mom about dinner saying I'll be late")
        XCTAssertEqual(intent, .init(recipient: "mom", subject: "dinner", body: "I'll be late", send: false))
    }

    func testSendFlagOnlyWhenExplicit() {
        XCTAssertEqual(MailComposeCapability.detect(in: "send an email to bob saying thanks"),
                       .init(recipient: "bob", subject: nil, body: "thanks", send: true))
        // "draft" keeps it a draft even though the word order is similar.
        XCTAssertEqual(MailComposeCapability.detect(in: "draft an email to bob saying thanks")?.send, false)
    }

    func testIgnoresNonEmailQueries() {
        XCTAssertNil(MailComposeCapability.detect(in: "what is the weather"))
        XCTAssertNil(MailComposeCapability.detect(in: "text bob hi"))
    }

    func testParseRecipientOnly() {
        let (recipient, subject, body) = MailComposeCapability.parse("sarah@work.com")
        XCTAssertEqual(recipient, "sarah@work.com")
        XCTAssertNil(subject)
        XCTAssertNil(body)
    }
}
