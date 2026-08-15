import Foundation
import SQLite3
import AlfredCore

// SQLITE_TRANSIENT is a C macro, invisible to Swift; -1 tells SQLite to copy the
// bound string before the statement is finalized.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Entity kinds

/// What an `entities` row is. The spec's six kinds, plus the two the local
/// extractor (LocalGraphExtractor) already emits — organizations and
/// communication preferences — so extracted facts land in the same graph
/// instead of being dropped at the boundary.
enum EntityKind: String, Codable, CaseIterable, Sendable {
    case person
    case place
    case concept
    case topic
    case project
    case tool
    case organization
    case communicationPreference

    /// Infer from an agentmemory memory `type` (architecture, decision,
    /// person, …) during the graph import.
    static func infer(fromAgentMemoryType type: String) -> EntityKind {
        switch type.lowercased() {
        case "person", "people", "contact": return .person
        case "project": return .project
        case "tool", "software": return .tool
        case "organization", "company", "team": return .organization
        case "preference", "communication": return .communicationPreference
        case "place", "location": return .place
        default: return .concept
        }
    }
}

// MARK: - Models (Codable, mirror the wire shapes the rest of Alfred uses)

/// One node in the memory graph.
struct Entity: Codable, Equatable, Sendable {
    let id: String          // stable uuid
    let kind: EntityKind
    let name: String
    let detail: String?
    let confidence: Double
    let firstMentioned: TimeInterval
    let lastMentioned: TimeInterval
    let mentionCount: Int
    let source: String?
}

/// One edge in the memory graph.
struct Relation: Codable, Equatable, Sendable {
    let id: String
    let sourceEntityId: String
    let targetEntityId: String
    let type: String
    let confidence: Double
    let firstOccurred: TimeInterval
    let lastOccurred: TimeInterval
    let occurrenceCount: Int
    let context: String?
}

/// A persistent screen observation (OCR + capture metadata). Mirrors the
/// `ScreenObservation` shape ScreenObservationStore already exposes, so the
/// store can delegate to this layer unchanged.
struct ScreenObservation: Codable, Equatable, Sendable {
    let id: Int64
    let capturedAt: TimeInterval
    let appBundleID: String
    let imagePath: String
    let ocrText: String
    let ocrConfidence: Double?
    let width: Int
    let height: Int
    let contentHash: String
}

/// A captured user ↔ assistant exchange, the fine-tuning raw material.
struct Conversation: Codable, Equatable, Sendable {
    let id: String
    let userMessage: String
    let assistantResponse: String
    let timestamp: TimeInterval
    let accepted: Bool
    let confidence: Double
    let topic: String
}

/// One indexed vault note (read-only mirror of Obsidian).
struct VaultNote: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let category: String
    let importance: Int
    let date: TimeInterval?
    let path: String
}

/// One ranked hit from the unified search.
struct SearchResult: Codable, Equatable, Sendable {
    let type: String          // entity | note | conversation | observation
    let id: String
    let title: String
    let snippet: String
    let timestamp: TimeInterval
    let confidence: Double
}

/// One hybrid graph hit — an entity and/or the relations touching it.
struct GraphResult: Codable, Equatable, Sendable {
    let entity: Entity
    let relations: [Relation]
}

// MARK: - UnifiedMemoryLayer

/// The single SQLite home for everything Alfred remembers.
///
/// One database (`~/.alfred/db/memory.db`, the existing location), one schema,
/// one search. The fragmented systems that used to own these facts — the JSON
/// personal-memory file, the UserDefaults person graph, the finetuning
/// captures file, the external agentmemory engine — either delegate here or
/// were migrated here once (see MigrationManager). This layer is the only
/// writer going forward.
///
/// Threading follows the ScreenObservationStore pattern proven in this
/// codebase: a plain class with no actor isolation; every DB helper opens its
/// own per-call FULLMUTEX-serialized connection, so anything — the main
/// actor, a detached migration task, a background tick — can call in safely.
final class UnifiedMemoryLayer {

    static let shared = UnifiedMemoryLayer()

    private static let databasePath = NSHomeDirectory() + "/.alfred/db/memory.db"

