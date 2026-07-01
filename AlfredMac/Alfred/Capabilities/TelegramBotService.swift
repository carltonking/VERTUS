import Foundation

/// Text Alfred over Telegram — a dedicated bot contact via the official Bot API. Cleaner than the
/// iMessage self-thread bot: a real separate contact (no double-bubble), instant long-poll delivery
/// (no chat.db polling), and direct HTTPS replies (no AppleScript). Opt-in, owner-only.
///
/// SAFETY: outward/irreversible actions (send email/text) are NOT run silently under headless — they
/// require a text-confirmation round-trip ("reply 'yes' to send"). Safe read/query commands run
/// directly through AssistantCore.process(headless:). Reuses AlfredBotWatcher's outward-action +
/// affirmative helpers.
///
/// A `Task { while !cancelled { … } }` long-poll loop; NOT a SafetyAuditEngine-scanned engine and no
/// stored Timer, so the startup audit stays green. Because getUpdates only returns INCOMING messages
/// (the bot's own replies are outgoing), there's no self-reply loop to guard against.
@MainActor
final class TelegramBotService: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status = "Telegram bot is off."

    private let core: AssistantCore
    private let appState: AppState
    private let messaging = MessagingCapability()
    private let mailCompose = MailComposeCapability()

    private var monitorTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let offsetKey = "telegram.nextOffset"

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
    private static var didLogHint = false

    init(core: AssistantCore, appState: AppState) {
        self.core = core
        self.appState = appState
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Connecting to Telegram…"
        monitorTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        isActive = false
        status = "Telegram bot is off."
    }

    private func token() -> String? {
        KeychainHelper.load(service: "com.alfred.app", account: "telegram")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
    private func ownerChatID() -> String { appState.telegramOwnerChatID.trimmingCharacters(in: .whitespaces) }

    // MARK: - Long-poll loop

    private func runLoop() async {
        while !Task.isCancelled {
            guard let token = token(), !token.isEmpty else {
                Self.logHintOnce(); status = "Add a Telegram bot token to enable the bot."
                try? await Task.sleep(nanoseconds: 5_000_000_000); continue
            }
            guard !ownerChatID().isEmpty else {
                status = "Set your Telegram chat ID to enable the bot."
                try? await Task.sleep(nanoseconds: 5_000_000_000); continue
            }

            let offset = defaults.integer(forKey: offsetKey)
            guard let data = await getUpdates(token: token, offset: offset) else {
                try? await Task.sleep(nanoseconds: 3_000_000_000); continue   // backoff on network error
            }
            guard let updates = Self.decodeUpdates(data) else {
                try? await Task.sleep(nanoseconds: 3_000_000_000); continue
            }

            // Advance the offset past everything returned (persisted so restarts don't reprocess).
            let next = Self.nextOffset(from: updates, current: offset)
            if next > offset { defaults.set(next, forKey: offsetKey) }

            for (_, text) in Self.ownerMessages(from: updates, ownerChatID: ownerChatID()) {
                await handle(text: text, token: token)
            }
            if isActive { status = "Listening on Telegram." }
        }
    }

    /// GET getUpdates with a 30s long-poll (returns instantly on a new message). The URLSession
    /// request timeout is 40s (> the long-poll) so it isn't cut off mid-wait.
    private func getUpdates(token: String, offset: Int) async -> Data? {
        var comps = URLComponents(string: "https://api.telegram.org/bot\(token)/getUpdates")!
        comps.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "timeout", value: "30"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 40
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[TelegramBot] getUpdates HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return data
        } catch {
            NSLog("[TelegramBot] getUpdates error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Command handling (mirrors AlfredBotWatcher, but no trigger; reply over HTTPS)

    private func handle(text: String, token: String) async {
        if let action = pending {
            pending = nil
            let reply = AlfredBotWatcher.isAffirmative(text) ? execute(action) : "Cancelled."
            await sendReply(reply, token: token)
            return
        }

        let cmd = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        // Outward email → confirm before sending.
        if let intent = MailComposeCapability.detect(in: cmd) {
            guard let body = intent.body, !body.trimmingCharacters(in: .whitespaces).isEmpty else {
                await sendReply("For safety, tell me exactly what to send, e.g. \"email \(intent.recipient) saying <message>\".", token: token)
                return
            }
            guard let r = await mailCompose.resolveEmail(for: intent.recipient) else {
                await sendReply("Couldn't find an email address for \"\(intent.recipient)\".", token: token)
                return
            }
            let action = PendingAction.email(email: r.email, display: r.display, subject: intent.subject, body: body)
            pending = action
            await sendReply(action.prompt, token: token)
            return
        }

        // Outward text → confirm before sending.
        if let intent = MessagingCapability.detect(in: cmd) {
            guard let message = intent.message, !message.trimmingCharacters(in: .whitespaces).isEmpty else {
                await sendReply("For safety, tell me exactly what to send, e.g. \"text \(intent.name) saying <message>\".", token: token)
                return
            }
            guard let recipient = await messaging.resolveRecipient(for: intent.name) else {
                await sendReply("Couldn't find \"\(intent.name)\" in Contacts.", token: token)
                return
            }
            let action = PendingAction.text(handle: recipient.handle, display: recipient.display, message: message)
            pending = action
            await sendReply(action.prompt, token: token)
            return
        }

        // Safe read/query → run headless, collect the reply, send once.
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
            NSLog("[TelegramBot] process failed: \(error.localizedDescription)")
            reply = "Sorry, I hit an error handling that."
        }
        await sendReply(reply.isEmpty ? "Done." : reply, token: token)
    }

    private func execute(_ action: PendingAction) -> String {
        switch action {
        case let .email(email, display, subject, body):
            return mailCompose.compose(to: email, display: display, subject: subject, body: body,
                                       send: true, confirmed: true)   // already confirmed via chat
        case let .text(handle, display, message):
            return messaging.send(message: message, toHandle: handle) ? "Sent to \(display)." : "Couldn't send to \(display)."
        }
    }

    // MARK: - Send (splits long replies)

    private func sendReply(_ text: String, token: String) async {
        for chunk in Self.splitReply(text) {
            await sendMessage(chunk, token: token)
        }
    }

    private func sendMessage(_ text: String, token: String) async {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": ownerChatID(), "text": text])
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                NSLog("[TelegramBot] sendMessage HTTP \(http.statusCode)")
            }
        } catch {
            NSLog("[TelegramBot] sendMessage error: \(error.localizedDescription)")
        }
    }

    // MARK: - Pure helpers (unit-tested)

    struct Update: Decodable {
        let updateId: Int
        let message: Message?
        enum CodingKeys: String, CodingKey { case updateId = "update_id"; case message }
    }
    struct Message: Decodable { let text: String?; let chat: Chat }
    struct Chat: Decodable { let id: Int64 }

    static func decodeUpdates(_ data: Data) -> [Update]? {
        struct Response: Decodable { let ok: Bool; let result: [Update] }
        return (try? JSONDecoder().decode(Response.self, from: data))?.result
    }

    /// Owner-only: keep only text messages whose chat.id matches `ownerChatID` (compared as strings so
    /// the config field can be pasted verbatim).
    static func ownerMessages(from updates: [Update], ownerChatID: String) -> [(updateId: Int, text: String)] {
        updates.compactMap { u in
            guard let m = u.message, let text = m.text, !text.isEmpty,
                  String(m.chat.id) == ownerChatID else { return nil }
            return (u.updateId, text)
        }
    }

    /// Next offset = max(update_id) + 1 (acks every update Telegram returned, owner or not).
    static func nextOffset(from updates: [Update], current: Int) -> Int {
        (updates.map(\.updateId).max().map { $0 + 1 }) ?? current
    }

    /// Splits a reply into ≤`maxLen` chunks (Telegram's 4096 limit), preferring newline/space breaks.
    static func splitReply(_ text: String, maxLen: Int = 4000) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > maxLen else { return [text] }
        var chunks: [String] = []
        var remaining = Substring(text)
        while remaining.count > maxLen {
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: maxLen)
            let slice = remaining[..<hardEnd]
            let cut = slice.lastIndex(of: "\n") ?? slice.lastIndex(of: " ") ?? hardEnd
            let piece = String(remaining[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            remaining = remaining[cut...].drop(while: { $0 == "\n" || $0 == " " })
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    private static func logHintOnce() {
        guard !didLogHint else { return }
        didLogHint = true
        NSLog("[TelegramBot] disabled — set the bot token (Keychain) and your Telegram chat ID.")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
