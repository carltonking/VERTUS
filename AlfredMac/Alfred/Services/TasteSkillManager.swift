//
//  TasteSkillManager.swift
//  Alfred
//
//  Alfred's anti-slop text layer — the philosophy of the open-source
//  taste-skill project (Leonxlnx/taste-skill, "the anti-slop framework for
//  AI agents") applied to text instead of UI design. The real taste-skill
//  is a set of prompt-conditioning skill files for frontend interfaces; the
//  text equivalent is what this manager provides locally and keylessly:
//
//   * A deterministic boringness evaluator (no model, instant) that scores
//     prose and short titles for generic phrasing and clichés, and
//   * A guarded Hermes rewrite turn that only fires when the evaluator
//     flags genuinely bland text — good writing is never double-charged a
//     model turn, and the rewritten result always degrades to the original.
//
//  Two integration modes, mirroring how the real taste-skill works:
//
//   * Condition generation — `generationGuidance(scope:)` injects a short
//     anti-slop paragraph into prompts Alfred already runs (the briefing,
//     the code agent), so output is born with taste instead of being
//     post-processed. Zero extra turns.
//   * Post-hoc polish — `polishIfNeeded(_:scope:)` rewrites a completed
//     draft (mail replies, routine names) when the evaluator says it's
//     bland. Bounded, gated, and always safe to drop.
//
//  Costs are real, so polish follows the house rules: `isTurnActive` is
//  checked before every model call, turns are bounded (60s), and the same
//  turn is never paid for twice — the deterministic gate decides whether
//  Hermes is needed at all.

import Foundation

// MARK: - Settings

/// How aggressively bland text gets rewritten.
enum TasteAggressiveness: String, Codable, CaseIterable, Identifiable {
    case conservative
    case moderate
    case aggressive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative: return "Conservative"
        case .moderate: return "Moderate"
        case .aggressive: return "Aggressive"
        }
    }
}

/// Whose voice the rewrite lands in.
enum TasteVoice: String, Codable, CaseIterable, Identifiable {
    /// The owner's learned register (WritingStyleService).
    case matchUser
    case professional
    case casual
    case technical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matchUser: return "Match my style"
        case .professional: return "Professional"
        case .casual: return "Casual"
        case .technical: return "Technical"
        }
    }
}

/// What a polish pass may touch.
enum TasteScope: String, Codable, CaseIterable, Identifiable {
    case emails
    case code
    case routines
    case briefing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emails: return "Email drafts"
        case .code: return "Code & comments"
        case .routines: return "Routine names"
        case .briefing: return "Briefings"
        }
    }
}

/// The persisted configuration. Defaults: on, moderate, the owner's voice,
/// every scope.
struct TasteSettings: Codable, Equatable {
    var enabled: Bool
    var aggressiveness: TasteAggressiveness
    var voice: TasteVoice
    var scopes: [TasteScope]

    static let `default` = TasteSettings(
        enabled: true,
        aggressiveness: .moderate,
        voice: .matchUser,
        scopes: [.emails, .code, .routines, .briefing])
}

// MARK: - Boringness evaluator (pure, tested)

/// The deterministic "is this bland?" judge. Pure and static so it unit-tests
/// with fixed expectations — this is the gate that decides whether a model
/// turn is spent, so it must be cheap, predictable and never throw.
enum TasteBoringness {

    /// A verdict: a 0–1 blandness score plus the phrases that pushed it up.
    struct Verdict: Equatable {
        let score: Double
        let needsPolish: Bool
        let matchedPhrases: [String]
    }

    /// The score above which a rewrite is worth a model turn. Higher = pickier:
    /// conservative only touches the worst offenders; aggressive rewrites
    /// anything with a whiff of boilerplate.
    static func threshold(for level: TasteAggressiveness) -> Double {
        switch level {
        case .conservative: return 0.5
        case .moderate: return 0.35
        case .aggressive: return 0.2
        }
    }

