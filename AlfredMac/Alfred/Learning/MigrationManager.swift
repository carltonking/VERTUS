import Foundation
import SQLite3
import AlfredCore

// SQLITE_TRANSIENT is a C macro, invisible to Swift; -1 tells SQLite to copy the
// bound string before the statement is finalized.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Migration manager

/// One-time consolidation: harvest every fragmented memory system into the
/// unified layer's single database (`~/.alfred/db/memory.db`).
///
/// The fragmented systems that used to own these facts — the GRDB-era legacy
/// tables in the same memory.db (person_records, screen_text_log,
/// conversation_history), the personal-memory.json records, the finetuning
/// captures.json, the Obsidian vault index, and the external agentmemory
/// graph — are each read once and folded into `UnifiedMemoryLayer`'s tables
/// (entities/relations/screen_observations/conversations/vault_notes).
///
/// Idempotent: gated on a UserDefaults migration version. Once complete it
/// never re-runs, so a launch can't re-harvest a source that has since been
/// retired. The vault-note mirror, by contrast, is refreshed on every launch
/// (INSERT OR REPLACE) — the vault is the source of truth and the user adds
/// notes in Obsidian over time.
///
/// Everything is best-effort: one failing source is logged and skipped, never
/// an error to the app. Run on launch in a detached task (it reads files and
/// may hit the agentmemory viewer over HTTP).
final class MigrationManager {

    static let shared = MigrationManager()

    /// Bump when a new harvest source is added.
    private static let migrationVersion = 19
    private let versionKey = "alfred.unified_memory_migration_v\(MigrationManager.migrationVersion)"

