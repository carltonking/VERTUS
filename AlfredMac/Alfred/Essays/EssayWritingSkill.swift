// MARK: - EssayWritingSkill
//
// Alfred's essay writer: the orchestrator that turns a topic into a
// submission-ready essay in the user's own voice. One request fans out across
// the pieces this directory owns —
//
//   SourceResearcher      → find credible web sources (Crawlee search)
//   WritingStyleAnalyzer  → the learned essay voice (paragraph rhythm,
//                           sentence variety, transitions, argument skeleton)
//   EssayOutlineGenerator → the per-type section template + the full prompt
//   CitationManager       → in-text guidance + the formatted reference list
//   TasteSkillManager     → (revise path) anti-slop prose polish
//
// and a single bounded Hermes turn does the writing. Style learning persists
// to UserDefaults and mirrors a coarse summary into MemPalace, so the next
// essay matches the last few automatically.

import Foundation

// MARK: - Settings

struct EssaySettings: Codable, Equatable, Sendable {
    var citationStyle: CitationStyle
    var tone: EssayTone
    var defaultLength: String
    var researchDepth: ResearchDepth
    var reviewBeforeSubmit: Bool

    static let `default` = EssaySettings(
        citationStyle: .mla,
        tone: .matchMyStyle,
        defaultLength: "1500 words",
        researchDepth: .light,
        reviewBeforeSubmit: true)
}

// MARK: - Result

struct EssayResult: Codable, Equatable, Sendable {
    var title: String
    /// The essay body plus the appended reference list.
    var essay: String
    var worksCited: String
    var citations: [Citation]
    var sources: [EssaySource]
    /// The style injection used (empty when writing in a fixed tone).
    var styleUsed: String
}

// MARK: - Skill

final class EssayWritingSkill {

    static let shared = EssayWritingSkill()

    private let settingsKey = "alfred.essay_settings"
    private let styleKey = "alfred.essay_style_profile"

    private let lock = NSLock()
    private var storedSettings: EssaySettings
    private var storedStyle: EssayStyleProfile

    /// The dedicated agent the essay turns run on. A separate HermesSession,
    /// not the shared user-facing one: `write_essay` is an MCP tool, so it is
    /// called *while* the user's session is mid-turn — running the essay on
    /// that session would deadlock it. Spawned lazily (the first essay pays
    /// the bridge startup), then reused, exactly like SpecializedAgent.
    private let agentLock = NSLock()
    private var essayAgent: HermesSession?

    private init() {
        storedSettings = Self.loadSettings() ?? .default
        storedStyle = Self.loadStyle() ?? .empty
    }

    /// The dedicated essay agent, spawning it on first use. Returns nil when
    /// the agent can't start (missing binary, stuck bridge) — callers then
    /// degrade to a clear message instead of throwing.
    private func ensureAgent() async -> HermesSession? {
        agentLock.lock()
        if let agent = essayAgent { agentLock.unlock(); return agent }
        agentLock.unlock()

        let session = HermesSession(workingDirectory: NSHomeDirectory(), turnDeadline: 600)
        do {
            try await session.start()
        } catch {
            NSLog("[essay] dedicated agent failed to start: %@", error.localizedDescription)
            return nil
        }
        agentLock.lock()
        essayAgent = session
        agentLock.unlock()
        return session
    }

    /// Tear down the dedicated agent at app quit, so no second Hermes process
    /// outlives Alfred.
    func shutdown() async {
        agentLock.lock()
        let agent = essayAgent
        essayAgent = nil
        agentLock.unlock()
        await agent?.shutdown()
    }

    // MARK: - Settings

    private func readSettings() -> EssaySettings {
        lock.lock()
        defer { lock.unlock() }
        return storedSettings
    }

    private func mutateSettings(_ change: (inout EssaySettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var updated = storedSettings
        change(&updated)
        guard updated != storedSettings else { return }
        storedSettings = updated
        persistSettings()
    }

    var settings: EssaySettings {
        get { readSettings() }
        set { mutateSettings { $0 = newValue } }
    }

    // MARK: - Style learning

    private func readStyle() -> EssayStyleProfile {
        lock.lock()
        defer { lock.unlock() }
        return storedStyle
    }

    /// Analyze one essay and fold it into the learned voice. Returns the
    /// updated profile. Persists to UserDefaults and mirrors a coarse summary
    /// into MemPalace so the voice is grounded for every future session.
    @discardableResult
    func learnStyle(from text: String) -> EssayStyleProfile {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return readStyle() }
        let analysis = WritingStyleAnalyzer.analyze(trimmed, citationStyle: readSettings().citationStyle.rawValue)

        lock.lock()
        let updated = WritingStyleAnalyzer.blend(storedStyle, analysis)
        storedStyle = updated
        lock.unlock()

        persistStyle()
        mirrorStyleToMemPalace(updated)
        return updated
    }

