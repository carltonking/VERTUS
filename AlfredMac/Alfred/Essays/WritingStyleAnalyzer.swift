// MARK: - WritingStyleAnalyzer
//
// The essay-voice learner. WritingStyleService already tracks the user's
// register (formality, contractions, vocabulary) from chat; this measures the
// *essay-specific* shape of their writing — paragraph rhythm, sentence
// variety, how they use evidence, the transitions they lean on, and the
// skeleton their arguments follow. Pure counting, no ML, deterministic so it
// unit-tests, exactly like the other learning layers.
//
// A profile is folded in with an exponential moving average (0.7 old / 0.3
// new), the same smoothing WritingStyleService uses, so one pasted sample
// can't whip the learned voice.

import Foundation

// MARK: - Tone

enum EssayTone: String, Codable, CaseIterable, Sendable {
    case academic
    case analytical
    case personal
    case critical
    case matchMyStyle

    var displayName: String {
        switch self {
        case .academic: return "Academic"
        case .analytical: return "Analytical"
        case .personal: return "Personal"
        case .critical: return "Critical"
        case .matchMyStyle: return "Match my style"
        }
    }
}

// MARK: - Profile

/// Simple / compound / complex sentence fractions, each 0–1.
struct SentenceVariety: Codable, Equatable, Sendable {
    var simpleFraction: Double
    var compoundFraction: Double
    var complexFraction: Double
}

/// The statistical snapshot of how the user writes essays.
struct EssayStyleProfile: Codable, Equatable, Sendable {
    /// Mean words per paragraph (paragraphs split on blank lines).
    var averageParagraphWords: Double
    var sentenceVariety: SentenceVariety
    /// Fraction of sentences that open with a quotation — the user's appetite
    /// for direct quotes over paraphrase.
    var quoteRatio: Double
    /// The most-used transition words, strongest first (up to 4).
    var commonTransitions: [String]
    /// The argument skeleton detected, e.g. "Thesis → Evidence → Analysis → Conclusion".
    var argumentStructure: String
    /// "academic", "personal", "critical", … — the register the voice leans to.
    var tone: String
    /// The citation style the user's essays default to.
    var citationStyle: String
    var sampleCount: Int

    var isEmpty: Bool { sampleCount == 0 }

    static let empty = EssayStyleProfile(
        averageParagraphWords: 0,
        sentenceVariety: SentenceVariety(simpleFraction: 0, compoundFraction: 0, complexFraction: 0),
        quoteRatio: 0,
        commonTransitions: [],
        argumentStructure: "",
        tone: "",
        citationStyle: "mla",
        sampleCount: 0)

    /// A compact, human-readable summary (also stored in MemPalace).
    var summary: String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        parts.append("essays average \(Int(averageParagraphWords.rounded())) words per paragraph")
        parts.append("\(Int((sentenceVariety.complexFraction * 100).rounded()))% complex / \(Int((sentenceVariety.compoundFraction * 100).rounded()))% compound / \(Int((sentenceVariety.simpleFraction * 100).rounded()))% simple sentences")
        if quoteRatio >= 0.15 { parts.append("leans on direct quotes over paraphrase") }
        if !commonTransitions.isEmpty {
            parts.append("favors transitions like \(commonTransitions.prefix(3).joined(separator: ", "))")
        }
        if !argumentStructure.isEmpty { parts.append("builds arguments as \(argumentStructure)") }
        parts.append("tone: \(tone)")
        parts.append("citation style: \(citationStyle)")
        return parts.joined(separator: "; ")
    }

    /// The bracketed directive injected into a generation prompt.
    func toPromptInjection() -> String {
        guard !isEmpty else { return "" }
        var sentences: [String] = []
        sentences.append("Match the user's essay voice: paragraphs of about \(Int(averageParagraphWords.rounded())) words; roughly \(Int((sentenceVariety.complexFraction * 100).rounded()))% complex, \(Int((sentenceVariety.compoundFraction * 100).rounded()))% compound, \(Int((sentenceVariety.simpleFraction * 100).rounded()))% simple sentences.")
        if quoteRatio >= 0.15 {
            sentences.append("Use direct quotations freely; otherwise paraphrase.")
        }
        if !commonTransitions.isEmpty {
            sentences.append("Prefer transitions like \(commonTransitions.prefix(4).joined(separator: ", ")).")
        }
        if !argumentStructure.isEmpty {
            sentences.append("Structure the argument as \(argumentStructure).")
        }
        if !tone.isEmpty {
            sentences.append("Write in a \(tone) register.")
        }
        return sentences.joined(separator: " ")
    }
}

// MARK: - Analyzer

enum WritingStyleAnalyzer {

    /// Measure one essay. Pure and deterministic — no state, no persistence.
    static func analyze(_ text: String, citationStyle: String = "mla") -> EssayStyleProfile {
        let paragraphs = paragraphs(in: text)
        let sentences = sentences(in: text)
        guard !sentences.isEmpty else { return .empty }

        let words = words(in: text)
        let totalWords = words.count
        let averageParagraphWords = totalWords > 0 && !paragraphs.isEmpty
            ? Double(totalWords) / Double(paragraphs.count)
            : 0

        // Sentence variety: subordinating conjunction → complex; coordinating
        // conjunction or semicolon → compound; else simple.
        var simple = 0, compound = 0, complex = 0
        var quoteSentences = 0
        for sentence in sentences {
            let lower = sentence.lowercased()
            if Self.subordinators.contains(where: { lower.contains($0) }) {
                complex += 1
            } else if Self.coordinators.contains(where: { lower.contains($0) }) || sentence.contains(";") {
                compound += 1
            } else {
                simple += 1
            }
            if sentence.contains("\"") || sentence.contains("“") || sentence.contains("”") {
                quoteSentences += 1
            }
        }
        let count = Double(sentences.count)
        let variety = SentenceVariety(
            simpleFraction: Double(simple) / count,
            compoundFraction: Double(compound) / count,
            complexFraction: Double(complex) / count)

        let transitions = Self.transitions(in: text)
        let structure = Self.argumentStructure(in: text)
        let tone = Self.tone(in: text, words: words)

        return EssayStyleProfile(
            averageParagraphWords: averageParagraphWords,
            sentenceVariety: variety,
            quoteRatio: Double(quoteSentences) / count,
            commonTransitions: transitions,
            argumentStructure: structure,
            tone: tone,
            citationStyle: citationStyle,
            sampleCount: 1)
    }