    private let databasePath = NSHomeDirectory() + "/.alfred/db/memory.db"
    private let capturesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".alfred/finetuning/captures.json")
    /// The agentmemory viewer's full-dump endpoint — the import source for the
    /// external graph (36 memories, each with title/content/type/concepts).
    private static let agentMemoryDumpURL = URL(string: "http://localhost:3114/memories")!

    private init() {}

    // MARK: - Entry

    /// Refresh the vault mirror, then run the one-time harvest if this
    /// migration version hasn't completed yet. Call from a detached task at
    /// launch. Never throws.
    func runIfNeeded() async {
        // Vault mirror refreshes every launch regardless of the migration gate.
        await refreshVaultIndex()

        guard UserDefaults.standard.integer(forKey: versionKey) < Self.migrationVersion else { return }
        NSLog("[migration] unified memory consolidation starting (v%d)", Self.migrationVersion)
        await harvestAll()
        UserDefaults.standard.set(Self.migrationVersion, forKey: versionKey)
        NSLog("[migration] consolidation complete — %@",
              UnifiedMemoryLayer.shared.counts().map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
    }

    // MARK: - Sources

    private func harvestAll() async {
        await harvestLegacyTables()
        harvestPersonalMemory()
        harvestCapturesJSON()
        await harvestAgentMemoryGraph()
        // Screen FTS triggers from the old store (if any) would double-index
        // inserts the unified layer now owns — drop them.
        UnifiedMemoryLayer.shared.dropLegacyScreenTriggers()
    }

    // MARK: Legacy GRDB tables (same memory.db)

    /// Fold the GRDB-era tables that still carry useful facts into the unified
    /// tables. Reads happen through this manager's own read-only connection;
    /// writes go through the unified layer so the schema stays in one place.
    private func harvestLegacyTables() async {
        guard let db = Self.openReadonly(databasePath) else {
            NSLog("[migration] legacy memory.db unreadable — skipping legacy tables")
            return
        }
        defer { sqlite3_close(db) }

        // 1. person_records → person entities.
        for row in Self.read(db, "SELECT name, aliases, firstSeen, lastSeen, interactionCount, notes FROM person_records") {
            guard let name = row[0] as? String, !name.isEmpty else { continue }
            let aliases = row[1] as? String ?? ""
            let notes = row[5] as? String ?? ""
            let firstSeen = row[2] as? Double ?? Date().timeIntervalSince1970
            let lastSeen = row[3] as? Double ?? firstSeen
            let interactions = row[4] as? Int64 ?? 1
            var detail = [aliases.isEmpty ? nil : "aliases: \(aliases)",
                          notes.isEmpty ? nil : notes].compactMap { $0 }.joined(separator: "; ")
            if detail.isEmpty { detail = "" }
            // Seed via addEntity (which sets first/last to now), then fold the
            // legacy mention count and timestamps in directly.
            let id = UnifiedMemoryLayer.shared.addEntity(
                kind: .person, name: name, detail: detail.isEmpty ? nil : detail,
                source: "legacy-person-record")
            if !id.isEmpty {
                UnifiedMemoryLayer.shared.seedEntityMetadata(
                    uuid: id, mentionCount: Int(interactions),
                    firstMentioned: firstSeen, lastMentioned: lastSeen)
            }
        }

        // 2. screen_text_log → screen observations (no JPEGs; synthetic hashes).
        var rows: [UnifiedMemoryLayer.LegacyScreenRow] = []
        for row in Self.read(db, "SELECT id, timestamp, app_name, bundle_id, text FROM screen_text_log ORDER BY timestamp") {
            guard let id = row[0] as? Int64,
                  let timestamp = row[1] as? Double,
                  let text = row[4] as? String, !text.isEmpty else { continue }
            let appName = row[2] as? String ?? ""
            let bundle = row[3] as? String ?? ""
            rows.append(UnifiedMemoryLayer.LegacyScreenRow(
                capturedAt: timestamp,
                appBundleID: bundle.isEmpty ? appName : bundle,
                ocrText: text,
                uniqueKey: "legacy-screen-text-log-\(id)"))
        }
        let screenCount = UnifiedMemoryLayer.shared.importLegacyScreenRows(rows)
        NSLog("[migration] screen_text_log → %d screen observations", screenCount)

        // 3. conversation_history → conversations (pair user → assistant).
        let history = Self.read(db, "SELECT role, content, timestamp FROM conversation_history ORDER BY timestamp")
        var pendingUser: (text: String, timestamp: Double)?
        var paired = 0
        for row in history {
            guard let role = row[0] as? String, let content = row[1] as? String, !content.isEmpty else { continue }
            let timestamp = row[2] as? Double ?? Date().timeIntervalSince1970
            if role == "user" {
                pendingUser = (content, timestamp)
            } else if role == "assistant", let user = pendingUser {
                UnifiedMemoryLayer.shared.addConversation(
                    user: user.text, assistant: content, timestamp: user.timestamp)
                paired += 1
                pendingUser = nil
            }
        }
        NSLog("[migration] conversation_history → %d conversations", paired)
    }

    // MARK: personal-memory.json

    /// PersonalMemoryStore records → entities. The file stays as-is (reflection
    /// still writes it); the unified layer is where grounding reads from now.
    private func harvestPersonalMemory() {
        let records = PersonalMemoryStore.shared.allRecords()
        guard !records.isEmpty else { return }
        var imported = 0
        for record in records {
            guard let kind = Self.entityKind(for: record.kind) else { continue }
            UnifiedMemoryLayer.shared.addEntity(
                kind: kind, name: record.title,
                detail: record.summary.isEmpty ? nil : record.summary,
                source: "personal-memory")
            imported += 1
        }
        NSLog("[migration] personal-memory.json → %d entities", imported)
    }

    /// Map a PersonalMemoryKind onto the unified graph's kinds. Kinds with no
    /// natural home are dropped (return nil).
    private static func entityKind(for kind: PersonalMemoryKind) -> EntityKind? {
        switch kind {
        case .person:          return .person
        case .communicationStyle: return .communicationPreference
        case .preference:      return .communicationPreference
        case .project:         return .project
        case .interest, .passion: return .topic
        case .routine, .classInfo, .goal, .habit, .lifeContext: return .concept
        }
    }

    // MARK: finetuning captures.json

    /// The old JSON capture log → conversations. FineTuneManager now reads
    /// through ConversationStore (a facade over the unified layer), so the
    /// historical captures must land in the conversations table.
    private func harvestCapturesJSON() {
        guard let data = try? Data(contentsOf: capturesURL),
              let captures = try? JSONDecoder().decode([ConversationCapture].self, from: data),
              !captures.isEmpty else { return }
        var imported = 0
        for capture in captures {
            let id = UnifiedMemoryLayer.shared.addConversation(
                user: capture.userMessage,
                assistant: capture.assistantResponse,
                timestamp: capture.timestamp,
                topic: capture.topic)
            if capture.accepted {
                // Preserve acceptance state so the fine-tune loop still sees
                // them as usable training material. The row id is the return
                // value of addConversation — no need to re-query for it.
                UnifiedMemoryLayer.shared.markAccepted(id: id, confidence: capture.confidence)
            }
            imported += 1
        }
        NSLog("[migration] captures.json → %d conversations", imported)
    }

    // MARK: Obsidian vault

    /// (Re)index every vault note into the vault_notes mirror. Runs on every
    /// launch — the vault is the source of truth and grows over time.
    /// `refresh()` first so this is self-contained (the app refreshes at
    /// launch anyway; the migration shouldn't depend on that ordering).
    private func refreshVaultIndex() async {
        MemoryStore.shared.refresh()
        let notes = MemoryStore.shared.allNotes()
        guard !notes.isEmpty else {
            NSLog("[migration] vault empty — mirror left as-is")
            return
        }
        let count = UnifiedMemoryLayer.shared.indexVaultNotes(from: notes)
        NSLog("[migration] vault mirror refreshed — %d notes", count)
    }

    // MARK: agentmemory graph

    /// Import the live agentmemory graph via the viewer's full-dump endpoint,
    /// then it can be decommissioned. Each memory becomes an entity (kind
    /// inferred from its type); each listed concept becomes a concept entity
    /// linked back with a `related_to` edge. Best-effort — a dead engine just
    /// skips the import.
    private func harvestAgentMemoryGraph() async {
        var request = URLRequest(url: Self.agentMemoryDumpURL)
        request.timeoutInterval = 4
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            NSLog("[migration] agentmemory viewer unreachable — graph import skipped (%@)", error.localizedDescription)
            return
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let memories = root["memories"] as? [[String: Any]] else {
            NSLog("[migration] agentmemory dump unparsable — graph import skipped")
            return
        }
        var imported = 0
        var linked = 0
        for memory in memories {
            guard let title = memory["title"] as? String, !title.isEmpty else { continue }
            let content = memory["content"] as? String ?? ""
            let type = memory["type"] as? String ?? "fact"
            let createdAt = Self.parseISO(memory["createdAt"] as? String)
                ?? Date().timeIntervalSince1970
            let id = UnifiedMemoryLayer.shared.addEntity(
                kind: EntityKind.infer(fromAgentMemoryType: type),
                name: String(title.prefix(200)),
                detail: content.isEmpty ? nil : String(content.prefix(2000)),
                source: "agentmemory-import")
            imported += 1
            if !id.isEmpty, createdAt > 0 {
                UnifiedMemoryLayer.shared.seedEntityMetadata(
                    uuid: id, mentionCount: 1,
                    firstMentioned: createdAt, lastMentioned: createdAt)
            }
            // Concepts → linked concept entities.
            if let concepts = memory["concepts"] as? [String] {
                for concept in concepts.prefix(12) where !concept.isEmpty {
                    let conceptID = UnifiedMemoryLayer.shared.addEntity(
                        kind: .concept, name: concept, detail: nil, source: "agentmemory-import")
                    if !id.isEmpty, !conceptID.isEmpty {
                        UnifiedMemoryLayer.shared.addRelation(
                            from: id, to: conceptID, type: "related_to",
                            context: "imported from agentmemory")
                        linked += 1
                    }
                }
            }
        }
        NSLog("[migration] agentmemory graph → %d entities, %d concept links", imported, linked)
    }

    // MARK: - Read-only plumbing (SELECTs only)

    private static func openReadonly(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else { return nil }
        return db
    }

    /// Run a SELECT and return every row as [Any?] (Int64/Double/String/nil).
    private static func read(_ db: OpaquePointer, _ sql: String) -> [[Any?]] {
        var out: [[Any?]] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            let count = sqlite3_column_count(stmt)
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:   row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, i) {
                        row.append(String(cString: c))
                    } else { row.append(nil) }
                default: row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    private static func parseISO(_ string: String?) -> TimeInterval? {
        guard let string, !string.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: string)?.timeIntervalSince1970
    }
}