    private init() {
        do {
            try FileManager.default.createDirectory(
                atPath: (Self.databasePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let db = try Self.openDB()
            defer { sqlite3_close(db) }
            try Self.runMigration(db)
        } catch {
            NSLog("[memory] unified layer init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Schema (v19)

    /// Idempotent DDL for the unified memory graph. `entities`/`relations` use
    /// an INTEGER rowid so the external-content FTS tables can reference it
    /// (FTS5 requires an integer rowid); `uuid` carries the stable string id
    /// the rest of Alfred addresses nodes by.
    ///
    /// `screen_observations` deliberately matches ScreenObservationStore's
    /// existing snake_case schema — both write to this same database, so the
    /// `IF NOT EXISTS` contract means whichever runs first defines the columns.
    private static let migrationDDL = """
    CREATE TABLE IF NOT EXISTS entities (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid            TEXT NOT NULL UNIQUE,
        kind            TEXT NOT NULL,
        name            TEXT NOT NULL,
        name_key        TEXT NOT NULL,
        detail          TEXT,
        confidence      REAL DEFAULT 1.0,
        first_mentioned REAL NOT NULL,
        last_mentioned  REAL NOT NULL,
        mention_count   INTEGER DEFAULT 1,
        source          TEXT,
        UNIQUE(kind, name_key)
    );
    CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind);
    CREATE INDEX IF NOT EXISTS idx_entities_last_mentioned ON entities(last_mentioned);

    CREATE TABLE IF NOT EXISTS relations (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid            TEXT NOT NULL UNIQUE,
        source_id       INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        target_id       INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        type            TEXT NOT NULL,
        confidence      REAL DEFAULT 0.8,
        first_occurred  REAL NOT NULL,
        last_occurred   REAL NOT NULL,
        occurrence_count INTEGER DEFAULT 1,
        context         TEXT,
        UNIQUE(source_id, target_id, type)
    );
    CREATE INDEX IF NOT EXISTS idx_relations_source ON relations(source_id);
    CREATE INDEX IF NOT EXISTS idx_relations_target ON relations(target_id);

    CREATE TABLE IF NOT EXISTS screen_observations (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        captured_at     REAL NOT NULL,
        app_bundle_id   TEXT NOT NULL,
        image_path      TEXT NOT NULL,
        ocr_text        TEXT NOT NULL DEFAULT '',
        ocr_confidence  REAL,
        width           INTEGER,
        height          INTEGER,
        content_hash    TEXT NOT NULL,
        created_at      REAL NOT NULL DEFAULT (unixepoch())
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_screen_observations_hash
        ON screen_observations(content_hash);
    CREATE INDEX IF NOT EXISTS idx_screen_observations_captured_at
        ON screen_observations(captured_at);
    CREATE INDEX IF NOT EXISTS idx_screen_observations_app_time
        ON screen_observations(app_bundle_id, captured_at);

    CREATE TABLE IF NOT EXISTS conversations (
        id                TEXT PRIMARY KEY,
        user_message      TEXT NOT NULL,
        assistant_response TEXT NOT NULL,
        timestamp         REAL NOT NULL,
        accepted          INTEGER NOT NULL DEFAULT 0,
        confidence        REAL NOT NULL DEFAULT 0.0,
        topic             TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_conversations_timestamp ON conversations(timestamp);
    CREATE INDEX IF NOT EXISTS idx_conversations_accepted ON conversations(accepted);

    CREATE TABLE IF NOT EXISTS vault_notes (
        id          TEXT PRIMARY KEY,
        title       TEXT NOT NULL,
        body        TEXT NOT NULL,
        category    TEXT,
        importance  INTEGER NOT NULL DEFAULT 2,
        date        REAL,
        path        TEXT UNIQUE
    );
    CREATE INDEX IF NOT EXISTS idx_vault_notes_category ON vault_notes(category);

    CREATE VIRTUAL TABLE IF NOT EXISTS screen_observations_fts USING fts5(
        ocr_text,
        content='screen_observations',
        content_rowid='id',
        tokenize='porter'
    );
    CREATE TRIGGER IF NOT EXISTS __unified_screen_fts_ai AFTER INSERT ON screen_observations BEGIN
        INSERT INTO screen_observations_fts(rowid, ocr_text) VALUES (new.id, new.ocr_text);
    END;
    CREATE TRIGGER IF NOT EXISTS __unified_screen_fts_ad AFTER DELETE ON screen_observations BEGIN
        INSERT INTO screen_observations_fts(screen_observations_fts, rowid, ocr_text)
        VALUES ('delete', old.id, old.ocr_text);
    END;

    CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts USING fts5(
        name,
        detail,
        content='entities',
        content_rowid='id',
        tokenize='porter'
    );
    CREATE TRIGGER IF NOT EXISTS __unified_entities_fts_ai AFTER INSERT ON entities BEGIN
        INSERT INTO entities_fts(rowid, name, detail) VALUES (new.id, new.name, new.detail);
    END;
    CREATE TRIGGER IF NOT EXISTS __unified_entities_fts_ad AFTER DELETE ON entities BEGIN
        INSERT INTO entities_fts(entities_fts, rowid, name, detail)
        VALUES ('delete', old.id, old.name, old.detail);
    END;
    CREATE TRIGGER IF NOT EXISTS __unified_entities_fts_au AFTER UPDATE ON entities BEGIN
        INSERT INTO entities_fts(entities_fts, rowid, name, detail)
        VALUES ('delete', old.id, old.name, old.detail);
        INSERT INTO entities_fts(rowid, name, detail) VALUES (new.id, new.name, new.detail);
    END;
    """

    // MARK: - Entities

    /// Upsert an entity by (kind, normalized name): a new node is created, an
    /// existing one gets its mention count bumped and the detail/source merged.
    /// Returns the stable uuid.
    @discardableResult
    func addEntity(kind: EntityKind, name: String, detail: String?, source: String) -> String {
        let now = Date().timeIntervalSince1970
        let key = Self.nameKey(name)
        guard let db = try? Self.openDB() else { return "" }
        defer { sqlite3_close(db) }

        if let existing = Self.entityRow(db, kind: kind, nameKey: key) {
            Self.exec(db, sql: """
                UPDATE entities SET mention_count = mention_count + 1,
                       last_mentioned = ?, detail = COALESCE(?, detail)
                WHERE id = ?
                """, args: [.double(now), .text(detail ?? ""), .int(Int(existing.rowID))])
            return existing.uuid
        }

        let uuid = UUID().uuidString
        Self.exec(db, sql: """
            INSERT INTO entities (uuid, kind, name, name_key, detail, confidence,
                                  first_mentioned, last_mentioned, mention_count, source)
            VALUES (?, ?, ?, ?, ?, 1.0, ?, ?, 1, ?)
            """, args: [.text(uuid), .text(kind.rawValue), .text(name), .text(key),
                        .text(detail ?? ""), .double(now), .double(now), .text(source)])
        return uuid
    }

    /// Record one mention of an existing entity (for tracking without new facts).
    func recordMention(entityID: String) {
        guard let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            UPDATE entities SET mention_count = mention_count + 1, last_mentioned = ?
            WHERE uuid = ?
            """, args: [.double(Date().timeIntervalSince1970), .text(entityID)])
    }

    func findEntity(byName name: String) -> Entity? {
        guard let db = try? Self.openDB() else { return nil }
        defer { sqlite3_close(db) }
        var found: Entity?
        do {
            try Self.queryRows(db, sql: """
                SELECT uuid, kind, name, detail, confidence, first_mentioned,
                       last_mentioned, mention_count, source
                FROM entities WHERE name_key = ?
                """, args: [.text(Self.nameKey(name))]) { stmt in
                found = Self.entity(stmt)
            }
        } catch { }
        return found
    }

    func searchEntities(query: String, limit: Int = 10) -> [Entity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }

        var entities: [Entity] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT e.uuid, e.kind, e.name, e.detail, e.confidence, e.first_mentioned,
                       e.last_mentioned, e.mention_count, e.source
                FROM entities_fts f JOIN entities e ON e.id = f.rowid
                WHERE entities_fts MATCH ?
                ORDER BY bm25(entities_fts) LIMIT ?
                """, args: [.text(trimmed), .int(limit)]) { stmt in
                entities.append(Self.entity(stmt))
            }
        } catch {
            // MATCH syntax error on punctuation-only queries → fall back to LIKE.
            return searchEntitiesByLike(query: trimmed, limit: limit)
        }
        return entities
    }

    private func searchEntitiesByLike(query: String, limit: Int) -> [Entity] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        let like = "%" + query.lowercased() + "%"
        var entities: [Entity] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT uuid, kind, name, detail, confidence, first_mentioned,
                       last_mentioned, mention_count, source
                FROM entities WHERE name_key LIKE ? OR lower(detail) LIKE ?
                ORDER BY last_mentioned DESC LIMIT ?
                """, args: [.text(like), .text(like), .int(limit)]) { stmt in
                entities.append(Self.entity(stmt))
            }
        } catch { }
        return entities
    }

    func getEntitiesByKind(_ kind: EntityKind, limit: Int = 50) -> [Entity] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var entities: [Entity] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT uuid, kind, name, detail, confidence, first_mentioned,
                       last_mentioned, mention_count, source
                FROM entities WHERE kind = ? ORDER BY last_mentioned DESC LIMIT ?
                """, args: [.text(kind.rawValue), .int(limit)]) { stmt in
                entities.append(Self.entity(stmt))
            }
        } catch { }
        return entities
    }

