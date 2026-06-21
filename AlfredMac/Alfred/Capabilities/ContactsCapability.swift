import Foundation
import Contacts

// MARK: - ContactsCapability
//
// Local, zero-auth contact lookup via the Contacts framework — "what's Mom's number", "email for
// Jake", "how do I reach Sarah". Reuses the Contacts permission already requested for Messages read.
// Read-only. Routed before the LLM so phone/email come back exact (no hallucinated digits).

enum ContactsCapability {

    /// Returns a contact-card answer when the query is a contact lookup, else nil.
    static func handle(_ query: String) async -> String? {
        guard let name = detectName(in: query) else { return nil }
        await ensureAccess()
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return "I need Contacts access to look that up — System Settings → Privacy & Security → Contacts → Alfred."
        }
        return lookup(name: name)
    }

    static func ensureAccess() async {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        _ = await withCheckedContinuation { cont in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in cont.resume(returning: granted) }
        }
    }

    /// Pulls the person's name out of phrasings like "what's Mom's number", "email for Jake",
    /// "phone number for Sarah Lee", "how do I reach Alex". Returns nil if it isn't a lookup.
    private static func detectName(in query: String) -> String? {
        let lowered = query.lowercased()

        // Compose/action requests ("send this email to Jake", "reply to this email", "summarize ...")
        // are for the LLM, not a contact lookup. Bail before the lookup heuristics run.
        let actionVerbs = ["send", "draft", "reply", "forward", "compose", "respond", "write ",
                           "summarize", "summarise", " cc ", " bcc "]
        if actionVerbs.contains(where: { lowered.contains($0) }) { return nil }

        let isLookup = ["number", "phone", "email", "e-mail", "reach", "contact", "cell", "mobile"]
            .contains { lowered.contains($0) }
        guard isLookup else { return nil }

        // Possessive "<name>'s number". Strip a leading interrogative first so "what's Mom's number"
        // doesn't match the "'s" inside "what's".
        var work = query
        for lead in ["what's ", "whats ", "what is ", "whose is ", "give me ", "tell me ", "show me "] {
            if work.lowercased().hasPrefix(lead) { work = String(work.dropFirst(lead.count)); break }
        }
        if let r = work.range(of: "'s ", options: .caseInsensitive) ?? work.range(of: "’s ", options: .caseInsensitive) {
            let before = String(work[..<r.lowerBound])
            if let name = lastNameWords(before), looksLikeName(name) { return name }
        }
        // "... for <name>" / "... reach <name>". Deliberately NOT " to "/" of " — they fire on
        // ordinary sentences ("send this to Jake", "summary of the day").
        for marker in [" for ", " reach " ] {
            if let r = lowered.range(of: marker) {
                let after = String(query[query.index(query.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: r.upperBound))...])
                let name = stripTrailingNoise(after.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,")))
                if looksLikeName(name) { return name }
            }
        }
        return nil
    }

    /// A real lookup target looks like a name: 1–3 words, at least one capitalized token, no leading
    /// article. Rejects junk like "the team about the launch" or "a pizza place".
    private static func looksLikeName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count < 40 else { return false }
        let words = t.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        let articles: Set<String> = ["a", "an", "the", "this", "that", "my", "some", "any", "your"]
        if let first = words.first, articles.contains(first.lowercased()) { return false }
        return words.contains { $0.first?.isUppercase == true }   // names are capitalized
    }

    /// Last 1–3 capitalized-ish words of a fragment (a person's name), skipping filler.
    private static func lastNameWords(_ fragment: String) -> String? {
        let filler: Set<String> = ["what", "whats", "what's", "is", "the", "my", "a", "give", "me",
                                   "tell", "show", "find", "get", "do", "you", "have", "know"]
        let words = fragment.split(separator: " ").map(String.init).filter { !filler.contains($0.lowercased()) }
        guard !words.isEmpty else { return nil }
        return words.suffix(3).joined(separator: " ")
    }

    private static func stripTrailingNoise(_ s: String) -> String {
        var out = s
        for tail in [" number", " phone", " email", " cell", " info", " contact"] {
            if out.lowercased().hasSuffix(tail) { out = String(out.dropLast(tail.count)) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func lookup(name: String) -> String {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]

        var matches: [CNContact] = []
        let predicate = CNContact.predicateForContacts(matchingName: name)
        if let found = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) {
            matches = found
        }
        // Fallback: predicate misses nicknames/partials — scan all and substring-match.
        if matches.isEmpty {
            let req = CNContactFetchRequest(keysToFetch: keys)
            let needle = name.lowercased()
            try? store.enumerateContacts(with: req) { c, _ in
                let full = "\(c.givenName) \(c.familyName) \(c.nickname)".lowercased()
                if full.contains(needle) { matches.append(c) }
            }
        }

        guard !matches.isEmpty else { return "No contact found for \"\(name)\"." }

        let cards = matches.prefix(3).map { c -> String in
            let display = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
            var parts: [String] = []
            for p in c.phoneNumbers { parts.append("\(labelName(p.label)): \(p.value.stringValue)") }
            for e in c.emailAddresses { parts.append("\(labelName(e.label)): \(e.value as String)") }
            let body = parts.isEmpty ? "no phone/email on file" : parts.joined(separator: "\n  ")
            return "\(display.isEmpty ? name : display):\n  \(body)"
        }
        return cards.joined(separator: "\n")
    }

    private static func labelName(_ raw: String?) -> String {
        guard let raw else { return "contact" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }
}
