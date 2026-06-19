import Foundation

struct WritingStyleAnalyzer {

    // MARK: - Public API

    func analyze(_ text: String) -> AnalysisResult {
        let sentences = splitSentences(text)
        let paragraphs = splitParagraphs(text)
        let words = tokenizeWords(text)
        let wordCount = words.count
        let sentenceCount = sentences.count

        let avgSentenceLength = sentenceCount > 0 ? Double(wordCount) / Double(sentenceCount) : 0
        let avgParagraphLength = paragraphs.count > 0 ? Double(sentences.count) / Double(paragraphs.count) : 0
        let greeting = extractGreeting(sentences)
        let closing = extractClosing(sentences)
        let formality = estimateFormality(text, sentences: sentences, words: words)
        let emojiCount = countEmojis(text)
        let punctPatterns = punctuationPatterns(text)
        let phrases = extractCommonPhrases(words)

        return AnalysisResult(
            wordCount: wordCount,
            sentenceCount: sentenceCount,
            avgSentenceLength: avgSentenceLength,
            avgParagraphLength: avgParagraphLength,
            greeting: greeting,
            closing: closing,
            formalityScore: formality,
            emojiCount: emojiCount,
            punctuationPatterns: punctPatterns,
            commonPhrases: phrases
        )
    }

    // MARK: - Sentence splitting

    func splitSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let abbreviations: Set<String> = [
            "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "ave", "blvd",
            "dept", "est", "inc", "ltd", "co", "corp", "vs", "etc", "e.g", "i.e",
            "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
            "approx", "appt", "apt", "assn", "attn", "ca", "cf", "chap", "col",
            "capt", "gen", "lt", "cmdr", "sgt", "cpl", "maj",
        ]

        var sentences: [String] = []
        var current = ""
        var previousChar: Character = " "
        var inNumber = false
        var idx = trimmed.startIndex

