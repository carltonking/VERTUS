// MARK: - PersonalTutorSkill
//
// Alfred's Personal Tutor — the "skill" that knows how this user learns.
//
// The loop, end to end:
//
//   1. `explain(concept:)` checks the mastery tracker ("user knows basic
//      loops", prerequisites, current confidence) and the learned learning
//      style, then asks Hermes for an explanation that leads with the method
//      that works for this user (code example, analogy, visual, …).
//   2. The explanation ends with the check question ("Does this make
//      sense?"); the user's reply lands in `recordFeedback`, which scores the
//      session and moves the concept's 1–5 confidence.
//   3. `LearningStyleAnalyzer` turns those scored sessions into a
//      `LearningStyle` — methods that work and don't, step-by-step vs
//      all-at-once, overview vs detail, Socratic vs direct. The Python DSPy
//      bridge (`dspy_tutor.py`) proposes its own teaching directives every 10
//      sessions when configured; the deterministic analyzer is always there.
//   4. Meaningful learnings mirror into MemPalace (category `.learning`) so
//      every future session — tutoring or not — starts knowing them.
//   5. `examPrep` and the briefing's Weak Concepts card target the concepts
//      the tracker says are weakest.
//
// Threading matches the other managers: not actor-isolated, an NSLock guards
// settings mutation + persistence, and every model turn is bounded and
// serialized through a turn gate so background tutoring can never hijack or
// interleave with the user's own conversation.

import Foundation

final class PersonalTutorSkill {

    static let shared = PersonalTutorSkill()

    /// The agent that writes explanations and questions. Handed over at
    /// launch by the app delegate, like the briefing generator's.
    weak var hermes: HermesSession?

    /// Test seam: a skill backed by a throwaway database, so unit tests never
    /// write to the real `~/.alfred/db/tutor.db` or real MemPalace. Default
    /// settings are pinned (not loaded from UserDefaults) so one test mutating
    /// `isEnabled` can't leak into the next via the shared defaults.
    static func makeForTesting(databasePath: String,
                               settings: TutorSettings = .default) -> PersonalTutorSkill {
        PersonalTutorSkill(store: ConceptMasteryTracker(databasePath: databasePath),
                           mirrorToMemPalace: false, settings: settings)
    }

    private let store: ConceptMasteryTracker
    /// Off in tests: learning data must never leak into the real MemPalace
    /// from a test run.
    private let mirrorToMemPalace: Bool

    private let storageKey = "alfred.tutor_settings"

    private let lock = NSLock()
    private var storedSettings: TutorSettings

    /// Serializes the skill's own model turns (see TutorTurnGate) so two
    /// tutoring calls never overlap on the single-turn Hermes session.
    private let turnGate = TutorTurnGate()

    /// Hard cap on one tutoring turn.
    static let turnTimeout: TimeInterval = 90

    private init(store: ConceptMasteryTracker = .shared, mirrorToMemPalace: Bool = true,
                 settings: TutorSettings? = nil) {
        self.store = store
        self.mirrorToMemPalace = mirrorToMemPalace
        storedSettings = settings ?? Self.load() ?? .default
    }

    // MARK: - Settings

    private func readSettings() -> TutorSettings {
        lock.lock()
        defer { lock.unlock() }
        return storedSettings
    }

