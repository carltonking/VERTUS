import AppKit
import Contacts
import Foundation

/// Send an iMessage to a named person (Blueprint v1 §9: messaging is a high-risk write — always
/// confirm). Detects "text <name> [saying <message>]". Resolves <name> → an iMessage handle via
/// Contacts, confirms, then sends through Messages.app via AppleScript. If no message is given,
/// the caller asks the user for it (two-turn flow).
@MainActor
struct MessagingCapability {

    struct Intent: Equatable {
        let name: String
        let message: String?       // verbatim text the user dictated — sent as-is
        let instruction: String?   // freeform ask ("telling her I'm running late") — drafted by the LLM

        init(name: String, message: String?, instruction: String? = nil) {
            self.name = name
            self.message = message
            self.instruction = instruction
        }
    }

    struct Recipient {
        let handle: String   // phone number or email
        let display: String
    }

    // MARK: - Detection

    static func detect(in query: String) -> Intent? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        // Most specific first so "send a text to" wins over "text".
        let triggers = ["send a text to ", "send text to ", "send an imessage to ",
                        "send a message to ", "send message to ", "imessage ", "text ", "message "]
        for t in triggers where lower.hasPrefix(t) {
            let rest = String(trimmed.dropFirst(t.count)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            let (name, message, instruction) = splitNameMessage(rest)
            guard !name.isEmpty else { return nil }
            return Intent(name: name, message: message, instruction: instruction)
        }
        return nil
    }

    /// Splits "<name> [, hi | saying hi | telling them I'm late | about dinner]" into parts. A
    /// comma / "saying" / "message:" clause is the user's VERBATIM text; a "telling/about/that"
    /// clause is an INSTRUCTION the drafting brain writes. With no delimiter the whole string is the
    /// name and both are nil (the caller then asks what to send). Verbatim wins on overlap.
    static func splitNameMessage(_ rest: String) -> (name: String, message: String?, instruction: String?) {
        // Search the original string (case-insensitively) so every index is valid on `rest`;
        // indices from a separate lowercased copy can shift and trap on length-changing characters.
        func firstRange(_ keys: [String]) -> Range<String.Index>? {
            keys.compactMap { rest.range(of: $0, options: .caseInsensitive) }.min { $0.lowerBound < $1.lowerBound }
        }
        let verbatim = firstRange([", ", ",", " saying ", " that says ", " message: ", ": ", " - "])
        let instr = firstRange([" telling them ", " tell them ", " to tell them ", " telling ", " tell ",
                                " letting them know ", " let them know ", " asking ", " to ask ",
                                " to say ", " about ", " that "])

        var cut = rest.endIndex
        for m in [verbatim, instr].compactMap({ $0 }) { cut = min(cut, m.lowerBound) }
        let name = String(rest[rest.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return (rest.trimmingCharacters(in: .whitespaces), nil, nil) }

        var message: String?
        var instruction: String?
        if let v = verbatim, instr == nil || v.lowerBound <= instr!.lowerBound {
            let m = String(rest[v.upperBound...]).trimmingCharacters(in: .whitespaces)
            message = m.isEmpty ? nil : m
        } else if let i = instr {
            let m = String(rest[i.upperBound...]).trimmingCharacters(in: .whitespaces)
            instruction = m.isEmpty ? nil : m
        }
        return (name, message, stripLeadingObjectPronoun(instruction))
    }

    // MARK: - Contact resolution

    /// True when the user has explicitly denied/restricted Contacts (so the caller can tell them
    /// to grant it in Settings rather than "contact not found").
    nonisolated static func contactsAccessDenied() -> Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        return s == .denied || s == .restricted
    }

    /// Resolves a name to an iMessage handle. A name that is already a phone/email is used as-is.
    /// Contacts access is requested AT MOST ONCE (only when undetermined) — TCC then remembers the
    /// decision, so subsequent texts don't re-prompt. Runs off the main actor so the UI never
    /// freezes ("thinking forever") while Contacts is queried.
    nonisolated func resolveRecipient(for name: String) async -> Recipient? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("@") || trimmed.range(of: "[0-9][0-9()+ -]{6,}", options: .regularExpression) != nil {
            return Recipient(handle: trimmed, display: trimmed)
        }

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            break
        case .notDetermined:
            guard await Self.requestContactsAccess() else { return nil }
        default:
            return nil   // denied / restricted
        }
        return Self.lookup(name: trimmed)
    }

    private nonisolated static func requestContactsAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func lookup(name: String) -> Recipient? {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        guard let contacts = try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys),
              let contact = contacts.first else { return nil }

        // Build the name from the keys we actually fetched. CNContactFormatter reads
        // middleName/prefix/suffix — unfetched keys throw CNPropertyNotFetchedException → crash.
        let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let display = full.isEmpty ? name : full
        if let phone = contact.phoneNumbers.first?.value.stringValue {
            return Recipient(handle: phone, display: display)
        }
        if let email = contact.emailAddresses.first?.value as String? {
            return Recipient(handle: email, display: display)
        }
        return nil
    }

    // MARK: - Send (with confirmation)

    func confirmAndSend(message: String, to recipient: Recipient) -> String {
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "No message to send."
        }
        guard Self.confirm(to: recipient.display, message: message) else { return "Message cancelled." }
        return send(message: message, toHandle: recipient.handle)
            ? "Sent to \(recipient.display)."
            : "Couldn't send. Make sure Messages is signed in and Alfred has Automation permission for Messages (System Settings → Privacy & Security → Automation)."
    }

    /// Raw send (no confirmation UI). The interactive path goes through `confirmAndSend`; the iMessage
    /// bot reuses this directly after its own text-confirmation round-trip.
    func send(message: String, toHandle handle: String) -> Bool {
        let script = """
        tell application "Messages"
            activate
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(Self.escape(handle))" of targetService
            send "\(Self.escape(message))" to targetBuddy
        end tell
        """
        var errorDict: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errorDict)
        return result != nil && errorDict == nil
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func confirm(to display: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send this message?"
        alert.informativeText = "To \(display):\n\n“\(message)”"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
