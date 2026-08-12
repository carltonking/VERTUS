import Foundation

// MARK: - Conversation store

/// The persisted capture log behind the fine-tuning loop — now a thin facade
/// over `UnifiedMemoryLayer`'s `conversations` table.
///
/// Kept as a class (rather than deleting it) so `HermesSession` and
/// `FineTuneManager` stay unchanged: the add/mark/infer/read contract is
/// identical, but the rows now live in the unified database alongside the
/// graph, screen observations and vault mirror. The old JSON file
/// (`~/.alfred/finetuning/captures.json`) is the migration source and is no
/// longer written. Sanitization, topic inference and rejection detection are
/// pure statics and stay here.
final class ConversationStore {

    static let shared = ConversationStore()

    init(fileURL: URL? = nil) {
        // The JSON file was the store's home before the consolidation; it
        // still exists on disk as the migration source (MigrationManager).
        // Nothing to load — the unified layer owns the data now.
    }

    // MARK: - Capture

    /// Add one exchange. Sensitive data (passwords, API keys, tokens) is
    /// stripped from both sides before anything is persisted. `accepted` is
    /// false until feedback or inference flips it.
    @discardableResult
    func addCapture(userMessage: String,
                    assistantResponse: String,
                    timestamp: TimeInterval) -> ConversationCapture {
        let user = Self.sanitize(userMessage)
        let reply = Self.sanitize(assistantResponse)
        let topic = Self.inferTopic(from: userMessage)
        let capture = ConversationCapture(
            userMessage: user,
            assistantResponse: reply,
            timestamp: timestamp,
            topic: topic)
        // The stable UUID is the row id in the unified table, so feedback
        // (markAccepted) can find the exact capture later.
        UnifiedMemoryLayer.shared.addConversation(
            user: user, assistant: reply, timestamp: timestamp,
            topic: topic, id: capture.id.uuidString)
        return capture
    }

    /// Explicit user feedback — the thumbs-up path. `confidence` defaults to
    /// 1.0 (the user said so) but can be passed lower for softer signals.
    func markAccepted(id: UUID, confidence: Double = 1.0) {
        UnifiedMemoryLayer.shared.markAccepted(id: id.uuidString, confidence: confidence)
    }

    /// Inference path: the user just sent a new message. If it isn't a
    /// rejection (\"wrong\", \"redo\", \"that's not right\"…) and the most recent
    /// capture is still unaccepted, treat the previous exchange as accepted
    /// at 0.7 — continuing the conversation is the strongest implicit signal.
    func inferAcceptance(followingUserMessage: String) {
        UnifiedMemoryLayer.shared.inferAcceptance(followingUserMessage: followingUserMessage)
    }

    // MARK: - Reading

    /// Accepted exchanges, newest first, capped at `limit`. This is what
    /// feeds a fine-tune run.
    func recentAccepted(limit: Int = 100) -> [ConversationCapture] {
        UnifiedMemoryLayer.shared.getAcceptedConversations(limit: limit).map { row in
            ConversationCapture(
                id: UUID(uuidString: row.id) ?? UUID(),
                userMessage: row.userMessage,
                assistantResponse: row.assistantResponse,
                timestamp: row.timestamp,
                accepted: row.accepted,
                confidence: row.confidence,
                topic: row.topic)
        }
    }

    var count: Int {
        UnifiedMemoryLayer.shared.countConversations()
    }

    /// Wipe the log (privacy reset or test setup).
    func reset() {
        UnifiedMemoryLayer.shared.clearConversations()
    }

    // MARK: - Sanitization

    /// Strip secrets before persistence. Conservative line-based approach:
    /// any line containing a known secret keyword gets its value redacted,
    /// and anything that looks like a long opaque token is masked. This is a
    /// best-effort filter, not a security boundary — it exists so a stray
    /// API key pasted into a message doesn't end up in a training file.
    static func sanitize(_ text: String) -> String {
        let secretPatterns = [
            #"(?i)\b(password|passwd|pwd)\b\s*[=:]\s*\S+"#,
            #"(?i)\b(api[_-]?key|apikey)\b\s*[=:]\s*\S+"#,
            #"(?i)\b(secret|client[_-]?secret)\b\s*[=:]\s*\S+"#,
            #"(?i)\b(auth[_-]?token|bearer[_-]?token|access[_-]?token|refresh[_-]?token)\b\s*[=:]\s*\S+"#,
            #"(?i)\b(private[_-]?key)\b\s*[=:]\s*\S+"#,
            #"(?i)\b(session[_-]?id|cookie)\b\s*[=:]\s*\S+"#,
        ]
        var out = text
        for pattern in secretPatterns {
            out = out.replacingRegexMatches(
                of: pattern,
                with: { match in
                    // Keep the keyword, redact the value. Split on BOTH `=` and
                    // `:` — a pattern like `password: hunter2` has no `=`, and
                    // splitting on `=` alone would return the whole match,
                    // leaking the secret.
                    let keyword = match.split(maxSplits: 1,
                                              whereSeparator: { $0 == "=" || $0 == ":" }).first
                    return (keyword.map(String.init) ?? "").trimmingCharacters(in: .whitespaces) + "=[REDACTED]"
                })
        }
        // Long opaque tokens (≥32 chars of hex/alnum) anywhere — JWT-ish,
        // API keys pasted bare. Leave short words alone.
        out = out.replacingOccurrences(
            of: #"\b[0-9A-Za-z_-]{32,}\b"#,
            with: "[REDACTED]",
            options: .regularExpression)
        return out
    }

    // MARK: - Topic

    /// Coarse topic bucket from keyword hits. Cheap and good enough for
    /// dataset mixing; unknown topics fall back to \"general\".
    static func inferTopic(from userMessage: String) -> String {
        let lower = userMessage.lowercased()
        let buckets: [(String, [String])] = [
            ("coding", ["code", "bug", "debug", "compile", "error", "script", "python", "swift", "api", "function", "crash", "repo", "git", "test"]),
            ("writing", ["write", "email", "essay", "draft", "summarize", "rewrite", "paragraph", "grammar", "proofread"]),
            ("scheduling", ["schedule", "calendar", "meeting", "appointment", "remind", "reminder", "event", "book", "reschedule", "date"]),
            ("research", ["research", "look up", "find", "search", "what is", "who is", "explain", "news", "latest"]),
            ("personal", ["my", "i feel", "i want", "plan", "goal", "habit", "routine", "health", "gym", "travel"]),
        ]
        for (topic, keywords) in buckets {
            if keywords.contains(where: { lower.contains($0) }) {
                return topic
            }
        }
        return "general"
    }

    /// Rejection phrases — a follow-up containing any of these means the
    /// previous answer was NOT accepted, so inference must not fire.
    static func isRejection(_ message: String) -> Bool {
        let lower = message.lowercased()
        let markers = ["wrong", "redo", "that's not", "that is not", "no that", "nope",
                       "not what i", "try again", "again but", "incorrect", "didn't work",
                       "did not work", "forget it", "never mind", "stop"]
        return markers.contains(where: { lower.contains($0) })
    }
}

// MARK: - Regex helper

private extension String {
    /// NSRegularExpression-based replace with a transform closure. Named
    /// distinctly so it can't collide with Foundation's own
    /// `replacingOccurrences(of:with:options:)` (which takes a plain string
    /// replacement, not a closure).
    func replacingRegexMatches(of pattern: String,
                               with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out = self
        let matches = regex.matches(in: self, options: [], range: range)
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: transform(matched))
        }
        return out
    }
}
