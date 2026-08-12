import Foundation

// MARK: - Writing style service

/// Learns the user's writing voice from their messages and makes it available
/// as a system-prompt injection.
///
/// `saveProfileFromQuery(_:)` is called once per user message from
/// `HermesSession.runTurn` (the same spot where messages land in the memory
/// graph), so the profile is always a step ahead of the next reply. Each
/// message's analysis is folded in with an exponential moving average
/// (0.7 × old + 0.3 × new) — a single formal email pasted into the bar can't
/// whip a normally-casual profile into a stiff one. The profile persists to
/// UserDefaults and is loaded at launch, so the voice survives restarts.
///
/// Lightweight by design: sentence splits, word counts and Set membership —
/// no ML, no NLP libraries, nothing that would ever block a turn.
final class WritingStyleService {

    static let shared = WritingStyleService()

    private let storageKey = "alfred.writing_style_profile"

    /// Serializes profile mutation + persistence. Reads are lock-free: a
    /// torn read of a value-type struct is impossible in Swift's memory
    /// model, and the read path (groundedPrompt) only needs the latest whole
    /// value.
    private let lock = NSLock()

    /// The current smoothed profile.
    private(set) var currentProfile: WritingStyleProfile

    private init() {
        currentProfile = Self.load() ?? .empty
    }

    // MARK: - Learning

    /// Analyze one user message and fold it into the profile. Best-effort:
    /// an analysis or persist failure keeps the previous profile — a hiccup
    /// must never reset the learned voice. Call after each user message.
    func saveProfileFromQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let analysis = analyze(trimmed)
        // Wordless input ("!!!", an emoji, "…") yields an empty analysis —
        // blending it in would drag a populated profile toward zero.
        guard !analysis.isEmpty else { return }

