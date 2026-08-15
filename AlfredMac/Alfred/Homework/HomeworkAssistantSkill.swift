// MARK: - HomeworkAssistantSkill
//
// Alfred's Homework Assistant — the "just do it" side of studying that the
// Personal Tutor deliberately won't do on graded work. The two skills split
// the homework surface cleanly:
//
//   * PersonalTutorSkill — teaching: explain a concept, Socratic guidance,
//     mastery tracking, exam prep. Its one hard rule: hints, not answers on
//     graded work.
//   * HomeworkAssistantSkill — submission: solve a problem completely (code,
//     math, physics) in the user's own style, formatted for hand-in. Teach
//     mode here *delegates* to the tutor's Socratic guide so the two never
//     disagree about what "help" means.
//
// The user chooses per call: `mode: "teach"` routes to the tutor (learn the
// type), `mode: "submit"` produces the submission-ready solution (when
// they're burned out — their call, explicitly made).
//
// ## Dedicated solver session
//
// These tools are called BY Hermes mid-turn. The shared bar session is busy
// exactly then, so the solver runs on its own long-lived HermesSession —
// the same choice multi_agent_run made ("runs on its own sessions, so it
// neither waits on nor blocks the shared bar session"). A single solver
// session is reused across calls and torn down at app quit.
//
// ## Style
//
// Solutions are written in the user's register. SolutionStyleMatcher blends
// the WritingStyleService profile (their measured voice) with what the
// tracker has learned about their solution habits, then injects that as a
// prompt block. Code solutions additionally respect the codeStyle setting
// (match-my-code vs generic best practices).
//
// ## Learning
//
// Every solve records the problem type into ProblemTypeTracker: teach-mode
// asks bump `struggles`, submission solves bump `solved`. The briefing's
// Homework card and the prompt injection both read that line, so the longer
// Alfred works homework with the user, the more precisely it knows what
// trips them up.

import Foundation

// MARK: - Problem classifier (pure, tested)

/// Turns a problem statement into the domain the right solver prompt needs.
/// Deterministic keyword scoring — cheap, predictable, and unit-testable.
/// Falls back to `math` for unknown statements (the most common homework
/// domain), with `.none` reserved for empty input.
enum HomeworkProblemClassifier {

    static func classify(_ problem: String) -> HomeworkDomain? {
        let lower = problem.lowercased()
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var cs = 0, math = 0, physics = 0
        for word in csKeywords where lower.contains(word) { cs += 1 }
        for word in mathKeywords where lower.contains(word) { math += 1 }
        for word in physicsKeywords where lower.contains(word) { physics += 1 }

        if cs >= math && cs >= physics && cs > 0 { return .cs }
        if physics > math && physics > 0 { return .physics }
        if math > 0 { return .math }
        return .math
    }

    static let csKeywords: [String] = [
        "function", "recursion", "recursive", "algorithm", "array", "loop",
        "iterate", "string", "variable", "compile", "debug", "python",
        "java", "swift", "c++", "code", "program", "stack", "queue", "hash",
        "binary search", "sort", "complexity", "big-o", "runtime", "pointer",
        "class", "method", "input", "output", "bug",
    ]

    static let mathKeywords: [String] = [
        "integral", "integrate", "derivative", "differentiate", "limit",
        "calculus", "equation", "solve for x", "matrix", "vector", "proof",
        "prove", "theorem", "sum", "series", "converge", "divergence",
        "function f", "graph", "probability", "permutation", "combination",
        "eigenvalue", "linear", "polynomial", "factor", "logarithm", "sqrt",
    ]

    static let physicsKeywords: [String] = [
        "force", "velocity", "acceleration", "momentum", "energy", "work",
        "power", "friction", "gravity", "newton", "mass", "charge", "electric",
        "magnetic", "circuit", "resistance", "voltage", "current", "wave",
        "frequency", "wavelength", "kinetic", "potential", "thermodynamics",
        "heat", "temperature", "pressure", "photon", "quantum", "relativity",
        "spring", "oscillation", "projectile",
    ]
}

