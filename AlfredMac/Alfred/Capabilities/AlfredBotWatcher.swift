import Foundation

/// Text Alfred over iMessage: Carlton texts "alfred <command>" to HIMSELF (the self-chat), Alfred
/// runs it headless and replies in the same thread. Opt-in, owner-only.
///
/// SAFETY: outward/irreversible actions (send email/text) are NOT run silently under headless — they
/// require a text-confirmation round-trip ("About to email Sarah: '…' — reply 'yes' to send"). Safe
/// read/query commands run directly through AssistantCore.process(headless:).
///
/// Modeled on InboundWatcher — a `Task { while !cancelled { checkOnce; sleep } }` loop with a
/// UserDefaults ROWID cursor + one-time baseline; NOT a SafetyAuditEngine-scanned engine and no
/// stored Timer, so the startup audit stays green.
@MainActor
final class AlfredBotWatcher: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status = "iMessage bot is off."

    private let core: AssistantCore
    private let appState: AppState
    private let messaging = MessagingCapability()
    private let mailCompose = MailComposeCapability()

    private let interval: TimeInterval
    private var monitorTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private let cursorKey = "imessageBot.lastRowID"
    private let baselineKey = "imessageBot.baselined"

    /// A single pending action (owner-only, so one slot suffices) awaiting a "yes"/"no" reply.
    private enum PendingAction {
        case email(email: String, display: String, subject: String?, body: String)
        case text(handle: String, display: String, message: String)
        var prompt: String {
            switch self {
            case let .email(_, display, _, body): return "About to email \(display): \"\(body)\" — reply 'yes' to send."
            case let .text(_, display, message): return "About to text \(display): \"\(message)\" — reply 'yes' to send."
            }
        }
    }
    private var pending: PendingAction?

    /// Texts Alfred just sent into the self-chat. Its replies are is_from_me=1 too, so we skip them
    /// on the next poll — this is what stops the "reply yes" prompt being consumed as its own answer
    /// (loop-safety), on top of replies not carrying the trigger + the advancing cursor.
    private var recentBotReplies: [String] = []
    private static var didLogHint = false

    init(core: AssistantCore, appState: AppState, interval: TimeInterval = 3) {
        self.core = core
        self.appState = appState
        self.interval = interval
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Listening for \"\(trigger())\" commands in your self-chat."
        monitorTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        isActive = false
        status = "iMessage bot is off."
    }

    private func trigger() -> String {
        let t = appState.imessageBotTrigger.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "alfred" : t
    }

    // MARK: - Loop

    private func runLoop() async {
        var emptyPolls = 0
        while !Task.isCancelled {
            let didWork = await checkOnce()
            emptyPolls = didWork ? 0 : min(emptyPolls + 1, 2)
            // Idle backoff: after consecutive empty polls, poll less often (3s → up to 9s) to cut
            // steady-state chat.db reads; resets to 3s the moment a poll finds new messages.
            let sleep = interval * Double(1 + emptyPolls)
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
        }
    }

    @discardableResult
    private func checkOnce() async -> Bool {
        let ownerHandle = appState.imessageBotOwnerHandle.trimmingCharacters(in: .whitespaces)
        guard !ownerHandle.isEmpty else {
            Self.logHintOnce()
            status = "Set your iMessage address to use the bot."
            return false
        }

        // Baseline once so pre-opt-in "alfred …" messages in history aren't run.
        if !defaults.bool(forKey: baselineKey) {
            let baseline = MessagesReadCapability.currentSelfChatMaxRowID(ownerHandle: ownerHandle) ?? 0
            defaults.set(Int(baseline), forKey: cursorKey)
            defaults.set(true, forKey: baselineKey)
        }

        let cursor = Int64(defaults.integer(forKey: cursorKey))
        let messages = MessagesReadCapability.recentSelfChatMessages(ownerHandle: ownerHandle, afterRowID: cursor, limit: 20)
        guard !messages.isEmpty else { return false }

        var newCursor = cursor
        let trig = trigger()
        for msg in messages {
            newCursor = max(newCursor, msg.rowid)
            // Skip Alfred's own replies (is_from_me=1 too) so we never re-process or loop.
            if let idx = recentBotReplies.firstIndex(of: msg.text) {
                recentBotReplies.remove(at: idx)
                continue
            }
            await handle(text: msg.text, ownerHandle: ownerHandle, trigger: trig)
        }
        defaults.set(Int(newCursor), forKey: cursorKey)   // advance the cursor past this batch
        status = "Last checked \(Self.time(Date()))."
        return true
    }

    // MARK: - Command handling

    private func handle(text: String, ownerHandle: String, trigger: String) async {
        // A pending confirmation: the NEXT self-message is the answer (no trigger required).
        if let action = pending {
            pending = nil
            let reply = Self.isAffirmative(text) ? execute(action) : "Cancelled."
            send(reply, to: ownerHandle)
            return
        }

        guard let cmd = Self.parseCommand(text, trigger: trigger) else { return }   // no trigger → not a command
        guard !cmd.isEmpty else {
            send("Yes? Add a command after \"\(trigger)\".", to: ownerHandle)
            return
        }

        // Outward email → confirm before sending.
        if let intent = MailComposeCapability.detect(in: cmd) {
            guard let body = intent.body, !body.trimmingCharacters(in: .whitespaces).isEmpty else {
                send("For safety, tell me exactly what to send, e.g. \"\(trigger) email \(intent.recipient) saying <message>\".", to: ownerHandle)
                return
            }
            guard let r = await mailCompose.resolveEmail(for: intent.recipient) else {
                send("Couldn't find an email address for \"\(intent.recipient)\".", to: ownerHandle)
                return
            }
            let action = PendingAction.email(email: r.email, display: r.display, subject: intent.subject, body: body)
            pending = action
            send(action.prompt, to: ownerHandle)
            return
        }

        // Outward text → confirm before sending.
        if let intent = MessagingCapability.detect(in: cmd) {
            guard let message = intent.message, !message.trimmingCharacters(in: .whitespaces).isEmpty else {
                send("For safety, tell me exactly what to send, e.g. \"\(trigger) text \(intent.name) saying <message>\".", to: ownerHandle)
                return
            }
            guard let recipient = await messaging.resolveRecipient(for: intent.name) else {
                send("Couldn't find \"\(intent.name)\" in Contacts.", to: ownerHandle)
                return
            }
            let action = PendingAction.text(handle: recipient.handle, display: recipient.display, message: message)
            pending = action
            send(action.prompt, to: ownerHandle)
            return
        }

        // Safe read/query → run headless. iMessage can't stream, so collect and send once.
        let reply: String
        do {
            reply = try await core.process(
                query: cmd,
                ownerName: appState.ownerName,
                screenContextEnabled: false,
                shellExecutionEnabled: appState.shellExecutionEnabled,
                memoryExtractionEnabled: true,
                headless: true,
                onToken: { _ in }
            )
        } catch {
            NSLog("[AlfredBot] process failed: \(error)")
            reply = "Sorry, I hit an error handling that."
        }
        send(reply.isEmpty ? "Done." : reply, to: ownerHandle)
    }

    private func execute(_ action: PendingAction) -> String {
        switch action {
        case let .email(email, display, subject, body):
            return mailCompose.compose(to: email, display: display, subject: subject, body: body,
                                       send: true, confirmed: true)   // already confirmed via text
        case let .text(handle, display, message):
            return messaging.send(message: message, toHandle: handle) ? "Sent to \(display)." : "Couldn't send to \(display)."
        }
    }

    /// Sends a reply into the self-chat and remembers it (trimmed, to match how chat.db reads back)
    /// so the next poll skips it — this is the loop-safety guard.
    private func send(_ text: String, to ownerHandle: String) {
        let msg = String(text.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        recentBotReplies.append(msg)
        if recentBotReplies.count > 40 { recentBotReplies.removeFirst() }
        _ = messaging.send(message: msg, toHandle: ownerHandle)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Strips the trigger word from a self-message, returning the command (empty if just the trigger),
    /// or nil when the message isn't addressed to Alfred. Case-insensitive; tolerates "alfred,"/":".
    nonisolated static func parseCommand(_ text: String, trigger: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trig = trigger.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trig.isEmpty else { return nil }
        let lower = t.lowercased()
        guard lower == trig || lower.hasPrefix(trig + " ") || lower.hasPrefix(trig + ",") || lower.hasPrefix(trig + ":") else {
            return nil
        }
        let rest = t.dropFirst(trig.count).drop(while: { $0 == " " || $0 == "," || $0 == ":" })
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func isAffirmative(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let yes: Set<String> = ["yes", "y", "yeah", "yep", "yup", "sure", "ok", "okay",
                                "send", "send it", "do it", "confirm", "go", "go ahead", "please do"]
        return yes.contains(t)
    }

    /// True when a command is an outward comms action that must be text-confirmed before running.
    static func isOutwardAction(_ cmd: String) -> Bool {
        MailComposeCapability.detect(in: cmd) != nil || MessagingCapability.detect(in: cmd) != nil
    }

    private static func logHintOnce() {
        guard !didLogHint else { return }
        didLogHint = true
        // Full Disk Access (read chat.db) + Automation for Messages (send) + a configured handle.
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: d)
    }
}