        lock.lock()
        updateProfile(with: analysis)
        persist()
        lock.unlock()
    }

    /// Fold a fresh analysis into the smoothed profile: 0.7 × old + 0.3 × new.
    /// The very first sample is adopted whole — averaging against a zero
    /// profile would just halve the first real signal.
    func updateProfile(with newAnalysis: WritingStyleProfile) {
        let old = currentProfile
        guard !old.isEmpty else {
            currentProfile = newAnalysis
            NSLog("[style] first sample adopted (formality %.2f, contractionFreq %.2f)",
                  newAnalysis.formalityScore, newAnalysis.contractionFreq)
            return
        }
        currentProfile = WritingStyleProfile(
            averageWordLength: Self.blend(old.averageWordLength, newAnalysis.averageWordLength),
            averageSentenceLength: Self.blend(old.averageSentenceLength, newAnalysis.averageSentenceLength),
            formalityScore: Self.blend(old.formalityScore, newAnalysis.formalityScore),
            uniqueVocabSize: Int(Self.blend(Double(old.uniqueVocabSize), Double(newAnalysis.uniqueVocabSize)).rounded()),
            contractionFreq: Self.blend(old.contractionFreq, newAnalysis.contractionFreq),
            exclamationFreq: Self.blend(old.exclamationFreq, newAnalysis.exclamationFreq),
            questionFreq: Self.blend(old.questionFreq, newAnalysis.questionFreq),
            technicalTermFreq: Self.blend(old.technicalTermFreq, newAnalysis.technicalTermFreq),
            sampleCount: old.sampleCount + 1)
    }

    /// The EMA weight: recent samples move the profile less and less as the
    /// history grows, so it settles into the user's actual voice.
    private static func blend(_ old: Double, _ new: Double) -> Double {
        0.7 * old + 0.3 * new
    }

    // MARK: - Analysis

    /// Measure one message's writing style. Pure and deterministic — no state,
    /// no persistence — so it can be unit-tested directly.
    func analyze(_ text: String) -> WritingStyleProfile {
        let sentences = Self.sentences(in: text)
        let words = Self.words(in: text)
        guard !words.isEmpty else { return .empty }

        let wordCount = words.count
        let lowerWords = words.map { $0.lowercased() }

        let averageWordLength = Double(words.reduce(0) { $0 + $1.count }) / Double(wordCount)
        let averageSentenceLength = Double(wordCount) / Double(max(sentences.count, 1))

        let uniqueVocabSize = Set(lowerWords).count

        let contractionHits = lowerWords.filter { Self.contractions.contains($0) }.count
        let contractionFreq = Double(contractionHits) / Double(wordCount)

        let exclamationFreq = Double(text.filter { $0 == "!" }.count) / Double(wordCount)
        let questionFreq = Double(text.filter { $0 == "?" }.count) / Double(wordCount)

        // Match inflected forms too: strip a trailing "s" (apis → api,
        // timeouts → timeout, databases → database) before the set lookup.
        let technicalHits = lowerWords.filter { Self.isTechnical($0) }.count
        let technicalTermFreq = Double(technicalHits) / Double(wordCount)

        // Formality estimate, 0–1: long words push formal, contractions and
        // exclamations push casual. Weighted so vocabulary dominates, then
        // smoothed by the EMA on the way into the stored profile.
        let longWordRatio = Double(lowerWords.filter { $0.count >= 7 }.count) / Double(wordCount)
        let contractionPressure = min(contractionFreq * 4, 1)
        let exclamationPressure = min(exclamationFreq * 5, 1)
        let formalityScore = min(max(
            longWordRatio * 0.6 + (1 - contractionPressure) * 0.25 + (1 - exclamationPressure) * 0.15,
            0), 1)

        return WritingStyleProfile(
            averageWordLength: averageWordLength,
            averageSentenceLength: averageSentenceLength,
            formalityScore: formalityScore,
            uniqueVocabSize: uniqueVocabSize,
            contractionFreq: contractionFreq,
            exclamationFreq: exclamationFreq,
            questionFreq: questionFreq,
            technicalTermFreq: technicalTermFreq,
            sampleCount: 1)
    }

    // MARK: Tokenization

    /// Split on `.` `!` `?`; a trailing fragment without a final mark is still
    /// counted as a sentence so short queries get a fair sentence length.
    private static func sentences(in text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
        return parts.map(String.init).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Whitespace split, punctuation stripped off each token (so "issue?" and
    /// "timeouts," don't pollute word length), apostrophes kept so "don't"
    /// stays one recognizable token. Numbers and short tokens (u, lol) count.
    private static func words(in text: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’"))
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> String? in
                let cleaned = token.trimmingCharacters(in: allowed.inverted)
                return cleaned.isEmpty ? nil : cleaned
            }
    }

    private static func isTechnical(_ word: String) -> Bool {
        if technicalTerms.contains(word) { return true }
        if word.count > 3, word.hasSuffix("s"),
           technicalTerms.contains(String(word.dropLast())) { return true }
        return false
    }

    // MARK: Vocabularies

    /// Common contractions + casual shorthand, lowercase. "u", "lol", "gonna"
    /// are included because they're stronger casual markers than most words.
    private static let contractions: Set<String> = [
        "don't", "don’t", "cant", "can't", "can’t", "wont", "won't", "won’t",
        "it's", "it’s", "i'm", "i’m", "i've", "i’ve", "i'll", "i’ll",
        "you're", "you’re", "you've", "you’ve", "we're", "we’re", "they're",
        "they’re", "isn't", "isn’t", "aren't", "aren’t", "wasn't", "wasn’t",
        "weren't", "weren’t", "didn't", "didn’t", "doesn't", "doesn’t",
        "haven't", "haven’t", "hasn't", "hasn’t", "that's", "that’s",
        "what's", "what’s", "let's", "let’s", "there's", "there’s",
        "wouldn't", "wouldn’t", "couldn't", "couldn’t", "shouldn't",
        "shouldn’t", "u", "lol", "lmao", "gonna", "wanna", "gotta", "yeah",
        "yep", "nah", "kinda", "sorta", "dunno", "idk", "btw", "imo", "plz",
    ]

    /// Alfred's own domain vocabulary — the terms most likely to appear in
    /// this user's messages about this very system.
    private static let technicalTerms: Set<String> = [
        "swift", "async", "await", "database", "sqlite", "query", "api",
        "llm", "memory", "ollama", "hermes", "agent", "model", "token",
        "endpoint", "debug", "timeout", "server", "client", "json", "macos",
        "deploy", "bug", "framework", "dependency",
    ]

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(currentProfile) else {
            NSLog("[style] persist failed — keeping in-memory profile")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func load() -> WritingStyleProfile? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.writing_style_profile"),
              let profile = try? JSONDecoder().decode(WritingStyleProfile.self, from: data)
        else { return nil }
        return profile
    }
}
