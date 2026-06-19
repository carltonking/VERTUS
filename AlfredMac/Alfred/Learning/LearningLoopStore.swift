import Foundation
import GRDB
import OSLog

final class LearningLoopStore {
    private let db: DatabaseQueue
    private let logger = Logger(subsystem: "com.alfred.learning-loop", category: "store")

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Record suggestion

    func recordSuggestion(
        userPrompt: String,
        alfredResponse: String,
        writingStyleContext: String = "",
        relationshipContext: String = "",
        habitContext: String = ""
    ) {
        let now = Date().timeIntervalSince1970
        let record = SuggestionRecord(
            id: nil,
            timestamp: now,
            userPrompt: String(userPrompt.prefix(2000)),
            alfredResponse: String(alfredResponse.prefix(4000)),
            writingStyleContext: String(writingStyleContext.prefix(500)),
            relationshipContext: String(relationshipContext.prefix(500)),
            habitContext: String(habitContext.prefix(500)),
            accepted: false,
            edited: false,
            rejected: false,
            finalUserVersion: ""
        )

        do {
            try db.write { db in
                try record.insert(db)
            }
        } catch {
            logger.error("Failed to record suggestion: \(error.localizedDescription)")
        }
    }

    // MARK: - Acceptance / edit / rejection

    func recordAcceptance(suggestionId: Int64) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE learning_suggestions SET accepted = 1, rejected = 0 WHERE id = ?",
                    arguments: [suggestionId]
                )
            }
            recordEvent(type: .suggestionAccepted, metadata: ["suggestionId": "\(suggestionId)"])
        } catch {
            logger.error("Failed to record acceptance: \(error.localizedDescription)")
        }
    }

    func recordEdit(suggestionId: Int64, finalUserVersion: String) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE learning_suggestions SET edited = 1, finalUserVersion = ? WHERE id = ?",
                    arguments: [finalUserVersion, suggestionId]
                )
            }
            recordEvent(type: .suggestionEdited, metadata: ["suggestionId": "\(suggestionId)"])
        } catch {
            logger.error("Failed to record edit: \(error.localizedDescription)")
        }
    }

    func recordRejection(suggestionId: Int64) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE learning_suggestions SET rejected = 1, accepted = 0 WHERE id = ?",
                    arguments: [suggestionId]
                )
            }
            recordEvent(type: .suggestionRejected, metadata: ["suggestionId": "\(suggestionId)"])
        } catch {
            logger.error("Failed to record rejection: \(error.localizedDescription)")
        }
    }

    // MARK: - Workflow events

    func recordWorkflowCompleted(metadata: [String: String] = [:]) {
        recordEvent(type: .workflowCompleted, metadata: metadata)
    }

    func recordWorkflowCancelled(metadata: [String: String] = [:]) {
        recordEvent(type: .workflowCancelled, metadata: metadata)
    }

    func recordFileActionConfirmed(metadata: [String: String] = [:]) {
        recordEvent(type: .fileActionConfirmed, metadata: metadata)
    }

    func recordFileActionCancelled(metadata: [String: String] = [:]) {
        recordEvent(type: .fileActionCancelled, metadata: metadata)
    }

    // MARK: - Queries

    func getTrainingCandidates(limit: Int = 100) -> [TrainingSuggestion] {
        do {
            let records = try db.read { db in
                try SuggestionRecord
                    .filter(sql: "accepted = 1 OR edited = 1")
                    .filter(sql: "rejected = 0")
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.map { record in
                TrainingSuggestion(
                    id: record.id,
                    timestamp: Date(timeIntervalSince1970: record.timestamp),
                    userPrompt: record.userPrompt,
                    alfredResponse: record.alfredResponse,
                    writingStyleContext: record.writingStyleContext,
                    relationshipContext: record.relationshipContext,
                    habitContext: record.habitContext,
                    accepted: record.accepted,
                    edited: record.edited,
                    rejected: record.rejected,
                    finalUserVersion: record.finalUserVersion
                )
            }
        } catch {
            logger.error("Failed to get training candidates: \(error.localizedDescription)")
            return []
        }
    }

    func getAllSuggestions(limit: Int = 500) -> [TrainingSuggestion] {
        do {
            let records = try db.read { db in
                try SuggestionRecord
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.map { record in
                TrainingSuggestion(
                    id: record.id,
                    timestamp: Date(timeIntervalSince1970: record.timestamp),
                    userPrompt: record.userPrompt,
                    alfredResponse: record.alfredResponse,
                    writingStyleContext: record.writingStyleContext,
                    relationshipContext: record.relationshipContext,
                    habitContext: record.habitContext,
                    accepted: record.accepted,
                    edited: record.edited,
                    rejected: record.rejected,
                    finalUserVersion: record.finalUserVersion
                )
            }
        } catch {
            logger.error("Failed to get all suggestions: \(error.localizedDescription)")
            return []
        }
    }

    func getEvents(limit: Int = 200) -> [LoopEvent] {
        do {
            let records = try db.read { db in
                try LoopEventRecord
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return records.map { record in
                let data = record.metadataJSON.data(using: .utf8)
                let meta = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
                return LoopEvent(
                    id: record.id,
                    timestamp: Date(timeIntervalSince1970: record.timestamp),
                    type: LoopEventType(rawValue: record.eventType) ?? .suggestionAccepted,
                    metadata: meta
                )
            }
        } catch {
            logger.error("Failed to get events: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private

    private func recordEvent(type: LoopEventType, metadata: [String: String]) {
        let metaStr = (try? JSONSerialization.data(withJSONObject: metadata, options: []))
            .map { String(data: $0, encoding: .utf8) ?? "{}" } ?? "{}"
        let record = LoopEventRecord(
            id: nil,
            timestamp: Date().timeIntervalSince1970,
            eventType: type.rawValue,
            metadataJSON: metaStr
        )
        do {
            try db.write { db in
                try record.insert(db)
            }
        } catch {
            logger.error("Failed to record event: \(error.localizedDescription)")
        }
    }
}