    /// Short labels (routine names, card titles) need their own heuristic:
    /// they rarely contain whole generic phrases, but "Daily research" and
    /// "Check my email" are still bland. A title is bland when it is short
    /// (≤ 6 words — longer strings are prose and get the phrase tables), has
    /// no distinguishing token and reads as a generic chore. The proper-noun
    /// signal is a capitalized word *after* the first — every title
    /// capitalizes its first word, so that one is not evidence of specificity.
    static func isGenericTitle(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (1...6).contains(words.count) else { return false }
        let lower = words.map { $0.lowercased() }
        // A proper noun (something capitalized mid-title) or a number means
        // the title actually names something.
        let distinguished = words.dropFirst().contains { word in
            word.count > 1 && word.first?.isUppercase == true
        } || lower.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil }
        if distinguished { return false }
        return lower.allSatisfy { Self.genericTitleWords.contains($0) }
    }

    /// Evaluate text. Titles (≤8 words) get the title heuristic; prose gets
    /// the phrase + buzzword tables. Combined hits cap at 1.0.
    static func evaluate(_ text: String, aggressiveness: TasteAggressiveness) -> Verdict {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return Verdict(score: 0, needsPolish: false, matchedPhrases: [])
        }
        let words = cleaned.split(whereSeparator: { $0.isWhitespace }).count

        var phrases: [String] = []
        var score = 0.0

        if words <= 6 {
            // Short labels: the title heuristic or nothing.
            if isGenericTitle(cleaned) {
                score = 0.75
                phrases.append("generic title")
            }
        } else {
            let lower = cleaned.lowercased()
            // Collect hits with their weights, then dedupe: "please do not
            // hesitate" contains "do not hesitate", so matching both would
            // double-charge the same words. Longest first; a hit contained in
            // a kept longer one is the same text and is dropped.
            var raw: [(text: String, weight: Double)] = []
            for phrase in genericPhrases where lower.contains(phrase) {
                raw.append((phrase, 0.22))
            }
            for word in buzzwords where lower.contains(word) {
                raw.append((word, 0.18))
            }
            for hit in raw.sorted(by: { $0.text.count > $1.text.count }) {
                if phrases.contains(where: { $0.contains(hit.text) }) { continue }
                phrases.append(hit.text)
                score += hit.weight
            }
            score = min(score, 1.0)
        }

        let threshold = threshold(for: aggressiveness)
        return Verdict(score: score, needsPolish: score >= threshold, matchedPhrases: phrases)
    }

    /// Whole generic phrases, lowercase, matched as substrings.
    static let genericPhrases: [String] = [
        "thank you for your email",
        "thank you for reaching out",
        "thank you for the update",
        "thank you for your time",
        "thank you in advance",
        "i appreciate your",
        "i appreciate the",
        "i hope this",
        "i hope you are",
        "hope this finds you well",
        "hope you're doing well",
        "i hope you're doing well",
        "i wanted to reach out",
        "i am writing to",
        "i am reaching out",
        "i would like to",
        "i would love to",
        "i trust this",
        "please do not hesitate",
        "do not hesitate",
        "feel free to reach out",
        "looking forward to your response",
        "look forward to hearing",
        "at your earliest convenience",
        "per my last email",
        "just checking in",
        "touching base",
        "keep you in the loop",
        "just a quick note",
        "let me know if you have any questions",
    ]

    /// Clichés and banned-by-taste buzzwords, matched as substrings.
    static let buzzwords: [String] = [
        "delve", "tapestry", "testament", "beacon", "revolutionize",
        "game-changer", "game changer", "seamless", "cutting-edge",
        "state-of-the-art", "best-in-class", "user-friendly", "synergy",
        "paradigm", "streamline", "unlock the power", "at the end of the day",
        "in today's fast-paced", "in conclusion", "it is important to note",
        "it's important to note", "in the world of", "when it comes to",
        "in this day and age", "low-hanging fruit", "think outside the box",
    ]

    /// Words that make a short title generic. Everything in the title must be
    /// one of these (plus be short and undistinguished) for the heuristic to fire.
    static let genericTitleWords: Set<String> = [
        "daily", "morning", "evening", "night", "weekly", "monthly",
        "check", "review", "summary", "scan", "tasks", "task", "todo",
        "todos", "email", "emails", "mail", "news", "research", "update",
        "updates", "reminders", "reminder", "routine", "routines", "basic",
        "simple", "quick", "my", "the", "a", "an", "of", "for", "and",
        "on", "in", "to", "me", "today", "weekly", "monthly", "daily",
    ]
}