// MARK: - Solution style matcher

/// Builds the "write in my style" block for solver prompts. Pure function of
/// the measured writing profile + the tracker's learned solution style —
/// testable without a session.
enum SolutionStyleMatcher {

    /// The stored preference key the tracker keeps the learned style under.
    static let learnedStyleKey = "learned_solution_style"

    /// The prompt block. Empty when nothing is known yet (fresh install).
    static func injection(writingProfile: String, learnedStyle: String?) -> String {
        var parts: [String] = []
        if !writingProfile.isEmpty { parts.append(writingProfile) }
        if let learnedStyle, !learnedStyle.isEmpty { parts.append(learnedStyle) }
        return parts.joined(separator: " ")
    }

    /// A compact human sentence describing the user's solution habits, for
    /// the tracker's preference slot. Built from the same profile fields the
    /// tutor uses, so a settled profile lands a useful style note.
    static func summarize(writingProfile: String) -> String {
        guard !writingProfile.isEmpty else { return "" }
        return "Solve in the user's register: \(writingProfile)"
    }
}

// MARK: - Manager

final class HomeworkAssistantSkill {

    static let shared = HomeworkAssistantSkill()

    /// Test seam: a skill backed by a throwaway tracker so unit tests never
    /// write to the real `~/.alfred/db/homework.db`.
    static func makeForTesting(tracker: ProblemTypeTracker) -> HomeworkAssistantSkill {
        HomeworkAssistantSkill(tracker: tracker)
    }

    private let tracker: ProblemTypeTracker
    private let storageKey = "alfred.homework_settings"

    private let lock = NSLock()
    private var storedSettings: HomeworkSettings

    /// The dedicated solver session, created lazily (spawning loads the MCP
    /// bridges, so the first solve pays the startup cost) and reused until
    /// app quit. Never the shared bar session — see the file header.
    private var solverSession: HermesSession?
    private var solverSessionCreationLock = NSLock()

    /// Serializes the solver's own model turns (single-session, like the
    /// tutor's gate) so concurrent homework asks queue rather than interleave.
    private let turnGate = HomeworkTurnGate()

    /// Hard cap on one solver turn — a wedged model must degrade to the
    /// fallback, never stall the tool call forever.
    static let turnTimeout: TimeInterval = 180

    private init(tracker: ProblemTypeTracker = .shared) {
        self.tracker = tracker
        storedSettings = Self.load() ?? .default
    }

    // MARK: - Settings

    private func readSettings() -> HomeworkSettings {
        lock.lock()
        defer { lock.unlock() }
        return storedSettings
    }

