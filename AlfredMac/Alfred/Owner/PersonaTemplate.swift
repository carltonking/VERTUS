import Foundation

// MARK: - PersonaTemplate (OCS §10)
//
// Renders the system prompt's opening from the owner configuration, in two clearly separated slots:
//
//   Slot 1  INVARIANT — code-controlled. Safety, honesty, anti-fabrication, confirmation of
//           irreversible acts, never-return-empty. Not configurable, because these are the
//           guarantees the product makes regardless of who owns it.
//   Slot 2  AUTHORED OWNER BLOCK — rendered from OwnerConfig. Identity, professional context, and
//           the voice preferences that used to be asserted as facts inside the invariant text.
//
// Slot 2 sits ABOVE every learned block (ProfileDigest, learned style rules, memories, relationship
// context, reflections, conversation history), so authored configuration is what the model reads
// first and learned observations cannot present themselves as equally authoritative (OCS §4).
//
// Template versioning: `templateVersion` is stamped into the rendered output's audit label so a
// prompt regression can be traced to a template change. Kept as a Swift constant rather than a
// bundled resource — the executable target's `Resources` directory holds only binary assets today,
// and a code constant keeps rendering deterministic in tests with no bundle lookup.

enum PersonaTemplate {

    /// Bump when the wording or slot structure changes.
    static let templateVersion = 1

    // MARK: - Slot 1: invariant

    /// Instructions that must hold for every owner. Voice preferences that genuinely belong to the
    /// owner (length, bullets, directness, time format, whether to push back) have been REMOVED from
    /// here and are rendered from configuration in slot 2 instead.
    ///
    /// Deliberately retained as invariant, because they are safety properties rather than taste:
    ///   • never invent status or data that was not provided,
    ///   • answer the current message,
    ///   • confirm irreversible or outward-facing actions,
    ///   • ask one question when an essential detail is genuinely missing,
    ///   • never return an empty reply.
    static func invariantInstructions(assistantName: String = "Alfred", currentDate: String) -> String {
        """
        You are \(assistantName), a personal assistant working for one person. You are not a generic
        chatbot: you act on their behalf, on their machine, with their data.

        GROUND RULES — these hold regardless of any preference stated below:
        - NEVER invent or guess status. If you weren't actually given data this turn (no calendar, no
          email, no file), do not claim to know it and do not describe it — say nothing about it
          rather than making something up.
        - Answer the CURRENT message. Recent conversation is background only; do not drag in an
          earlier, unrelated topic unless they clearly refer back to it. Never invent a task they
          didn't ask for.
        - A short reply like "yes", "ok", or "do it" confirms the thing you offered in your previous
          turn — carry it out. If your last turn offered nothing to confirm, briefly ask what they'd
          like. ALWAYS reply with something; never return an empty message.
        - Confirm BEFORE anything irreversible or outward-facing: deleting, or sending/posting on
          their behalf. Everything else, the request itself is your permission.
        - If an essential detail is genuinely missing (who to message, which file or item), ask ONE
          short question. Never invent a detail. Don't ask about things with a sensible default.
        - Be intellectually honest. Say when you're uncertain, and don't present a guess as a fact.

        CAPABILITY:
        - Answer any question as fully and well as a top general assistant: explain concepts, write
          and debug code, do math, draft and edit writing, reason through problems, give advice.
          Match effort to the question — a quick fact gets a sentence; "explain/why/how/design" gets
          a complete, well-structured answer.
        - You also act on this Mac (apps, files, calendar, web, screen context). Use that when it
          helps; otherwise just answer like the capable assistant you are.

        Current date and time (the owner's local time): \(currentDate)
        """
    }

    // MARK: - Slot 2: authored owner block

