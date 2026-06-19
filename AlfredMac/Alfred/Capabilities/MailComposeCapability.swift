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
        let body: String?
        let send: Bool
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

        let (recipient, subject, body) = parse(rest)
        guard !recipient.isEmpty else { return nil }
        return Intent(recipient: recipient, subject: subject, body: body, send: send)
    }

    /// Splits "<recipient> about <subject> saying <body>" into its parts (each optional after the
    /// recipient). The recipient is everything before the first subject/body delimiter.
    static func parse(_ rest: String) -> (recipient: String, subject: String?, body: String?) {
        let lower = rest.lowercased()
        func firstRange(_ keys: [String]) -> Range<String.Index>? {
            keys.compactMap { lower.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        }
        let subjMatch = firstRange([" about ", " subject ", " regarding ", " re: "])
        let bodyMatch = firstRange([" saying ", " that says ", " body: ", " message: ", ": "])

        var cut = rest.endIndex
        if let s = subjMatch { cut = min(cut, s.lowerBound) }
        if let b = bodyMatch { cut = min(cut, b.lowerBound) }
        let recipient = String(rest[rest.startIndex..<cut]).trimmingCharacters(in: .whitespaces)

        var subject: String?
        if let s = subjMatch {
            var end = rest.endIndex
            if let b = bodyMatch, b.lowerBound > s.lowerBound { end = b.lowerBound }
            let v = String(rest[s.upperBound..<end]).trimmingCharacters(in: .whitespaces)
            subject = v.isEmpty ? nil : v
        }
        var body: String?
        if let b = bodyMatch {
            let v = String(rest[b.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = v.isEmpty ? nil : v
        }
        return (recipient, subject, body)
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
            set newMessage to make new outgoing message with properties {subject:"\(Self.esc(subj))", content:"\(Self.esc(bodyText))", visible:true}
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
