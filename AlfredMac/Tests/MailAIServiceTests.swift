import XCTest
@testable import Alfred

/// Covers the pure, deterministic parts of the mail copilot (MailAIService):
/// subject normalization, conversation grouping, and the structured search
/// filter that natural-language queries compile into. Everything here avoids
/// Hermes and the SQLite cache — no model calls, no disk.
final class MailAIServiceTests: XCTestCase {

    private func message(uid: String,
                         fromName: String = "",
                         fromAddress: String = "a@example.com",
                         subject: String,
                         date: TimeInterval? = nil,
                         snippet: String = "",
                         unread: Bool = false) -> MailMessage {
        MailMessage(
            account: "icloud",
            mailbox: "Inbox",
            uid: uid,
            fromName: fromName,
            fromAddress: fromAddress,
            subject: subject,
            date: date,
            snippet: snippet,
            isUnread: unread,
            isFlagged: false,
            hasAttachments: false)
    }

    // MARK: - Subject normalization

    func testNormalizedSubjectStripsReplyAndForwardPrefixes() {
        XCTAssertEqual(MailAIService.normalizedSubject("Re: Budget"), "Budget")
        XCTAssertEqual(MailAIService.normalizedSubject("Re: Re: Budget"), "Budget")
        XCTAssertEqual(MailAIService.normalizedSubject("Fwd: Party invite"), "Party invite")
        XCTAssertEqual(MailAIService.normalizedSubject("Budget"), "Budget")
        XCTAssertEqual(MailAIService.normalizedSubject("re:  Budget"), "Budget")
        // A subject that merely contains "re:" in a word is untouched.
        XCTAssertEqual(MailAIService.normalizedSubject("Rewrite the plan"), "Rewrite the plan")
    }

    // MARK: - Conversation grouping

    func testConversationSiblingsGroupsBySenderAndNormalizedSubject() {
        let inbox = [
            message(uid: "1", fromAddress: "sarah@x.com", subject: "Budget", date: 100),
            message(uid: "2", fromAddress: "sarah@x.com", subject: "Re: Budget", date: 200),
            message(uid: "3", fromAddress: "other@x.com", subject: "Re: Budget", date: 300),
            message(uid: "4", fromAddress: "sarah@x.com", subject: "Party", date: 400),
        ]
        let siblings = MailAIService.conversationSiblings(
            sender: "sarah@x.com", subject: "Re: Budget", in: inbox)
        // Oldest first, same sender + normalized subject only.
        XCTAssertEqual(siblings.map(\.uid), ["1", "2"])
    }

    func testConversationSiblingsAreOldestFirstAndCappedAtSix() {
        let inbox = (1...8).map { index in
            message(uid: "\(index)", fromAddress: "s@x.com",
                    subject: "Budget", date: TimeInterval(index))
        }
        let siblings = MailAIService.conversationSiblings(
            sender: "s@x.com", subject: "Budget", in: inbox)
        XCTAssertEqual(siblings.count, 6)
        XCTAssertEqual(siblings.first?.uid, "1")
        XCTAssertEqual(siblings.last?.uid, "6")
    }

    func testConversationSiblingsExcludeTheCurrentMessage() {
        let inbox = [
            message(uid: "1", fromAddress: "sarah@x.com", subject: "Budget", date: 100),
            message(uid: "2", fromAddress: "sarah@x.com", subject: "Re: Budget", date: 200),
            message(uid: "3", fromAddress: "sarah@x.com", subject: "Budget", date: 300),
        ]
        // Reading message 2 — its own envelope must not count as a sibling.
        let siblings = MailAIService.conversationSiblings(
            sender: "sarah@x.com", subject: "Re: Budget", in: inbox,
            excluding: (account: "icloud", mailbox: "Inbox", uid: "2"))
        XCTAssertEqual(siblings.map(\.uid), ["1", "3"])
    }

