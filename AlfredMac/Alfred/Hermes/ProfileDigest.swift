import Foundation

/// Hermes Tier‑1: a bounded-markdown profile in two small files, regenerated on-device and
/// injected into Alfred's system prompt every session. Capacity caps force consolidation
/// (merge related facts, drop redundancy) so the profile stays small and high-signal.
///
/// Files live at `~/.alfred/profile/USER.md` and `MEMORY.md`. The user never edits these; the
/// agent curates them. They are derived only from local signals and consolidated by the local
/// model (`LocalLearningLLM`) — nothing leaves the Mac.
enum ProfileDigest {
    static let userCap = 1400
    static let memoryCap = 2200

    /// Minimum captured evidence before we'll build a profile at all. Below this, we refuse to
    /// generate (and never let the model invent traits/projects/people from nothing).
    static let minScreenTextRecords = 5

    /// Written to USER.md when there isn't enough real data. Treated as "no profile" by readers.
    static let emptySentinel = "Profile empty — no data yet"

    /// Honest answer when the profile is empty/minimal.
    static let notEnoughDataMessage = """
        I haven't captured enough of your activity yet to build a profile. Turn on screen text \
        capture and use Alfred more, then I'll learn about you — all kept locally on your Mac.
        """

    /// True when there's enough real captured data to justify generating a profile.
    static func hasEnoughData(screenTextCount: Int, meetingCount: Int) -> Bool {
        screenTextCount >= minScreenTextRecords || meetingCount >= 1
    }

    /// Trims a profile file's contents; the empty sentinel reads back as "".
    private static func cleaned(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == emptySentinel ? "" : t
    }