    func currentStyle() -> EssayStyleProfile {
        readStyle()
    }

    /// The human/machine-readable description of the learned voice — what the
    /// `analyze_my_writing_style` tool reports.
    func styleDescription() -> String {
        let style = readStyle()
        guard !style.isEmpty else {
            return "No essay style learned yet. Analyze a past essay with learnStyle and Alfred will start matching it."
        }
        return style.toPromptInjection()
    }

    // MARK: - Research

    /// Find sources for a topic, then (when a session is free) summarize each
    /// and extract quotable lines in one bounded turn. Degrades to bare
    /// title/url/snippet sources when Hermes is busy or unconfigured.
    func research(topic: String, depth: ResearchDepth? = nil) async -> [EssaySource] {
        let resolvedDepth = depth ?? readSettings().researchDepth
        let sources = await SourceResearcher.shared.searchSources(topic: topic, depth: resolvedDepth)
        guard !sources.isEmpty, let hermes = await ensureAgent(), await !hermes.isTurnActive else { return sources }

        let numbered = sources.enumerated()
            .map { "\($0.offset): \($0.element.title) — \($0.element.snippet)" }
            .joined(separator: "\n")
        let prompt = """
        You are Alfred's research assistant. For each numbered source below, write \
        a one-sentence summary and up to two short, quotable lines. Respond with \
        EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"sources":[{"index":0,"summary":"one sentence","quotes":["quote"]}]}

        SOURCES:
        \(numbered)
        """
        guard let obj = await Self.runJSONTurn(hermes, prompt: prompt, timeout: 60),
              let items = obj["sources"] as? [[String: Any]] else { return sources }

        var enriched = sources
        for item in items {
            guard let index = item["index"] as? Int, enriched.indices.contains(index) else { continue }
            enriched[index].summary = (item["summary"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            enriched[index].keyQuotes = (item["quotes"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return enriched
    }

    // MARK: - Writing

    /// Generate a full essay: research → outline → write → cite. Returns a
    /// usable result or a clear failure string in `essay` — never throws.
    func writeEssay(topic: String, length: String? = nil, type: EssayType? = nil,
                    citationStyle: CitationStyle? = nil, tone: EssayTone? = nil) async -> EssayResult {
        let settings = readSettings()
        let resolvedLength = length ?? settings.defaultLength
        let resolvedStyle = citationStyle ?? settings.citationStyle
        let resolvedTone = tone ?? settings.tone
        let resolvedType = type ?? EssayType.detect(from: topic)

        let sources = await research(topic: topic, depth: settings.researchDepth)
        let style = resolvedTone == .matchMyStyle ? readStyle() : .empty

        guard let hermes = await ensureAgent() else {
            return EssayResult(
                title: topic,
                essay: "Alfred's essay agent couldn't start (missing Hermes binary or a stuck bridge).",
                worksCited: "", citations: [], sources: sources, styleUsed: "")
        }
        guard await !hermes.isTurnActive else {
            return EssayResult(
                title: topic,
                essay: "Alfred is busy with another request. Ask again in a moment.",
                worksCited: "", citations: [], sources: sources, styleUsed: "")
        }

        let prompt = EssayOutlineGenerator.generationPrompt(
            topic: topic, length: resolvedLength, type: resolvedType,
            tone: resolvedTone, style: style, citationStyle: resolvedStyle,
            sources: sources)

        guard let body = await Self.runTextTurn(hermes, prompt: prompt, timeout: 300),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return EssayResult(
                title: topic,
                essay: "The essay turn didn't produce text — it may have timed out. Ask again.",
                worksCited: "", citations: [], sources: sources, styleUsed: style.toPromptInjection())
        }

        let citations = sources.map(\.citation)
        let worksCited = CitationManager.referenceList(citations, style: resolvedStyle)
        let full = "\(body)\n\n### \(resolvedStyle.listHeader)\n\(worksCited)"

        return EssayResult(
            title: topic,
            essay: full,
            worksCited: worksCited,
            citations: citations,
            sources: sources,
            styleUsed: style.toPromptInjection())
    }

    /// Revise an essay from a natural-language instruction, keeping the voice.
    func revise(essay: String, feedback: String, tone: EssayTone? = nil) async -> String {
        let trimmed = essay.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !notes.isEmpty, let hermes = await ensureAgent() else { return essay }

        let style = (tone ?? readSettings().tone) == .matchMyStyle
            ? readStyle().toPromptInjection()
            : ""

        let prompt = """
        You are Alfred's essay editor. Revise the essay below according to the \
        feedback, preserving the user's voice throughout.

        Feedback: \(notes)
        \(style.isEmpty ? "" : "Voice: \(style)")

        Return the complete revised essay only — no preamble, no markdown fences.

        ESSAY:
        \(trimmed)
        """
        return await Self.runTextTurn(hermes, prompt: prompt, timeout: 240) ?? essay
    }

    /// The citation sanity check, delegated to the pure formatter.
    func checkCitations(essay: String, citations: [Citation], style: CitationStyle) -> [String] {
        CitationManager.check(essay, citations: citations, style: style)
    }

    /// The text-only citation check (the MCP tool's path): verify the essay's
    /// own reference list is internally consistent.
    func checkCitations(essay: String, style: CitationStyle? = nil) -> [String] {
        CitationManager.checkReferenceList(essay, style: style ?? readSettings().citationStyle)
    }

    // MARK: - Persistence

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(storedSettings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private func persistStyle() {
        guard let data = try? JSONEncoder().encode(storedStyle) else { return }
        UserDefaults.standard.set(data, forKey: styleKey)
    }

    private static func loadSettings() -> EssaySettings? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.essay_settings") else { return nil }
        return try? JSONDecoder().decode(EssaySettings.self, from: data)
    }

    private static func loadStyle() -> EssayStyleProfile? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.essay_style_profile") else { return nil }
        return try? JSONDecoder().decode(EssayStyleProfile.self, from: data)
    }

    /// Mirror the voice into MemPalace as a coarse, stable fact so it upserts
    /// instead of spawning a new memory every essay.
    private func mirrorStyleToMemPalace(_ style: EssayStyleProfile) {
        guard !style.isEmpty else { return }
        let paragraph = Int((style.averageParagraphWords / 10).rounded()) * 10
        let complex = Int((style.sentenceVariety.complexFraction * 10).rounded()) * 10
        let structure = style.argumentStructure.isEmpty ? "standard" : style.argumentStructure
        let content = "essay voice: \(paragraph)-word paragraphs, \(complex)% complex sentences, \(structure) structure, \(style.tone) tone"
        MemPalaceManager.shared.remember(
            content: content,
            category: .preference,
            source: "essay_style",
            tags: ["essay", "style"],
            confidence: 0.6)
    }

    // MARK: - Bounded turns

    private static let turnTimeout: TimeInterval = 300

    /// Stream a plain-text answer out of the session, bounded so a wedged turn
    /// can never hang the caller forever.
    private static func runTextTurn(_ session: HermesSession, prompt: String,
                                    timeout: TimeInterval) async -> String? {
        enum Outcome {
            case transcript(String)
            case timedOut
        }
        let turn = Task { () -> String in
            var transcript = ""
            for await event in await session.prompt(prompt, capture: false) {
                switch event {
                case .text(let chunk): transcript.append(chunk)
                case .failed: break
                case .thought, .toolStarted, .toolProgress, .usage, .finished:
                    break
                }
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
        guard case .transcript(let text) = outcome else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "```markdown", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Race a JSON object out of the model stream (the same helper the memory
    /// and taste layers use). Returns nil on timeout or unparsable output.
    private static func runJSONTurn(_ session: HermesSession, prompt: String,
                                    timeout: TimeInterval) async -> [String: Any]? {
        enum Outcome {
            case transcript(String)
            case timedOut
        }
        let turn = Task { () -> String in
            var transcript = ""
            for await event in await session.prompt(prompt, capture: false) {
                switch event {
                case .text(let chunk): transcript.append(chunk)
                case .failed: break
                case .thought, .toolStarted, .toolProgress, .usage, .finished:
                    break
                }
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
        guard case .transcript(let raw) = outcome else { return nil }
        let cleaned = Self.extractJSONObject(from: raw)
        guard let data = cleaned.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Pull the first balanced {...} object out of a model reply.
    private static func extractJSONObject(from raw: String) -> String {
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
