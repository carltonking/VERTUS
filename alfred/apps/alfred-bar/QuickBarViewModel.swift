import Foundation

/// Client for the ALFRED server: POST /api/prompt + GET /api/events (SSE).
final class QuickBarViewModel: ObservableObject {
    @Published var transcript: [TranscriptEntry] = []
    @Published var isStreaming = false
    @Published var currentActivity: String?
    /// Did the in-flight turn produce any reply text yet? The "working"
    /// bubble shows while streaming before the first text chunk arrives —
    /// and it must re-appear on EVERY send, not just the first (keying off
    /// hasAssistantText stays true forever after the first reply).
    @Published var turnHasText = false
    /// Visible wrapped lines in the prompt editor (1…3). The prompt strip
    /// grows only when the text wraps past one line, capped at three.
    @Published var promptLines: CGFloat = 1
    /// True once the user has pressed send at least once.
    /// The output area only exists after this.
    @Published var sentAtLeastOnce = false

    private var streamTask: Task<Void, Never>?
    private var config: ServerConfig

    init(config: ServerConfig = ServerConfig.load()) {
        self.config = config
    }

    func send(_ text: String) {
        guard !isStreaming else { return }
        transcript.append(TranscriptEntry(role: "you", text: text))
        isStreaming = true
        sentAtLeastOnce = true
        currentActivity = "thinking…"
        turnHasText = false
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.run(text)
        }
    }

    func reset() {
        streamTask?.cancel()
        transcript.removeAll()
        currentActivity = nil
        turnHasText = false
        isStreaming = false
    }

    /// Start a fresh session — stops any in-flight stream and instantly
    /// clears ALFRED's text output box.
    func newSession() {
        reset()
    }

    /// Seeds a sample exchange (no network) for `--demo-output` render checks:
    /// a "You" bubble plus ALFRED's reply, so both bubble styles show.
    func seedDemoOutput() {
        sentAtLeastOnce = true
        transcript.append(TranscriptEntry(
            role: "you",
            text: "Show me the new chat bubbles!"
        ))
        transcript.append(TranscriptEntry(
            role: "alfred",
            text: "Done — your prompts sit on the right, my replies on the "
                + "left, and the bar hugs the conversation."
        ))
    }

    /// Seeds a long multi-line answer (no network) so the ten-line cap and
    /// the in-pane scroll behaviour can be checked via `--demo-long`.
    func seedLongOutput() {
        sentAtLeastOnce = true
        let lines = (1...24).map { "Line \($0): ALFRED output row number \($0) with enough text to wrap comfortably." }
        transcript.append(TranscriptEntry(role: "alfred", text: lines.joined(separator: "\n")))
    }

    // MARK: - Streaming

    private func run(_ text: String) async {
        do {
            // Open SSE stream first so no reply is lost, then POST the prompt.
            let events = try await openEventStream()
            do {
                let accepted = try await postPrompt(text)
                guard accepted else {
                    await appendAssistant("⚠️ Server did not accept the prompt.")
                    return
                }
                // Consume events until done/error.
                for try await event in events {
                    if Task.isCancelled { break }
                    await handle(event)
                }
            } catch {
                await appendAssistant("⚠️ \(error.localizedDescription)")
            }
        } catch is CancellationError {
        } catch {
            await appendAssistant("⚠️ \(error.localizedDescription)")
        }
        await MainActor.run {
            isStreaming = false
            currentActivity = nil
        }
    }

    private func handle(_ event: StreamEvent) async {
        switch event {
        case .text(let chunk):
            await appendToLastAssistant(chunk)
        case .activity(let text):
            await MainActor.run { currentActivity = text }
        case .done:
            break
        case .error(let message):
            await appendAssistant("⚠️ \(message)")
        }
    }

    private func postPrompt(_ text: String) async throws -> Bool {
        guard let url = URL(string: "\(config.baseURL)/api/prompt") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue("local", forHTTPHeaderField: "X-Alfred-Client")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 202 else {
            throw URLError(.badServerResponse) // message surfaced via error event
        }
        return true
    }

    private func openEventStream() async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let url = URL(string: "\(config.baseURL)/api/events") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        guard let data = payload.data(using: .utf8),
                              let event = StreamEvent.decode(from: data) else { continue }
                        continuation.yield(event)
                        if case .done = event { break }
                        if case .error = event { break }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transcript helpers

    @MainActor
    private func appendAssistant(_ text: String) {
        transcript.append(TranscriptEntry(role: "alfred", text: text))
        turnHasText = true
    }

    @MainActor
    private func appendToLastAssistant(_ chunk: String) {
        turnHasText = true
        if var last = transcript.last, last.role == "alfred" {
            last.text += chunk
            transcript[transcript.count - 1] = last
        } else {
            transcript.append(TranscriptEntry(role: "alfred", text: chunk))
        }
    }
}

// MARK: - Output helpers

extension QuickBarViewModel {
    /// Full accumulated ALFRED output (for the copy button).
    var alfredOutput: String {
        transcript
            .filter { $0.role == "alfred" }
            .map { $0.text }
            .joined()
    }

    /// True once any ALFRED output or working state exists.
    var hasOutput: Bool {
        transcript.contains { $0.role == "alfred" }
    }

    /// True once ALFRED's reply has started producing text (streaming or done).
    /// Hidden when false — that's when the "thinking" bubble shows.
    var hasAssistantText: Bool {
        transcript.contains { $0.role == "alfred" && !$0.text.isEmpty }
    }

    /// True while ALFRED is working on the current turn and hasn't produced
    /// its first text chunk yet — when the "working" bubble is shown.
    var isThinking: Bool { isStreaming && !turnHasText }

    /// All transcript text joined (drives auto-scroll following in the view).
    var transcriptText: String {
        transcript.map(\.text).joined()
    }
}

// MARK: - Server config

struct ServerConfig {
    var baseURL: String
    var token: String

    static func load() -> ServerConfig {
        let defaults = UserDefaults.standard
        let base = defaults.string(forKey: "alfred.baseURL") ?? "http://127.0.0.1:8787"
        var token = defaults.string(forKey: "alfred.token") ?? ""
        if token.isEmpty {
            // Fall back to ~/.alfred/token (local mode).
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".alfred/token")
            token = (try? String(contentsOf: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ServerConfig(baseURL: base, token: token)
    }
}

// MARK: - Stream events

enum StreamEvent {
    case text(String)
    case activity(String)
    case done
    case error(String)

    static func decode(from data: Data) -> StreamEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch obj["type"] as? String {
        case "text":
            return .text(obj["text"] as? String ?? "")
        case "activity":
            return .activity(obj["text"] as? String ?? "")
        case "done":
            return .done
        case "error":
            return .error(obj["message"] as? String ?? "unknown error")
        default:
            return nil
        }
    }
}
