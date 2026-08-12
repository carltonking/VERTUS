import Foundation

/// Answers messages sent from the iOS app, using Hermes on this Mac.
///
/// This replaces `TelegramBotService`, which long-polled Telegram and ran queries
/// through Alfred's own `AssistantCore`. Both of those are gone: the client is now
/// Alfred's app rather than Telegram, and the brain is Hermes rather than
/// AssistantCore. The shape that made the old one work is kept exactly — the Mac
/// reaches *out* and holds a connection open, so nothing has to reach *in*. No
/// port forwarding, no VPN, no dynamic DNS, works from cellular.
///
///     iPhone ──▶ /api/mac ──▶ [ relay ] ◀── this class holds a poll open
///            ◀────────────────────────── posts the answer back
///
/// The Mac must be awake. That is inherent: the whole point of routing here rather
/// than answering in the cloud is that this is where the local model, the screen,
/// and the accessibility tree are.
actor RelayWorker {

    /// The relay endpoint, e.g. https://alfredai.vercel.app/api/mac
    private let endpoint: URL
    /// Same shared secret the iOS app uses (APP_TOKEN).
    private let token: String
    private let hermes: HermesSession

    private var task: Task<Void, Never>?

    /// Backoff after a network failure. Starts small so a blip costs nothing, and
    /// caps so a long outage doesn't spin.
    private var backoff: Duration = .seconds(1)
    private static let maxBackoff: Duration = .seconds(60)

    init(endpoint: URL, token: String, hermes: HermesSession) {
        self.endpoint = endpoint
        self.token = token
        self.hermes = hermes
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                if let message = try await poll() {
                    await answer(message)
                }
                backoff = .seconds(1)   // a completed round trip clears the backoff
            } catch is CancellationError {
                return
            } catch {
                // Offline, relay down, token wrong — all look the same from here and
                // all want the same response: wait, then try again.
                NSLog("[relay] %@ — retrying in %@", error.localizedDescription, "\(backoff)")
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, Self.maxBackoff)
            }
        }
    }

    // MARK: - Relay protocol

    private struct Incoming: Decodable {
        struct Message: Decodable {
            let id: String
            let text: String
        }
        let message: Message?
    }

    /// Hold a request open until the relay has something, or it times out empty.
    private func poll() async throws -> Incoming.Message? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Longer than the relay's own hold, so the server decides when a poll ends
        // rather than the client tearing it down mid-flight.
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.malformed }
        guard http.statusCode == 200 else { throw RelayError.status(http.statusCode) }
        return try JSONDecoder().decode(Incoming.self, from: data).message
    }

    /// Run the message through Hermes and post the result back.
    private func answer(_ message: Incoming.Message) async {
        // Structured commands bypass Hermes entirely. They are answered locally
        // and returned as JSON; see MessagesCapability for the contract.
        if message.text.hasPrefix("alfred:messages:") {
            let reply = handleStructuredCommand(message.text)
            try? await post(id: message.id, reply: reply)
            return
        }

        var text = ""
        var failure: String?

        for await event in await hermes.prompt(message.text) {
            switch event {
            case .text(let chunk):
                text += chunk
            case .failed(let message):
                failure = message
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                // Tool progress is useful in the bar, where it lands next to the
                // input as it happens. Here it would arrive as one lump after the
                // fact, so only the answer is sent.
                break
            }
        }

        let reply = failure
            ?? (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "I didn't have an answer for that."
                : text)

        do {
            try await post(id: message.id, reply: reply)
        } catch {
            // The phone will time out and say so. Losing the reply is bad, but
            // retrying blind risks answering twice, and the user can just ask again.
            NSLog("[relay] could not deliver reply: %@", error.localizedDescription)
        }
    }

    // MARK: - Structured commands

    /// Commands the phone sends that never reach the model: JSON in, JSON out.
    ///
    ///   alfred:messages:list
    ///   alfred:messages:thread {"guid":"..."}
    ///   alfred:messages:send {"guid":"...","text":"..."}
    private func handleStructuredCommand(_ command: String) -> String {
        let body = String(command.dropFirst("alfred:messages:".count))
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)

        switch parts.first ?? "" {
        case "list":
            return MessagesCapability.shared.listConversations()

        case "thread":
            guard parts.count > 1,
                  let data = parts[1].data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let guid = payload["guid"] as? String
            else {
                return "{\"ok\":false,\"error\":\"Malformed thread request.\"}"
            }
            return MessagesCapability.shared.threadMessages(guid: guid)

        case "send":
            guard parts.count > 1,
                  let data = parts[1].data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let guid = payload["guid"] as? String,
                  let text = payload["text"] as? String
            else {
                return "{\"ok\":false,\"error\":\"Malformed send request.\"}"
            }
            return MessagesCapability.shared.sendMessage(guid: guid, text: text)

        default:
            return "{\"ok\":false,\"error\":\"Unknown command.\"}"
        }
    }

    private func post(id: String, reply: String) async throws {
        // The reply goes to the bare endpoint, not a /reply path. Vercel mounts this
        // function at exactly /api/mac, so a subpath like /api/mac/reply matches no
        // route and gets a 404 before this code ever sees it.
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "reply": reply])
        request.timeoutInterval = 30

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RelayError.status((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    enum RelayError: LocalizedError {
        case status(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .status(let code): return "relay returned HTTP \(code)"
            case .malformed: return "relay returned a malformed response"
            }
        }
    }
}