    private func mutateSettings(_ change: (inout TutorSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var updated = storedSettings
        change(&updated)
        guard updated != storedSettings else { return }
        storedSettings = updated
        persist()
    }

    var settings: TutorSettings {
        get { readSettings() }
        set { mutateSettings { $0 = newValue } }
    }

    var isEnabled: Bool {
        get { readSettings().enabled }
        set { mutateSettings { $0.enabled = newValue } }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func load() -> TutorSettings? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.tutor_settings"),
              let settings = try? JSONDecoder().decode(TutorSettings.self, from: data)
        else { return nil }
        return settings
    }

    /// Test seam: reload the persisted settings without going through the
    /// singleton's cached copy.
    static func loadForTest() -> TutorSettings? { load() }

    // MARK: - Tutoring session

    /// Explain a concept the way this user learns. Returns the explanation
    /// plus the check question, or a graceful fallback when Hermes is busy,
    /// unconfigured, or the turn fails. Records the session (outcome pending)
    /// so `recordFeedback` can score it.
    func explain(concept: String, course: String? = nil) async -> String {
        let trimmed = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What would you like me to explain?" }
        let settings = readSettings()
        guard settings.enabled, let hermes else {
            return "I'm not set up to tutor right now — ask me again when Alfred's agent is running."
        }

        let mastery = store.mastery(for: trimmed)
        let prerequisites = store.prerequisites(for: trimmed)
        let style = learningStyle()
        let prompt = ExplanationGenerator.buildPrompt(
            concept: trimmed, course: course, mastery: mastery,
            prerequisites: prerequisites, style: style, settings: settings)
        let plannedMethod = ExplanationGenerator.method(for: trimmed, style: style, course: course)

        guard let result = await runBoundedTurn(prompt) else {
            return "I couldn't put together an explanation just now. Try again in a moment."
        }
        guard let explanation = result["explanation"] as? String,
              !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "I couldn't put together an explanation just now. Try again in a moment." }

        let method = ExplanationGenerator.resolveMethod(
            result["method_used"] as? String, fallback: plannedMethod)
        store.recordSession(concept: trimmed, course: course, mode: .explain, method: method)

        // A brand-new concept is worth remembering outside the tutor too.
        if mastery == nil, mirrorToMemPalace {
            let courseLabel = course.map { " in \($0)" } ?? ""
            mirror(content: "User is currently learning \(trimmed)\(courseLabel)",
                   confidence: 0.6)
        }
        return ExplanationGenerator.render(
            explanation: explanation,
            check: (result["check"] as? String) ?? ExplanationGenerator.checkQuestion())
    }

    // MARK: - Homework help (Socratic)

    /// Guide the user to the answer themselves — or just answer when the
    /// settings say so (Answer mode / Just answer). Returns the questions,
    /// or the direct answer in answer mode.
    func socraticGuide(problem: String, concept: String? = nil) async -> String {
        let trimmed = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What are you stuck on?" }
        let settings = readSettings()
        guard settings.enabled, let hermes else {
            return "I'm not set up to tutor right now — ask me again when Alfred's agent is running."
        }

        let depth = settings.socraticDepth
        let answerMode = settings.mode == .answer || depth == .justAnswer

        let prompt: String
        if answerMode {
            prompt = """
            The user wants the answer directly — no questions. Solve their \
            problem clearly and concisely, showing the key steps. Respond with \
            EXACTLY ONE JSON object, nothing else, no markdown fences:
            {"answer": "the solution"}

            Problem:
            \(trimmed)
            """
        } else {
            prompt = SocraticMethodEngine.buildPrompt(
                problem: trimmed, concept: concept, depth: depth)
        }

        guard let result = await runBoundedTurn(prompt) else {
            return "I couldn't put together guiding questions just now. Try again in a moment."
        }

        // Record the session so "user learned X via Socratic method" lands in
        // the tracker — but only when the concept is nameable. A long pasted
        // problem with no concept would otherwise pollute the concept table
        // with the whole question as a "concept".
        let conceptName = concept ?? trimmed
        if conceptName.count <= 60 || concept != nil {
            store.recordSession(concept: conceptName, course: nil,
                                mode: .socratic, method: .socratic)
        }

        if answerMode {
            return (result["answer"] as? String)
                ?? "I couldn't answer that just now. Try again in a moment."
        }
        return renderQuestions(result)
    }