    /// Fold a fresh analysis into a smoothed profile (0.7 old / 0.3 new); the
    /// first sample is adopted whole.
    static func blend(_ old: EssayStyleProfile, _ new: EssayStyleProfile) -> EssayStyleProfile {
        guard !old.isEmpty else { return new }
        let b = { (a: Double, c: Double) -> Double in 0.7 * a + 0.3 * c }
        // Transitions: union, ranked by combined count approximated by
        // frequency order in the new profile first, then the old.
        let mergedTransitions = Array((new.commonTransitions + old.commonTransitions)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .sorted { $0.value > $1.value }
            .map(\.key)
            .prefix(4))
        return EssayStyleProfile(
            averageParagraphWords: b(old.averageParagraphWords, new.averageParagraphWords),
            sentenceVariety: SentenceVariety(
                simpleFraction: b(old.sentenceVariety.simpleFraction, new.sentenceVariety.simpleFraction),
                compoundFraction: b(old.sentenceVariety.compoundFraction, new.sentenceVariety.compoundFraction),
                complexFraction: b(old.sentenceVariety.complexFraction, new.sentenceVariety.complexFraction)),
            quoteRatio: b(old.quoteRatio, new.quoteRatio),
            commonTransitions: mergedTransitions,
            argumentStructure: new.argumentStructure.isEmpty ? old.argumentStructure : new.argumentStructure,
            tone: new.tone.isEmpty ? old.tone : new.tone,
            citationStyle: new.citationStyle.isEmpty ? old.citationStyle : new.citationStyle,
            sampleCount: old.sampleCount + 1)
    }

    // MARK: - Detectors

    /// The top transitions (up to 4) by occurrence count.
    static func transitions(in text: String) -> [String] {
        let lower = text.lowercased()
        var counts: [String: Int] = [:]
        for word in transitionWords {
            let hits = lower.components(separatedBy: word).count - 1
            if hits > 0 { counts[word] = hits }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(4)
            .map { $0.key.capitalized(with: nil) }
    }

    /// Infer the argument skeleton from structural markers. Returns a
    /// chain of the stages detected, or "" when nothing is recognizable.
    static func argumentStructure(in text: String) -> String {
        let lower = text.lowercased()
        let paragraphs = paragraphs(in: text)
        guard !paragraphs.isEmpty else { return "" }

        var stages: [String] = []
        let first = paragraphs.first?.lowercased() ?? ""
        if thesisMarkers.contains(where: { first.contains($0) }) {
            stages.append("Thesis")
        }
        stages.append("Evidence")
        stages.append("Analysis")
        if counterMarkers.contains(where: { lower.contains($0) }) {
            stages.append("Counterargument")
            if rebuttalMarkers.contains(where: { lower.contains($0) }) {
                stages.append("Rebuttal")
            }
        }
        let last = paragraphs.last?.lowercased() ?? ""
        if conclusionMarkers.contains(where: { last.contains($0) }) || stages.count >= 3 {
            stages.append("Conclusion")
        }
        return stages.joined(separator: " → ")
    }

    /// Classify the register. Critical wins over personal; personal over
    /// analytical; analytical over the formality-based academic default.
    static func tone(in text: String, words: [String]) -> String {
        let lower = text.lowercased()
        if criticalMarkers.contains(where: { lower.contains($0) }) { return "critical" }
        let firstPerson = words.filter { ["i", "i'm", "i’m", "my", "we", "our"].contains($0.lowercased()) }.count
        if !words.isEmpty, Double(firstPerson) / Double(words.count) >= 0.02 { return "personal" }
        if analyticalMarkers.contains(where: { lower.contains($0) }) { return "analytical" }
        return "academic"
    }

    // MARK: Tokenization

    private static func paragraphs(in text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func words(in text: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’"))
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> String? in
                let cleaned = token.trimmingCharacters(in: allowed.inverted)
                return cleaned.isEmpty ? nil : cleaned
            }
    }

    // MARK: Vocabularies

    static let subordinators = ["although", "because", "since", "while", "whereas", "if", "unless", "though", "whereas"]
    static let coordinators = [" and ", " but ", " or ", " so ", " yet ", " nor "]
    static let transitionWords = [
        "furthermore", "however", "in contrast", "this suggests that", "moreover",
        "consequently", "therefore", "nevertheless", "in addition", "for instance",
        "similarly", "on the other hand", "ultimately",
    ]
    static let thesisMarkers = ["argue", "this essay", "thesis", "claim", "will examine", "will explore"]
    static let counterMarkers = ["however", "on the other hand", "some critics", "critics argue", "others argue"]
    static let rebuttalMarkers = ["nevertheless", "nonetheless", "yet", "despite"]
    static let conclusionMarkers = ["ultimately", "in conclusion", "finally", "in sum", "to conclude"]
    static let analyticalMarkers = ["this suggests", "implies", "reveals", "signifies", "demonstrates", "therefore"]
    static let criticalMarkers = ["however", "on the other hand", "critics", "rebut", "despite", "nevertheless"]
}
