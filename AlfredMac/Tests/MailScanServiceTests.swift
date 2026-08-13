import XCTest
@testable import Alfred

/// Covers the deterministic halves of the folder sweep (MailScanService):
/// what `assembleSummary` derives from a fetch + classifications, which
/// messages are worth a model turn (`classificationCandidates`), and the
/// one-line summary text. No Himalaya, no Hermes, no disk.
final class MailScanServiceTests: XCTestCase {

    // MARK: - Helpers

    /// The separator MailMessage.id uses (account\u{1F}mailbox\u{1F}uid) —
    /// classification keys in the sweep are message ids, so tests must build
    /// them with the same separator or nothing matches.
    private func key(_ uid: String, mailbox: String = "Inbox") -> String {
        "icloud\u{1F}\(mailbox)\u{1F}\(uid)"
    }

    private func folder(_ name: String, role: String,
                        total: Int = 0, unseen: Int = 0, flagged: Int = 0) -> MailFolderStat {
        MailFolderStat(account: "icloud", id: name.lowercased(),
                       name: name, role: role, total: total, unseen: unseen, flagged: flagged)
    }

    private func message(_ uid: String,
                         mailbox: String = "Inbox",
                         fromName: String = "",
                         fromAddress: String = "a@example.com",
                         subject: String,
                         date: TimeInterval? = nil,
                         snippet: String = "",
                         unread: Bool = false,
                         flagged: Bool = false) -> MailMessage {
        MailMessage(
            account: "icloud",
            mailbox: mailbox,
            uid: uid,
            fromName: fromName,
            fromAddress: fromAddress,
            subject: subject,
            date: date,
            snippet: snippet,
            isUnread: unread,
            isFlagged: flagged,
            hasAttachments: false)
    }

    private func classification(label: String,
                                importance: Int? = nil,
                                category: String? = nil,
                                confidence: Double? = 0.9,
                                reason: String? = nil) -> MailClassification {
        MailClassification(
            label: label,
            tone: "Friendly",
            summary: "short summary",
            importance: importance,
            category: category,
            confidence: confidence,
            reason: reason)
    }

    // MARK: - Unread and flagged totals

    func testAssembleSummarySumsInboxUnreadAndAllFlagged() {
        let folders = [
            folder("Inbox", role: "inbox", unseen: 3, flagged: 1),
            folder("Junk", role: "junk", flagged: 2),
            folder("Archive", role: "archive", flagged: 0),
        ]
        let summary = MailScanService.assembleSummary(
            folders: folders, messages: [], classifications: [:], now: 1000)

        XCTAssertEqual(summary.unreadTotal, 3)
        XCTAssertEqual(summary.flaggedTotal, 3)
        XCTAssertEqual(summary.scannedAt, 1000)
        // Nothing classified → nothing surfaced.
        XCTAssertTrue(summary.important.isEmpty)
        XCTAssertTrue(summary.spamMiss.isEmpty)
    }

    // MARK: - Important + spam_miss

    func testImportantInboxMessageSurfacesWithHighConfidence() {
        let messages = [message("1", fromName: "Prof. Wu", subject: "Q2 deadline")]
        let classifications = [key("1"): classification(
            label: "needs_reply", importance: 5, category: "academic", confidence: 0.87)]
        let summary = MailScanService.assembleSummary(
            folders: [], messages: messages, classifications: classifications, now: 1000)

        XCTAssertEqual(summary.important.count, 1)
        XCTAssertEqual(summary.important[0].uid, "1")
        XCTAssertEqual(summary.important[0].importance, 5)
        XCTAssertEqual(summary.important[0].confidence, 0.87, accuracy: 0.001)
        XCTAssertTrue(summary.spamMiss.isEmpty)
    }

