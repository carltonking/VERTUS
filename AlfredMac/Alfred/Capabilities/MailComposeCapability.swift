import AppKit
import Contacts
import Foundation

/// Email via the Mail.app bridge (Blueprint v1 §9: email is read/summarize/draft, **send gated**).
///
/// Default is DRAFT — open a pre-filled Mail compose window the user reviews and sends themselves.
/// Auto-send happens ONLY when the user explicitly says "send" AND a body is present AND they
/// confirm. Recipient resolved from Contacts (or used directly if it's already an address).
@MainActor
struct MailComposeCapability {

    struct Intent: Equatable {
        let recipient: String
        let subject: String?
        let body: String?          // verbatim text the user dictated ("saying ...") — sent as-is
        let instruction: String?   // freeform ask ("telling her I'll be late") — drafted by the LLM
        let send: Bool

        init(recipient: String, subject: String?, body: String?, instruction: String? = nil, send: Bool) {
            self.recipient = recipient
            self.subject = subject
            self.body = body
            self.instruction = instruction
            self.send = send
        }
    }

    // MARK: - Detection

    static func detect(in query: String) -> Intent? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let triggers = ["draft an email to ", "draft email to ", "compose an email to ",
                        "compose email to ", "write an email to ", "write email to ",
                        "send an email to ", "send email to ", "send a email to ",
                        "email to ", "email "]
        guard let t = triggers.first(where: { lower.hasPrefix($0) }) else { return nil }
        let rest = String(trimmed.dropFirst(t.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }

        // "send" is an auto-send request only if not explicitly a draft/compose/write.
        let send = lower.contains("send ")
            && !lower.contains("draft") && !lower.contains("compose") && !lower.contains("write")

        let (recipient, subject, body, instruction) = parse(rest)
        guard !recipient.isEmpty else { return nil }
        return Intent(recipient: recipient, subject: subject, body: body, instruction: instruction, send: send)
    }

    /// Splits "<recipient> about <subject> [saying <verbatim body> | telling them <instruction>]"
    /// into parts (each optional after the recipient). A "saying/message:" clause is the user's
    /// VERBATIM text; a "telling/asking/that" clause — or a bare "about <topic>" with no body — is
    /// an INSTRUCTION the drafting brain turns into a message. Verbatim wins on overlap (e.g.
    /// " that says " contains " that ").
    static func parse(_ rest: String) -> (recipient: String, subject: String?, body: String?, instruction: String?) {
        // Search the original string (case-insensitively) so every index is valid on `rest`.
        // Indices taken from a separate lowercased copy shift and can trap on length-changing
        // characters (e.g. "İ", "ẞ").
        func firstRange(_ keys: [String]) -> Range<String.Index>? {
            keys.compactMap { rest.range(of: $0, options: .caseInsensitive) }.min { $0.lowerBound < $1.lowerBound }
        }
        let subjMatch = firstRange([" about ", " regarding ", " re: ", " subject "])
        let bodyMatch = firstRange([" saying ", " that says ", " body: ", " message: "])
        let instrMatch = firstRange([" telling ", " to tell ", " tell ", " letting ", " to let ",
                                     " asking ", " to ask ", " to say ", " that "])

        var cut = rest.endIndex
        for m in [subjMatch, bodyMatch, instrMatch].compactMap({ $0 }) { cut = min(cut, m.lowerBound) }
        let recipient = String(rest[rest.startIndex..<cut]).trimmingCharacters(in: .whitespaces)

        var subject: String?
        if let s = subjMatch {
            var end = rest.endIndex
            for m in [bodyMatch, instrMatch].compactMap({ $0 }) where m.lowerBound > s.lowerBound {
                end = min(end, m.lowerBound)
            }
            let v = String(rest[s.upperBound..<end]).trimmingCharacters(in: .whitespaces)
            subject = v.isEmpty ? nil : v
        }

        // Earliest of body/instruction owns the content; verbatim body wins ties.
        var body: String?
        var instruction: String?
        if let b = bodyMatch, instrMatch == nil || b.lowerBound <= instrMatch!.lowerBound {
            let v = String(rest[b.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = v.isEmpty ? nil : v
        } else if let i = instrMatch {
            let v = String(rest[i.upperBound...]).trimmingCharacters(in: .whitespaces)
            instruction = v.isEmpty ? nil : v
        }
        // "email Sarah about the Q3 report" (no verbatim/instruction) → draft about the topic.
        if body == nil, instruction == nil, let subj = subject { instruction = subj }

        return (recipient, subject, body, stripLeadingObjectPronoun(instruction))
    }

    // MARK: - Recipient resolution

    nonisolated func resolveEmail(for recipient: String) async -> (email: String, display: String)? {
        let r = recipient.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return nil }
        if r.contains("@") { return (r, r) }

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: break
        case .notDetermined: guard await Self.requestContactsAccess() else { return nil }
        default: return nil
        }
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        guard let contacts = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: r), keysToFetch: keys) else { return nil }
        for c in contacts {
            if let email = c.emailAddresses.first?.value as String? {
                let display = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return (email, display.isEmpty ? r : display)
            }
        }
        return nil
    }

    private nonisolated static func requestContactsAccess() async -> Bool {
        await withCheckedContinuation { cont in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in cont.resume(returning: granted) }
        }
    }

    // MARK: - Compose / send

    func compose(to email: String, display: String, subject: String?, body: String?, send: Bool) -> String {
        let subj = subject ?? ""
        let bodyText = body ?? ""
        // Never auto-send an empty message; fall back to a reviewable draft.
        let doSend = send && !bodyText.trimmingCharacters(in: .whitespaces).isEmpty

        if doSend {
            guard Self.confirmSend(to: display, subject: subj, body: bodyText) else { return "Email cancelled." }
        }

        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(Self.esc(subj))", content:"\(Self.escBody(bodyText))", visible:true}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:"\(Self.esc(email))"}
            end tell
            \(doSend ? "send newMessage" : "")
            activate
        end tell
        """
        var err: NSDictionary?
        let ran = NSAppleScript(source: script)?.executeAndReturnError(&err) != nil && err == nil
        guard ran else {
            return "Couldn't \(doSend ? "send" : "draft") the email — make sure Mail is set up and Alfred has Automation permission for Mail (System Settings → Privacy & Security → Automation)."
        }
        if doSend { return "Sent email to \(display)." }
        if send { return "Opened a draft to \(display) in Mail — add your message and send." }
        return "Drafted an email to \(display) in Mail — review it and hit send."
    }

    // MARK: - Helpers

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }

    /// Escapes a multi-line body for AppleScript, turning newlines into `return` concatenation so a
    /// drafted email keeps its paragraphs (greeting / body / sign-off on separate lines).
    private static func escBody(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
                       .replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
        return escaped.replacingOccurrences(of: "\n", with: "\" & return & \"")
    }

    private static func confirmSend(to display: String, subject: String, body: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send this email?"
        alert.informativeText = "To \(display)\nSubject: \(subject.isEmpty ? "(none)" : subject)\n\n\(body)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
