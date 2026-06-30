import Foundation

/// Strips an email body down to ONLY what the sender actually wrote — drops quoted reply text,
/// the original-message / "On <date>, <name> wrote:" attribution and everything below it, and a
/// trailing signature. Pure and unit-testable so we learn the user's voice, not text others wrote.
enum EmailBodyCleaner {

    static func ownTextOnly(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        // 1. Cut at the reply/forward header — everything below is the quoted original.
        if var cut = lines.firstIndex(where: { isReplyHeader($0) }) {
            // Pull the cut up over a wrapped "On <…>" attribution that precedes the "wrote:" line.
            while cut > 0 && lines[cut - 1].trimmingCharacters(in: .whitespaces).hasPrefix("On ") {
                cut -= 1
            }
            lines = Array(lines[..<cut])
        }

        // 2. Cut at a signature delimiter / mobile footer.
        if let sig = lines.firstIndex(where: { isSignatureMarker($0) }) {
            lines = Array(lines[..<sig])
        }

        // 3. Drop quoted lines (leading ">", after optional spaces).
        lines = lines.filter { !isQuoted($0) }

        // 4. Trim, drop leading/trailing blanks, squeeze runs of blank lines.
        return tidy(lines)
    }

    // MARK: - Line classifiers (pure)

    static func isReplyHeader(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-----Original Message-----") { return true }
        if t.hasPrefix("________________________________") { return true }   // Outlook divider
        // "On <date>, <name> wrote:" — the common single-line attribution …
        if t.range(of: #"^On\b.*\bwrote:\s*$"#, options: .regularExpression) != nil { return true }
        // … and the wrapped form whose final line ends with "wrote:" (next to an address).
        if t.hasSuffix("wrote:") && t.count < 200 && (t.contains("@") || t.lowercased().contains("wrote")) {
            return true
        }
        return false
    }

    static func isQuoted(_ line: String) -> Bool {
        line.drop(while: { $0 == " " }).first == ">"
    }

    static func isSignatureMarker(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // RFC 3676 signature delimiter ("-- ", with or without the trailing space) and em-dash form.
        if t == "--" || t == "—" { return true }
        if t.lowercased().hasPrefix("sent from my ") { return true }
        return false
    }

    // MARK: - Tidy (pure)

    private static func tidy(_ lines: [String]) -> String {
        var out = lines
        while let f = out.first, f.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        while let l = out.last, l.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }

        var result: [String] = []
        var lastBlank = false
        for line in out {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank && lastBlank { continue }
            result.append(line)
            lastBlank = blank
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
