import Foundation
import UserNotifications

/// Watches for coding-agent activity (Claude Code / opencode) on the Mac and
/// fires a "your coding agent has finished" notification when a session goes
/// quiet: a macOS banner plus, when the relay is configured, an APNs push to
/// the iOS app.
///
/// Detection is session-based, not process-based (opencode's work can run in a
/// long-lived server process, so process exit is unreliable): every 5 seconds
/// the newest session for each agent is located — Claude Code's
/// `~/.claude/projects/*/*.jsonl`, or opencode's SQLite store — and when a
/// session stops growing for 45 s the newest assistant-written message is
/// extracted as the notification body. Sessions already around at launch are
/// silently adopted as baseline, and every notified session is recorded in
/// UserDefaults so nothing fires twice. Best-effort throughout.
final class AgentCompletionWatcher {

    static let shared = AgentCompletionWatcher()

    private enum AgentKind: String, CaseIterable {
        case claude, opencode

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .opencode: return "opencode"
            }
        }
    }

    private static let pollInterval: TimeInterval = 5
    /// How long a session must be silent (no new messages) before we call it done.
    private static let quietThreshold: TimeInterval = 45
    private static let defaultsPrefix = "agent.notified.session:"
    private static let maxBodyLength = 200

    /// One session per agent kind: the latest key we've seen, and the state
    /// transition (appearance → silence) that drives the notification.
    private struct Track {
        /// session key → when we first saw it. Entries are dropped once the
        /// session is remembered (notified or adopted as pre-existing).
        var firstSeen: [String: Date] = [:]
    }

    private var timer: Timer?
    private var track: [AgentKind: Track] = [:]
    private let lock = NSLock()

    private init() {
        for kind in AgentKind.allCases { track[kind] = Track() }
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()   // baseline: adopt whatever is already there, never notify it
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Poll

    private func poll() {
        Task.detached(priority: .utility) { [self] in
            for kind in AgentKind.allCases { poll(kind: kind) }
        }
    }

    private func poll(kind: AgentKind) {
        let sessions = recentSessions(for: kind)
        guard !sessions.isEmpty else { return }
        let now = Date()

        lock.lock(); defer { lock.unlock() }
        var state = track[kind]!
        var stillTracked: [String: Date] = [:]

        for info in sessions {
            let age = info.activityAge(now)
            // Already reported (this run or a previous launch)? Skip forever.
            if alreadyNotified(kind, session: info.key) { continue }

            if let firstSeen = state.firstSeen[info.key] {
                // We saw it fresh once — if it has now been quiet for the
                // threshold, the agent is done.
                if age >= Self.quietThreshold {
                    remember(kind, session: info.key)
                    debug("\(kind.rawValue): \(info.key) quiet \(Int(age))s — finishing")
                    notify(kind: kind, session: info.key)
                } else {
                    stillTracked[info.key] = firstSeen
                }
            } else {
                // First observation. Anything already old at first sight is
                // pre-existing (app launch, or finished long ago) — adopt it
                // silently. Fresh ones get tracked until they go quiet.
                if age >= Self.quietThreshold {
                    remember(kind, session: info.key)
                    debug("\(kind.rawValue): adopted pre-existing \(info.key) (quiet \(Int(age))s)")
                } else {
                    stillTracked[info.key] = now
                    debug("\(kind.rawValue): tracking \(info.key)")
                }
            }
        }
        state.firstSeen = stillTracked
        track[kind] = state
    }

    // MARK: - Session info

    /// (dedupe key, last-activity age) for the agent's recent sessions.
    private struct SessionInfo {
        let key: String
        let lastActivity: Date
        func activityAge(_ now: Date) -> TimeInterval { now.timeIntervalSince(lastActivity) }
    }

    private func recentSessions(for kind: AgentKind) -> [SessionInfo] {
        switch kind {
        case .claude: return claudeRecent()
        case .opencode: return opencodeRecent()
        }
    }

    /// All jsonl under `~/.claude/projects`, activity = file modification time.
    private func claudeRecent() -> [SessionInfo] {
        let projects = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        guard let projectURLs = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ) else { return [] }
        var sessions: [SessionInfo] = []
        for project in projectURLs where project.hasDirectoryPath {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                // Only sessions from the last 24 h matter; older ones are noise.
                if Date().timeIntervalSince(m) > 24 * 3600 { continue }
                sessions.append(SessionInfo(
                    key: f.deletingPathExtension().lastPathComponent,
                    lastActivity: m))
            }
        }
        return sessions
    }

    /// opencode's recently active sessions via SQLite (activity = last message
    /// write; a finished session stops growing).
    private func opencodeRecent() -> [SessionInfo] {
        let db = NSHomeDirectory() + "/.local/share/opencode/opencode.db"
        guard FileManager.default.isReadableFile(atPath: db) else { return [] }
        let sql = """
        SELECT m.session_id, max(m.time_updated) FROM message m \
        GROUP BY m.session_id ORDER BY max(m.time_updated) DESC LIMIT 8
        """
        guard let out = shell("/usr/bin/sqlite3", [db, sql]) else { return [] }
        var sessions: [SessionInfo] = []
        for line in out.components(separatedBy: "\n") {
            let fields = line.split(separator: "|")
            guard fields.count == 2, let key = String(fields[0]).nilIfEmpty,
                  let ms = Double(String(fields[1])), ms > 0
            else { continue }
            sessions.append(SessionInfo(key: key, lastActivity: Date(timeIntervalSince1970: ms / 1000)))
        }
        return sessions
    }

    // MARK: - Finalize

    private func notify(kind: AgentKind, session: String) {
        guard let text = sessionText(kind: kind, session: session) else {
            debug("\(kind.rawValue): \(session) has no usable text — skipped")
            return
        }
        let message = "just wanted to remind you that your coding agent has finished working on: \"\(text.agentBody)\""
        postLocalNotification(message: message)
        pushRemote(title: "Coding Agent", body: message)
        NSLog("[Agent] %@ finished — %@", kind.displayName, String(text.agentBody.prefix(60)))
        debug("\(kind.rawValue): notified for \(session): \(String(text.agentBody.prefix(50)))")
    }

    private func sessionText(kind: AgentKind, session: String) -> String? {
        switch kind {
        case .claude: return claudeSessionText(id: session)
        case .opencode: return opencodeSessionText(id: session)
        }
    }

    /// Last assistant-written text in the given Claude session (tail read only).
    private func claudeSessionText(id: String) -> String? {
        let projects = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        guard let projectURLs = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil),
              let dir = projectURLs.first(where: {
                  FileManager.default.fileExists(
                      atPath: $0.appendingPathComponent(id + ".jsonl").path )
              })
        else { return nil }
        let url = dir.appendingPathComponent(id + ".jsonl")
        guard let tail = tail(of: url, bytes: 64 * 1024) else { return nil }
        for line in tail.components(separatedBy: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "assistant",
                  let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Last non-empty assistant text part of the given opencode session.
    private func opencodeSessionText(id: String) -> String? {
        let db = NSHomeDirectory() + "/.local/share/opencode/opencode.db"
        guard FileManager.default.isReadableFile(atPath: db) else { return nil }
        let sql = """
        SELECT p.data->>'$.text' FROM part p JOIN message m ON p.message_id = m.id \
        WHERE m.session_id = '\(id)' AND m.data->>'$.role' = 'assistant' \
        AND p.data->>'$.type' = 'text' AND length(p.data->>'$.text') > 0 \
        ORDER BY p.time_updated DESC LIMIT 1
        """
        guard let out = shell("/usr/bin/sqlite3", [db, sql]),
              let text = out.split(separator: "\n").first
        else { return nil }
        let trimmed = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Delivery

    private func postLocalNotification(message: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Coding Agent"
            content.body = message
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "AgentCompletion.\(UUID().uuidString)",
                content: content, trigger: nil
            )) { error in
                if let error { NSLog("[Agent] notification failed: %@", error.localizedDescription) }
            }
        }
    }

    /// Phone push via the relay's /api/notify — only when a relay is configured.
    private func pushRemote(title: String, body: String) {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "relayEndpoint"),
              let base = URL(string: raw),
              let scheme = base.scheme, let host = base.host,
              let token = defaults.string(forKey: "relayToken"), !token.isEmpty,
              let url = URL(string: "\(scheme)://\(host)/api/notify")
        else {
            debug("phone push skipped — relay not configured")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title, "body": body])
        URLSession.shared.dataTask(with: request) { [self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            self.debug("phone push \(ok ? "delivered" : "failed (best effort)")")
        }.resume()
    }

    // MARK: - Dedupe

    /// Every session ever reported for this agent kind, as a persisted set.
    /// (String sets via UserDefaults `stringArray` — capped so it can't grow
    /// without bound.)
    private func alreadyNotified(_ kind: AgentKind, session: String) -> Bool {
        defaultsSet(kind).contains(session)
    }

    /// Persist the session as notified so neither this nor a future launch
    /// reports it again.
    private func remember(_ kind: AgentKind, session: String) {
        var set = defaultsSet(kind)
        set.insert(session)
        if set.count > 50 { set = Set(set.suffix(50)) }
        UserDefaults.standard.set(Array(set), forKey: Self.defaultsPrefix + kind.rawValue)
    }

    private func defaultsSet(_ kind: AgentKind) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.defaultsPrefix + kind.rawValue) ?? [])
    }

    // MARK: - Helpers

    /// Vim-like debug trail — unified logging was unreliable in this setup.
    private func debug(_ line: String) {
        let entry = "\(Date().timeIntervalSince1970) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/alfred_agent_watch.log")) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? entry.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/alfred_agent_watch.log"))
        }
    }

    /// Synchronous one-shot command; nil on any failure path.
    private func shell(_ command: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    /// Last `bytes` of a file as UTF-8 (or the whole file when smaller).
    private func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = max(0, Int(size) - bytes)
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    /// Truncated for a notification body, with an ellipsis when cut.
    var agentBody: String {
        guard count > 200 else { return self }
        return String(prefix(200)) + "…"
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}