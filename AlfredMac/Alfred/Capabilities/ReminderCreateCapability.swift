import Foundation

// MARK: - ReminderCreateCapability
//
// Parses "remind me to <thing> [at <time>]" into a title + optional due date for Apple Reminders.
// Date parsing uses NSDataDetector, which understands natural phrasing ("tomorrow at 5pm", "next
// monday", "in 2 hours") for free. Pure parsing only — the actual EKReminder write is done by
// CalendarRemindersCapability.createReminder in AssistantCore. Creating a reminder is a safe local
// write (like a calendar event or a note), so no confirmation gate.

enum ReminderCreateCapability {

    struct Parsed { let title: String; let dueDate: Date? }

    /// Returns a parsed reminder when the query asks to create one, else nil.
    static func detect(_ query: String) -> Parsed? {
        let lowered = query.lowercased()
        // Trigger phrases, longest first so we strip the most specific prefix.
        let triggers = ["set a reminder to ", "set a reminder for ", "set a reminder ",
                        "add a reminder to ", "add a reminder ", "create a reminder to ",
                        "create a reminder ", "remind me to ", "remind me about ", "remind me "]

        var remainder: String?
        for t in triggers {
            if let r = lowered.range(of: t) {
                let startOffset = lowered.distance(from: lowered.startIndex, to: r.upperBound)
                remainder = String(query[query.index(query.startIndex, offsetBy: startOffset)...])
                break
            }
        }
        guard var text = remainder?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }

        // Pull out a date/time anywhere in the text, then remove that phrase from the title.
        var dueDate: Date?
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = text as NSString
            let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if let m = matches.first, let date = m.date {
                dueDate = date
                // Remove the matched time phrase plus a dangling "at"/"on"/"by" lead-in.
                var range = m.range
                let before = ns.substring(to: range.location).lowercased()
                for lead in [" at ", " on ", " by ", " around ", " for "] where before.hasSuffix(lead) {
                    range = NSRange(location: range.location - (lead.count - 1), length: range.length + (lead.count - 1))
                    break
                }
                text = ns.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Tidy the title: drop a leading "to/about/that", trailing punctuation.
        for lead in ["to ", "about ", "that "] where text.lowercased().hasPrefix(lead) {
            text = String(text.dropFirst(lead.count)); break
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?")).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return Parsed(title: capitalizeFirst(text), dueDate: dueDate)
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
