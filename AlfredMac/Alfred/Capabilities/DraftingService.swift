import Foundation

/// Drops a leading object pronoun the verb governs ("telling HER I'll be late" → "I'll be late")
/// so a drafting instruction reads cleanly. Shared by the email and text intent parsers. A
/// free function (not an actor method) so the non-isolated parsers can call it.
func stripLeadingObjectPronoun(_ s: String?) -> String? {
    guard let s else { return nil }
    let pronouns = ["her ", "him ", "them ", "'em ", "they "]
    let lower = s.lowercased()
    for p in pronouns where lower.hasPrefix(p) {
        let stripped = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? s : stripped
    }
    return s
}

/// The "drafting brain" behind email and text. Turns a freeform instruction ("tell Sarah I'll be
/// 10 minutes late") into a message body that sounds like the user, by combining:
///   • the learned WRITING VOICE (WritingStyleStore.generateStyleContext) — phrasing, greetings,
///     closings, formality, emoji habits, and
///   • per-recipient RELATIONSHIP context (RelationshipStore.contextForPerson) — who this is and
///     the tone the user uses with them.
///
/// It only GENERATES text. Nothing here sends — the caller always routes the result through the
/// existing draft/confirm flow (a reviewable Mail draft, or the iMessage confirmation alert), so
/// the app's send-gating and SafetyAuditEngine guarantees are preserved.
@MainActor
final class DraftingService {

    enum Channel {
        case email, text
        var label: String { self == .email ? "email" : "text message" }
    }

    private let router: LLMRouter
    private let writingStyle: WritingStyleStore?
    private let relationships: RelationshipStore?
    private let ownerName: String

    init(router: LLMRouter,
         writingStyle: WritingStyleStore?,
         relationships: RelationshipStore?,
         ownerName: String) {
        self.router = router
        self.writingStyle = writingStyle
        self.relationships = relationships
        self.ownerName = ownerName.trimmingCharacters(in: .whitespaces)
    }

    /// Generate a message body from a freeform `instruction`, in the user's voice, addressed to
    /// `recipientDisplay`. `recipientName` is the raw name used to look up relationship context.
    /// `threadContext` is the prior message/email being replied to, when available.
    /// Returns the cleaned body, or nil on failure so the caller can fall back to a manual draft.
    func draftBody(channel: Channel,
                   recipientName: String,
                   recipientDisplay: String,
                   instruction: String,
                   threadContext: String? = nil) async -> String? {
        let instr = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty else { return nil }

        // Few-shot the model with REAL writing samples — far stronger imitation than the statistics
        // alone. Exemplars are first-party (the owner's own words), so unlike relationship notes
        // they are NOT gated to local providers; the router's egress redaction still applies. Prefer
        // the channel's source: real sent iMessages (then Alfred-chat) for texts, email for email.
        let preferredSources: [WritingSource] = channel == .email ? [.email] : [.imessage, .chat]
        let exemplars = writingStyle?.voiceExemplars(preferredSources: preferredSources) ?? []
        // Free-text relationship notes stay on-device: only include them for a local provider.
        let who = relationships?.contextForPerson(name: recipientName,
                                                  includeNotes: !router.isActiveProviderCloud)

        let system = Self.buildSystemPrompt(
            owner: ownerName,
            channel: channel,
            recipientDisplay: recipientDisplay,
            styleContext: writingStyle?.generateStyleContext(),
            exemplars: exemplars,
            relationshipContext: who
        )

        var user = "Write a \(channel.label) to \(recipientDisplay). The message should: \(instr)"
        if let thread = threadContext?.trimmingCharacters(in: .whitespacesAndNewlines), !thread.isEmpty {
            user += "\n\nYou are replying to this message:\n\"\"\"\n\(String(thread.prefix(2000)))\n\"\"\""
        }

        do {
            let raw = try await router.complete(prompt: user, system: system)
            let body = Self.clean(raw)
            return body.isEmpty ? nil : body
        } catch {
            return nil
        }
    }

    /// Builds the drafting system prompt. Pure (no actor state / network) so it's unit-testable:
    /// base instructions + channel guidance + the statistical voice profile + few-shot real-writing
    /// exemplars + per-recipient context. Only the drafting path uses this — the general assistant
    /// prompt (AssistantCore.buildSystem) is deliberately untouched.
    nonisolated static func buildSystemPrompt(owner ownerName: String,
                                              channel: Channel,
                                              recipientDisplay: String,
                                              styleContext: String?,
                                              exemplars: [String],
                                              relationshipContext: String?) -> String {
        let owner = ownerName.isEmpty ? "the user" : ownerName

        var system = """
        You are \(owner)'s personal assistant, writing a \(channel.label) on their behalf to \
        \(recipientDisplay). Write ONLY the message body, in \(owner)'s own voice — no preamble, no \
        explanation, no subject line, and no bracketed placeholders like [Name]. Do not wrap the \
        message in quotes. Produce exactly what \(owner) would send.
        """

        switch channel {
        case .email:
            system += "\nUse a natural greeting and sign-off consistent with the writing style below."
        case .text:
            system += "\nKeep it short and conversational like a real text — usually 1–3 sentences, " +
                      "with no greeting or sign-off unless the style clearly calls for one."
        }

        if let voice = styleContext?.trimmingCharacters(in: .whitespacesAndNewlines), !voice.isEmpty {
            system += "\n\n--- HOW \(owner.uppercased()) WRITES ---\n\(voice)"
        }

        // Few-shot exemplars — only when we actually have real samples. "match the phrasing/voice,
        // NOT the content" makes the model copy voice rather than the sample's subject matter.
        if !exemplars.isEmpty {
            let bullets = exemplars.map { "• \"\($0)\"" }.joined(separator: "\n")
            system += "\n\n--- EXAMPLES OF \(owner.uppercased())'S ACTUAL WRITING " +
                      "(match the phrasing/voice, NOT the content) ---\n\(bullets)"
        }

        if let who = relationshipContext, !who.isEmpty {
            system += "\n\n--- WHO YOU'RE WRITING TO ---\n\(who)\n" +
                      "Match the tone and formality \(owner) would use with this person."
        }

        return system
    }

    /// Strip stray wrapping quotes and an accidental leading "Subject:" line some models add despite
    /// the instructions.
    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 1, t.hasPrefix("\""), t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.lowercased().hasPrefix("subject:"), let nl = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}
