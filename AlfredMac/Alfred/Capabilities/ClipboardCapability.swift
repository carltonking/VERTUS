import Foundation
import AppKit

// MARK: - ClipboardCapability
//
// Local, zero-auth read of the macOS clipboard — "what's in my clipboard", "what did I copy".
// Read-only (never writes). Routed before the LLM so the content is verbatim.

enum ClipboardCapability {

    static func handle(_ query: String) -> String? {
        let q = query.lowercased()
        let triggers = ["what's in my clipboard", "whats in my clipboard", "what's on my clipboard",
                        "read my clipboard", "what did i copy", "what's copied", "whats copied",
                        "my clipboard", "show my clipboard", "paste my clipboard", "clipboard contents"]
        guard triggers.contains(where: { q.contains($0) }) else { return nil }

        let pb = NSPasteboard.general
        if let text = pb.string(forType: .string), !text.isEmpty {
            let trimmed = text.count > 1000 ? String(text.prefix(1000)) + "…" : text
            return "Your clipboard:\n\(trimmed)"
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return "Your clipboard has an image on it."
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return "Your clipboard:\n" + urls.map(\.path).joined(separator: "\n")
        }
        return "Your clipboard is empty (or holds something I can't read as text)."
    }
}