    /// Format the model's questions+hints JSON into the text the user sees.
    /// Heavy depth shows no hints (they arrive as empty strings anyway).
    private func renderQuestions(_ result: [String: Any]) -> String {
        guard let questions = result["questions"] as? [String] else {
            return "I couldn't put together guiding questions just now. Try again in a moment."
        }
        let hints = result["hints"] as? [String] ?? []
        var lines: [String] = []
        for (index, question) in questions.enumerated() {
            let cleaned = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            lines.append("Q\(index + 1). \(cleaned)")
            if index < hints.count {
                let hint = hints[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !hint.isEmpty {
                    lines.append("   (Hint: \(hint))")
                }
            }
        }
        guard !lines.isEmpty else {
            return "I couldn't put together guiding questions just now. Try again in a moment."
        }
        lines.append("")
        lines.append("Work through these one at a time — I'll wait for each answer.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Feedback (the learning signal)

    /// Score the user's answer to the check question. Resolves the pending
    /// session for the concept (the one `explain` recorded), moves the 1–5
    /// confidence, mirrors meaningful changes to MemPalace, and re-derives
    /// the learning style. When no pending session exists (feedback for a
    /// concept explained outside the tutor), a manual session is recorded.
    @discardableResult
    func recordFeedback(concept: String, outcome: TutoringOutcome,
                        course: String? = nil) -> ConceptMastery? {
        let trimmed = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sessionID: String
        if let pending = store.pendingSession(for: trimmed) {
            sessionID = pending.id
        } else {
            sessionID = store.recordSession(concept: trimmed, course: course,
                                            mode: .manual, method: .direct)
        }
        guard !sessionID.isEmpty else { return nil }

        let updated = store.recordOutcome(sessionID: sessionID, outcome: outcome)

        if mirrorToMemPalace {
            if let updated {
                switch outcome {
                case .understood where updated.confidence >= 4:
                    mirror(content: "User understands \(trimmed) (\(updated.confidence)/5)",
                           confidence: 0.8)
                case .confused:
                    mirror(content: "User is confused about \(trimmed) — it needs another angle",
                           confidence: 0.7)
                default:
                    break
                }
            }
            mirrorSettledStyleIfChanged()
        }

        // Every 10 sessions, let the DSPy bridge propose its own teaching
        // directives (no-op when Python/DSPy isn't configured).
        let total = store.sessionCount()
        if total > 0, total % 10 == 0 {
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.compileTeachingRules()
            }
        }
        return updated
    }

    // MARK: - Mastery (direct)

    /// The `track_mastery` tool: the user (or agent) tells Alfred the real
    /// level. Mirrors the change to MemPalace.
    @discardableResult
    func trackMastery(concept: String, confidence: Int, course: String? = nil) -> ConceptMastery? {
        let trimmed = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let updated = store.setMastery(name: trimmed, confidence: confidence, course: course)
        if let updated, mirrorToMemPalace {
            mirror(content: "User's understanding of \(trimmed) is \(updated.confidence)/5",
                   confidence: 0.8)
        }
        return updated
    }

    // MARK: - Weak concepts

    /// Concepts the user is still struggling with, weakest first.
    func weakConcepts(limit: Int = 10) -> [ConceptMastery] {
        guard readSettings().enabled else { return [] }
        return store.weakConcepts(limit: limit)
    }

    /// Concepts the user has clearly mastered or is strong on (confidence
    /// ≥ 4), strongest first — the "strong in X" half of the weekly review.
    func strongConcepts(limit: Int = 10) -> [ConceptMastery] {
        guard readSettings().enabled else { return [] }
        return store.strongConcepts(limit: limit)
    }

    /// The `what_am_i_weak_at` tool text.
    func whatAmIWeakAt() -> String {
        let weak = store.weakConcepts(limit: 8)
        guard !weak.isEmpty else {
            return "No weak spots on record yet — Alfred learns what trips you up as we work together. Ask me to explain something and tell me when it doesn't click."
        }
        var lines = ["Concepts to work on, weakest first:"]
        for concept in weak {
            var line = "  • \(concept.name)"
            if let course = concept.course, !course.isEmpty { line += " (\(course))" }
            line += " — \(concept.confidence)/5"
            if concept.sessionCount > 0 {
                line += ", asked about \(concept.sessionCount) time\(concept.sessionCount == 1 ? "" : "s")"
            }
            if concept.confusedCount > 0 {
                line += ", confused \(concept.confusedCount) time\(concept.confusedCount == 1 ? "" : "s")"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("Say \"explain <concept>\" to work on one of these, or \"prepare for my exam\" for a focused practice session.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Exam prep

    /// The `exam_prep_routine` tool: focused practice on the weak concepts,
    /// at the user's difficulty level, with immediate feedback + explanation
    /// per problem. `instruction` overrides the default "3–5 problems" line
    /// so the Study Routines can ask for a full timed test or a final review
    /// as the exam approaches.
    func examPrep(examDate: String?, topics: [String] = [],
                  instruction: String? = nil) async -> String {
        let settings = readSettings()
        guard settings.enabled, let hermes else {
            return "I'm not set up to tutor right now — ask me again when Alfred's agent is running."
        }

        var weak = store.weakConcepts(limit: 12)
        if !topics.isEmpty {
            let wanted = topics.map { $0.lowercased() }
            let filtered = weak.filter { concept in
                wanted.contains { concept.name.lowercased().contains($0)
                    || (concept.course?.lowercased().contains($0) ?? false) }
            }
            if !filtered.isEmpty { weak = filtered }
        }
        guard !weak.isEmpty else {
            return "I don't have enough data to know what to drill — explain a few concepts and tell me when they click or don't, then ask again."
        }

        let style = learningStyle()
        let weakLines = weak.map { concept -> String in
            "  - \(concept.name) (\(concept.confidence)/5, \(concept.sessionCount) session\(concept.sessionCount == 1 ? "" : "s"))"
        }.joined(separator: "\n")

        let intensityDescription: String
        switch settings.practiceIntensity {
        case .easy:   intensityDescription = "accessible warm-up problems that build confidence"
        case .medium: intensityDescription = "typical exam-style problems"
        case .hard:   intensityDescription = "challenging problems that push past the syllabus"
        }

        let prompt = """
        You are Alfred, a personal tutor preparing this user for an exam. \
        Focus practice on their weak concepts — weight the drill toward the \
        weakest ones.

        \(LearningStyleAnalyzer.promptBlock(style, course: weak.first?.course))

        Difficulty: \(intensityDescription).
        \(examDate.map { "Exam date: \($0)." } ?? "No exam date given — pace the drill for steady review.")

        Weak concepts (weakest first):
        \(weakLines)

        \(instruction ?? "Generate 3-5 practice problems, ordered weakest-concept-first. For each problem give the full answer and a short explanation of the method, so the user gets immediate feedback.")

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"problems": [{"concept": "...", "question": "...", "answer": "...", "explanation": "..."}]}
        """

        guard let result = await runBoundedTurn(prompt) else {
            return "I couldn't put together practice problems just now. Try again in a moment."
        }
        guard let problems = result["problems"] as? [[String: Any]], !problems.isEmpty else {
            return "I couldn't put together practice problems just now. Try again in a moment."
        }

        // Record a practice session per covered concept so the tracker's
        // session counts reflect the extra reps.
        let plannedMethod = ExplanationGenerator.method(
            for: weak.first?.name ?? "", style: style, course: weak.first?.course)
        for problem in problems {
            if let name = problem["concept"] as? String, !name.isEmpty {
                store.recordSession(concept: name, course: weak.first(where: {
                    ConceptMasteryTracker.nameKey($0.name) == ConceptMasteryTracker.nameKey(name)
                })?.course, mode: .examPrep, method: plannedMethod)
            }
        }

        var lines: [String] = []
        if let examDate, !examDate.isEmpty {
            lines.append("Practice for your \(examDate) exam — \(problems.count) problems, weakest first:")
        } else {
            lines.append("Practice — \(problems.count) problems, weakest first:")
        }
        for (index, problem) in problems.enumerated() {
            let concept = (problem["concept"] as? String) ?? "concept"
            lines.append("")
            lines.append("\(index + 1). [\(concept)]")
            lines.append((problem["question"] as? String) ?? "")
            lines.append("")
            lines.append("   Answer: \((problem["answer"] as? String) ?? "")")
            if let explanation = problem["explanation"] as? String, !explanation.isEmpty {
                lines.append("   Why: \(explanation)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Learning style

    /// The current learned style: deterministic analysis of the session
    /// history, augmented by any DSPy-proposed directives.
    func learningStyle() -> LearningStyle {
        let directives = storedDSPyDirectives()
        return LearningStyleAnalyzer.analyze(
            sessions: store.recentSessions(), externalDirectives: directives)
    }

    /// The `my_learning_style` tool text.
    func myLearningStyle() -> String {
        let style = learningStyle()
        guard style.sessionCount > 0 else {
            return "Alfred hasn't learned your learning style yet — no tutoring sessions on record. Ask me to explain something and tell me whether it clicks; after about 5 sessions I'll know how you learn best."
        }

        var lines = ["How you learn, as Alfred sees it (\(style.sessionCount) tutoring session\(style.sessionCount == 1 ? "" : "s") logged, \(Int((style.confidence * 100).rounded()))% confident):"]
        if !style.preferredMethods.isEmpty {
            lines.append("  • Best with: \(style.preferredMethods.map(\.displayName).joined(separator: ", "))")
        }
        if style.structure != .unknown {
            lines.append("  • Structure: \(style.structure.displayName)")
        }
        if style.depth != .unknown {
            lines.append("  • Depth: \(style.depth.displayName)")
        }
        if style.guidance != .unknown {
            lines.append("  • Guidance: \(style.guidance.displayName)")
        }
        if !style.methodsThatWork.isEmpty {
            lines.append("  • Methods that work: \(style.methodsThatWork.joined(separator: ", "))")
        }
        if !style.methodsThatDont.isEmpty {
            lines.append("  • Methods to avoid: \(style.methodsThatDont.joined(separator: ", "))")
        }
        if !style.isSettled {
            lines.append("")
            lines.append("Still settling — after \(LearningStyleAnalyzer.settledThreshold) sessions the profile firms up.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Briefing card

    /// The Weak Concepts card for the briefing. Nil while the tutor has no
    /// data, so a fresh install never gets an empty card.
    func tutorCard() -> TutorCard? {
        guard readSettings().enabled else { return nil }
        let weak = store.weakConcepts(limit: 3)
        let style = learningStyle()
        guard !weak.isEmpty || style.sessionCount > 0 else { return nil }
        return TutorCard(
            weakConcepts: weak.map {
                TutorWeakConcept(name: $0.name, course: $0.course,
                                 confidence: $0.confidence, sessions: $0.sessionCount,
                                 confusedCount: $0.confusedCount)
            },
            preferredMethods: style.preferredMethods.map(\.displayName),
            sessionCount: style.sessionCount,
            masteredCount: store.masteredCount())
    }

    /// The spec's milestone: once the style is settled (5+ sessions), remember
    /// the teaching methods that work in MemPalace — once per change, so a
    /// settled profile doesn't re-mirror on every feedback.
    private func mirrorSettledStyleIfChanged() {
        let style = learningStyle()
        guard style.isSettled, !style.methodsThatWork.isEmpty else { return }
        let key = "mirrored_style"
        let signature = style.methodsThatWork.joined(separator: ", ")
        guard store.preference(key) != signature else { return }
        store.setPreference(key, value: signature)
        mirror(content: "User learns best via: \(signature)", confidence: 0.8)
    }

    // MARK: - DSPy teaching-rule bridge

    /// Ask the bundled Python script to propose teaching directives via real
    /// DSPy. Returns the directives, or [] when the bridge is unavailable
    /// (no python3, no `dspy` package, or the run failed/timed out) — the
    /// deterministic analyzer covers every case, so this is pure augmentation.
    func compileTeachingRules() async -> [String] {
        guard let python = Self.pythonBinary(),
              let scriptURL = Bundle.module.url(forResource: "dspy_tutor", withExtension: "py")
        else { return [] }

        let sessions = store.recentSessions(limit: 100).map { session -> [String: Any] in
            [
                "concept": session.concept,
                "mode": session.mode.rawValue,
                "method": session.method.rawValue,
                "outcome": session.outcome.rawValue,
            ]
        }
        let payload: [String: Any] = ["sessions": sessions]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [scriptURL.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            NSLog("[tutor] DSPy bridge failed to launch: %@", error.localizedDescription)
            return []
        }
        stdin.fileHandleForWriting.write(data)
        try? stdin.fileHandleForWriting.close()

        let timeout: TimeInterval = 60
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            NSLog("[tutor] DSPy bridge timed out after %.0fs", timeout)
            return []
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let obj = (try? JSONSerialization.jsonObject(with: outData)) as? [String: Any],
              let engine = obj["engine"] as? String, engine == "dspy",
              let raw = obj["directives"] as? [String]
        else { return [] }

        let directives = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !directives.isEmpty, let encoded = try? JSONEncoder().encode(directives),
           let json = String(data: encoded, encoding: .utf8) {
            store.setPreference("dspy_methods", value: json)
            NSLog("[tutor] DSPy proposed %d teaching directives", directives.count)
        }
        return directives
    }

    /// The DSPy-proposed directives stored by the last successful bridge run.
    private func storedDSPyDirectives() -> [String] {
        guard let raw = store.preference("dspy_methods"),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    private static func pythonBinary() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.hermes/hermes-agent/venv/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - MemPalace mirror

    /// Store a durable learning fact in MemPalace (category `.learning`) so
    /// every session — tutoring or not — starts knowing it, and mirror it
    /// verbatim into the real palace when the CLI is installed. Best-effort:
    /// MemPalace being off or absent never breaks the tutor.
    private func mirror(content: String, confidence: Double) {
        guard mirrorToMemPalace else { return }
        let palace = MemPalaceManager.shared
        guard palace.isEnabled else { return }
        _ = palace.remember(content: content, category: .learning,
                            source: "tutor", confidence: confidence)
        palace.verbatimRemember(content)
    }

    // MARK: - Bounded Hermes turn (mirrors TasteSkillManager)

    /// One bounded prompt turn racing a JSON object out of the model stream.
    /// Returns nil when the deadline wins or the reply won't parse — the
    /// caller degrades to its fallback text, never a crash.
    private func runBoundedTurn(_ prompt: String,
                                timeout: TimeInterval = turnTimeout) async -> [String: Any]? {
        guard let hermes else { return nil }
        let outcome = await turnGate.enqueue { [weak self] in
            guard let self, let hermes = self.hermes else { return nil }
            // Re-check at run time — the owner's turn, if one began while this
            // ask queued, must win.
            guard !(await hermes.isTurnActive) else { return nil }
            return await Self.runPromptBounded(hermes, prompt: prompt, timeout: timeout)
        }
        return outcome
    }

    /// The subprocess-free bounded prompt core (static so it unit-tests
    /// without a session): streams a `capture: false` turn, races a deadline,
    /// and pulls the first balanced JSON object out of the reply.
    static func runPromptBounded(_ session: HermesSession, prompt: String,
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
        guard case .transcript(let text) = outcome else {
            NSLog("[tutor] model turn timed out after \(Int(timeout))s")
            return nil
        }
        let cleaned = Self.extractJSONObject(from: text)
        guard let data = cleaned.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj
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
}

// MARK: - Turn gate

/// Serializes the skill's own model turns. HermesSession is single-turn: a
/// second concurrent prompt would overwrite the first's event sink and
/// interleave the streams, so tutoring calls queue sequentially. The
/// `isTurnActive` check is re-run inside the gate at prompt time (TOCTOU-safe).
private actor TutorTurnGate {
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
