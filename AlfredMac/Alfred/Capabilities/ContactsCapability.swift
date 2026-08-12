import Contacts
import Foundation

/// Resolves a person's name to their contact record, so the model can turn
/// "text Rohan" into a handle the Messages capability can send to.
///
/// The model's failure mode before this existed was improvising: with no way to
/// look a name up, Hermes asked the user for Rohan's phone number (or made one
/// up). Contacts lookup closes that gap — the chat's own database only knows
/// handles like `+1 555…` or `email@icloud.com`, not that they're "Rohan", and
/// this connects the two.
struct ContactsCapability {

    /// Collect a single contact's sendable handles, prefixed with the name.
    struct Contact {
        let fullName: String
        let phones: [(label: String, value: String)]
        let emails: [(label: String, value: String)]

        /// Renders one numbered line for the search output so the model can pick
        /// which handle to send to.
        func line(_ index: Int) -> String {
            var handles: [String] = []
            handles.append(contentsOf: phones.map { label, value in
                "\(label.isEmpty ? "phone" : label):\(value)"
            })
            handles.append(contentsOf: emails.map { label, value in
                "\(label.isEmpty ? "email" : label):\(value)"
            })
            guard !handles.isEmpty else { return "\(index). \(fullName) — no phone or email on record" }
            return "\(index). \(fullName)\n   \(handles.joined(separator: " · "))"
        }
    }

    func findContact(query: String) async throws -> String {
        let store = CNContactStore()

        // Same shape as CalendarCapability.makeStore: prompt on first use, point
        // at System Settings on a denial. Contacts only needs the read grant, so
        // it's a single authorize-ornot path.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        var authorized = false
        switch status {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = try await store.requestAccess(for: .contacts)
        default:
            break
        }
        guard authorized else {
            throw CapabilityError.denied("Alfred can't read your contacts yet. Grant it in System Settings → Privacy & Security → Contacts, then try again.")
        }

        // CNContactFormatter.string(from:style:) silently throws an uncaught ObjC
        // NSException if the contact record lacks any key it touches (middle name,
        // nickname, …), so it must be given exactly the descriptor it needs.
        var keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        keys.append(CNContactFormatter.descriptorForRequiredKeys(for: .fullName))

        // unifiedContacts(matching:) throws, so a bad predicate (rare) becomes a
        // clean error instead of a crash.
        let matches: [CNContact]
        do {
            matches = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: query),
                keysToFetch: keys)
        } catch {
            throw CapabilityError.denied("Couldn't search Contacts: \(error.localizedDescription)")
        }

        let contacts = matches
            .filter { !$0.phoneNumbers.isEmpty || !$0.emailAddresses.isEmpty }
            .map { contact in
                Contact(
                    fullName: Self.displayName(contact),
                    phones: contact.phoneNumbers.map {
                        ($0.label ?? "", $0.value.stringValue) },
                    emails: contact.emailAddresses.map {
                        ($0.label ?? "", $0.value as String) })
            }
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }

        guard !contacts.isEmpty else {
            return "No contacts match \"\(query)\". Try a fuller name or part of an email."
        }

        let heading = contacts.count == 1
            ? "Found:"
            : "Found \(contacts.count) matches:"
        return heading + "\n" + contacts.enumerated().map { $0.element.line($0.offset + 1) }.joined(separator: "\n")
    }

    /// "Rohan Mehta" → "Rohan Mehta"; falls back to nickname or family name.
    private static func displayName(_ contact: CNContact) -> String {
        let full = CNContactFormatter.string(
            from: contact, style: .fullName) ?? ""
        let nickname = contact.nickname
        if full.isEmpty, !nickname.isEmpty { return nickname }
        return full
    }

    struct CapabilityError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
        static func denied(_ message: String) -> Self { Self(reason: message) }
    }
}