// MARK: - Manager

/// Owns the taste settings and the two integration modes. Cross-cutting like
/// WritingStyleService (which it pairs with): it is read from the MainActor
/// managers (MailAIService, RoutineManager), the nonisolated MCP tool server
/// and the nonisolated SettingsModel. Not actor-isolated — an NSLock
/// serializes settings mutation + persistence, and the slow parts (Hermes
/// turns) are bounded so awaiting a call never blocks the caller.
final class TasteSkillManager {

    static let shared = TasteSkillManager()

    /// The agent that writes rewrites. Handed over at launch, like the
    /// briefing generator's.
    weak var hermes: HermesSession?

    private let storageKey = "alfred.taste_settings"

    /// Serializes settings mutation + persistence. Reads are lock-free value
    /// reads (safe under Swift's memory model), matching WritingStyleService.
    private let lock = NSLock()

    /// Serializes the manager's own model turns (see TasteTurnGate) so two
    /// polish passes never overlap on the single-turn Hermes session.
    private let turnGate = TasteTurnGate()

    /// Hard cap on one polish turn — a wedged session must degrade to the
    /// original text, never stall the caller.
    static let turnTimeout: TimeInterval = 60

    private var storedSettings: TasteSettings

    private func readSettings() -> TasteSettings {
        lock.lock()
        defer { lock.unlock() }
        return storedSettings
    }

    /// Mutate + persist under one lock acquisition — a get-then-set split would
    /// let a concurrent write slip in between and be lost.
    private func mutateSettings(_ change: (inout TasteSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var updated = storedSettings
        change(&updated)
        guard updated != storedSettings else { return }
        storedSettings = updated
        persist()
    }

    var settings: TasteSettings {
        get { readSettings() }
        set { mutateSettings { $0 = newValue } }
    }

    // Convenience accessors the settings views bind to.
    var isEnabled: Bool {
        get { readSettings().enabled }
        set { mutateSettings { $0.enabled = newValue } }
    }

    var aggressiveness: TasteAggressiveness {
        get { readSettings().aggressiveness }
        set { mutateSettings { $0.aggressiveness = newValue } }
    }

    var voice: TasteVoice {
        get { readSettings().voice }
        set { mutateSettings { $0.voice = newValue } }
    }

    var scopes: [TasteScope] {
        get { readSettings().scopes }
        set { mutateSettings { $0.scopes = newValue } }
    }

    private init() {
        storedSettings = Self.load() ?? .default
    }

    // MARK: - Gating

    /// Should a polish pass even be considered for this text in this scope?
    /// The cheap, deterministic first filter — a model turn is only spent
    /// when this passes.
    func shouldPolish(scope: TasteScope, text: String) -> Bool {
        let settings = readSettings()
        guard settings.enabled,
              settings.scopes.contains(scope),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return TasteBoringness.evaluate(text, aggressiveness: settings.aggressiveness).needsPolish
    }

    // MARK: - Polish

    /// Rewrite bland text with personality and specificity — but only when the
    /// deterministic evaluator says it's worth a model turn. Always returns a
    /// string: the rewritten text when the turn succeeds and changes it, the
    /// original otherwise. Never nil, never throws.
    ///
    /// `context` adds outside facts the rewrite should tie into ("the project
    /// deadline", the email subject). `voiceOverride` lets a single call
    /// depart from the settings voice (the MCP polish_text tool's `style`).
    func polishIfNeeded(_ text: String, scope: TasteScope,
                        context: String? = nil,
                        voiceOverride: TasteVoice? = nil,
                        turnTimeoutOverride: TimeInterval? = nil) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldPolish(scope: scope, text: trimmed) else { return text }
        return await runPolishTurn(
            trimmed, voice: voiceOverride ?? storedSettings.voice,
            context: context, timeout: turnTimeoutOverride)
    }