        while idx < trimmed.endIndex {
            let char = trimmed[idx]

            if char.isNumber || (char == "." && inNumber) {
                if char.isNumber {
                    inNumber = true
                }
                current.append(char)
                previousChar = char
                idx = trimmed.index(after: idx)
                continue
            }
            inNumber = false

            current.append(char)

            let enders: Set<Character> = [".", "!", "?"]
            if enders.contains(char) {
                let wordsBefore = current.split(separator: " ").map(String.init)
                if let lastWord = wordsBefore.last?.trimmingCharacters(in: .punctuationCharacters).lowercased() {
                    if abbreviations.contains(lastWord) {
                        previousChar = char
                        idx = trimmed.index(after: idx)
                        continue
                    }
                    if lastWord.count == 1 && lastWord.first?.isUppercase == true {
                        previousChar = char
                        idx = trimmed.index(after: idx)
                        continue
                    }
                }

                if previousChar == char && char != "." {
                    previousChar = char
                    idx = trimmed.index(after: idx)
                    continue
                }

                let remainder = trimmed[trimmed.index(after: idx)...]
                let firstChar = remainder.trimmingCharacters(in: .whitespaces).first
                if let fc = firstChar, fc.isLowercase {
                    previousChar = char
                    idx = trimmed.index(after: idx)
                    continue
                }

                let cleaned = current.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    sentences.append(cleaned)
                }
                current = ""
            }
            previousChar = char
            idx = trimmed.index(after: idx)
        }

        let remaining = current.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        return sentences.isEmpty ? [trimmed] : sentences
    }

    // MARK: - Paragraph splitting

    func splitParagraphs(_ text: String) -> [String] {
        let blocks = text.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var paragraphs: [String] = []
        var current: [String] = []

        for block in blocks {
            if block.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                }
            } else {
                current.append(block)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs
    }

    // MARK: - Tokenization

    func tokenizeWords(_ text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: #"[^\w\s'-]"#, with: " ", options: .regularExpression)
        return cleaned.split(separator: " ")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Greeting detection

    func extractGreeting(_ sentences: [String]) -> String? {
        guard let first = sentences.first?.trimmingCharacters(in: .whitespaces) else { return nil }

        let greetings: [(pattern: String, formal: Bool)] = [
            ("dear", true),
            ("hello", false),
            ("hi ", false),
            ("hey", false),
            ("good morning", true),
            ("good afternoon", true),
            ("good evening", true),
            ("greetings", true),
            ("to whom it may concern", true),
            ("hiya", false),
            ("howdy", false),
            ("yo", false),
            ("sup", false),
            ("hey there", false),
            ("hi there", false),
        ]

        let lowered = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
        for (pattern, _) in greetings {
            if lowered.hasPrefix(pattern) {
                let words = lowered.split(separator: " ")
                if pattern.split(separator: " ").count < words.count {
                    let greetingWords = words.prefix(pattern.split(separator: " ").count + 1)
                    let detected = greetingWords.map { $0.capitalized }.joined(separator: " ")
                    if detected.count <= 20 {
                        return detected
                    }
                }
                let capped = pattern.capitalized
                return capped
            }
        }
        return nil
    }

    // MARK: - Closing detection

    func extractClosing(_ sentences: [String]) -> String? {
        guard let last = sentences.last?.trimmingCharacters(in: .whitespaces) else { return nil }

        let closings: [String] = [
            "best regards", "kind regards", "warm regards", "regards",
            "best", "cheers", "thanks", "thank you", "sincerely",
            "yours truly", "yours sincerely", "yours faithfully",
            "respectfully", "cordially", "with appreciation",
            "talk soon", "talk later", "take care", "all the best",
            "Have a great day", "have a good one",
        ]

        let lowered = last.lowercased().trimmingCharacters(in: .punctuationCharacters)
        for closing in closings {
            if lowered.hasPrefix(closing) || lowered == closing {
                let words = lowered.split(separator: " ")
                let closingWords = closing.split(separator: " ").count
                if closingWords < words.count {
                    let detected = words.prefix(closingWords + 1).map { $0.capitalized }.joined(separator: " ")
                    if detected.count <= 25 {
                        return detected
                    }
                }
                return closing.capitalized
            }
        }
        return nil
    }

    // MARK: - Formality estimation

    func estimateFormality(_ text: String, sentences: [String], words: [String]) -> Double {
        guard !words.isEmpty else { return 0.5 }

        var formalScore = 0.0
        var signals = 0

        let lowered = text.lowercased()

        // Contractions → informal (-)
        let contractions: Set<String> = [
            "don't", "can't", "won't", "couldn't", "wouldn't", "shouldn't",
            "isn't", "aren't", "wasn't", "weren't", "hasn't", "haven't",
            "hadn't", "doesn't", "didn't", "mustn't", "needn't",
            "i'm", "you're", "he's", "she's", "it's", "we're", "they're",
            "i've", "you've", "we've", "they've",
            "i'll", "you'll", "he'll", "she'll", "it'll", "we'll", "they'll",
            "i'd", "you'd", "he'd", "she'd", "we'd", "they'd",
            "gonna", "wanna", "gotta", "ain't", "ya", "lemme", "gimme",
        ]
        let contractionCount = words.filter { contractions.contains($0.lowercased()) }.count
        if contractionCount > 0 {
            let rate = Double(contractionCount) / Double(words.count)
            formalScore -= rate * 0.3
            signals += 1
        }

        // Formal closings → formal (+)
        if let closing = extractClosing(sentences) {
            let formalClosings = ["sincerely", "regards", "yours truly", "respectfully", "cordially"]
            if formalClosings.contains(where: { closing.lowercased().contains($0) }) {
                formalScore += 0.15
                signals += 1
            }
        }

        // Formal greetings → formal (+)
        if let greeting = extractGreeting(sentences) {
            let formalGreetings = ["dear", "good morning", "good afternoon", "good evening", "greetings", "to whom"]
            if formalGreetings.contains(where: { greeting.lowercased().contains($0) }) {
                formalScore += 0.15
                signals += 1
            }
        }

        // Sentence length signal
        let avgLen = sentences.count > 0
            ? Double(words.count) / Double(sentences.count)
            : 0
        if avgLen > 18 {
            formalScore += 0.1
            signals += 1
        } else if avgLen < 8 {
            formalScore -= 0.1
            signals += 1
        }

        // Slang → informal (-)
        let slangTerms: Set<String> = [
            "lol", "lmao", "idk", "tbh", "afk", "btw", "omg", "wtf", "lmk",
            "nvm", "ikr", "smh", "fyi", "aka", "asap", "diy",
            "cool", "awesome", "amazing", "literally", "basically",
            "okay", "ok", "yeah", "yep", "nope", "nah", "hey",
        ]
        let slangCount = words.filter { slangTerms.contains($0.lowercased()) }.count
        if slangCount > 0 {
            let rate = Double(slangCount) / Double(words.count)
            formalScore -= rate * 0.25
            signals += 1
        }

        // Passive voice markers → formal (+)
        let passiveMarkers = ["is ", "are ", "was ", "were ", "been ", "being ", "by "]
        let passiveCount = passiveMarkers.filter { lowered.contains($0) }.count
        if passiveCount > 2 {
            formalScore += 0.05
            signals += 1
        }

        // First-person pronouns → slightly informal
        let firstPerson = ["i ", "me ", "my ", "we ", "us ", "our "]
        let fpCount = firstPerson.filter { lowered.contains($0) }.count
        if fpCount > 3 {
            formalScore -= 0.03
            signals += 1
        }

        // Capitalization signal — proper sentence capitalization suggests formality
        let capitalizedSentences = sentences.filter { $0.first?.isUppercase == true }.count
        if sentences.count > 0 {
            let capRate = Double(capitalizedSentences) / Double(sentences.count)
            if capRate > 0.9 {
                formalScore += 0.05
                signals += 1
            }
        }

        if signals == 0 { return 0.5 }

        let clamped = max(0.0, min(1.0, 0.5 + formalScore))
        return clamped
    }

    // MARK: - Emoji detection

    func countEmojis(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1F600...0x1F64F,
                 0x1F300...0x1F5FF,
                 0x1F680...0x1F6FF,
                 0x1F1E0...0x1F1FF,
                 0x2600...0x26FF,
                 0x2700...0x27BF,
                 0xFE00...0xFE0F,
                 0x1F900...0x1F9FF,
                 0x1FA00...0x1FA6F,
                 0x1FA70...0x1FAFF,
                 0x200D,
                 0x2934...0x2935,
                 0x2B05...0x2B07,
                 0x2B1B...0x2B1C,
                 0x3030, 0x303D, 0x3297, 0x3299,
                 0x23F0...0x23F3,
                 0x23F8...0x23FA,
                 0x25AA...0x25AB,
                 0x25B6, 0x25C0, 0x25FB...0x25FE:
                count += 1
            default:
                break
            }
        }
        return count
    }

    // MARK: - Punctuation patterns

    func punctuationPatterns(_ text: String) -> [String: Int] {
        var patterns: [String: Int] = [
            "!": 0, "?": 0, "...": 0, "—": 0, "\"": 0,
        ]

        var ellipsisCount = 0
        var i = text.startIndex
        while i < text.endIndex {
            let char = text[i]
            if char == "!" { patterns["!", default: 0] += 1 }
            else if char == "?" { patterns["?", default: 0] += 1 }
            else if char == "." {
                var dots = 1
                var next = text.index(after: i)
                while next < text.endIndex && text[next] == "." {
                    dots += 1
                    i = next
                    next = text.index(after: i)
                }
                if dots >= 3 {
                    ellipsisCount += 1
                }
            }
            else if char == "\u{2014}" || char == "-" {
                if i > text.startIndex && text[text.index(before: i)] == " " {
                    let nextIdx = text.index(after: i)
                    if nextIdx < text.endIndex && text[nextIdx] == " " {
                        patterns["—", default: 0] += 1
                    }
                }
            }
            else if char == "\"" { patterns["\"", default: 0] += 1 }
            i = text.index(after: i)
        }
        patterns["..."] = ellipsisCount
        return patterns
    }

    // MARK: - Common phrases (n-grams)

    func extractCommonPhrases(_ words: [String], minFrequency: Int = 2) -> [(phrase: String, count: Int)] {
        guard words.count >= 2 else { return [] }

        var bigramCounts: [String: Int] = [:]

        for i in 0..<(words.count - 1) {
            let w1 = words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let w2 = words[i + 1].lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard w1.count >= 2 && w2.count >= 2 else { continue }

            let stopWords: Set<String> = ["the", "a", "an", "is", "was", "are", "were",
                                           "be", "been", "being", "have", "has", "had",
                                           "do", "does", "did", "will", "would", "can",
                                           "could", "shall", "should", "may", "might",
                                           "to", "of", "in", "for", "on", "with", "at",
                                           "by", "from", "as", "into", "through", "during",
                                           "before", "after", "above", "below", "up", "down",
                                           "it", "its", "this", "that", "these", "those"]
            if stopWords.contains(w1) && stopWords.contains(w2) { continue }

            let phrase = "\(w1) \(w2)"
            bigramCounts[phrase, default: 0] += 1
        }

        let filtered = bigramCounts.filter { $0.value >= minFrequency }
        let sorted = filtered.sorted { $0.value > $1.value }
        return sorted.prefix(10).map { ($0.key, $0.value) }
    }

    // MARK: - Result

    struct AnalysisResult {
        let wordCount: Int
        let sentenceCount: Int
        let avgSentenceLength: Double
        let avgParagraphLength: Double
        let greeting: String?
        let closing: String?
        let formalityScore: Double
        let emojiCount: Int
        let punctuationPatterns: [String: Int]
        let commonPhrases: [(phrase: String, count: Int)]
    }
}
