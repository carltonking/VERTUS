import Foundation

struct PersonDetector {
    // Compiled once. This regex was rebuilt on every detectEmailLikeNames call (and the
    // force-unwrap re-evaluated each time); the pattern is a constant, so compile it once.
    private static let emailNamePattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z]+\.[a-zA-Z]+)@[a-zA-Z]+\.(edu|com|org|net)"#)

    private let knownPrefixes: Set<String> = [
        "professor", "prof", "dr", "doctor", "mr", "mrs", "ms", "mx",
        "captain", "coach", "sir", "madam",
    ]

    // MARK: - Public API

    func detectPeople(in text: String) -> [DetectedPerson] {
        var results: [DetectedPerson] = []

        results.append(contentsOf: detectPrefixedNames(text))
        results.append(contentsOf: detectConsecutiveCapitals(text))
        results.append(contentsOf: detectEmailLikeNames(text))

        return deduplicate(results)
    }

    func detectPersonOfInterest(_ text: String) -> String? {
        let candidates = detectPeople(in: text)
        return candidates
            .sorted { $0.confidence > $1.confidence }
            .first?.name
    }

    // MARK: - Prefix-based detection

    private func detectPrefixedNames(_ text: String) -> [DetectedPerson] {
        let lowered = text.lowercased()
        var results: [DetectedPerson] = []

        for prefix in knownPrefixes {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let range = lowered.range(of: prefix, range: searchRange) {
                let after = lowered[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let nameWord = after.split(separator: " ").first.map(String.init) ?? ""

                guard nameWord.count >= 2,
                      nameWord.first?.isUppercase == true,
                      nameWord.allSatisfy({ $0.isLetter })
                else {
                    searchRange = range.upperBound..<lowered.endIndex
                    continue
                }

                let fullName = "\(prefix.capitalized) \(nameWord)"
                results.append(DetectedPerson(
                    name: fullName,
                    confidence: 0.8,
                    source: "prefix",
                    metadata: ["title": prefix]
                ))
                searchRange = range.upperBound..<lowered.endIndex
            }
        }
        return results
    }

    // MARK: - Consecutive capitals (potential full names)

    private func detectConsecutiveCapitals(_ text: String) -> [DetectedPerson] {
        let words = text.split(separator: " ").map(String.init)
        var results: [DetectedPerson] = []

        for i in 0..<(words.count - 1) {
            let w1 = words[i].trimmingCharacters(in: .punctuationCharacters)
            let w2 = words[i + 1].trimmingCharacters(in: .punctuationCharacters)

            guard w1.count >= 2, w2.count >= 2 else { continue }
            guard w1.first?.isUppercase == true, w2.first?.isUppercase == true else { continue }
            guard w1.allSatisfy({ $0.isLetter }), w2.allSatisfy({ $0.isLetter }) else { continue }

            let lowered1 = w1.lowercased()
            let lowered2 = w2.lowercased()

            // Skip common non-name words
            let skipWords: Set<String> = [
                "the", "this", "that", "these", "those", "what", "which", "where",
                "when", "why", "how", "who", "whom", "whose",
                "there", "their", "they", "them", "then", "than",
                "have", "has", "had", "does", "doesn", "did", "didn",
                "will", "would", "could", "should", "shall", "can", "may", "might",
                "please", "thank", "thanks", "hello", "hi", "hey",
                "best", "sincerely", "regards", "cheers",
                "dear", "good", "great", "okay", "ok",
                "also", "just", "like", "really", "very", "much",
                "some", "any", "each", "every", "both", "few", "more", "most",
                "other", "another", "such", "own", "same", "different",
            ]
            if skipWords.contains(lowered1) || skipWords.contains(lowered2) {
                continue
            }

            // Skip if either looks like a verb (common -ed, -ing endings)
            if lowered1.hasSuffix("ed") || lowered1.hasSuffix("ing") { continue }
            if lowered2.hasSuffix("ed") || lowered2.hasSuffix("ing") { continue }

            let fullName = "\(w1) \(w2)"
            results.append(DetectedPerson(
                name: fullName,
                confidence: 0.5,
                source: "consecutive_capitals",
                metadata: [:]
            ))
        }
        return results
    }

    // MARK: - Email-like patterns

    private func detectEmailLikeNames(_ text: String) -> [DetectedPerson] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = Self.emailNamePattern.matches(in: text, range: range)

        return matches.compactMap { match -> DetectedPerson? in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            let emailName = String(text[nameRange])
            let parts = emailName.split(separator: ".")

            guard parts.count == 2,
                  let first = parts.first.map(String.init),
                  let last = parts.last.map(String.init)
            else { return nil }

            let capitalizedFirst = first.prefix(1).uppercased() + first.dropFirst().lowercased()
            let capitalizedLast = last.prefix(1).uppercased() + last.dropFirst().lowercased()
            let fullName = "\(capitalizedFirst) \(capitalizedLast)"

            guard fullName.count >= 5 else { return nil }

            return DetectedPerson(
                name: fullName,
                confidence: 0.7,
                source: "email_pattern",
                metadata: ["email_name": emailName]
            )
        }
    }

    // MARK: - Dedup

    private func deduplicate(_ results: [DetectedPerson]) -> [DetectedPerson] {
        var seen: [String: DetectedPerson] = [:]
        for r in results {
            let key = r.name.lowercased().trimmingCharacters(in: .whitespaces)
            if let existing = seen[key] {
                if r.confidence > existing.confidence {
                    seen[key] = r
                }
            } else {
                seen[key] = r
            }
        }
        return Array(seen.values)
    }

    // MARK: - Detected person

    struct DetectedPerson {
        let name: String
        let confidence: Double
        let source: String
        let metadata: [String: String]
    }
}