    func testConversationTextDoesNotDoubleCountTheCurrentMessage() {
        let inbox = [
            message(uid: "1", fromAddress: "sarah@x.com", subject: "Budget",
                    date: 100, snippet: "earlier numbers"),
            message(uid: "2", fromAddress: "sarah@x.com", subject: "Re: Budget",
                    date: 200, snippet: "new numbers"),
        ]
        let parts = EmailCapability.MessageParts(
            from: "Sarah", fromAddress: "sarah@x.com", to: [], cc: [],
            subject: "Re: Budget", date: Date(timeIntervalSince1970: 200),
            messageID: "m2", text: "Latest full text.", html: nil, attachments: [])
        let text = MailAIService.conversationText(
            for: parts, in: inbox,
            excluding: (account: "icloud", mailbox: "Inbox", uid: "2"))
        // One prior sibling + the current message = 2, not 3.
        XCTAssertTrue(text.hasPrefix("Conversation (2 messages):"), text)
        XCTAssertTrue(text.contains("earlier numbers"))
        XCTAssertFalse(text.contains("new numbers")) // the current message appears once, as full text
        XCTAssertTrue(text.contains("Latest full text."))
    }

    // MARK: - Structured search filter

    func testFilterMatchesSenderAndTerms() {
        let inbox = [
            message(uid: "1", fromName: "Sarah Lee", fromAddress: "sarah@x.com",
                    subject: "Budget review", snippet: "numbers attached"),
            message(uid: "2", fromAddress: "bob@x.com", subject: "Budget review", snippet: ""),
            message(uid: "3", fromName: "Sarah Lee", fromAddress: "sarah@x.com",
                    subject: "Lunch", snippet: ""),
        ]
        let intent = MailSearchIntent(
            sender: "sarah", terms: ["budget"], unreadOnly: false, sinceDays: nil, note: "")
        XCTAssertEqual(MailAIService.filter(inbox, intent: intent).map(\.uid), ["1"])
    }

    func testFilterUnreadOnly() {
        let inbox = [
            message(uid: "1", fromAddress: "a@x.com", subject: "Hi", unread: true),
            message(uid: "2", fromAddress: "a@x.com", subject: "Hi", unread: false),
        ]
        let intent = MailSearchIntent(
            sender: nil, terms: [], unreadOnly: true, sinceDays: nil, note: "")
        XCTAssertEqual(MailAIService.filter(inbox, intent: intent).map(\.uid), ["1"])
    }

    func testFilterSinceDaysDropsOlderMessages() {
        let now = Date().timeIntervalSince1970
        let inbox = [
            message(uid: "1", fromAddress: "a@x.com", subject: "Fresh", date: now - 86_400),
            message(uid: "2", fromAddress: "a@x.com", subject: "Old", date: now - 8 * 86_400),
        ]
        let intent = MailSearchIntent(
            sender: nil, terms: [], unreadOnly: false, sinceDays: 7, note: "")
        XCTAssertEqual(MailAIService.filter(inbox, intent: intent).map(\.uid), ["1"])
    }

    func testEmptyIntentMatchesEverything() {
        let inbox = [
            message(uid: "1", fromAddress: "a@x.com", subject: "One"),
            message(uid: "2", fromAddress: "b@x.com", subject: "Two"),
        ]
        let intent = MailSearchIntent(
            sender: nil, terms: [], unreadOnly: false, sinceDays: nil, note: "")
        XCTAssertEqual(MailAIService.filter(inbox, intent: intent).map(\.uid), ["1", "2"])
    }

    // MARK: - Draft helpers

    func testWithSignatureAppendsOnce() {
        let body = MailAIService.withSignature(
            "Thanks for the update.", signature: "\n\nCarlton\nCS @ NYU\n")
        XCTAssertEqual(body, "Thanks for the update.\n\nCarlton\nCS @ NYU")
        // Re-running (the model may have included it) doesn't double it.
        XCTAssertEqual(MailAIService.withSignature(body, signature: "Carlton\nCS @ NYU"), body)
    }

    func testWithSignatureSkipsWhenEmpty() {
        XCTAssertEqual(MailAIService.withSignature("Hi there", signature: "   "), "Hi there")
    }

    func testToneDescription() {
        XCTAssertEqual(MailAIService.toneDescription("formal"), "formal and polished")
        XCTAssertEqual(MailAIService.toneDescription("casual"), "casual and friendly")
        XCTAssertEqual(MailAIService.toneDescription("match-context"),
                       "the register the sender used in their message")
    }
}