    /// Render the owner block from configuration.
    ///
    /// Returns "" when nothing is configured, so an unconfigured install produces no block at all
    /// rather than a paragraph of placeholders. Every field is omitted individually when absent —
    /// there is no "REQUIRES_USER_INPUT" text path into a prompt.
    static func ownerBlock(_ snapshot: OwnerConfigSnapshot) -> String {
        let c = snapshot.config
        var lines: [String] = []

        // Identity ------------------------------------------------------------------
        let name = snapshot.preferredName ?? snapshot.fullName
        if let name {
            var who = "You work for \(name)"
            if let role = c.identity.roleTitle?.nilIfEmptyOwnerValue {
                who += ", \(role)"
                if let org = c.identity.organization?.nilIfEmptyOwnerValue { who += " at \(org)" }
            } else if let org = c.identity.organization?.nilIfEmptyOwnerValue {
                who += " at \(org)"
            }
            lines.append(who + ".")
        }

        let p = c.identity.pronouns
        if name != nil {
            lines.append("Refer to them as \(p.subject)/\(p.object)/\(p.possessive).")
        }

        if let summary = c.professional.summaryLine?.nilIfEmptyOwnerValue {
            lines.append(summary)
        }
        if !c.professional.expertiseAreas.isEmpty {
            lines.append("Their work centers on: \(c.professional.expertiseAreas.joined(separator: ", ")).")
        }
        if !c.professional.industries.isEmpty {
            lines.append("Industries: \(c.professional.industries.joined(separator: ", ")).")
        }

        lines.append("Write times in \(c.identity.timeFormat.promptLabel), in their local time (\(c.identity.timeZone)).")

        // Voice preferences — formerly hardcoded assertions, now owner-authored ------
        if let register = snapshot.defaultRegister {
            lines += voiceLines(register)
        }
        for rule in c.communication.global.rules where !rule.trimmed.isEmpty {
            lines.append(rule.trimmed)
        }

        // Vocabulary ----------------------------------------------------------------
        let terms = c.vocabulary.terms.filter { !$0.value.trimmed.isEmpty }
        if !terms.isEmpty {
            let rendered = terms.sorted { $0.key < $1.key }
                .map { "\($0.key) = \"\($0.value)\"" }.joined(separator: ", ")
            lines.append("Use their vocabulary: \(rendered).")
        }

        guard !lines.isEmpty else { return "" }
        return """
            ABOUT THE PERSON YOU WORK FOR — this is their own configuration, written by them. It is
            authoritative: where anything you have learned or been told conflicts with it, this wins.
            \(lines.map { "- \($0)" }.joined(separator: "\n"))
            """
    }

    /// Voice lines derived from the active register. Each is emitted only when the owner set it.
    private static func voiceLines(_ r: OwnerConfig.Communication.Register) -> [String] {
        var out: [String] = []
        if let tone = r.tone?.nilIfEmptyOwnerValue { out.append("Tone: \(tone).") }
        if let length = r.typicalLength {
            switch length {
            case .oneLine: out.append("Default to a single line.")
            case .short:   out.append("Default to short answers — a line or two unless the substance needs more.")
            case .medium:  out.append("Default to a moderate length.")
            case .long:    out.append("Longer, more complete answers are welcome.")
            }
        }
        if let bullets = r.useBullets {
            switch bullets {
            case .never:       out.append("Do not use bullet-point lists.")
            case .whenListing: out.append("Use bullets only when genuinely listing things.")
            case .freely:      out.append("Bullets are fine whenever they help.")
            }
        }
        if let directness = r.directness {
            if directness >= 4 {
                out.append("Be direct: lead with the answer, cut preamble and hedging. Push back respectfully when something is debatable rather than simply agreeing.")
            } else if directness <= 2 {
                out.append("Be gentle and diplomatic in how you put things.")
            }
        }
        if let formality = r.formality {
            if formality >= 4 { out.append("Keep the register formal.") }
            else if formality <= 2 { out.append("Keep the register casual.") }
        }
        if let detail = r.technicalDetail {
            switch detail {
            case .minimal: out.append("Keep technical detail to a minimum.")
            case .working: out.append("Assume working technical knowledge.")
            case .deep:    out.append("Deep technical detail is expected.")
            }
        }
        for phrase in r.avoidPhrases where !phrase.trimmed.isEmpty {
            out.append("Never use the phrase \"\(phrase.trimmed)\".")
        }
        for claim in r.avoidClaims where !claim.trimmed.isEmpty {
            out.append("Never claim or commit to: \(claim.trimmed).")
        }
        return out
    }

    // MARK: - Composition

    /// Slot 1 + slot 2, in order. This is what replaces `AssistantPersona.systemIntro` when the
    /// owner-configuration feature flag is on and a configuration exists.
    static func render(snapshot: OwnerConfigSnapshot?, currentDate: String,
                       assistantName: String = "Alfred") -> String {
        let invariant = invariantInstructions(assistantName: assistantName, currentDate: currentDate)
        guard let snapshot, snapshot.allows(.ownerProfileBlock) else { return invariant }
        let block = ownerBlock(snapshot)
        return block.isEmpty ? invariant : invariant + "\n\n" + block
    }

    /// Non-sensitive provenance for audit lines: which configuration revision and template version
    /// produced a prompt. Records the pointer, never the content.
    static func auditLabel(snapshot: OwnerConfigSnapshot?) -> String {
        guard let snapshot else { return "ownerConfig:none template:v\(templateVersion)" }
        return "ownerConfig:\(snapshot.auditLabel) template:v\(templateVersion)"
    }
}
