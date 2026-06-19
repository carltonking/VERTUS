import Foundation

/// Strips polite / filler wrappers from a request so intent detection works regardless of phrasing.
///
/// "Can you please open Spotify for me" → "open Spotify"
/// "Alfred, text mom saying hi"         → "text mom saying hi"
/// "delete report.pdf, thanks"          → "delete report.pdf"
///
/// Only leading/trailing wrappers are removed — the core verb, object, and parameters (with their
/// original casing) are preserved, so downstream parsers see a clean imperative.
enum QueryNormalizer {

    /// Phrases removed from the FRONT of a query (longest/most-specific first so they win).
    private static let leadingFillers: [String] = [
        "hey alfred", "ok alfred", "okay alfred", "yo alfred", "hi alfred", "alfred",
        "can you please", "could you please", "would you please", "will you please",
        "i want you to", "i'd like you to", "i would like you to", "i need you to",
        "please can you", "please could you",
        "can you", "could you", "would you", "will you", "can u", "could u",
        "please go ahead and", "go ahead and",
        "please", "pls", "plz", "kindly",
    ]

    /// Phrases removed from the END of a query.
    private static let trailingFillers: [String] = [
        "please", "for me", "thanks", "thank you", "pls", "plz", "asap", "right now", "now",
    ]

    static func normalize(_ query: String) -> String {
        var s = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading fillers repeatedly ("hey alfred can you please open x" → "open x").
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for filler in leadingFillers where lower.hasPrefix(filler) {
                let after = s.index(s.startIndex, offsetBy: filler.count)
                guard after < s.endIndex else { continue }   // whole query is filler — keep it
                let boundary = s[after]
                guard boundary == " " || boundary == "," else { continue }   // must be a word boundary
                s = String(s[after...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
                break
            }
        }

        // Strip trailing fillers repeatedly ("open spotify for me please" → "open spotify").
        changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for filler in trailingFillers where lower.hasSuffix(filler) {
                let cut = s.index(s.endIndex, offsetBy: -filler.count)
                guard cut > s.startIndex else { continue }
                let boundary = s[s.index(before: cut)]
                guard boundary == " " || boundary == "," else { continue }
                s = String(s[..<cut]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
                break
            }
        }

        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? query.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }
}