    /// Mutate + persist under one lock acquisition.
    private func mutateSettings(_ change: (inout HomeworkSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var updated = storedSettings
        change(&updated)
        guard updated != storedSettings else { return }
        storedSettings = updated
        persist()
    }

    var settings: HomeworkSettings {
        get { readSettings() }
        set { mutateSettings { $0 = newValue } }
    }

    var isEnabled: Bool {
        get { readSettings().enabled }
        set { mutateSettings { $0.enabled = newValue } }
    }

    var defaultMode: HomeworkMode {
        get { readSettings().defaultMode }
        set { mutateSettings { $0.defaultMode = newValue } }
    }

    var codeStyle: HomeworkCodeStyle {
        get { readSettings().codeStyle }
        set { mutateSettings { $0.codeStyle = newValue } }
    }

    var showSteps: HomeworkShowSteps {
        get { readSettings().showSteps }
        set { mutateSettings { $0.showSteps = newValue } }
    }

    var difficulty: HomeworkDifficulty {
        get { readSettings().difficulty }
        set { mutateSettings { $0.difficulty = newValue } }
    }

    var format: HomeworkFormat {
        get { readSettings().format }
        set { mutateSettings { $0.format = newValue } }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func load() -> HomeworkSettings? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.homework_settings"),
              let settings = try? JSONDecoder().decode(HomeworkSettings.self, from: data)
        else { return nil }
        return settings
    }

    /// Test seam: reload the persisted settings without the singleton's cache.
    static func loadForTest() -> HomeworkSettings? { load() }

    // MARK: - Lifecycle

    /// App-quit teardown: release the dedicated solver process. Called from
    /// applicationWillTerminate alongside the other managers. The session's
    /// shutdown is async (actor-isolated), so it's fire-and-forget here —
    /// app quit doesn't wait on it, matching AlfredApp's own teardown.
    func stop() {
        solverSessionCreationLock.lock()
        let session = solverSession
        solverSession = nil
        solverSessionCreationLock.unlock()
        if let session {
            Task { await session.shutdown() }
        }
    }

    // MARK: - The solver session

    private func solver() -> HermesSession? {
        solverSessionCreationLock.lock()
        defer { solverSessionCreationLock.unlock() }
        if let solverSession { return solverSession }
        let session = HermesSession(workingDirectory: NSHomeDirectory(),
                                    turnDeadline: Self.turnTimeout)
        solverSession = session
        return session
    }

    // MARK: - Public API (MCP tools)

    /// The `solve_problem` tool. `mode` overrides the settings default:
    /// "teach" routes to the tutor's Socratic guide (learn the type),
    /// "submit" produces the submission-ready solution. Records the problem
    /// type either way.
    func solveProblem(_ problem: String, mode: String?) async -> String {
        let trimmed = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What problem are you working on?" }
        let settings = readSettings()
        guard settings.enabled else {
            return "Homework help is off in Settings — turn it on and ask again."
        }

        let chosen = mode.flatMap(HomeworkMode.init(rawValue:)) ?? settings.defaultMode
        let domain = HomeworkProblemClassifier.classify(trimmed) ?? .math
        let topic = Self.topicName(trimmed)

        switch chosen {
        case .teach:
            tracker.recordStruggle(domain: domain, topic: topic)
            // The tutor owns teaching. Hand the problem over unchanged — the
            // tutor's Socratic engine decides how much to give away.
            return await PersonalTutorSkill.shared.socraticGuide(problem: trimmed)
        case .submit:
            tracker.recordSolved(domain: domain, topic: topic)
            let result = await runSolverTurn(
                prompt: submissionPrompt(problem: trimmed, domain: domain, settings: settings))
            return renderSubmission(result, settings: settings)
        }
    }

    /// The `explain_problem` tool: how to approach it, not the answer.
    func explainProblem(_ problem: String) async -> String {
        let trimmed = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What problem should I walk you through?" }
        guard readSettings().enabled else {
            return "Homework help is off in Settings — turn it on and ask again."
        }
        let domain = HomeworkProblemClassifier.classify(trimmed) ?? .math
        let topic = Self.topicName(trimmed)
        tracker.recordStruggle(domain: domain, topic: topic)
        let result = await runSolverTurn(
            prompt: Self.approachPrompt(problem: trimmed, domain: domain))
        return renderApproach(result)
    }

    /// The `write_code` tool: a submission-ready code solution in the user's
    /// coding style, with comments and test cases.
    func writeCode(requirements: String, language: String?) async -> String {
        let trimmed = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What should the code do?" }
        let settings = readSettings()
        guard settings.enabled else {
            return "Homework help is off in Settings — turn it on and ask again."
        }
        let topic = Self.topicName(trimmed)
        tracker.recordSolved(domain: .cs, topic: topic)
        let result = await runSolverTurn(
            prompt: codePrompt(requirements: trimmed, language: language, settings: settings))
        guard let code = result?["code"] as? String,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "I couldn't write that code just now. Try again in a moment."
        }
        let lang = language ?? ""
        var lines: [String] = []
        if code.contains("```") {
            // The model already fenced it — don't double-wrap.
            lines.append(code)
        } else {
            lines.append("```\(lang)")
            lines.append(code)
            lines.append("```")
        }
        if let notes = result?["notes"] as? String, !notes.isEmpty {
            lines.append("")
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    /// The `solve_math` tool: step-by-step, LaTeX optional, alternative
    /// methods when they exist.
    func solveMath(_ problem: String) async -> String {
        let trimmed = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What math problem?" }
        let settings = readSettings()
        guard settings.enabled else {
            return "Homework help is off in Settings — turn it on and ask again."
        }
        let topic = Self.topicName(trimmed)
        tracker.recordSolved(domain: .math, topic: topic)
        let result = await runSolverTurn(
            prompt: mathPrompt(problem: trimmed, settings: settings))
        return renderMath(result, settings: settings)
    }

    /// The `solve_physics` tool: concepts first, then equations, then
    /// intuition — the "why does this make sense" the spec calls out.
    func solvePhysics(_ problem: String) async -> String {
        let trimmed = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What physics problem?" }
        let settings = readSettings()
        guard settings.enabled else {
            return "Homework help is off in Settings — turn it on and ask again."
        }
        let topic = Self.topicName(trimmed)
        tracker.recordSolved(domain: .physics, topic: topic)
        let result = await runSolverTurn(
            prompt: physicsPrompt(problem: trimmed, settings: settings))
        return renderPhysics(result, settings: settings)
    }

    /// The `format_solution` tool: re-format an existing solution. Pure and
    /// instant — no model turn. "code" wraps in a fence, "latex" keeps math
    /// delimiters honest, "text" returns the plain answer.
    func formatSolution(_ solution: String, format: String?) -> String {
        let trimmed = solution.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let chosen = format.flatMap(HomeworkFormat.init(rawValue:)) ?? .text
        switch chosen {
        case .code:
            return trimmed.contains("```") ? trimmed : "```\n\(trimmed)\n```"
        case .latex:
            // Wrap in display math when there's any math content and no
            // delimiters yet — never double-wrap an existing expression.
            let looksMathy = trimmed.contains("=") || trimmed.contains("∫")
                || trimmed.contains("\\")
            if looksMathy && !trimmed.contains("$") {
                return "\\(" + trimmed + "\\)"
            }
            return trimmed
        case .text:
            return trimmed
        }
    }

    // MARK: - Learned style

    /// The `what_i_struggle_with` helper text (and briefing card source):
    /// the weakest problem types on record.
    func struggleSummary() -> String {
        let topics = tracker.struggleTopics(limit: 6)
        guard !topics.isEmpty else {
            return "No problem types on record yet. Ask Alfred for homework help and tell him when it clicks — after a few problems he'll know what trips you up."
        }
        var lines = ["Problem types to watch, most-struggled first:"]
        for stat in topics {
            var line = "  • \(stat.topic) (\(stat.domain.displayName))"
            line += " — struggled \(stat.struggles)×, solved \(stat.solved)×"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Re-learn the style note from the current writing profile and persist
    /// it to the tracker. Called on each submit solve so the note stays a
    /// step ahead.
    private func refreshLearnedStyle() {
        let profile = WritingStyleService.shared.currentProfile.toPromptInjection()
        guard !profile.isEmpty else { return }
        let note = SolutionStyleMatcher.summarize(writingProfile: profile)
        guard !note.isEmpty else { return }
        tracker.setPreference(SolutionStyleMatcher.learnedStyleKey, value: note)
    }

    // MARK: - Bounded solver turn

    /// One bounded turn on the dedicated solver session, serialized through
    /// the gate. Returns the parsed JSON object, or nil on timeout/failure —
    /// callers degrade to their fallback text.
    private func runSolverTurn(prompt: String) async -> [String: Any]? {
        guard let session = solver() else { return nil }
        let outcome = await turnGate.enqueue {
            await Self.runPromptBounded(session, prompt: prompt, timeout: Self.turnTimeout)
        }
        switch outcome {
        case .parsed(let obj):
            return obj
        case .unparsed:
            return nil
        case .timedOut:
            NSLog("[homework] solver turn timed out after \(Int(Self.turnTimeout))s")
            resetSolverSession()
            return nil
        }
    }

    /// A timed-out turn can leave the model mid-stream. Drop the session so
    /// the next call starts a fresh process instead of reusing a wedged one.
    private func resetSolverSession() {
        solverSessionCreationLock.lock()
        let session = solverSession
        solverSession = nil
        solverSessionCreationLock.unlock()
        if let session {
            Task { await session.shutdown() }
        }
    }

    /// How the bounded turn ended — lets the caller tell a timeout (drop the
    /// session) apart from an unparseable reply (keep it, the model answered).
    enum SolverOutcome {
        case parsed([String: Any])
        case unparsed
        case timedOut
    }

    /// The subprocess-free bounded prompt core (static so it unit-tests
    /// without a session), mirroring PersonalTutorSkill's.
    static func runPromptBounded(_ session: HermesSession, prompt: String,
                                 timeout: TimeInterval = turnTimeout)
        async -> SolverOutcome {
        enum TurnOutcome {
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
        let outcome: TurnOutcome = await withTaskGroup(of: TurnOutcome.self) { group in
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
        guard case .transcript(let text) = outcome else { return .timedOut }
        let cleaned = Self.extractJSONObject(from: text)
        guard let data = cleaned.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .unparsed }
        return .parsed(obj)
    }

    /// Pull the first balanced {...} object out of a model reply, even when it
    /// arrives wrapped in prose or markdown fences.
    static func extractJSONObject(from raw: String) -> String {
        let chars = Array(raw)
        var depth = 0
        var inString = false
        var escaped = false
        var start = -1
        for (i, ch) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{":
                if start < 0 { start = i }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, start >= 0 {
                    return String(chars[start...i])
                }
            default:
                break
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Renderers

    /// Turn the submission solve's JSON into the user-facing text: solution,
    /// then steps per the showSteps setting, then a style note when relevant.
    private func renderSubmission(_ result: [String: Any]?, settings: HomeworkSettings) -> String {
        guard let result,
              let solution = result["solution"] as? String,
              !solution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "I couldn't work that one out just now. Try again in a moment." }

        refreshLearnedStyle()

        var lines: [String] = []
        if settings.format == .code, !solution.contains("```") {
            lines.append("```")
            lines.append(solution)
            lines.append("```")
        } else {
            lines.append(solution)
        }

        if settings.showSteps != .never,
           let steps = result["steps"] as? [String], !steps.isEmpty {
            lines.append("")
            lines.append("Steps:")
            for (index, step) in steps.enumerated() {
                let cleaned = step.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                lines.append("\(index + 1). \(cleaned)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderMath(_ result: [String: Any]?, settings: HomeworkSettings) -> String {
        guard let result,
              let solution = result["solution"] as? String,
              !solution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "I couldn't solve that one just now. Try again in a moment." }

        var lines: [String] = []
        if settings.showSteps != .never,
           let steps = result["steps"] as? [String], !steps.isEmpty {
            lines.append("Steps:")
            for (index, step) in steps.enumerated() {
                let cleaned = step.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                lines.append("\(index + 1). \(cleaned)")
            }
            lines.append("")
        }

        let formatted: String
        if settings.format == .latex, !solution.contains("$") {
            formatted = "\\(" + solution + "\\)"
        } else {
            formatted = solution
        }
        lines.append(formatted)

        if let alternatives = result["alternatives"] as? [String], !alternatives.isEmpty {
            lines.append("")
            lines.append("Alternative method" + (alternatives.count == 1 ? "" : "s") + ":")
            for alternative in alternatives {
                lines.append("  • \(alternative)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Turn the approach solve's JSON into readable guidance: the strategy,
    /// then what to try, then pitfalls to dodge. Degrades to a gentle prompt
    /// to retry when the turn came back empty.
    private func renderApproach(_ result: [String: Any]?) -> String {
        guard let result,
              let approach = result["approach"] as? String,
              !approach.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "I couldn't break that one down just now. Try again in a moment." }

        var lines: [String] = [approach]
        if let steps = result["steps"] as? [String], !steps.isEmpty {
            lines.append("")
            lines.append("Try:")
            for step in steps {
                let cleaned = step.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                lines.append("  • \(cleaned)")
            }
        }
        if let pitfalls = result["pitfalls"] as? [String], !pitfalls.isEmpty {
            lines.append("")
            lines.append("Watch out for:")
            for pitfall in pitfalls {
                let cleaned = pitfall.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                lines.append("  • \(cleaned)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderPhysics(_ result: [String: Any]?, settings: HomeworkSettings) -> String {
        guard let result,
              let solution = result["solution"] as? String,
              !solution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "I couldn't solve that one just now. Try again in a moment." }

        var lines: [String] = []
        if let concepts = result["concepts"] as? [String], !concepts.isEmpty {
            lines.append("Concepts: " + concepts.joined(separator: ", "))
        }
        if settings.showSteps != .never,
           let steps = result["steps"] as? [String], !steps.isEmpty {
            lines.append("Steps:")
            for (index, step) in steps.enumerated() {
                let cleaned = step.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                lines.append("\(index + 1). \(cleaned)")
            }
        }
        lines.append(solution)
        if let intuition = result["intuition"] as? String, !intuition.isEmpty {
            lines.append("")
            lines.append("Why it makes sense: \(intuition)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt builders

    /// The common "write like the user" block for every solver prompt.
    private func styleBlock(settings: HomeworkSettings) -> String {
        let profile = WritingStyleService.shared.currentProfile.toPromptInjection()
        let learned = tracker.preference(SolutionStyleMatcher.learnedStyleKey)
        let style = SolutionStyleMatcher.injection(writingProfile: profile, learnedStyle: learned)
        var parts: [String] = []
        if !style.isEmpty { parts.append("Write the solution in the user's voice: \(style)") }
        switch settings.difficulty {
        case .matchLevel: parts.append("Match the user's level — not over-explained, not too terse.")
        case .challenge: parts.append("Push slightly past the user's current level where it's instructive.")
        case .simplify: parts.append("Keep it as simple as possible while staying correct.")
        }
        return parts.joined(separator: " ")
    }

    private func submissionPrompt(problem: String, domain: HomeworkDomain,
                                   settings: HomeworkSettings) -> String {
        """
        You are Alfred, solving a homework problem for the user in submission \
        mode — they explicitly asked for the complete solution, so produce the \
        final answer they can hand in.

        \(styleBlock(settings: settings))

        Domain: \(domain.displayName).
        \(settings.showSteps == .never ? "Do not show working steps." : "Include the key working steps.")

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"solution": "the complete, submission-ready solution", "steps": ["key step", "..."]}

        Problem:
        \(problem)
        """
    }

    private static func approachPrompt(problem: String, domain: HomeworkDomain) -> String {
        """
        You are Alfred, explaining how to approach a homework problem WITHOUT \
        giving the answer away — the user will solve it themselves.

        Domain: \(domain.displayName).

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"approach": "the strategy, in plain language", "steps": ["what to try first", "..."], "pitfalls": ["common mistakes"]}

        Problem:
        \(problem)
        """
    }

    private func codePrompt(requirements: String, language: String?,
                             settings: HomeworkSettings) -> String {
        let styleDirective: String
        switch settings.codeStyle {
        case .matchMine:
            let profile = WritingStyleService.shared.currentProfile.toPromptInjection()
            styleDirective = profile.isEmpty
                ? "Match the user's coding habits: clear names, guard against bad input, comments that explain why."
                : "Match the user's register: \(profile). Mirror their naming, error handling and comment style."
        case .generic:
            styleDirective = "Follow generic best practices: clear names, defensive error handling, concise comments."
        }

        return """
        You are Alfred, writing a submission-ready code solution for a \
        homework problem. The user explicitly asked for the code — produce it \
        complete, tested against the obvious cases.

        \(styleDirective)
        Keep complexity appropriate — do not over-engineer a simple problem.
        \(language.map { "Language: \($0)." } ?? "Use the most natural language for the problem.")

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"code": "the complete program", "notes": "how it works + the test cases it passes"}

        Requirements:
        \(requirements)
        """
    }

    private func mathPrompt(problem: String, settings: HomeworkSettings) -> String {
        """
        You are Alfred, solving a math homework problem step by step.

        \(styleBlock(settings: settings))
        \(settings.format == .latex ? "Format math with LaTeX delimiters (\\( ... \\)) so it renders." : "Write math in plain, readable form.")

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"solution": "the final answer", "steps": ["step 1", "..."], "alternatives": ["optional alternative method"]}

        Problem:
        \(problem)
        """
    }

    private func physicsPrompt(problem: String, settings: HomeworkSettings) -> String {
        """
        You are Alfred, solving a physics homework problem.

        \(styleBlock(settings: settings))

        Structure the answer as: the physical concepts that apply, the setup \
        and equations, the solution, and a one-line intuition for why the \
        result makes sense.

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"solution": "the final answer with the key equations", "steps": ["setup", "..."], "concepts": ["concept", "..."], "intuition": "why it makes sense"}

        Problem:
        \(problem)
        """
    }

    // MARK: - Topic naming

    /// A short, stable topic name for the tracker: the first few words of the
    /// problem, so repeated problems on the same topic upsert into one row.
    private static func topicName(_ problem: String) -> String {
        let cleaned = problem
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return cleaned }
        let count = min(words.count, 6)
        return words.prefix(count).joined(separator: " ")
    }

    // MARK: - Wire helpers

    /// The settings wire shape the phone round-trips.
    static func homeworkSettingsWire(_ settings: HomeworkSettings) -> [String: Any] {
        [
            "enabled": settings.enabled,
            "defaultMode": settings.defaultMode.rawValue,
            "codeStyle": settings.codeStyle.rawValue,
            "showSteps": settings.showSteps.rawValue,
            "difficulty": settings.difficulty.rawValue,
            "format": settings.format.rawValue,
        ]
    }

    /// Decode a settings wire dictionary back into the model.
    static func homeworkSettings(from raw: Any?) -> HomeworkSettings? {
        guard let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return try? JSONDecoder().decode(HomeworkSettings.self, from: data)
    }

    /// The problem-type stats the briefing card and the phone read.
    static func problemTypeWire(_ stat: ProblemTypeStat) -> [String: Any] {
        [
            "id": stat.id,
            "domain": stat.domain.rawValue,
            "topic": stat.topic,
            "struggles": stat.struggles,
            "solved": stat.solved,
            "lastSeen": stat.lastSeen,
        ]
    }
}

// MARK: - Turn gate

/// Serializes the solver session's model turns. HermesSession is single-turn,
/// so concurrent homework asks queue sequentially instead of interleaving the
/// streams on the one solver session.
private actor HomeworkTurnGate {
    private var previous: Task<HomeworkAssistantSkill.SolverOutcome, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> HomeworkAssistantSkill.SolverOutcome)
        async -> HomeworkAssistantSkill.SolverOutcome {
        let prior = previous
        let task = Task { [prior] in
            _ = await prior?.value
            return await operation()
        }
        previous = task
        return await task.value
    }
}
