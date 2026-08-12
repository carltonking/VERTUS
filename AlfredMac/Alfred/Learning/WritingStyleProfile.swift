import Foundation

// MARK: - Writing style profile

/// A statistical snapshot of how the user writes — tone, vocabulary,
/// sentence rhythm, formality — measured with pure counting, no ML.
///
/// Every field is produced by `WritingStyleService.analyze(_:)` from the raw
/// message text: sentences are split on `.` `!` `?`, words on whitespace, and
/// the rest are cheap counts (contractions, exclamation marks, technical
/// terms from a fixed domain list). The profile is smoothed over time by the
/// service (exponential moving average), so a single unusual message can't
/// whipsaw the voice.
struct WritingStyleProfile: Codable, Equatable {

    // MARK: Fields

    /// Mean word length in characters (apostrophes kept, punctuation stripped).
    var averageWordLength: Double
    /// Mean words per sentence.
    var averageSentenceLength: Double
    /// 0.0 = chatty/plain, 1.0 = formal. Estimated from long-word ratio,
    /// contraction frequency and exclamation frequency.
    var formalityScore: Double
    /// Distinct lowercased words observed.
    var uniqueVocabSize: Int
    /// Fraction of words that are contractions or casual shorthand
    /// (don't, it's, gonna, lol, u …). 0.0–1.0.
    var contractionFreq: Double
    /// Exclamation marks per word. 0.0–1.0.
    var exclamationFreq: Double
    /// Question marks per word. 0.0–1.0.
    var questionFreq: Double
    /// Fraction of words matching Alfred's technical vocabulary
    /// (swift, async, database, api, llm …). 0.0–1.0.
    var technicalTermFreq: Double

    /// Number of messages folded in so far. Lets the service give the very
    /// first message full weight instead of diluting it through the average.
    var sampleCount: Int

    /// True before any real message has been analyzed — no signal yet.
    var isEmpty: Bool { sampleCount == 0 }

    /// The neutral starting point: every metric zero, injection says nothing.
    static let empty = WritingStyleProfile(
        averageWordLength: 0,
        averageSentenceLength: 0,
        formalityScore: 0,
        uniqueVocabSize: 0,
        contractionFreq: 0,
        exclamationFreq: 0,
        questionFreq: 0,
        technicalTermFreq: 0,
        sampleCount: 0)

    // MARK: - Prompt injection

    /// Two to three plain sentences describing the learned voice, ready to be
    /// appended to the system prompt. Returns "" while the profile is empty,
    /// so a fresh install injects nothing and the agent keeps its default.
    func toPromptInjection() -> String {
        guard !isEmpty else { return "" }

        var sentences: [String] = []

        // 1. Tone: formality plus contraction frequency pick the register.
        if formalityScore >= 0.6 {
            sentences.append(contractionFreq < 0.03
                ? "The user writes formally and precisely, avoiding contractions and casual shorthand."
                : "The user writes in a fairly formal register, with occasional casual shorthand.")
        } else if formalityScore <= 0.4 {
            sentences.append(contractionFreq >= 0.06
                ? "The user writes casually and conversationally, using contractions and informal shorthand."
                : "The user writes conversationally, in plain everyday language.")
        } else {
            sentences.append("The user writes in a plain, mixed register — neither stiffly formal nor heavily slangy.")
        }

        // 2. Vocabulary and rhythm: technical comfort first, else sentence
        //    length as the proxy for how much room a reply should take.
        if technicalTermFreq >= 0.08 {
            sentences.append("They are comfortable with technical vocabulary — code, APIs, databases, models — so using it back at them is fine.")
        } else if averageWordLength <= 4.2 {
            sentences.append("They favour short, everyday words, so keep terminology plain.")
        } else if averageSentenceLength >= 18 {
            sentences.append("Their sentences run long, so fuller answers fit their rhythm.")
        } else {
            sentences.append("Keep sentences short to match their rhythm.")
        }

        // 3. The ask — always the same shape, in the register just described.
        sentences.append("Match this register in your replies: concise, direct, in the user's voice.")

        return sentences.joined(separator: " ")
    }
}
