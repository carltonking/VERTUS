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
        let message: String?
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
            let (name, message) = splitNameMessage(rest)
            guard !name.isEmpty else { return nil }
            return Intent(name: name, message: message)
        }
        return nil
    }

    /// Splits "bob saying hi" / "bob: hi" into (name, message). With no delimiter the whole
    /// string is the name and message is nil (the caller then asks for the message).
    static func splitNameMessage(_ rest: String) -> (name: String, message: String?) {
        let lower = rest.lowercased()
        // Comma is the most natural split ("text carlton, hey").
        let delimiters = [", ", ",", " saying ", " that says ", " telling them ", " tell them ",
                          " message: ", ": ", " - ", " about "]
        for d in delimiters {
            if let r = lower.range(of: d) {
                let offset = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let endOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
                let name = String(rest.prefix(offset)).trimmingCharacters(in: .whitespaces)
                let msg = String(rest.dropFirst(endOffset)).trimmingCharacters(in: .whitespaces)
                return (name, msg.isEmpty ? nil : msg)
            }
        }
        return (rest, nil)
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

    private func send(message: String, toHandle handle: String) -> Bool {
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
