import Foundation

struct RelationshipInferrer {

    // MARK: - Public API

    func infer(from text: String, currentType: RelationshipType? = nil) -> InferredRelationship {
        guard currentType != .unknown || currentType == nil else {
            return InferredRelationship(type: currentType!, confidence: 1.0, evidence: "manual")
        }

        let lowered = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        var candidates: [(type: RelationshipType, confidence: Double, evidence: String)] = []

        // Title-based rules
        let titleRules: [(Set<String>, RelationshipType, Double)] = [
            (["professor", "prof"], .professor, 0.85),
            (["dr", "doctor"], .professor, 0.60),
            (["recruiter", "talent acquisition", "hiring manager", "hr"], .recruiter, 0.80),
            (["manager", "supervisor", "lead", "director"], .manager, 0.60),
            (["teammate", "team member", "peer", "colleague"], .teammate, 0.60),
            (["coworker", "co-worker", "work with", "works with"], .coworker, 0.70),
            (["client", "customer", "account"], .client, 0.75),
        ]

        for (triggers, type, confidence) in titleRules {
            if triggers.contains(where: { lowered.contains($0) }) {
                candidates.append((type, confidence, "title: \(triggers.first ?? "")"))
            }
        }

        // Family clues
        if lowered.contains("my ") || lowered.contains("our ") {
            let familyTerms: Set<String> = ["mom", "dad", "brother", "sister", "uncle", "aunt",
                                            "grandma", "grandpa", "cousin", "nephew", "niece",
                                            "husband", "wife", "spouse", "son", "daughter"]
            if familyTerms.contains(where: { lowered.contains($0) }) {
                candidates.append((.family, 0.80, "family term"))
            }
        }

        // Friend clues
        let friendTerms: Set<String> = ["my friend", "buddy", "pal", "bestie", "close friend"]
        if friendTerms.contains(where: { lowered.contains($0) }) {
            candidates.append((.friend, 0.65, "friend term"))
        }

        // Domain-based: .edu → academic
        if lowered.contains(".edu") || lowered.contains("university") || lowered.contains("college") {
            if currentType == nil || currentType == .unknown {
                candidates.append((.classmate, 0.35, "academic domain"))
            }
        }

        guard !candidates.isEmpty else {
            return InferredRelationship(type: .unknown, confidence: 0.3, evidence: "no rules matched")
        }

        let best = candidates.sorted { $0.confidence > $1.confidence }.first!
        return InferredRelationship(type: best.type, confidence: best.confidence, evidence: best.evidence)
    }

    func merge(existing: Relationship?, new: InferredRelationship) -> RelationshipType {
        guard let existing else { return new.type }
        guard !existing.isManualOverride else { return existing.type }

        if new.confidence > existing.confidence + 0.15 {
            return new.type
        }
        return existing.type
    }

    // MARK: - Result

    struct InferredRelationship {
        let type: RelationshipType
        let confidence: Double
        let evidence: String
    }
}
