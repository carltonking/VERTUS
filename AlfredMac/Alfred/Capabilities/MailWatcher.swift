import AppKit
import Foundation
import UserNotifications

// MARK: - Classification

enum MailClassificationError: LocalizedError {
    case busy
    case badResponse

    var errorDescription: String? {
        switch self {
        case .busy: return "Advanced: a conversation is already streaming."
        case .badResponse: return "Mail classification returned an unreadable response."
        }
    }
}

/// Decides whether an email is important and warrants a reply.
///
/// The triage is routed through the same long-lived `HermesSession` the bar
/// uses, so Alfred has exactly one credential stack and the model the user
/// actually picked with `hermes model` does the judging. It is a single
/// tool-free prompt that must answer in one JSON object.
///
/// Guard rails:
///   * The watcher checks `isTurnActive` first. If the bar (or the phone relay)
///     is mid-response it backs off and lets the next sweep pick the mail up
///     again — classification never cuts across a conversation the user is
///     watching.
///   * The prompt hard-bans tool use. The point is triage, not taking action.
struct MailClassifier {

    struct Decision: Decodable {
        let important: Bool
        let replyNeeded: Bool
        let summary: String
    }

    /// Run one triage turn against the session and parse the JSON verdict.
    /// Returns nil when the model's answer can't be parsed (not fatal).
    static func classify(emailText: String, via session: HermesSession) async throws -> Decision? {
        guard !(await session.isTurnActive) else { throw MailClassificationError.busy }

        let room = 3000
        let trimmed = String(emailText.prefix(room))
        let prompt = """
        You triage a person's email. You accept the email below and must respond \
        with JSON only — no prose, no markdown fences, no tools. Do not call any \
        tool. The JSON:
        {"important": bool, "replyNeeded": bool, "summary": "string"}
        - important: true only if this needs a person's attention (meetings, requests, \
        deadlines, personal contacts). False for spam, receipts, statements, newsletters, \
        marketing, automatic notifications.
        - replyNeeded: true only if the sender is expecting the person to reply back.
        - summary: a short phrase (under 10 words) naming what the sender wants, e.g. \
        "wants to reschedule lunch on Thursday" or "asks for the quarterly numbers by Friday".

        Email:
        \(trimmed)
        """

        var transcript = ""
        // capture: false — mail triage is a system turn, not a user exchange.
        for await event in await session.prompt(prompt, capture: false) {
            if case let .text(chunk) = event {
                transcript.append(chunk)
            }
            if case .failed = event {
                throw MailClassificationError.badResponse
            }
        }

        let cleaned = transcript
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONDecoder().decode(Decision.self, from: Data(cleaned.utf8))
    }
}

// MARK: - Watcher

/// Watches the Inbox for new mail and delivers a notification when something
/// important arrives.
///
///     [timer] → latestEnvelopes → new ids? → readMessage → classify → UNNotification
///
/// Two decisions keep this from being another pull-spam engine:
///
///   * **Baseline first.** The first run records the current inbox as already
///     seen, so turning this on doesn't re-notify you for the mail you already
///     have. Only mail that arrives afterwards is eligible.
///   * **Classify, don't announce.** A new envelope only produces a
///     notification when the model says it's important AND naturally expects a
///     reply. Reading the subject line alone can't tell those apart — hence the
///     tiny API call.
///
/// Tap handling lives in AppDelegate (open the bar with the full message); this
/// class only decides and delivers. It reads Date history from UserDefaults —
/// set of "seen" message ids — so it's crash-safe and survives restarts.
final class MailWatcher {

    static let shared = MailWatcher()

    private static let seenKey = "mailWatcher.seenIDs"
    private static let baselinedKey = "mailWatcher.baselined"
    private static let pollInterval: TimeInterval = 60

    /// The agent session that both classifies and (eventually) replies. Exposed
    /// for the app to hand over its own session at launch.
    weak var hermes: HermesSession?

    private var timer: Timer?

    private init() {}

    // MARK: - Lifecycle

    /// Ask for notification permission (idempotent) and start polling.
    func start() {
        requestAuthorization()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()   // immediate first sweep (baseline)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("[mailalerts] notification permission failed: %@", error.localizedDescription)
            } else if granted {
                NSLog("[mailalerts] notification permission granted")
            }
        }
    }

    // MARK: - Poll

    private func poll() {
        Task { await self.pollOnce() }
    }

    private func pollOnce() async {
        let envelopes: [EmailCapability.MailEnvelope]
        do {
            envelopes = try EmailCapability.shared.latestEnvelopes(
                account: "icloud", mailbox: "Inbox", limit: 50)
        } catch {
            NSLog("[mail] envelope list failed: %@", error.localizedDescription)
            return
        }
        guard !envelopes.isEmpty else { return }

        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])

        // First sweep: remember everything currently in the inbox and leave it
        // alone. This is what makes the watcher usable from day one.
        if !UserDefaults.standard.bool(forKey: Self.baselinedKey) {
            seen.formUnion(envelopes.map(\.id))
            Self.save(seen)
            UserDefaults.standard.set(true, forKey: Self.baselinedKey)
            NSLog("[mail] baselined inbox with %d messages", envelopes.count)
            return
        }

        let newOnes = envelopes.filter { !seen.contains($0.id) && $0.isUnread }
        guard !newOnes.isEmpty else { return }

        // Remember everything seen this sweep even if classification fails, so a
        // malformed message doesn't get re-classified forever.
        seen.formUnion(envelopes.map(\.id))
        Self.save(seen)

        // One notification per sweep even if a burst of important mail lands —
        // the bar is the place for the rest, not the notification centre.
        for envelope in newOnes.prefix(5) {
            guard let session = self.hermes else {
                NSLog("[mail] no hermes session — skipping classification")
                break
            }
            if await session.isTurnActive {
                // The user (or the phone relay) is mid-reply; don't cut across a
                // conversation someone is watching. The msg is already marked seen
                // above, so we won't nag twice — the next envelope that qualifies
                // takes its place on the next sweep.
                NSLog("[mail] already streaming — deferring classification")
                break
            }
            guard let text = try? EmailCapability.shared.readMessage(
                id: envelope.id, account: "icloud", mailbox: "Inbox")
            else { continue }

            let decision: MailClassifier.Decision?
            do {
                decision = try await MailClassifier.classify(emailText: text, via: session)
            } catch {
                NSLog("[mail] classify of %@ failed: %@", envelope.id, error.localizedDescription)
                continue
            }
            guard let decision, decision.important, decision.replyNeeded else { continue }

            let senderName = envelope.fromName?.isEmpty == false
                ? envelope.fromName!
                : envelope.fromEmail
            deliver(title: "Email from \\(senderName)", summary: decision.summary, envelope: envelope)
        }
    }

    private static func save(_ seen: Set<String>) {
        UserDefaults.standard.set(Array(seen.sorted()), forKey: seenKey)
    }

    // MARK: - Deliver

    private func deliver(title senderName: String, summary: String, envelope: EmailCapability.MailEnvelope) {
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = "\(summary). Want me to respond?"
        content.userInfo = [
            "mailMessageID": envelope.id,
            "mailSender": senderName,
            "mailSubject": envelope.subject ?? "",
        ]
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "mail-\(envelope.id)",
            content: content,
            trigger: nil)   // deliver now

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[mail] could not post notification for %@: %@", envelope.id, error.localizedDescription)
            }
        }
    }
}