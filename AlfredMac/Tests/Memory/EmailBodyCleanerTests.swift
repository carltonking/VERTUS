import XCTest
@testable import Alfred

/// Covers the quote/signature stripping (so we learn only what Carlton wrote) and the Gmail
/// watermark idempotency. The live network fetch isn't tested.
final class EmailBodyCleanerTests: XCTestCase {

    // MARK: - Quote / signature stripping

    func testStripsTopPostedReply() {
        let raw = """
        Thanks for the proposal — this looks great, let's move forward.

        On Mon, Jan 1, 2024 at 10:00 AM, Sarah Chen <sarah@example.com> wrote:
        > Here is the proposal we discussed.
        > Let me know your thoughts.
        """
        XCTAssertEqual(EmailBodyCleaner.ownTextOnly(raw),
                       "Thanks for the proposal — this looks great, let's move forward.")
    }

    func testStripsInlineQuotedLines() {
        let raw = """
        > Are we still on for Thursday?
        Yes, Thursday at 2pm works perfectly for me.
        > Should I book the room?
        I already booked it, we're all set.
        """
        XCTAssertEqual(EmailBodyCleaner.ownTextOnly(raw),
                       "Yes, Thursday at 2pm works perfectly for me.\nI already booked it, we're all set.")
    }

    func testStripsRfcSignature() {
        let raw = """
        Sounds good, I'll send the contract over tomorrow morning.

        --
        Carlton King
        Founder, Alfred
        """
        XCTAssertEqual(EmailBodyCleaner.ownTextOnly(raw),
                       "Sounds good, I'll send the contract over tomorrow morning.")
    }

    func testStripsMobileFooter() {
        let raw = "Quick note — running about ten minutes late, see you soon.\n\nSent from my iPhone"
        XCTAssertEqual(EmailBodyCleaner.ownTextOnly(raw),
                       "Quick note — running about ten minutes late, see you soon.")
    }

    func testStripsReplyAndSignatureTogether() {
        let raw = """
        Appreciate the update — let's regroup Friday to finalize the numbers.

        --
        Carlton

        On Tue, Feb 2, 2024 at 9:15 AM, Bob <bob@example.com> wrote:
        > Here are the latest figures.
        """
        XCTAssertEqual(EmailBodyCleaner.ownTextOnly(raw),
                       "Appreciate the update — let's regroup Friday to finalize the numbers.")
    }

    // MARK: - Watermark idempotency

    func testWatermarkIsIdempotent() {
        let emails = [
            GmailCapability.SentEmail(internalDate: 100, body: "a"),
            GmailCapability.SentEmail(internalDate: 300, body: "b"),
            GmailCapability.SentEmail(internalDate: 200, body: "c"),
        ]
        let watermark = GmailCapability.newWatermark(emails, current: 0)
        XCTAssertEqual(watermark, 300, "watermark is the latest internalDate")
        XCTAssertTrue(GmailCapability.emailsNewerThan(emails, watermark).isEmpty,
                      "re-running past the watermark imports nothing new")
        XCTAssertEqual(GmailCapability.emailsNewerThan(emails, 150).map(\.internalDate).sorted(),
                       [200, 300], "incremental keeps only newer-than-watermark emails")
    }
}
