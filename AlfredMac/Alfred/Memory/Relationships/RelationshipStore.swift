import Foundation
import GRDB
import OSLog

final class RelationshipStore {
    private let db: DatabaseQueue
    private let detector = PersonDetector()
    private let inferrer = RelationshipInferrer()
    private let logger = Logger(subsystem: "com.alfred.relationships", category: "store")

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Person CRUD

    @discardableResult
    func upsertPerson(name: String, alias: String? = nil, notes: String = "") -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        do {
            // Check if person exists by name (case-insensitive)
            if let existing = try db.read({ db in
                try PersonRecord.filter(sql: "LOWER(name) = ?", arguments: [trimmed.lowercased()]).fetchOne(db)
            }) {
                let now = Date().timeIntervalSince1970
                var aliases = existing.aliasList
                if let a = alias, !a.isEmpty, !aliases.contains(a) {
                    aliases.append(a)
                }
                try db.write { db in
                    try db.execute(
                        sql: """
                            UPDATE person_records
                            SET lastSeen = ?, interactionCount = interactionCount + 1, aliases = ?, notes = ?
                            WHERE id = ?
                            """,
                        arguments: [now, aliases.joined(separator: "|"), notes, existing.id]
                    )
                }
                return existing.id
            } else {
                let now = Date().timeIntervalSince1970
                let aliasStr = alias.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let record = PersonRecord(
                    id: nil,
                    name: trimmed,
                    aliases: aliasStr,
                    firstSeen: now,
                    lastSeen: now,
                    interactionCount: 1,
                    notes: notes
                )
                try db.write { db in
                    try record.insert(db)
                }
                return record.id
            }
        } catch {
            logger.error("Failed to upsert person: \(error.localizedDescription)")
            return nil
        }
    }

    func getPerson(id: Int64) -> Person? {
        do {
            let records = try db.read { db in
                try PersonRecord.filter(Column("id") == id).fetchAll(db)
            }
            guard let record = records.first else { return nil }

            let rel = try bestRelationship(for: id)
            return Person(
                id: record.id,
                name: record.name,
                aliases: record.aliasList,
                firstSeen: Date(timeIntervalSince1970: record.firstSeen),
                lastSeen: Date(timeIntervalSince1970: record.lastSeen),
                interactionCount: record.interactionCount,
                notes: record.notes,
                primaryRelationship: rel
            )
        } catch {
            logger.error("Failed to get person: \(error.localizedDescription)")
            return nil
        }
    }

    func searchPeople(query: String, limit: Int = 20) -> [Person] {
        do {
            let pattern = "%\(query)%"
            let records = try db.read { db in
                try PersonRecord
                    .filter(Column("name").like(pattern) || Column("aliases").like(pattern))
                    .order(Column("interactionCount").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return try records.map { record in
                let rel = try bestRelationship(for: record.id!)
                return Person(
                    id: record.id,
                    name: record.name,
                    aliases: record.aliasList,
                    firstSeen: Date(timeIntervalSince1970: record.firstSeen),
                    lastSeen: Date(timeIntervalSince1970: record.lastSeen),
                    interactionCount: record.interactionCount,
                    notes: record.notes,
                    primaryRelationship: rel
                )
            }
        } catch {
            logger.error("Failed to search people: \(error.localizedDescription)")
            return []
        }
    }

    func getMostFrequentContacts(limit: Int = 10) -> [Person] {
        do {
            let records = try db.read { db in
                try PersonRecord
                    .order(Column("interactionCount").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return try records.map { record in
                let rel = try bestRelationship(for: record.id!)
                return Person(
                    id: record.id,
                    name: record.name,
                    aliases: record.aliasList,
                    firstSeen: Date(timeIntervalSince1970: record.firstSeen),
                    lastSeen: Date(timeIntervalSince1970: record.lastSeen),
                    interactionCount: record.interactionCount,
                    notes: record.notes,
                    primaryRelationship: rel
                )
            }
        } catch {
            logger.error("Failed to get frequent contacts: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Interactions

    func recordInteraction(personId: Int64, source: InteractionSource, summary: String) {
        do {
            let now = Date().timeIntervalSince1970
            let record = InteractionRecord(
                id: nil,
                personId: personId,
                timestamp: now,
                source: source.rawValue,
                summary: String(summary.prefix(500))
            )
            try db.write { db in
                try record.insert(db)
                try db.execute(
                    sql: "UPDATE person_records SET lastSeen = ?, interactionCount = interactionCount + 1 WHERE id = ?",
                    arguments: [now, personId]
                )
            }
        } catch {
            logger.error("Failed to record interaction: \(error.localizedDescription)")
        }
    }

    // MARK: - Relationships

    func setRelationship(personId: Int64, type: RelationshipType, manual: Bool = false) {
        let now = Date().timeIntervalSince1970
        let confidence = manual ? 1.0 : inferrer.infer(from: type.rawValue).confidence

        do {
            try db.write { db in
                // Upsert: delete existing, insert new
                try db.execute(
                    sql: "DELETE FROM relationship_records WHERE personId = ?",
                    arguments: [personId]
                )
                let record = RelationshipRecord(
                    id: nil,
                    personId: personId,
                    relationshipType: type.rawValue,
                    confidence: confidence,
                    lastUpdated: now,
                    isManualOverride: manual
                )
                try record.insert(db)
            }
        } catch {
            logger.error("Failed to set relationship: \(error.localizedDescription)")
        }
    }

    func getRelationshipSummary() -> String {
        let people = getMostFrequentContacts(limit: 20)
        guard !people.isEmpty else {
            return "No relationships recorded yet."
        }

        var lines: [String] = []
        lines.append("Known people:")

        for person in people {
            let typeLabel = person.primaryRelationship?.type.rawValue ?? "unknown"
            let freqLabel: String
            switch person.interactionCount {
            case ..<3:  freqLabel = "occasional"
            case ..<10: freqLabel = "regular"
            default:    freqLabel = "frequent"
            }
            let lastSeen = person.lastSeen
            let daysAgo = Calendar.current.dateComponents([.day], from: lastSeen, to: Date()).day ?? 0
            let timeLabel = daysAgo == 0 ? "today" : "\(daysAgo) day\(daysAgo == 1 ? "" : "s") ago"
            lines.append("  • \(person.name) (\(typeLabel), \(freqLabel), last \(timeLabel))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Heuristic detection from text

    func processText(
        _ text: String,
        source: InteractionSource,
        relationshipType: RelationshipType? = nil
    ) {
        let detected = detector.detectPeople(in: text)
        for p in detected where p.confidence >= 0.4 {
            guard let personId = upsertPerson(name: p.name) else { continue }
            recordInteraction(personId: personId, source: source, summary: String(text.prefix(200)))

            let inferred = inferrer.infer(from: text, currentType: relationshipType)
            let existing = try? bestRelationship(for: personId)
            if existing == nil {
                let merged = inferrer.merge(existing: nil, new: inferred)
                setRelationship(personId: personId, type: merged)
            }
        }
    }

    // MARK: - Context generation

    func generateRelationshipContext() -> String {
        let recent = recentInteractions(limit: 5)
        let summary = getRelationshipSummary()

        guard !recent.isEmpty else { return summary }

        var lines: [String] = []
        lines.append(summary)
        lines.append("")
        lines.append("Recent interactions:")

        for interaction in recent {
            let name = personName(for: interaction.personId) ?? "Someone"
            let daysAgo = Calendar.current.dateComponents([.day], from: interaction.timestamp, to: Date()).day ?? 0
            let timeLabel = daysAgo == 0 ? "today" : "\(daysAgo) day\(daysAgo == 1 ? "" : "s") ago"
            let summaryLabel = interaction.summary.prefix(100)
            lines.append("  • \(name) \(timeLabel) — \(summaryLabel)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private func bestRelationship(for personId: Int64) throws -> Relationship? {
        guard let record = try db.read({ db in
            try RelationshipRecord
                .filter(Column("personId") == personId)
                .order(Column("confidence").desc)
                .fetchOne(db)
        }) else { return nil }

        return Relationship(
            id: record.id,
            personId: record.personId,
            type: RelationshipType(rawValue: record.relationshipType) ?? .unknown,
            confidence: record.confidence,
            lastUpdated: Date(timeIntervalSince1970: record.lastUpdated),
            isManualOverride: record.isManualOverride
        )
    }

    private func recentInteractions(limit: Int = 10) -> [Interaction] {
        do {
            let records = try db.read { db in
                try InteractionRecord
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.map { record in
                Interaction(
                    id: record.id,
                    personId: record.personId,
                    timestamp: Date(timeIntervalSince1970: record.timestamp),
                    source: InteractionSource(rawValue: record.source) ?? .manual,
                    summary: record.summary
                )
            }
        } catch {
            return []
        }
    }

    private func personName(for personId: Int64) -> String? {
        let records = try? db.read { db in
            try PersonRecord.filter(Column("id") == personId).fetchAll(db)
        }
        return records?.first?.name
    }
}