    private static var dirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".alfred/profile", directoryHint: .isDirectory)
    }
    private static var userURL: URL { dirURL.appending(path: "USER.md") }
    private static var memoryURL: URL { dirURL.appending(path: "MEMORY.md") }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    }

    // buildSystem() reads USER.md + MEMORY.md on every LLM query. Cache their contents and refresh
    // the cache from write() (the single mutation point, via regenerate()) so a just-regenerated
    // profile is visible immediately. Lock-guarded because readers can run under concurrent tasks.
    private static let cacheLock = NSLock()
    private static var cachedUser: String?
    private static var cachedMemory: String?

    static func readUser() -> String {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedUser { return cachedUser }
        let value = (try? String(contentsOf: userURL, encoding: .utf8)) ?? ""
        cachedUser = value
        return value
    }
    static func readMemory() -> String {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedMemory { return cachedMemory }
        let value = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
        cachedMemory = value
        return value
    }

    /// Bounded private-profile block for the system prompt. When no real profile exists yet, this
    /// injects an explicit anti-fabrication GUARD (not nothing) so the model can't invent personal
    /// facts when asked "what do you know about me?".
    static func injectedSystemText() -> String {
        let user = cleaned(readUser())
        let mem = cleaned(readMemory())
        if user.isEmpty && mem.isEmpty {
            return """
                ABOUT THE USER: You have NOT built any profile of this user and have no stored \
                personal data about them. If they ask what you know about them (in any phrasing), \
                say you haven't learned enough yet and suggest enabling screen-text capture and \
                using Alfred more. NEVER invent personality traits, projects, relationships, \
                habits, goals, or preferences. State only facts you are actually given.
                """
        }
        var block = "WHAT ALFRED KNOWS ABOUT THE USER (private profile, derived only from real "
        block += "captured data — use it to personalize, but only recite it verbatim if asked):"
        if !user.isEmpty { block += "\n\n[USER]\n\(user)" }
        if !mem.isEmpty { block += "\n\n[MEMORY]\n\(mem)" }
        return block
    }

    /// Human-facing answer to "what do you know about me?". Honest when there's no real profile.
    static func whatDoYouKnow() -> String {
        let user = cleaned(readUser())
        let mem = cleaned(readMemory())
        if user.isEmpty && mem.isEmpty { return notEnoughDataMessage }
        var out = "Here's what I've learned about you — kept locally on your Mac:\n"
        if !user.isEmpty { out += "\n\(user)" }
        if !mem.isEmpty { out += "\n\n\(mem)" }
        return out
    }

    /// Regenerates USER.md / MEMORY.md from freeform signal lines. Refuses to generate (writes the
    /// empty sentinel) unless there's enough real captured data — it never fabricates a profile
    /// from nothing. Consolidation is on-device (Ollama); with no local model it stores only the
    /// raw factual signals (no invented traits).
    static func regenerate(ownerName: String, signals: [String], screenTextCount: Int, meetingCount: Int) async {
        ensureDir()
        guard hasEnoughData(screenTextCount: screenTextCount, meetingCount: meetingCount) else {
            write(user: emptySentinel, memory: "")
            return
        }
        let joined = signals
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !joined.isEmpty else { write(user: emptySentinel, memory: ""); return }

        if let consolidated = await consolidate(ownerName: ownerName, signals: joined,
                                                existingUser: cleaned(readUser()),
                                                existingMemory: cleaned(readMemory())) {
            if cleaned(consolidated.user).isEmpty && cleaned(consolidated.memory).isEmpty {
                write(user: emptySentinel, memory: "")   // model judged the evidence too thin
            } else {
                write(user: consolidated.user, memory: consolidated.memory)
            }
        } else {
            // No local model reachable: store the raw, factual signals only. Do NOT invent a
            // personality profile — USER stays minimal.
            write(user: "Name: \(ownerName)", memory: String(joined.suffix(memoryCap)))
        }
    }

    private static func consolidate(ownerName: String, signals: String,
                                    existingUser: String, existingMemory: String) async -> (user: String, memory: String)? {
        let system = """
            You maintain a private user profile for a personal assistant. Use ONLY facts explicitly \
            present in the SIGNALS. NEVER invent names, personality traits, projects, relationships, \
            or preferences — if a detail isn't supported by the signals, omit it. If the signals are \
            too thin to state anything concrete, output exactly this line and nothing else:
            \(emptySentinel)
            Otherwise output STRICT markdown with exactly two sections and no preamble:
            ## USER
            (<= \(userCap) chars: only what the signals support — name, role, observed app/tool usage)
            ## MEMORY
            (<= \(memoryCap) chars: durable facts grounded in the signals — projects, topics, people seen)
            Be terse. Prefer omission over guessing.
            """
        let prompt = """
            User name: \(ownerName)

            EXISTING USER:
            \(existingUser.isEmpty ? "(none)" : existingUser)

            EXISTING MEMORY:
            \(existingMemory.isEmpty ? "(none)" : existingMemory)

            SIGNALS (recent local observations — the ONLY source of truth):
            \(signals)
            """
        guard let out = await LocalLearningLLM.shared.run(system: system, prompt: prompt) else { return nil }
        // Model explicitly judged the evidence insufficient.
        if out.range(of: "## USER", options: .caseInsensitive) == nil,
           out.range(of: emptySentinel, options: .caseInsensitive) != nil {
            return (emptySentinel, "")
        }
        return splitSections(out)
    }

    private static func splitSections(_ md: String) -> (user: String, memory: String)? {
        guard let userRange = md.range(of: "## USER", options: .caseInsensitive) else { return nil }
        let afterUser = md[userRange.upperBound...]
        if let memRange = afterUser.range(of: "## MEMORY", options: .caseInsensitive) {
            let user = String(afterUser[..<memRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let memory = String(afterUser[memRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (String(user.prefix(userCap)), String(memory.prefix(memoryCap)))
        }
        let user = String(afterUser).trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(user.prefix(userCap)), "")
    }

    private static func write(user: String, memory: String) {
        ensureDir()
        try? user.write(to: userURL, atomically: true, encoding: .utf8)
        try? memory.write(to: memoryURL, atomically: true, encoding: .utf8)
        // The files now contain exactly these strings — refresh the cache so readers see them.
        cacheLock.lock()
        cachedUser = user
        cachedMemory = memory
        cacheLock.unlock()
    }
}
