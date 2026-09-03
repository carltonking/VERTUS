import Foundation

/// Client for the VERTUS server: POST /api/prompt + GET /api/events (SSE).
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

    // MARK: Slash commands (skills)

    /// Slash-command catalog from the hub (GET /api/skills): every registry
    /// command plus every installed skill — the same list the vertus CLI's
    /// '/' menu shows.
    @Published var slashCommands: [SlashCommand] = []
    /// Live suggestion list for the current '/'-prefixed prompt text.
    @Published var slashSuggestions: [SlashCommand] = []
    private var catalogLoaded = false
    private var catalogRetry = false

    init(config: ServerConfig = ServerConfig.load()) {
        self.config = config
    }

    /// Kick off a one-time catalog fetch; safe to call on every keystroke.
    /// On failure it arms a single retry so a hub that was still starting up
    /// (or temporarily down) doesn't leave the menu permanently empty.
    func ensureSlashCatalog() {
        guard !catalogLoaded else { return }
        catalogLoaded = true
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = URL(string: "\(self.config.baseURL)/api/skills") else { return }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(self.config.token)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 10
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.badServerResponse)
                }
                let raw = obj["commands"] as? [[String: Any]] ?? []
                let cmds = raw.compactMap { entry -> SlashCommand? in
                    guard let name = entry["name"] as? String else { return nil }
                    return SlashCommand(
                        name: name,
                        description: entry["description"] as? String ?? ""
                    )
                }
                await MainActor.run { self.slashCommands = cmds.sorted { $0.name < $1.name } }
            } catch {
                // Autocomplete is best-effort; sending plain text still works.
                // Allow one retry on the next keystroke (e.g. the hub was
                // mid-restart when the bar first opened).
                await MainActor.run {
                    if !self.catalogRetry {
                        self.catalogRetry = true
                        self.catalogLoaded = false
                    }
                }
            }
        }
    }

    /// Recompute suggestions while the user types. Active whenever the
    /// prompt is a single leading /token (no space yet) — exactly like the
    /// CLI's '/' menu.
    func updateSlashSuggestions(for prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !prompt.contains(" ") else {
            if !slashSuggestions.isEmpty { slashSuggestions = [] }
            return
        }
        let query = String(trimmed.dropFirst()).lowercased()
        let matches = slashCommands.filter { cmd in
            let bare = cmd.name.dropFirst().lowercased()
            return query.isEmpty || bare.hasPrefix(query) || bare.contains(query)
        }
        // No cap: the dropdown is a 4-row scrollable window, so every match
        // stays reachable by scrolling.
        if matches.map(\.name) != slashSuggestions.map(\.name) {
            slashSuggestions = matches
        }
        ensureSlashCatalog()
    }

    /// Complete the prompt with the picked command (keeps the '/' form); the
    /// user then types their arguments after it and hits send.
    func completeSlash(_ command: SlashCommand) -> String {
        slashSuggestions = []
        return command.name + " "
    }

    /// Geometry shared by the view layer: the dropdown shows at most 4 rows.
    static let slashVisibleRows = 4
    static let slashRowHeight: CGFloat = 22

    /// One dropdown row's fixed height.
    var slashRowHeight: CGFloat { Self.slashRowHeight }

    /// Reserved space below the prompt strip while the dropdown is open:
    /// 4 rows + internal padding + breathing room. Zero when closed. The
    /// widget grows by exactly this much and the strip floats above it.
    var slashMenuSpace: CGFloat {
        slashSuggestions.isEmpty
            ? 0
            : CGFloat(min(slashSuggestions.count, Self.slashVisibleRows)) * Self.slashRowHeight + 16
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
    /// clears VERTUS's text output box.
    func newSession() {
        reset()
    }

    /// Seeds a sample exchange (no network) for `--demo-output` render checks:
    /// a "You" bubble plus VERTUS's reply, so both bubble styles show.
    func seedDemoOutput() {
        sentAtLeastOnce = true
        transcript.append(TranscriptEntry(
            role: "you",
            text: "Show me the new chat bubbles!"
        ))
        transcript.append(TranscriptEntry(
            role: "vertus",
            text: "Done — your prompts sit on the right, my replies on the "
                + "left, and the bar hugs the conversation."
        ))
    }

    /// Seeds a long multi-line answer (no network) so the ten-line cap and
    /// the in-pane scroll behaviour can be checked via `--demo-long`.
    func seedLongOutput() {
        sentAtLeastOnce = true
        let lines = (1...24).map { "Line \($0): VERTUS output row number \($0) with enough text to wrap comfortably." }
        transcript.append(TranscriptEntry(role: "vertus", text: lines.joined(separator: "\n")))
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
        req.setValue("local", forHTTPHeaderField: "X-Vertus-Client")
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
        transcript.append(TranscriptEntry(role: "vertus", text: text))
        turnHasText = true
    }

    @MainActor
    private func appendToLastAssistant(_ chunk: String) {
        turnHasText = true
        if var last = transcript.last, last.role == "vertus" {
            last.text += chunk
            transcript[transcript.count - 1] = last
        } else {
            transcript.append(TranscriptEntry(role: "vertus", text: chunk))
        }
    }
}

// MARK: - Output helpers

extension QuickBarViewModel {
    /// Full accumulated VERTUS output (for the copy button).
    var vertusOutput: String {
        transcript
            .filter { $0.role == "vertus" }
            .map { $0.text }
            .joined()
    }

    /// True once any VERTUS output or working state exists.
    var hasOutput: Bool {
        transcript.contains { $0.role == "vertus" }
    }

    /// True once VERTUS's reply has started producing text (streaming or done).
    /// Hidden when false — that's when the "thinking" bubble shows.
    var hasAssistantText: Bool {
        transcript.contains { $0.role == "vertus" && !$0.text.isEmpty }
    }

    /// True while VERTUS is working on the current turn and hasn't produced
    /// its first text chunk yet — when the "working" bubble is shown.
    var isThinking: Bool { isStreaming && !turnHasText }

    /// All transcript text joined (drives auto-scroll following in the view).
    var transcriptText: String {
        transcript.map(\.text).joined()
    }
}

// MARK: - Slash commands

/// One entry in the '/' autocomplete menu: "/name" plus a short description.
struct SlashCommand: Identifiable, Equatable {
    let name: String
    let description: String
    var id: String { name }
}

// MARK: - Server config

struct ServerConfig {
    var baseURL: String
    var token: String

    static func load() -> ServerConfig {
        let defaults = UserDefaults.standard
        let base = defaults.string(forKey: "vertus.baseURL") ?? "http://127.0.0.1:8787"
        var token = defaults.string(forKey: "vertus.token") ?? ""
        if token.isEmpty {
            // Fall back to ~/.vertus/token (local mode).
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".vertus/token")
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