    // MARK: - Relations

    /// Upsert an edge between two entities (by uuid), bumping occurrence count
    /// when it already exists. Returns the relation uuid.
    @discardableResult
    func addRelation(from sourceID: String, to targetID: String, type: String,
                     context: String? = nil) -> String {
        guard let db = try? Self.openDB() else { return "" }
        defer { sqlite3_close(db) }
        let now = Date().timeIntervalSince1970

        guard let source = Self.entityRow(db, uuid: sourceID),
              let target = Self.entityRow(db, uuid: targetID) else { return "" }

        if let existing = Self.relationRow(db, sourceID: source.rowID, targetID: target.rowID, type: type) {
            Self.exec(db, sql: """
                UPDATE relations SET occurrence_count = occurrence_count + 1,
                       last_occurred = ?, context = COALESCE(?, context)
                WHERE id = ?
                """, args: [.double(now), .text(context ?? ""), .int(Int(existing.rowID))])
            return existing.uuid
        }

        let uuid = UUID().uuidString
        Self.exec(db, sql: """
            INSERT INTO relations (uuid, source_id, target_id, type, confidence,
                                   first_occurred, last_occurred, occurrence_count, context)
            VALUES (?, ?, ?, ?, 0.8, ?, ?, 1, ?)
            """, args: [.text(uuid), .int(Int(source.rowID)), .int(Int(target.rowID)), .text(type),
                        .double(now), .double(now), .text(context ?? "")])
        return uuid
    }

    func findRelations(from entityID: String) -> [Relation] {
        relations(column: "source_id", uuid: entityID, reversed: false)
    }

    func findRelations(to entityID: String) -> [Relation] {
        relations(column: "target_id", uuid: entityID, reversed: true)
    }