    func testImportantJunkMailBecomesSpamMiss() {
        let messages = [message("7", mailbox: "Junk", fromAddress: "registrar@nyu.edu",
                                subject: "Hold on your account")]
        let classifications = [key("7", mailbox: "Junk"): classification(
            label: "action_item", importance: 4, category: "important", confidence: 0.95)]
        let summary = MailScanService.assembleSummary(
            folders: [], messages: messages, classifications: classifications, now: 1000)

        XCTAssertTrue(summary.important.isEmpty)
        XCTAssertEqual(summary.spamMiss.count, 1)
        XCTAssertEqual(summary.spamMiss[0].mailbox, "Junk")
        XCTAssertEqual(summary.spamMiss[0].uid, "7")
    }

    func testLowImportanceMailIsNotSurfaced() {
        let messages = [message("1", fromAddress: "news@example.com", subject: "Weekly digest")]
        let classifications = [key("1"): classification(
            label: "fyi", importance: 2, category: "newsletter", confidence: 0.8)]
        let summary = MailScanService.assembleSummary(
            folders: [], messages: messages, classifications: classifications, now: 1000)

        XCTAssertTrue(summary.important.isEmpty)
        XCTAssertTrue(summary.spamMiss.isEmpty)
    }

    func testUnclassifiedMessagesAreIgnored() {
        let messages = [message("1", fromAddress: "a@x.com", subject: "Something")]
        let summary = MailScanService.assembleSummary(
            folders: [], messages: messages, classifications: [:], now: 1000)
        XCTAssertTrue(summary.important.isEmpty)
        XCTAssertTrue(summary.spamMiss.isEmpty)
    }

    func testImportantIsSortedByConfidenceAndBoundedAtEight() {
        var messages: [MailMessage] = []
        var classifications: [String: MailClassification] = [:]
        for index in 1...10 {
            let uid = "\(index)"
            messages.append(message(uid, subject: "Mail \(uid)"))
            classifications[key(uid)] = classification(
                label: "needs_reply", importance: 4, category: "important",
                confidence: Double(index) / 10.0)
        }
        let summary = MailScanService.assembleSummary(
            folders: [], messages: messages, classifications: classifications, now: 1000)

        XCTAssertEqual(summary.important.count, 8)
        XCTAssertEqual(summary.important.first?.uid, "10") // highest confidence first
    }

    // MARK: - Candidate selection

    func testCandidatesAreUnreadInboxJunkOrFlagged() {
        let candidates = MailScanService.classificationCandidates(from: [
            message("1", mailbox: "Inbox", subject: "Unread inbox", unread: true),
            message("2", mailbox: "Inbox", subject: "Read inbox"),
            message("3", mailbox: "Junk", subject: "Junk mail"),
            message("4", mailbox: "Archive", subject: "Flagged archive", flagged: true),
            message("5", mailbox: "Archive", subject: "Plain archive"),
        ])

        XCTAssertEqual(Set(candidates.map(\.uid)), Set(["1", "3", "4"]))
    }

    // MARK: - One-line summary

    func testOneLineSummarizesUnreadFlaggedAndSpamMiss() {
        let summary = EmailScanSummary(
            folders: [],
            unreadTotal: 3,
            flaggedTotal: 2,
            important: [],
            spamMiss: [
                MailScanItem(
                    account: "icloud", mailbox: "Junk", uid: "1",
                    fromName: "Prof. Wu", fromAddress: "wu@nyu.edu",
                    subject: "Q2 deadline", date: 0, snippet: "",
                    importance: 5, category: "academic",
                    confidence: 0.9, reason: "deadline"),
            ],
            scannedAt: 1000)

        let line = summary.oneLine
        XCTAssertTrue(line.contains("3 unread"), line)
        XCTAssertTrue(line.contains("2 flagged"), line)
        XCTAssertTrue(line.contains("Prof. Wu"), line)
    }

    func testOneLineIsEmptyWhenNothingNeedsAttention() {
        XCTAssertEqual(EmailScanSummary().oneLine, "Nothing needs attention.")
    }
}
