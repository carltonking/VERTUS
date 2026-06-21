import Foundation

// MARK: - NotesCapability
//
// Local, zero-auth Apple Notes control via AppleScript — no API, no token. Create a note, search
// notes by title, or list recent ones. Routed through QuickCommands so it's instant and bypasses
// the LLM (reliable, and the local model is slow). Creating a note is a safe local write, so no
// confirmation gate (mirrors calendar create).
//
// v1 search is title-based (fast, reliable). Full body search / reading a note's contents is a
// later enhancement.

struct NotesCapability {

    enum Action {
        case create(String)   // note body (first line becomes the title)
        case search(String)   // title term
        case list
    }

    private static func hasAny(_ s: String, _ subs: [String]) -> Bool { subs.contains { s.contains($0) } }

    /// Maps a query to a Notes action, or nil. Checks SEARCH/LIST verbs before CREATE so
    /// "show my note about X" reads rather than creates.
    static func detect(_ original: String) -> Action? {
        let lowered = original.lowercased()
        guard lowered.contains("note") else { return nil }

        if lowered == "my notes" || lowered == "recent notes" || lowered == "list my notes"
            || lowered == "show my notes" || lowered == "show me my notes" { return .list }

        // Search: a read verb + a term after "about"/"for".
        if hasAny(lowered, ["find my note", "find note", "search my notes", "search notes",
                            "show my note", "show me my note", "do i have a note", "pull up my note",
                            "look for a note", "what notes", "note about", "notes about"]) {
            if let term = extractTerm(from: original) { return .search(term) }
            return .list
        }

        // Create: a write verb. Extract the content after it.
        for prefix in ["make a note that ", "make a note to ", "make a note ", "create a note that ",
                       "create a note ", "add a note that ", "add a note ", "take a note ",
                       "write a note ", "new note ", "note that ", "note to self ", "jot down ",
                       "remember that ", "remember to "] {
            if lowered.hasPrefix(prefix) {
                let content = String(original.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { return .create(content) }
            }
        }
        return nil
    }

    private static func extractTerm(from original: String) -> String? {
        let lowered = original.lowercased()
        for marker in [" about ", " for ", " containing ", " titled ", " called "] {
            if let r = lowered.range(of: marker) {
                let term = String(original[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
                if !term.isEmpty { return term }
            }
        }
        return nil
    }

    static func handle(_ action: Action) -> String {
        switch action {
        case .create(let content):
            let title = String(content.prefix(50))
            let body = escape(content)
            let result = runScript("""
                tell application "Notes"
                    make new note with properties {body:"\(body)"}
                end tell
                """, ok: "Saved to Notes: \(title)", fallback: "Couldn't save the note — is Notes set up?")
            return result
        case .search(let term):
            let out = runScript("""
                tell application "Notes"
                    set out to ""
                    set c to 0
                    repeat with n in (notes whose name contains "\(escape(term))")
                        if c ≥ 8 then exit repeat
                        set out to out & "• " & (name of n) & linefeed
                        set c to c + 1
                    end repeat
                    return out
                end tell
                """, fallback: "Couldn't reach Notes.")
            return out.isEmpty ? "No notes found with \"\(term)\" in the title." : "Notes matching \"\(term)\":\n\(out)"
        case .list:
            let out = runScript("""
                tell application "Notes"
                    set out to ""
                    set c to 0
                    repeat with n in notes
                        if c ≥ 8 then exit repeat
                        set out to out & "• " & (name of n) & linefeed
                        set c to c + 1
                    end repeat
                    return out
                end tell
                """, fallback: "Couldn't reach Notes.")
            return out.isEmpty ? "You don't have any notes yet." : "Your recent notes:\n\(out)"
        }
    }

    // MARK: - AppleScript

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }

    private static func runScript(_ source: String, ok: String = "", fallback: String) -> String {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return fallback }
        let output = script.executeAndReturnError(&errorDict)
        if errorDict != nil { return fallback }
        let text = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? ok : text
    }
}
