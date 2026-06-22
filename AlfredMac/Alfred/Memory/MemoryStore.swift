import Foundation
import GRDB
import OSLog

// MARK: - Records

struct MemoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memories"

    var id: Int64?
    var content: String
    var tags: String
    var created_at: Double
    var accessed_at: Double

    var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private struct ConversationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversation_history"

    var id: Int64?
    var role: String
    var content: String
    var timestamp: Double
}

/// Blueprint v1 §8 audit log: one row per AlfredBar command (and, later, per routine
/// run). Captures the transparency triple — model_used, route_reason, command_class —
/// plus what (redacted) data left the device.
struct RunRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "runs"

    var id: Int64?
    var source: String              // "bar" | "routine"
    var routine_id: Int64?          // nullable; FK to task_definitions (routines arrive in M2)
    var prompt: String
    var started_at: Double
    var finished_at: Double?
    var model_used: String?         // e.g. "local", "gemini"
    var route_reason: String?       // short transparency reason
    var command_class: String?      // blueprint command class
    var status: String              // "running" | "success" | "failed" | "blocked"
    var output_full: String?
    var output_summary: String?
    var error_text: String?
    var data_sent_to_cloud: String? // egress/redaction summary; nil/empty = nothing sent

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Blueprint v1 §5 routine: a scheduled natural-language prompt run headless through the
/// same engine as AlfredBar. Cron-scheduled; only `unattended-safe` routines run headless.
struct RoutineRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "routines"

    var id: Int64?
    var title: String
    var prompt_text: String
    var schedule_cron: String           // 5-field cron, e.g. "0 6 * * *"
    var timezone: String                // IANA id, e.g. "America/New_York"
    var enabled: Bool
    var policy_class: String            // e.g. "unattended-safe"
    var trigger_type: String            // "schedule" | "manual" | "api"
    var last_run_at: Double?
    var next_run_at: Double?
    var last_status: String?            // "success" | "failed" | "blocked"
    var last_output_summary: String?
    var created_at: Double

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Hermes Tier‑2: structured screen text captured on-device via Accessibility, FTS5-searchable.
struct ScreenTextRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "screen_text_log"
    var id: Int64?
    var timestamp: Double
    var app_name: String
    var bundle_id: String
    var window_title: String
    var text: String
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Hermes Tier‑2: a captured meeting/conversation — on-device transcript + local summary.
struct MeetingRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "meeting_transcripts"
    var id: Int64?
    var started_at: Double
    var ended_at: Double?
    var title: String
    var transcript: String
    var summary: String?
    var action_items: String?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Store

final class MemoryStore {
    static let logger = Logger(subsystem: "com.alfred.memory", category: "store")
    let db: DatabaseQueue
    var initError: Error?

    lazy var writingStyleStore: WritingStyleStore? = {
        try? WritingStyleStore(db: db)
    }()

    lazy var timelineStore: TimelineStore = {
        TimelineStore(db: db)
    }()

    lazy var relationshipStore: RelationshipStore = {
        RelationshipStore(db: db)
    }()

    lazy var habitStore: HabitStore = {
        HabitStore(db: db, timeline: timelineStore)
    }()

    lazy var learningLoopStore: LearningLoopStore = {
        LearningLoopStore(db: db)
    }()

    lazy var rewardEngine: RewardEngine = {
        RewardEngine(
            db: db,
            learningLoop: learningLoopStore,
            habits: habitStore,
            writingStyle: writingStyleStore,
            timeline: timelineStore
        )
    }()

    lazy var taskEngine: TaskEngine = {
        TaskEngine(db: db)
    }()

    lazy var taskDashboardService: TaskDashboardService = {
        let svc = TaskDashboardService(engine: taskEngine)
        svc.subscribe()
        return svc
    }()