    /// The MCP-facing entry (the polish_text tool). Respects the enabled flag
    /// and the deterministic boringness gate, but not the per-scope gate — an
    /// agent that explicitly asks for polish gets it. `style` maps onto a
    /// voice override when one is given.
    func polishForAgent(_ text: String, style: String? = nil) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = readSettings()
        guard settings.enabled, !trimmed.isEmpty, let hermes else { return text }
        guard TasteBoringness.evaluate(
            trimmed, aggressiveness: settings.aggressiveness).needsPolish else { return text }
        let voice = style.flatMap(Self.voice(fromStyle:)) ?? settings.voice
        return await runPolishTurn(trimmed, voice: voice, context: nil)
    }

    /// The one rewrite turn, shared by every entry. Returns the original on any
    /// failure, timeout or "already good" verdict — callers always get a usable
    /// string and never pay for a worse result. `timeout` lets in-path callers
    /// (a mail draft already waited on its own model turn) bound the extra wait
    /// tighter than the 60s default.
    private func runPolishTurn(_ trimmed: String, voice: TasteVoice,
                               context: String?,
                               timeout: TimeInterval? = nil) async -> String {
        guard let hermes else { return trimmed }
        let level = readSettings().aggressiveness
        let voiceBlock = voiceDescription(voice)
        let contextBlock = context.map { "Context to tie into: \($0)" } ?? ""

        let prompt = """
        You are Alfred's taste editor. Rewrite the text below to be specific, \
        vivid and human — the opposite of generic AI boilerplate.

        Aggressiveness (\(level.rawValue)):
        - conservative: minimal changes. Remove only the worst generic phrases \
        and clichés; keep everything else as written.
        - moderate: remove generic filler and clichés, sharpen vague statements, \
        keep the structure and length roughly the same.
        - aggressive: rewrite fully for voice and specificity. Cut clichés \
        without mercy, tighten, and make every sentence earn its place.

        Voice: \(voiceBlock)

        Rules:
        - Never invent facts. If the text lacks specifics, make it concrete \
        without adding false detail — prefer the original's facts over flourish.
        - Preserve technical terms, names, numbers and jargon exactly.
        - Keep the length close to the original; do not pad.
        - If the text is already specific and un-bland, leave it unchanged.

        \(contextBlock)

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"rewritten": "the improved text", "changed": true or false}

        Text:
        \(trimmed)
        """
        let outcome = await turnGate.enqueue { [weak self] in
            guard let self, let hermes = self.hermes else { return nil }
            // Re-check at run time — the owner's turn, if one began while this
            // ask queued, must win.
            guard !(await hermes.isTurnActive) else { return nil }
            return await Self.runPromptBounded(hermes, prompt: prompt, timeout: timeout ?? Self.turnTimeout)
        }
        guard let outcome,
              let rewritten = outcome["rewritten"] as? String,
              let changed = outcome["changed"] as? Bool,
              changed,
              !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return trimmed }
        let polished = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        return polished == trimmed ? trimmed : polished
    }

    /// Map an MCP style string onto a voice. Unknown styles fall back to nil
    /// (the settings voice).
    private static func voice(fromStyle style: String) -> TasteVoice? {
        switch style.lowercased() {
        case "casual": return .casual
        case "formal": return .professional
        case "technical": return .technical
        case "marketing": return .professional
        default: return nil
        }
    }

    /// Concrete rewrite suggestions for a piece of text (the MCP
    /// suggest_improvements tool). Nil when Hermes is busy or fails.
    func suggestImprovements(_ text: String) async -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard readSettings().enabled, !trimmed.isEmpty, let hermes else { return nil }
        let prompt = """
        You are Alfred's taste editor. List the specific things making this \
        text bland or generic, and one concrete fix for each. Respond with \
        EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"suggestions": ["replace X with Y", "..."]}
        Keep each suggestion short (under 15 words) and actionable.

        Text:
        \(trimmed)
        """
        let outcome = await turnGate.enqueue { [weak self] in
            guard let self, let hermes = self.hermes else { return nil }
            guard !(await hermes.isTurnActive) else { return nil }
            return await Self.runPromptBounded(hermes, prompt: prompt)
        }
        guard let outcome, let raw = outcome["suggestions"] as? [String] else { return nil }
        return raw.filter { !$0.isEmpty }
    }

    // MARK: - Condition generation

    /// A short anti-slop paragraph to inject into a prompt Alfred already
    /// runs — the briefing, the code agent — so output is born with taste.
    /// Returns "" when disabled or the scope is off, so callers can append
    /// unconditionally.
    func generationGuidance(scope: TasteScope) -> String {
        let settings = readSettings()
        guard settings.enabled, settings.scopes.contains(scope) else { return "" }
        switch scope {
        case .briefing:
            return "Write with taste: name the actual people, times and places; "
                + "no filler, no clichés, no 'I hope this finds you well' boilerplate. "
                + "Specific beats generic every time."
        case .code:
            return "Write comments that explain why, not just what. No boilerplate "
                + "docstrings, no '// Initialize user' one-liners that echo the code. "
                + "Name the intent, the edge case, or the tradeoff — or write no comment."
        case .emails, .routines:
            return ""
        }
    }

    // MARK: - Voice

    private func voiceDescription(_ voice: TasteVoice) -> String {
        switch voice {
        case .matchUser:
            let injection = WritingStyleService.shared.currentProfile.toPromptInjection()
            return injection.isEmpty
                ? "the owner's own register — plain, direct, human"
                : injection
        case .professional:
            return "professional but warm and direct; no corporate boilerplate"
        case .casual:
            return "casual, friendly, conversational — like a message to a friend"
        case .technical:
            return "precise and technical, comfortable with jargon, no fluff"
        }
    }

    // MARK: - Bounded turn (mirrors MailAIService)

    /// One bounded prompt turn racing a JSON object out of the model stream.
    /// Returns nil when the deadline wins or the reply won't parse.
    private static func runPromptBounded(_ session: HermesSession, prompt: String,
                                         timeout: TimeInterval = turnTimeout)
        async -> [String: Any]? {
        enum Outcome {
            case transcript(String)
            case timedOut
        }
        let turn = Task { () -> String in
            var transcript = ""
            for await event in await session.prompt(prompt, capture: false) {
                if case let .text(chunk) = event { transcript.append(chunk) }
                if case .failed = event { break }
            }
            return transcript
        }
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .transcript(await turn.value) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                turn.cancel()
                return .timedOut
            }
            guard let first = await group.next() else { return .timedOut }
            group.cancelAll()
            return first
        }
        switch outcome {
        case .timedOut:
            NSLog("[taste] model turn timed out after \(Int(Self.turnTimeout))s; keeping original")
            return nil
        case .transcript(let transcript):
            let cleaned = transcript
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleaned.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func load() -> TasteSettings? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.taste_settings"),
              let settings = try? JSONDecoder().decode(TasteSettings.self, from: data)
        else { return nil }
        return settings
    }
}

// MARK: - Turn gate

/// Serializes the manager's own model turns. HermesSession is single-turn:
/// a second concurrent prompt would overwrite the first's event sink and
/// interleave the streams, so polish passes queue sequentially. The
/// `isTurnActive` check is re-run inside the gate at prompt time (TOCTOU-safe).
private actor TasteTurnGate {
    private var previous: Task<[String: Any]?, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> [String: Any]?)
        async -> [String: Any]? {
        let prior = previous
        let task = Task { [prior] in
            _ = await prior?.value
            return await operation()
        }
        previous = task
        return await task.value
    }
}