    func getRelationsBetween(_ entityID1: String, _ entityID2: String) -> [Relation] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var out: [Relation] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT r.uuid, se.uuid, te.uuid, r.type, r.confidence, r.first_occurred,
                       r.last_occurred, r.occurrence_count, r.context
                FROM relations r
                JOIN entities se ON se.id = r.source_id
                JOIN entities te ON te.id = r.target_id
                WHERE (se.uuid = ? AND te.uuid = ?) OR (se.uuid = ? AND te.uuid = ?)
                ORDER BY r.last_occurred DESC
                """, args: [.text(entityID1), .text(entityID2),
                            .text(entityID2), .text(entityID1)]) { stmt in
                out.append(Self.relation(stmt))
            }
        } catch { }
        return out
    }

    /// A hybrid graph hit: the entity plus every relation touching it.
    func searchGraph(query: String, limit: Int = 8) -> [GraphResult] {
        let entities = searchEntities(query: query, limit: limit)
        guard !entities.isEmpty else { return [] }
        var out: [GraphResult] = []
        for entity in entities {
            let relations = findRelations(from: entity.id) + findRelations(to: entity.id)
            out.append(GraphResult(entity: entity, relations: relations))
        }
        return out
    }

    // MARK: - Screen observations

    /// Insert one observation (deduped by content hash — a re-captured frame
    /// is skipped, exactly like ScreenObservationStore did).
    /// Insert one observation. Dedup is atomic: the unique index on
    /// `content_hash` decides, and `INSERT OR IGNORE` + `sqlite3_changes`
    /// report the outcome with no check-then-insert race. Returns -1 when the
    /// frame was a duplicate (the caller drops any JPEG it already wrote).
    @discardableResult
    func insertScreenObservation(capturedAt: TimeInterval, appBundleID: String,
                                 imagePath: String, ocrText: String, confidence: Double?,
                                 width: Int, height: Int, contentHash: String) -> Int64 {
        guard let db = try? Self.openDB() else { return -1 }
        defer { sqlite3_close(db) }

        Self.exec(db, sql: """
            INSERT OR IGNORE INTO screen_observations
                (captured_at, app_bundle_id, image_path, ocr_text, ocr_confidence,
                 width, height, content_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, args: [
                .double(capturedAt), .text(appBundleID), .text(imagePath), .text(ocrText),
                confidence.map { .double($0) } ?? .null,
                .int(width), .int(height), .text(contentHash),
            ])
        guard sqlite3_changes(db) > 0 else { return -1 }
        return Int64(sqlite3_last_insert_rowid(db))
    }

    func searchScreenByOCR(query: String, limit: Int = 20) -> [ScreenObservation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }

        var rows: [ScreenObservation] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT s.id, s.captured_at, s.app_bundle_id, s.image_path, s.ocr_text,
                       s.ocr_confidence, s.width, s.height, s.content_hash
                FROM screen_observations_fts f JOIN screen_observations s ON s.id = f.rowid
                WHERE screen_observations_fts MATCH ?
                ORDER BY bm25(screen_observations_fts) LIMIT ?
                """, args: [.text(trimmed), .int(limit)]) { stmt in
                rows.append(Self.screenObservation(stmt))
            }
        } catch {
            return searchScreenByLike(query: trimmed, limit: limit)
        }
        return rows
    }

    private func searchScreenByLike(query: String, limit: Int) -> [ScreenObservation] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        let like = "%" + query.lowercased() + "%"
        var rows: [ScreenObservation] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, captured_at, app_bundle_id, image_path, ocr_text,
                       ocr_confidence, width, height, content_hash
                FROM screen_observations WHERE lower(ocr_text) LIKE ?
                ORDER BY captured_at DESC LIMIT ?
                """, args: [.text(like), .int(limit)]) { stmt in
                rows.append(Self.screenObservation(stmt))
            }
        } catch { }
        return rows
    }

    func getScreenObservationsByApp(bundleID: String, since: TimeInterval? = nil,
                                    limit: Int = 50) -> [ScreenObservation] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var sql = """
            SELECT id, captured_at, app_bundle_id, image_path, ocr_text,
                   ocr_confidence, width, height, content_hash
            FROM screen_observations
            """
        var args: [Bind] = []
        if !bundleID.isEmpty {
            sql += " WHERE app_bundle_id = ?"
            args.append(.text(bundleID))
        }
        if let since {
            sql += bundleID.isEmpty ? " WHERE captured_at >= ?" : " AND captured_at >= ?"
            args.append(.double(since))
        }
        sql += " ORDER BY captured_at DESC LIMIT ?"
        args.append(.int(limit))
        var rows: [ScreenObservation] = []
        do {
            try Self.queryRows(db, sql: sql, args: args) { stmt in
                rows.append(Self.screenObservation(stmt))
            }
        } catch { }
        return rows
    }

    /// Delete observations older than `retentionDays` and their capture files.
    func pruneScreenObservations(retentionDays: TimeInterval = 7) {
        guard let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        let cutoff = Date().timeIntervalSince1970 - retentionDays * 86_400
        var stalePaths: [String] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT image_path FROM screen_observations WHERE captured_at < ?
                """, args: [.double(cutoff)]) { stmt in
                stalePaths.append(Self.textColumn(stmt, 0))
            }
        } catch { }
        Self.exec(db, sql: "DELETE FROM screen_observations WHERE captured_at < ?",
                  args: [.double(cutoff)])
        for path in stalePaths where !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Turn observation (replaces the external agentmemory engine)

    /// Run the local extractor over one conversation turn (a user prompt or an
    /// Alfred reply) and write every fact into the unified graph. This is the
    /// on-device replacement for the decommissioned `AgentMemoryClient`:
    /// alfred-coder (Ollama) pulls people, organizations and communication
    /// preferences out of the text, and each fact lands as its own
    /// entity/relation frame. Fire-and-forget — the caller
    /// (HermesSession.runTurn) returns immediately.
    func observeTurn(_ text: String, source: String) {
        guard !text.isEmpty else { return }
        Task.detached {
            let facts = await LocalGraphExtractor.shared.extract(from: text)
            guard !facts.isEmpty else { return }
            // 1. Every entity as its own write; keep name → uuid so the edges
            //    below can link the stored nodes.
            var ids: [String: String] = [:]
            for entity in facts.entities {
                let id = UnifiedMemoryLayer.shared.addEntity(
                    kind: Self.entityKind(for: entity.kind),
                    name: entity.name,
                    detail: entity.detail,
                    source: source)
                ids[entity.name.lowercased()] = id
            }
            // 2. Every edge as its own write, resolved by name.
            for relation in facts.relations {
                guard let from = ids[relation.sourceName.lowercased()],
                      let to = ids[relation.targetName.lowercased()],
                      !from.isEmpty, !to.isEmpty else { continue }
                UnifiedMemoryLayer.shared.addRelation(from: from, to: to, type: relation.type)
            }
        }
    }

    /// Map the local extractor's kinds onto the unified graph's kinds.
    private static func entityKind(for kind: GraphEntity.Kind) -> EntityKind {
        switch kind {
        case .person: return .person
        case .organization: return .organization
        case .communicationPreference: return .communicationPreference
        }
    }

    // MARK: - Conversations

    @discardableResult
    func addConversation(user: String, assistant: String, timestamp: TimeInterval,
                         topic: String = "general", id: String? = nil) -> String {
        let conversationID = id ?? UUID().uuidString
        guard let db = try? Self.openDB() else { return conversationID }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            INSERT INTO conversations (id, user_message, assistant_response,
                                       timestamp, accepted, confidence, topic)
            VALUES (?, ?, ?, ?, 0, 0.0, ?)
            """, args: [.text(conversationID), .text(user), .text(assistant),
                        .double(timestamp), .text(topic)])
        return conversationID
    }

    func markAccepted(id: String, confidence: Double) {
        guard let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            UPDATE conversations SET accepted = 1, confidence = ?
            WHERE id = ?
            """, args: [.double(confidence), .text(id)])
    }

    /// Inference path: the most recent capture, if still unaccepted and the
    /// follow-up isn't a rejection, counts as accepted at 0.7.
    func inferAcceptance(followingUserMessage: String) {
        guard !ConversationStore.isRejection(followingUserMessage),
              let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            UPDATE conversations SET accepted = 1, confidence = 0.7
            WHERE id = (SELECT id FROM conversations WHERE accepted = 0
                        ORDER BY timestamp DESC LIMIT 1)
            """)
    }

    func getAcceptedConversations(limit: Int = 100) -> [Conversation] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var out: [Conversation] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, user_message, assistant_response, timestamp, accepted,
                       confidence, topic
                FROM conversations WHERE accepted = 1
                ORDER BY timestamp DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                out.append(Self.conversation(stmt))
            }
        } catch { }
        return out
    }

    func searchConversations(query: String, limit: Int = 20) -> [Conversation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        let like = "%" + trimmed.lowercased() + "%"
        var out: [Conversation] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, user_message, assistant_response, timestamp, accepted,
                       confidence, topic
                FROM conversations
                WHERE lower(user_message) LIKE ? OR lower(assistant_response) LIKE ?
                ORDER BY timestamp DESC LIMIT ?
                """, args: [.text(like), .text(like), .int(limit)]) { stmt in
                out.append(Self.conversation(stmt))
            }
        } catch { }
        return out
    }

    /// True when an observation with this content hash already exists — lets
    /// the caller skip JPEG writes before the DB dedup would.
    func hasScreenObservation(contentHash: String) -> Bool {
        guard let db = try? Self.openDB() else { return false }
        defer { sqlite3_close(db) }
        var exists = false
        do {
            try Self.queryRows(db, sql: """
                SELECT 1 FROM screen_observations WHERE content_hash = ? LIMIT 1
                """, args: [.text(contentHash)]) { _ in exists = true }
        } catch { }
        return exists
    }

    /// Overwrite the timestamps/mention count a fresh `addEntity` set — the
    /// migration path folds legacy metadata in after seeding the row.
    func seedEntityMetadata(uuid: String, mentionCount: Int,
                            firstMentioned: TimeInterval, lastMentioned: TimeInterval) {
        guard let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            UPDATE entities SET mention_count = ?, first_mentioned = ?, last_mentioned = ?
            WHERE uuid = ?
            """, args: [.int(mentionCount), .double(firstMentioned),
                        .double(lastMentioned), .text(uuid)])
    }

    /// One legacy screen-text-log row being folded into `screen_observations`
    /// (no JPEG exists, so the content hash is synthetic and unique).
    struct LegacyScreenRow {
        var capturedAt: TimeInterval
        var appBundleID: String
        var ocrText: String
        var uniqueKey: String
    }

    /// Bulk-import legacy screen text rows in one connection. Returns how many
    /// landed; the FTS triggers index each as it goes.
    @discardableResult
    func importLegacyScreenRows(_ rows: [LegacyScreenRow]) -> Int {
        guard let db = try? Self.openDB() else { return 0 }
        defer { sqlite3_close(db) }
        var imported = 0
        for row in rows {
            Self.exec(db, sql: """
                INSERT OR IGNORE INTO screen_observations
                    (captured_at, app_bundle_id, image_path, ocr_text, content_hash)
                VALUES (?, ?, '', ?, ?)
                """, args: [.double(row.capturedAt), .text(row.appBundleID),
                            .text(row.ocrText), .text(row.uniqueKey)])
            imported += 1
        }
        return imported
    }

    /// Drop the old store's FTS triggers on `screen_observations` (if they
    /// exist) so inserts this layer owns aren't double-indexed.
    func dropLegacyScreenTriggers() {
        guard let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: "DROP TRIGGER IF EXISTS __screen_observations_fts_ai")
        Self.exec(db, sql: "DROP TRIGGER IF EXISTS __screen_observations_fts_ad")
        Self.exec(db, sql: "DROP TRIGGER IF EXISTS __screen_observations_fts_au")
    }

    // MARK: - Vault notes (read-only mirror)

    /// (Re)index a set of vault notes. The Obsidian vault stays the source of
    /// truth; this table is the searchable mirror. Returns how many landed.
    @discardableResult
    func indexVaultNotes(from notes: [MemoryNote]) -> Int {
        guard let db = try? Self.openDB() else { return 0 }
        defer { sqlite3_close(db) }
        var count = 0
        for note in notes {
            let path = note.url?.path ?? note.id
            let id = note.id.isEmpty ? path : note.id
            Self.exec(db, sql: """
                INSERT OR REPLACE INTO vault_notes (id, title, body, category, importance, date, path)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, args: [
                    .text(id), .text(note.title), .text(note.body), .text(note.category),
                    .int(note.importance), .double(note.date.timeIntervalSince1970),
                    .text(path),
                ])
            count += 1
        }
        return count
    }

    func getVaultNote(byPath path: String) -> VaultNote? {
        guard let db = try? Self.openDB() else { return nil }
        defer { sqlite3_close(db) }
        var found: VaultNote?
        do {
            try Self.queryRows(db, sql: """
                SELECT id, title, body, category, importance, date, path
                FROM vault_notes WHERE path = ?
                """, args: [.text(path)]) { stmt in
                found = Self.vaultNote(stmt)
            }
        } catch { }
        return found
    }

    func searchVault(query: String, limit: Int = 8) -> [VaultNote] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        let terms = Self.terms(trimmed)
        guard !terms.isEmpty else { return [] }
        let like = "%" + terms.joined(separator: "%") + "%"
        var out: [VaultNote] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, title, body, category, importance, date, path
                FROM vault_notes
                WHERE lower(title) LIKE ? OR lower(body) LIKE ?
                ORDER BY importance DESC, date DESC LIMIT ?
                """, args: [.text(like), .text(like), .int(limit)]) { stmt in
                out.append(Self.vaultNote(stmt))
            }
        } catch { }
        return out
    }

    // MARK: - Unified search

    /// One ranked list across every memory type. Entities and observations
    /// rank by FTS bm25; notes and conversations by term coverage, with a
    /// recency boost on top. The caller chooses how many of each it wants.
    func search(query: String, limit: Int = 12) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [SearchResult] = []
        for entity in searchEntities(query: trimmed, limit: 4) {
            results.append(SearchResult(
                type: "entity",
                id: entity.id,
                title: entity.name,
                snippet: entity.detail ?? "",
                timestamp: entity.lastMentioned,
                confidence: entity.confidence))
        }
        for note in searchVault(query: trimmed, limit: 4) {
            results.append(SearchResult(
                type: "note",
                id: note.id,
                title: note.title,
                snippet: Self.snippet(of: note.body, query: trimmed),
                timestamp: note.date ?? 0,
                confidence: Double(note.importance) / 5.0))
        }
        for conversation in searchConversations(query: trimmed, limit: 3) {
            results.append(SearchResult(
                type: "conversation",
                id: conversation.id,
                title: conversation.userMessage,
                snippet: conversation.assistantResponse,
                timestamp: conversation.timestamp,
                confidence: conversation.accepted ? 1.0 : 0.4))
        }
        for observation in searchScreenByOCR(query: trimmed, limit: 3) {
            results.append(SearchResult(
                type: "observation",
                id: String(observation.id),
                title: observation.appBundleID,
                snippet: observation.ocrText,
                timestamp: observation.capturedAt,
                confidence: observation.ocrConfidence ?? 0.5))
        }
        return Array(results.prefix(limit))
    }

    /// A compact bracketed grounding block for prompt injection — the
    /// replacement for the old MemoryStore + PersonalMemoryStore +
    /// AgentMemoryClient three-way grounding. Empty when nothing matched.
    func groundingText(for query: String, limit: Int = 6) -> String {
        let results = search(query: query, limit: limit)
        guard !results.isEmpty else { return "" }
        return results.map { result in
            let snippet = Self.compact(result.snippet, max: 60)
            switch result.type {
            case "entity":  return "[entity:\(result.title)\(snippet.isEmpty ? "" : " — \(snippet)")]"
            case "note":    return "[vault:\(result.title)\(snippet.isEmpty ? "" : " — \(snippet)")]"
            case "conversation":
                return "[conversation: “\(Self.compact(result.title, max: 60))” → “\(snippet)”]"
            case "observation": return "[screen:\(result.title): \(snippet)]"
            default: return "[memory:\(result.title)]"
            }
        }.joined(separator: " ")
    }

    // MARK: - Graph traversal

    /// Every person entity, ranked by confidence × mention count with a
    /// recency decay — the `PersonMemoryService.currentPeople()` replacement.
    func getPeopleIKnow(limit: Int = 20) -> [Entity] {
        getEntitiesByKind(.person, limit: limit).sorted {
            strength($0) > strength($1)
        }
    }

    /// What Alfred and a given person talk about: every topic/concept/project
    /// entity connected to them by a `communicates_about`-family relation.
    func getTopicsIDiscuss(with personID: String, limit: Int = 10) -> [Entity] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var out: [Entity] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT e.uuid, e.kind, e.name, e.detail, e.confidence, e.first_mentioned,
                       e.last_mentioned, e.mention_count, e.source
                FROM relations r
                JOIN entities e ON e.id = r.target_id
                JOIN entities p ON p.id = r.source_id
                WHERE p.uuid = ? AND e.kind IN ('topic', 'concept', 'project')
                ORDER BY r.last_occurred DESC LIMIT ?
                """, args: [.text(personID), .int(limit)]) { stmt in
                out.append(Self.entity(stmt))
            }
        } catch { }
        return out
    }

    /// People connected to recently-mentioned entities — the people Alfred has
    /// been in contact with lately.
    func getRecentConversationPartners(since: TimeInterval, limit: Int = 10) -> [Entity] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var out: [Entity] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT DISTINCT p.uuid, p.kind, p.name, p.detail, p.confidence,
                       p.first_mentioned, p.last_mentioned, p.mention_count, p.source
                FROM relations r
                JOIN entities p ON p.id = r.source_id
                JOIN entities e ON e.id = r.target_id
                WHERE p.kind = 'person' AND e.last_mentioned >= ?
                ORDER BY p.last_mentioned DESC LIMIT ?
                """, args: [.double(since), .int(limit)]) { stmt in
                out.append(Self.entity(stmt))
            }
        } catch { }
        return out
    }

    /// A human-readable relationship summary for prompt grounding, matching
    /// the shape `PersonMemoryService.toPromptInjection()` produced.
    func getRelationshipSummary(limit: Int = 3) -> String {
        let people = getPeopleIKnow(limit: limit)
        guard !people.isEmpty else { return "" }

        var sentences: [String] = []
        let line = people.map { person -> String in
            let strengthLabel: String
            switch strength(person) {
            case ..<0.4: strengthLabel = "a distant contact"
            case ..<0.7: strengthLabel = "an active contact"
            default: strengthLabel = "a close contact"
            }
            return "\(person.name) (\(strengthLabel))"
        }.joined(separator: ", ")
        sentences.append("The user's closest relationships are with \(line).")

        for person in people.prefix(2) {
            let topics = getTopicsIDiscuss(with: person.id, limit: 3).map(\.name)
            if !topics.isEmpty {
                sentences.append("\(person.name) — discusses \(topics.joined(separator: ", ")).")
            }
        }
        sentences.append("Refer to these people by name when they come up.")
        return sentences.joined(separator: " ")
    }

    /// Total conversation rows — the ConversationStore facade's `count`.
    func countConversations() -> Int {
        guard let db = try? Self.openDB() else { return 0 }
        defer { sqlite3_close(db) }
        var count = 0
        do {
            try Self.queryRows(db, sql: "SELECT COUNT(*) FROM conversations") { stmt in
                count = Self.intColumn(stmt, 0)
            }
        } catch { }
        return count
    }

    /// Wipe every conversation row — the ConversationStore facade's `reset`.
    func clearConversations() {
        guard let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: "DELETE FROM conversations")
    }

    // MARK: - Sanity

    /// How many rows are in each unified table — for the migration report.
    func counts() -> [String: Int] {
        guard let db = try? Self.openDB() else { return [:] }
        defer { sqlite3_close(db) }
        var out: [String: Int] = [:]
        for table in ["entities", "relations", "screen_observations", "conversations", "vault_notes"] {
            var count = 0
            do {
                try Self.queryRows(db, sql: "SELECT COUNT(*) FROM \(table)") { stmt in
                    count = Self.intColumn(stmt, 0)
                }
            } catch { }
            out[table] = count
        }
        return out
    }

    // MARK: - Scoring

    /// 0.0–1.0 relationship strength: confidence × a mention-count curve with
    /// a recency decay — the same philosophy as the retired
    /// PersonMemoryService.relationshipStrength.
    private func strength(_ entity: Entity) -> Double {
        let m = Double(entity.mentionCount)
        let base: Double
        switch m {
        case ..<10:  base = m / 10 * 0.5
        case ..<50:  base = 0.5 + (m - 10) / 40 * 0.3
        case ..<100: base = 0.8 + (m - 50) / 50 * 0.2
        default:     base = 1.0
        }
        let daysSilent = max(0, (Date().timeIntervalSince1970 - entity.lastMentioned) / 86_400)
        let recency = 0.5 + 0.5 * exp(-daysSilent / 21)
        return min(1.0, base * recency * entity.confidence)
    }

    // MARK: - Row readers

    private struct EntityRow {
        let rowID: Int64
        let uuid: String
    }

    private struct RelationRow {
        let rowID: Int64
        let uuid: String
    }

    private static func entity(_ stmt: OpaquePointer) -> Entity {
        Entity(
            id: textColumn(stmt, 0),
            kind: EntityKind(rawValue: textColumn(stmt, 1)) ?? .concept,
            name: textColumn(stmt, 2),
            detail: nullableTextColumn(stmt, 3),
            confidence: doubleColumn(stmt, 4),
            firstMentioned: doubleColumn(stmt, 5),
            lastMentioned: doubleColumn(stmt, 6),
            mentionCount: intColumn(stmt, 7),
            source: nullableTextColumn(stmt, 8))
    }

    private static func relation(_ stmt: OpaquePointer) -> Relation {
        Relation(
            id: textColumn(stmt, 0),
            sourceEntityId: textColumn(stmt, 1),
            targetEntityId: textColumn(stmt, 2),
            type: textColumn(stmt, 3),
            confidence: doubleColumn(stmt, 4),
            firstOccurred: doubleColumn(stmt, 5),
            lastOccurred: doubleColumn(stmt, 6),
            occurrenceCount: intColumn(stmt, 7),
            context: nullableTextColumn(stmt, 8))
    }

    private static func screenObservation(_ stmt: OpaquePointer) -> ScreenObservation {
        ScreenObservation(
            id: Int64(intColumn(stmt, 0)),
            capturedAt: doubleColumn(stmt, 1),
            appBundleID: textColumn(stmt, 2),
            imagePath: textColumn(stmt, 3),
            ocrText: textColumn(stmt, 4),
            ocrConfidence: nullableDoubleColumn(stmt, 5),
            width: intColumn(stmt, 6),
            height: intColumn(stmt, 7),
            contentHash: textColumn(stmt, 8))
    }

    private static func conversation(_ stmt: OpaquePointer) -> Conversation {
        Conversation(
            id: textColumn(stmt, 0),
            userMessage: textColumn(stmt, 1),
            assistantResponse: textColumn(stmt, 2),
            timestamp: doubleColumn(stmt, 3),
            accepted: intColumn(stmt, 4) != 0,
            confidence: doubleColumn(stmt, 5),
            topic: nullableTextColumn(stmt, 6) ?? "general")
    }

    private static func vaultNote(_ stmt: OpaquePointer) -> VaultNote {
        VaultNote(
            id: textColumn(stmt, 0),
            title: textColumn(stmt, 1),
            body: textColumn(stmt, 2),
            category: nullableTextColumn(stmt, 3) ?? "documents",
            importance: intColumn(stmt, 4),
            date: nullableDoubleColumn(stmt, 5),
            path: textColumn(stmt, 6))
    }

    private static func entityRow(_ db: OpaquePointer, kind: EntityKind, nameKey: String) -> EntityRow? {
        var row: EntityRow?
        do {
            try queryRows(db, sql: """
                SELECT id, uuid FROM entities WHERE kind = ? AND name_key = ? LIMIT 1
                """, args: [.text(kind.rawValue), .text(nameKey)]) { stmt in
                row = EntityRow(rowID: Int64(intColumn(stmt, 0)), uuid: textColumn(stmt, 1))
            }
        } catch { }
        return row
    }

    private static func entityRow(_ db: OpaquePointer, uuid: String) -> EntityRow? {
        var row: EntityRow?
        do {
            try queryRows(db, sql: """
                SELECT id, uuid FROM entities WHERE uuid = ? LIMIT 1
                """, args: [.text(uuid)]) { stmt in
                row = EntityRow(rowID: Int64(intColumn(stmt, 0)), uuid: textColumn(stmt, 1))
            }
        } catch { }
        return row
    }

    private static func relationRow(_ db: OpaquePointer, sourceID: Int64, targetID: Int64, type: String) -> RelationRow? {
        var row: RelationRow?
        do {
            try queryRows(db, sql: """
                SELECT id, uuid FROM relations
                WHERE source_id = ? AND target_id = ? AND type = ? LIMIT 1
                """, args: [.int(Int(sourceID)), .int(Int(targetID)), .text(type)]) { stmt in
                row = RelationRow(rowID: Int64(intColumn(stmt, 0)), uuid: textColumn(stmt, 1))
            }
        } catch { }
        return row
    }

    private func relations(column: String, uuid: String, reversed: Bool) -> [Relation] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var out: [Relation] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT r.uuid, se.uuid, te.uuid, r.type, r.confidence, r.first_occurred,
                       r.last_occurred, r.occurrence_count, r.context
                FROM relations r
                JOIN entities se ON se.id = r.source_id
                JOIN entities te ON te.id = r.target_id
                WHERE \(reversed ? "te.uuid" : "se.uuid") = ?
                ORDER BY r.last_occurred DESC
                """, args: [.text(uuid)]) { stmt in
                out.append(Self.relation(stmt))
            }
        } catch { }
        return out
    }

    // MARK: - SQLite plumbing (static + nonisolated: connections are per-call)

    private static func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(databasePath, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let db else {
            throw MemoryError.database("could not open \(databasePath) (\(rc))")
        }
        return db
    }

    private static func runMigration(_ db: OpaquePointer) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, migrationDDL, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw MemoryError.database(message)
        }
    }

    private enum Bind {
        case text(String)
        case double(Double)
        case int(Int)
        case null
    }

    private enum MemoryError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self {
            case .database(let message): return "memory store error: \(message)"
            }
        }
    }

    /// Run a write/DDL statement. Logs prepare and step failures so a silently
    /// unindexed FTS row or a failed insert never disappears without a trace.
    /// SQLITE_CONSTRAINT is expected on the upsert paths (a concurrent writer
    /// won the race) and is deliberately quiet.
    private static func exec(_ db: OpaquePointer, sql: String, args: [Bind] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("[memory] exec prepare failed: %@", lastErrorMessage(db))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_CONSTRAINT {
            NSLog("[memory] exec step failed (%d): %@", rc, lastErrorMessage(db))
        }
    }

    private static func queryRows(_ db: OpaquePointer, sql: String, args: [Bind] = [],
                                             row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MemoryError.database(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            row(stmt)
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {
            throw MemoryError.database(lastErrorMessage(db))
        }
    }

    private static func bind(_ stmt: OpaquePointer, _ args: [Bind]) {
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            switch arg {
            case .text(let value):
                sqlite3_bind_text(stmt, i, value, -1, SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(stmt, i, value)
            case .int(let value):
                sqlite3_bind_int64(stmt, i, Int64(value))
            case .null:
                sqlite3_bind_null(stmt, i)
            }
        }
    }

    private static func lastErrorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private static func nullableTextColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : textColumn(stmt, index)
    }

    private static func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    private static func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    private static func nullableDoubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    // MARK: - Text helpers

    /// Normalized lookup key: lowercased, whitespace-collapsed.
    private static func nameKey(_ name: String) -> String {
        name
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func terms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    private static func compact(_ text: String, max: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count <= max ? cleaned : String(cleaned.prefix(max)) + "…"
    }

    /// A short excerpt around the first query-term hit, or the start of the text.
    private static func snippet(of text: String, query: String) -> String {
        let lower = text.lowercased()
        let terms = Self.terms(query)
        if let firstTerm = terms.first, let range = lower.range(of: firstTerm) {
            let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.lowerBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
            return compact(String(text[start..<end]), max: 120)
        }
        return compact(text, max: 120)
    }
}
