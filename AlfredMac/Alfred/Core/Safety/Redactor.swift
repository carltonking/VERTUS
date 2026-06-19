import Foundation

/// In-process redaction (Blueprint v1 §7).
///
/// Non-removable default patterns replace sensitive content with `[REDACTED]` in Swift,
/// in-process, BEFORE any cloud request is built. This lives in the policy/egress layer —
/// not in individual tools — so safety never depends on the dispatcher model being correct.
struct Redactor {

    struct Result {
        let text: String
        let redactionCount: Int
        var didRedact: Bool { redactionCount > 0 }
    }

    /// Non-removable default patterns (Blueprint: `password.*`, `ssn`, `credit.?card`).
    /// Users may append patterns in a later milestone; these can never be removed.
    static let defaultPatterns: [NSRegularExpression] = {
        let sources = [
            // Labelled secrets: "password: hunter2", "api key = abc123", "token=..."
            #"(?i)\b(?:passwords?|passcode|api[ _-]?key|secret|token)\b\s*[:=]\s*\S+"#,
            // US SSN: 123-45-6789
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            // Credit-card-shaped: 4 groups of 4 digits with optional spaces/hyphens
            #"\b(?:\d{4}[ -]?){3}\d{1,4}\b"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private let patterns: [NSRegularExpression]

    init(patterns: [NSRegularExpression] = Redactor.defaultPatterns) {
        self.patterns = patterns
    }

    /// Replaces every match of every pattern with `[REDACTED]`.
    func redact(_ text: String) -> Result {
        var working = text
        var count = 0
        for re in patterns {
            let matches = re.matches(in: working, range: NSRange(working.startIndex..., in: working))
            guard !matches.isEmpty else { continue }
            count += matches.count
            let mutable = NSMutableString(string: working)
            // Replace back-to-front so earlier ranges stay valid.
            for match in matches.reversed() {
                mutable.replaceCharacters(in: match.range, with: "[REDACTED]")
            }
            working = mutable as String
        }
        return Result(text: working, redactionCount: count)
    }

    /// Redacts a system prompt + message batch, returning the sanitized payload and the
    /// total number of redactions across all of it.
    func redact(messages: [LLMMessage], system: String) -> (messages: [LLMMessage], system: String, count: Int) {
        var total = 0
        let redactedSystem = redact(system)
        total += redactedSystem.redactionCount
        let redactedMessages = messages.map { message -> LLMMessage in
            var copy = message
            let result = redact(message.content)
            total += result.redactionCount
            copy.content = result.text
            return copy
        }
        return (redactedMessages, redactedSystem.text, total)
    }
}