    init() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".alfred/db", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = dir.appending(path: "memory.db").path
        db = try DatabaseQueue(path: dbPath)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "memories", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("content", .text).notNull()
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("created_at", .double).notNull()
                t.column("accessed_at", .double).notNull()
            }

            try db.create(table: "conversation_history", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .double).notNull()
            }

            try db.create(virtualTable: "memories_fts", ifNotExists: true, using: FTS5()) { t in
                t.synchronize(withTable: "memories")
                t.column("content")
            }
        }

        migrator.registerMigration("v2_suggestion_interactions") { db in
            try db.create(table: "suggestion_interactions", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("suggestionId", .text).notNull()
                t.column("category", .text).notNull()
                t.column("accepted", .boolean).notNull().defaults(to: false)
                t.column("dismissed", .boolean).notNull().defaults(to: false)
                t.column("timestamp", .double).notNull()
                t.column("contextAppName", .text)
                t.column("contextBundleIdentifier", .text)
                t.column("contextWindowTitle", .text)
            }

            try db.create(index: "idx_suggestion_interactions_category", on: "suggestion_interactions", columns: ["category"])
            try db.create(index: "idx_suggestion_interactions_timestamp", on: "suggestion_interactions", columns: ["timestamp"])
        }

        migrator.registerMigration("v3_writing_style") { db in
            try db.create(table: "writing_samples", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source", .text).notNull()
                t.column("text", .text).notNull()
                t.column("wordCount", .integer).notNull()
                t.column("sentenceCount", .integer).notNull()
                t.column("avgSentenceLength", .double).notNull()
                t.column("hasGreeting", .boolean).notNull()
                t.column("hasClosing", .boolean).notNull()
                t.column("formalityScore", .double).notNull()
                t.column("emojiCount", .integer).notNull()
                t.column("timestamp", .double).notNull()
            }

            try db.create(table: "writing_profile", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("avgSentenceLength", .double).notNull()
                t.column("avgParagraphLength", .double).notNull()
                t.column("commonGreetings", .text).notNull().defaults(to: "")
                t.column("commonClosings", .text).notNull().defaults(to: "")
                t.column("commonPhrases", .text).notNull().defaults(to: "")
                t.column("vocabularyPreferences", .text).notNull().defaults(to: "{}")
                t.column("punctuationPatterns", .text).notNull().defaults(to: "")
                t.column("emojiUsage", .double).notNull()
                t.column("formalityScore", .double).notNull()
                t.column("totalSamples", .integer).notNull()
                t.column("lastUpdated", .double).notNull()
            }
        }

        migrator.registerMigration("v4_activity_timeline") { db in
            try db.create(table: "activity_timeline", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("eventType", .text).notNull()
                t.column("applicationName", .text).notNull()
                t.column("windowTitle", .text)
                t.column("metadataJSON", .text)
            }
            try db.create(index: "idx_timeline_timestamp", on: "activity_timeline", columns: ["timestamp"])
            try db.create(index: "idx_timeline_eventType", on: "activity_timeline", columns: ["eventType"])
            try db.create(index: "idx_timeline_application", on: "activity_timeline", columns: ["applicationName"])
        }

        migrator.registerMigration("v5_relationships") { db in
            try db.create(table: "person_records", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("aliases", .text).notNull().defaults(to: "")
                t.column("firstSeen", .double).notNull()
                t.column("lastSeen", .double).notNull()
                t.column("interactionCount", .integer).notNull().defaults(to: 0)
                t.column("notes", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_person_name", on: "person_records", columns: ["name"])

            try db.create(table: "relationship_records", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("personId", .integer).notNull().references("person_records", onDelete: .cascade)
                t.column("relationshipType", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("lastUpdated", .double).notNull()
                t.column("isManualOverride", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_relationship_person", on: "relationship_records", columns: ["personId"])

            try db.create(table: "interaction_records", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("personId", .integer).notNull().references("person_records", onDelete: .cascade)
                t.column("timestamp", .double).notNull()
                t.column("source", .text).notNull()
                t.column("summary", .text).notNull()
            }
            try db.create(index: "idx_interaction_person", on: "interaction_records", columns: ["personId"])
            try db.create(index: "idx_interaction_timestamp", on: "interaction_records", columns: ["timestamp"])
        }

        migrator.registerMigration("v6_habits") { db in
            try db.create(table: "habit_records", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("habitType", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("firstObserved", .double).notNull()
                t.column("lastObserved", .double).notNull()
                t.column("occurrenceCount", .integer).notNull().defaults(to: 0)
                t.column("metadataJSON", .text).notNull().defaults(to: "{}")
            }
            try db.create(index: "idx_habit_type", on: "habit_records", columns: ["habitType"])
            try db.create(index: "idx_habit_confidence", on: "habit_records", columns: ["confidence"])
        }

        migrator.registerMigration("v7_learning_loop") { db in
            try db.create(table: "learning_suggestions", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("userPrompt", .text).notNull()
                t.column("alfredResponse", .text).notNull()
                t.column("writingStyleContext", .text).notNull().defaults(to: "")
                t.column("relationshipContext", .text).notNull().defaults(to: "")
                t.column("habitContext", .text).notNull().defaults(to: "")
                t.column("accepted", .boolean).notNull().defaults(to: false)
                t.column("edited", .boolean).notNull().defaults(to: false)
                t.column("rejected", .boolean).notNull().defaults(to: false)
                t.column("finalUserVersion", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_learning_timestamp", on: "learning_suggestions", columns: ["timestamp"])
            try db.create(index: "idx_learning_accepted", on: "learning_suggestions", columns: ["accepted"])

            try db.create(table: "learning_events", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("eventType", .text).notNull()
                t.column("metadataJSON", .text).notNull().defaults(to: "{}")
            }
            try db.create(index: "idx_learning_events_type", on: "learning_events", columns: ["eventType"])
            try db.create(index: "idx_learning_events_timestamp", on: "learning_events", columns: ["timestamp"])
        }

        migrator.registerMigration("v8_reward_signals") { db in
            try db.create(table: "reward_signals", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("signalType", .text).notNull()
                t.column("strength", .double).notNull()
                t.column("sourceContextJSON", .text).notNull().defaults(to: "{}")
                t.column("explanationTags", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_reward_timestamp", on: "reward_signals", columns: ["timestamp"])
            try db.create(index: "idx_reward_signalType", on: "reward_signals", columns: ["signalType"])
        }

        migrator.registerMigration("v9_tasks") { db in
            try db.create(table: "task_definitions", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("taskDescription", .text).notNull().defaults(to: "")
                t.column("scheduleType", .text).notNull().defaults(to: "manual")
                t.column("stepsJSON", .text).notNull().defaults(to: "[]")
                t.column("lastRun", .double)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .double).notNull()
            }
            try db.create(index: "idx_tasks_schedule", on: "task_definitions", columns: ["scheduleType"])
            try db.create(index: "idx_tasks_enabled", on: "task_definitions", columns: ["enabled"])

            try db.create(table: "task_runs", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskId", .integer).notNull().references("task_definitions", onDelete: .cascade)
                t.column("timestamp", .double).notNull()
                t.column("status", .text).notNull().defaults(to: "running")
                t.column("outputJSON", .text).notNull().defaults(to: "{}")
            }
            try db.create(index: "idx_runs_taskId", on: "task_runs", columns: ["taskId"])
            try db.create(index: "idx_runs_timestamp", on: "task_runs", columns: ["timestamp"])
        }

        migrator.registerMigration("v10_runs_audit") { db in
            try db.create(table: "runs", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source", .text).notNull().defaults(to: "bar")
                t.column("routine_id", .integer).references("task_definitions", onDelete: .setNull)
                t.column("prompt", .text).notNull().defaults(to: "")
                t.column("started_at", .double).notNull()
                t.column("finished_at", .double)
                t.column("model_used", .text)
                t.column("route_reason", .text)
                t.column("command_class", .text)
                t.column("status", .text).notNull().defaults(to: "running")
                t.column("output_full", .text)
                t.column("output_summary", .text)
                t.column("error_text", .text)
                t.column("data_sent_to_cloud", .text)
            }
            try db.create(index: "idx_audit_runs_started", on: "runs", columns: ["started_at"])
            try db.create(index: "idx_audit_runs_source", on: "runs", columns: ["source"])
            try db.create(index: "idx_audit_runs_status", on: "runs", columns: ["status"])
        }

        migrator.registerMigration("v11_routines") { db in
            try db.create(table: "routines", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull().defaults(to: "")
                t.column("prompt_text", .text).notNull().defaults(to: "")
                t.column("schedule_cron", .text).notNull().defaults(to: "")
                t.column("timezone", .text).notNull().defaults(to: "")
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("policy_class", .text).notNull().defaults(to: "unattended-safe")
                t.column("last_run_at", .double)
                t.column("next_run_at", .double)
                t.column("last_status", .text)
                t.column("last_output_summary", .text)
                t.column("created_at", .double).notNull()
            }
            try db.create(index: "idx_routines_enabled", on: "routines", columns: ["enabled"])
        }

        // The v10 `runs.routine_id` had an FK -> `task_definitions` (routines did not exist
        // yet). Rebuild `runs` so routine_id carries no cross-table FK at all — it is a plain
        // integer for a single-user audit log. A cross-table FK is undesirable here: GRDB's
        // migrator runs a whole-database `PRAGMA foreign_key_check` before commit, so a stray
        // orphan anywhere would roll back the migration and make the DB un-openable forever.
        migrator.registerMigration("v12_runs_routine_fk") { db in
            try db.execute(sql: "ALTER TABLE runs RENAME TO runs_old")
            try db.create(table: "runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source", .text).notNull().defaults(to: "bar")
                t.column("routine_id", .integer)
                t.column("prompt", .text).notNull().defaults(to: "")
                t.column("started_at", .double).notNull()
                t.column("finished_at", .double)
                t.column("model_used", .text)
                t.column("route_reason", .text)
                t.column("command_class", .text)
                t.column("status", .text).notNull().defaults(to: "running")
                t.column("output_full", .text)
                t.column("output_summary", .text)
                t.column("error_text", .text)
                t.column("data_sent_to_cloud", .text)
            }
            try db.execute(sql: """
                INSERT INTO runs (id, source, routine_id, prompt, started_at, finished_at,
                    model_used, route_reason, command_class, status, output_full,
                    output_summary, error_text, data_sent_to_cloud)
                SELECT id, source, routine_id, prompt, started_at, finished_at,
                    model_used, route_reason, command_class, status, output_full,
                    output_summary, error_text, data_sent_to_cloud
                FROM runs_old
                """)
            // Defensive: drop any routine_id that no longer resolves to a routine.
            try db.execute(sql: "UPDATE runs SET routine_id = NULL WHERE routine_id IS NOT NULL AND routine_id NOT IN (SELECT id FROM routines)")
            try db.execute(sql: "DROP TABLE runs_old")
            try db.create(index: "idx_audit_runs_started", on: "runs", columns: ["started_at"])
            try db.create(index: "idx_audit_runs_source", on: "runs", columns: ["source"])
            try db.create(index: "idx_audit_runs_status", on: "runs", columns: ["status"])
            try db.create(index: "idx_audit_runs_routine", on: "runs", columns: ["routine_id"])
        }

        // Trigger type per routine: "schedule" (auto-fires on cron), "manual" (Run-now only),
        // or "api" (external alfred:// URL trigger). Existing rows default to "schedule" so
        // behavior is preserved.
        migrator.registerMigration("v13_routine_trigger") { db in
            try db.execute(sql: "ALTER TABLE routines ADD COLUMN trigger_type TEXT NOT NULL DEFAULT 'schedule'")
        }

        // Hermes capture (local-only): structured screen text + meeting transcripts, each with an
        // FTS5 index so Alfred can search weeks-old context with natural-language queries.
        migrator.registerMigration("v14_hermes_capture") { db in
            try db.create(table: "screen_text_log", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("app_name", .text).notNull().defaults(to: "")
                t.column("bundle_id", .text).notNull().defaults(to: "")
                t.column("window_title", .text).notNull().defaults(to: "")
                t.column("text", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_screen_text_ts", on: "screen_text_log", columns: ["timestamp"])
            try db.create(virtualTable: "screen_text_fts", ifNotExists: true, using: FTS5()) { t in
                t.synchronize(withTable: "screen_text_log")
                t.column("text")
            }

            try db.create(table: "meeting_transcripts", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("transcript", .text).notNull().defaults(to: "")
                t.column("summary", .text)
                t.column("action_items", .text)
            }
            try db.create(index: "idx_meeting_started", on: "meeting_transcripts", columns: ["started_at"])
            try db.create(virtualTable: "meeting_fts", ifNotExists: true, using: FTS5()) { t in
                t.synchronize(withTable: "meeting_transcripts")
                t.column("transcript")
            }
        }

        try migrator.migrate(db)
    }

    // MARK: - Run audit log (Blueprint v1 §8)

    /// Opens an audit row for a command and returns its id. Call `completeRun` when done.
    /// Returns nil only if the write fails — callers should degrade gracefully (audit
    /// logging must never block command execution).
    func startRun(source: String, prompt: String, routineId: Int64? = nil) -> Int64? {
        var rec = RunRecord(
            id: nil,
            source: source,
            routine_id: routineId,
            prompt: prompt,
            started_at: Date().timeIntervalSince1970,
            finished_at: nil,
            model_used: nil,
            route_reason: nil,
            command_class: nil,
            status: "running",
            output_full: nil,
            output_summary: nil,
            error_text: nil,
            data_sent_to_cloud: nil
        )
        do {
            try db.write { db in try rec.insert(db) }
            return rec.id
        } catch {
            return nil
        }
    }

    /// Finalizes an audit row with the transparency triple + outcome. No-op on bad id.
    func completeRun(
        id: Int64,
        status: String,
        modelUsed: String? = nil,
        routeReason: String? = nil,
        commandClass: String? = nil,
        outputFull: String? = nil,
        outputSummary: String? = nil,
        errorText: String? = nil,
        dataSentToCloud: String? = nil
    ) {
        try? db.write { db in
            try db.execute(
                sql: """
                    UPDATE runs SET
                        finished_at = ?, status = ?, model_used = ?, route_reason = ?,
                        command_class = ?, output_full = ?, output_summary = ?,
                        error_text = ?, data_sent_to_cloud = ?
                    WHERE id = ?
                    """,
                arguments: [
                    Date().timeIntervalSince1970, status, modelUsed, routeReason,
                    commandClass, outputFull, outputSummary, errorText, dataSentToCloud, id,
                ]
            )
        }
    }

    /// One-shot audit row for a bar action that completes synchronously (text / email / file op).
    /// These return before the dispatcher's start/complete pair, so they're logged directly here.
    func recordAction(
        prompt: String,
        status: String,
        commandClass: String?,
        outputSummary: String?,
        modelUsed: String? = "local",
        dataSentToCloud: String? = nil
    ) {
        let now = Date().timeIntervalSince1970
        var rec = RunRecord(
            id: nil, source: "bar", routine_id: nil, prompt: prompt,
            started_at: now, finished_at: now, model_used: modelUsed, route_reason: nil,
            command_class: commandClass, status: status, output_full: nil,
            output_summary: outputSummary, error_text: nil, data_sent_to_cloud: dataSentToCloud
        )
        try? db.write { db in try rec.insert(db) }
    }

    /// Most recent audit rows, newest first (for the Activity view).
    func recentRuns(limit: Int = 100) -> [RunRecord] {
        (try? db.read { db in
            try RunRecord
                .order(Column("started_at").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Routines (Blueprint v1 §5/§6)

    @discardableResult
    func addRoutine(_ routine: RoutineRecord) -> Int64? {
        var rec = routine
        do {
            try db.write { db in try rec.insert(db) }
            return rec.id
        } catch {
            Self.logger.error("addRoutine failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func updateRoutine(_ routine: RoutineRecord) {
        guard routine.id != nil else {
            Self.logger.error("updateRoutine called with nil id — edit dropped")
            return
        }
        do {
            try db.write { db in try routine.update(db) }
        } catch {
            Self.logger.error("updateRoutine failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteRoutine(id: Int64) {
        do {
            try db.write { db in
                // routine_id carries no FK cascade — clear references in the audit log first.
                try db.execute(sql: "UPDATE runs SET routine_id = NULL WHERE routine_id = ?", arguments: [id])
                _ = try RoutineRecord.deleteOne(db, key: id)
            }
        } catch {
            Self.logger.error("deleteRoutine failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func allRoutines() -> [RoutineRecord] {
        (try? db.read { db in
            try RoutineRecord.order(Column("created_at").desc).fetchAll(db)
        }) ?? []
    }

    func enabledRoutines() -> [RoutineRecord] {
        (try? db.read { db in
            try RoutineRecord.filter(Column("enabled") == true).fetchAll(db)
        }) ?? []
    }

    func setRoutineEnabled(id: Int64, enabled: Bool) {
        try? db.write { db in
            try db.execute(sql: "UPDATE routines SET enabled = ? WHERE id = ?", arguments: [enabled, id])
        }
    }

    /// Records the outcome of a routine run on the routine row (Blueprint §5 fields).
    func recordRoutineRun(id: Int64, ranAt: Double, nextRunAt: Double?, status: String, summary: String?) {
        try? db.write { db in
            try db.execute(
                sql: """
                    UPDATE routines SET last_run_at = ?, next_run_at = ?, last_status = ?, last_output_summary = ?
                    WHERE id = ?
                    """,
                arguments: [ranAt, nextRunAt, status, summary, id]
            )
        }
    }

    /// Audit rows for a single routine, newest first — backs the per-routine output dropdown.
    func runsForRoutine(id: Int64, limit: Int = 20) -> [RunRecord] {
        (try? db.read { db in
            try RunRecord
                .filter(Column("routine_id") == id)
                .order(Column("started_at").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    /// Loads a single routine by id (used by the external URL-scheme trigger).
    func routine(id: Int64) -> RoutineRecord? {
        try? db.read { db in try RoutineRecord.fetchOne(db, key: id) }
    }

    // MARK: - Hermes capture (screen text + meetings, local-only)

    @discardableResult
    func insertScreenText(timestamp: Double, appName: String, bundleId: String,
                          windowTitle: String, text: String) -> Int64? {
        var rec = ScreenTextRecord(id: nil, timestamp: timestamp, app_name: appName,
                                   bundle_id: bundleId, window_title: windowTitle, text: text)
        do { try db.write { db in try rec.insert(db) }; return rec.id }
        catch { Self.logger.error("insertScreenText failed: \(error.localizedDescription, privacy: .public)"); return nil }
    }

    /// Natural-language search over captured screen text (FTS5), newest match first.
    func searchScreenText(_ query: String, limit: Int = 30) -> [ScreenTextRecord] {
        (try? db.read { db -> [ScreenTextRecord] in
            if let pattern = FTS5Pattern(matchingAllTokensIn: query) {
                return try ScreenTextRecord
                    .joining(required: ScreenTextRecord.hasOne(
                        Table("screen_text_fts"), using: ForeignKey(["rowid"], to: ["rowid"])))
                    .filter(sql: "screen_text_fts MATCH ?", arguments: [pattern])
                    .order(Column("timestamp").desc).limit(limit).fetchAll(db)
            }
            return try ScreenTextRecord.order(Column("timestamp").desc).limit(limit).fetchAll(db)
        }) ?? []
    }

    func recentScreenText(limit: Int = 50) -> [ScreenTextRecord] {
        (try? db.read { db in
            try ScreenTextRecord.order(Column("timestamp").desc).limit(limit).fetchAll(db)
        }) ?? []
    }

    func pruneScreenText(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(days * 86_400)
        try? db.write { db in
            try db.execute(sql: "DELETE FROM screen_text_log WHERE timestamp < ?", arguments: [cutoff])
        }
    }

    @discardableResult
    func insertMeeting(_ meeting: MeetingRecord) -> Int64? {
        var rec = meeting
        do { try db.write { db in try rec.insert(db) }; return rec.id }
        catch { Self.logger.error("insertMeeting failed: \(error.localizedDescription, privacy: .public)"); return nil }
    }

    func recentMeetings(limit: Int = 50) -> [MeetingRecord] {
        (try? db.read { db in
            try MeetingRecord.order(Column("started_at").desc).limit(limit).fetchAll(db)
        }) ?? []
    }

    // MARK: - Memory operations

    func save(content: String, tags: [String] = []) throws {
        let now = Date().timeIntervalSince1970
        let record = MemoryRecord(
            id: nil,
            content: content,
            tags: tags.joined(separator: ", "),
            created_at: now,
            accessed_at: now
        )
        try db.write { db in
            try record.insert(db)
        }
    }

    func search(query: String, limit: Int = 20) throws -> [MemoryRecord] {
        // Fetch in a read transaction
        let results = try db.read { db -> [MemoryRecord] in
            let ftsPattern = FTS5Pattern(matchingAllTokensIn: query)

            if let pattern = ftsPattern {
                return try MemoryRecord
                    .joining(required: MemoryRecord.hasOne(
                        Table("memories_fts"),
                        using: ForeignKey(["rowid"], to: ["rowid"])
                    ))
                    .filter(sql: "memories_fts MATCH ?", arguments: [pattern])
                    .order(Column("accessed_at").desc)
                    .limit(limit)
                    .fetchAll(db)
            } else {
                return try MemoryRecord
                    .filter(Column("content").like("%\(query)%"))
                    .order(Column("accessed_at").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        }

        // Update accessed_at in a separate write transaction (read connections reject writes)
        let ids = results.compactMap(\.id)
        if !ids.isEmpty {
            let now = Date().timeIntervalSince1970
            try db.write { db in
                try db.execute(
                    sql: "UPDATE memories SET accessed_at = ? WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                    arguments: StatementArguments([now] + ids.map { DatabaseValue(value: $0) })
                )
            }
        }

        return results
    }

    // MARK: - Conversation history

    func saveMessage(role: String, content: String) throws {
        let row = ConversationRow(
            id: nil,
            role: role,
            content: content,
            timestamp: Date().timeIntervalSince1970
        )
        try db.write { db in
            try row.insert(db)
        }
    }

    func loadHistory(limit: Int = 200) throws -> [LLMMessage] {
        try db.read { db in
            let rows = try ConversationRow
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
            return rows.reversed().map { LLMMessage(role: $0.role, content: $0.content) }
        }
    }

    func clearHistory() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM conversation_history")
        }
    }

    /// Prune conversation history by age and enforce a hard row cap.
    /// The day-based cutoff alone is unbounded within a single retention window
    /// (a heavy day can write thousands of rows), so `maxRows` caps total growth
    /// by keeping only the most recent rows regardless of age.
    func pruneConversationHistory(olderThanDays days: Int, maxRows: Int = 5_000) throws {
        try db.write { db in
            if days > 0 {
                let cutoff = Date().timeIntervalSince1970 - TimeInterval(days * 86_400)
                try db.execute(sql: "DELETE FROM conversation_history WHERE timestamp < ?", arguments: [cutoff])
            }
            if maxRows > 0 {
                try db.execute(
                    sql: """
                    DELETE FROM conversation_history
                    WHERE id NOT IN (
                        SELECT id FROM conversation_history
                        ORDER BY timestamp DESC, id DESC
                        LIMIT ?
                    )
                    """,
                    arguments: [maxRows]
                )
            }
        }
    }

    func clearMemories() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM memories")
        }
    }

    // MARK: - Suggestion interactions

    func saveSuggestionInteraction(_ interaction: SuggestionInteraction) throws {
        try db.write { db in
            try interaction.insert(db)
        }
    }

    func suggestionInteractions(limit: Int = 500) throws -> [SuggestionInteraction] {
        try db.read { db in
            try SuggestionInteraction
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func suggestionInteractions(for category: String, days: Int = 30) throws -> [SuggestionInteraction] {
        let cutoff = Date().timeIntervalSince1970 - TimeInterval(days * 86400)
        return try db.read { db in
            try SuggestionInteraction
                .filter(Column("category") == category && Column("timestamp") >= cutoff)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    func suggestionAcceptanceRates(days: Int = 30) throws -> [(category: String, shown: Int, accepted: Int, rate: Double)] {
        let cutoff = Date().timeIntervalSince1970 - TimeInterval(days * 86400)
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    category,
                    COUNT(*) AS shown,
                    SUM(CASE WHEN accepted = 1 THEN 1 ELSE 0 END) AS accepted
                FROM suggestion_interactions
                WHERE timestamp >= ?
                GROUP BY category
                ORDER BY accepted DESC
                """, arguments: [cutoff])

            return rows.map { row in
                let shown: Int = row["shown"]
                let accepted: Int = row["accepted"]
                let rate = shown > 0 ? Double(accepted) / Double(shown) : 0.0
                return (row["category"] as String, shown, accepted, rate)
            }
        }
    }

    func recentUserQueries(limit: Int = 50) throws -> [String] {
        try db.read { db in
            let rows = try ConversationRow
                .filter(Column("role") == "user")
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
            return rows.reversed().map(\.content)
        }
    }

    func clearSuggestionInteractions() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM suggestion_interactions")
        }
    }
}
