import Foundation

/// Detects an explicit "operate my Mac" request and extracts the task to perform.
///
/// Only explicit openers ("control my mac", "use my mac to", …) qualify, so ordinary questions
/// and chat are never hijacked into the computer-control path. Pure + unit-testable.
enum ComputerControlIntent {
    private static let openers = [
        "control my mac", "control the mac", "control this mac",
        "control my computer", "control the computer", "control computer",
        "use my mac to", "use the mac to", "operate my mac", "operate the mac",
    ]

    /// Returns the task text (everything after the opener, connectors stripped), or nil if the
    /// query isn't an explicit control request.
    static func task(in query: String) -> String? {
        let lower = query.lowercased()
        guard let opener = openers.first(where: { lower.contains($0) }),
              let range = lower.range(of: opener) else { return nil }

        var rest = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        for connector in ["and ", "to ", "by ", "please ", ": ", "- ", ", "] {
            if rest.lowercased().hasPrefix(connector) {
                rest = String(rest.dropFirst(connector.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // If nothing followed the opener (e.g. just "control my mac"), fall back to the whole query.
        return rest.isEmpty ? query : rest
    }
}
