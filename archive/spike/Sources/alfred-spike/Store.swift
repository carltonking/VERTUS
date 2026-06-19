import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Alfred's local memory store. SQLite via the system libsqlite3 — no external deps.
/// Lives in Application Support (NOT the repo), holds OCR text + embeddings only.
/// NOTE: plaintext for v1 dev; at-rest encryption (SQLCipher) is a Phase 4 hardening item.
final class Store {
    private var db: OpaquePointer?
    let path: String

    struct Memory {
        let id: Int64
        let ts: Date
        let app: String?
        let text: String
    }

    init() throws {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alfred", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent("alfred.db").path

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw Err("open failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    struct Err: Error, CustomStringConvertible { let m: String; init(_ m: String) { self.m = m }; var description: String { m } }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw Err("exec failed: \(msg)")
        }
    }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS memories (
          id   INTEGER PRIMARY KEY AUTOINCREMENT,
          ts   REAL NOT NULL,
          app  TEXT,
          text TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS embeddings (
          memory_id INTEGER PRIMARY KEY REFERENCES memories(id),
          vec       BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_memories_ts ON memories(ts);

        CREATE TABLE IF NOT EXISTS style_samples (
          id     INTEGER PRIMARY KEY AUTOINCREMENT,
          ts     REAL NOT NULL,
          source TEXT NOT NULL,        -- 'harvest' | 'manual'
          text   TEXT NOT NULL UNIQUE  -- dedup identical samples
        );
        CREATE TABLE IF NOT EXISTS style_card (
          id      INTEGER PRIMARY KEY CHECK (id = 1),
          text    TEXT NOT NULL,
          updated REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS people (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
          first_seen REAL NOT NULL,
          last_seen  REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS interactions (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          person_id INTEGER NOT NULL REFERENCES people(id),
          ts        REAL NOT NULL,
          direction TEXT,                 -- 'to' | 'from' | 'mention'
          topic     TEXT,
          sentiment TEXT,                 -- 'positive' | 'neutral' | 'negative'
          snippet   TEXT NOT NULL,
          UNIQUE(person_id, snippet)      -- dedup repeated captures
        );
        CREATE INDEX IF NOT EXISTS idx_interactions_person ON interactions(person_id);

        CREATE TABLE IF NOT EXISTS preferences (
          id     INTEGER PRIMARY KEY AUTOINCREMENT,
          ts     REAL NOT NULL,
          text   TEXT NOT NULL UNIQUE,
          weight INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS last_output (
          id     INTEGER PRIMARY KEY CHECK (id = 1),
          kind   TEXT NOT NULL,        -- 'draft' | 'do'
          intent TEXT NOT NULL,
          output TEXT NOT NULL,
          ts     REAL NOT NULL
        );
        """)
    }

    // MARK: - learned preferences (Phase 6)

    /// Add a preference rule; if it already exists, bump its weight instead.
    func addPreference(_ text: String, ts: Date) throws {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO preferences (ts, text, weight) VALUES (?,?,1)
            ON CONFLICT(text) DO UPDATE SET weight = weight + 1, ts = excluded.ts
            """, -1, &stmt, nil)
        sqlite3_bind_double(stmt, 1, ts.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    func preferences(limit: Int = 40) throws -> [(text: String, weight: Int)] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT text, weight FROM preferences ORDER BY weight DESC, ts DESC LIMIT ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
        }
        return out
    }

    func setLastOutput(kind: String, intent: String, output: String, ts: Date) throws {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO last_output (id, kind, intent, output, ts) VALUES (1,?,?,?,?)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, intent, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, output, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, ts.timeIntervalSince1970)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }

    func lastOutput() throws -> (kind: String, intent: String, output: String)? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT kind, intent, output FROM last_output WHERE id = 1", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                String(cString: sqlite3_column_text(stmt, 2)))
    }

    // MARK: - relationship map (Phase 3)

    struct Person { let id: Int64; let name: String; let count: Int; let lastSeen: Date }
    struct Interaction { let ts: Date; let direction: String?; let topic: String?; let sentiment: String?; let snippet: String }

    @discardableResult
    func upsertPerson(name: String, ts: Date) throws -> Int64 {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO people (name, first_seen, last_seen) VALUES (?,?,?)
            ON CONFLICT(name) DO UPDATE SET last_seen = max(last_seen, excluded.last_seen)
            """, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, ts.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, ts.timeIntervalSince1970)
        sqlite3_step(stmt); sqlite3_finalize(stmt)
        return try personID(name: name) ?? -1
    }

    func personID(name: String) throws -> Int64? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM people WHERE name = ? COLLATE NOCASE", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    @discardableResult
    func addInteraction(personID: Int64, ts: Date, direction: String?, topic: String?, sentiment: String?, snippet: String) throws -> Bool {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO interactions (person_id, ts, direction, topic, sentiment, snippet) VALUES (?,?,?,?,?,?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, personID)
        sqlite3_bind_double(stmt, 2, ts.timeIntervalSince1970)
        bindOpt(stmt, 3, direction); bindOpt(stmt, 4, topic); bindOpt(stmt, 5, sentiment)
        sqlite3_bind_text(stmt, 6, snippet, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        return sqlite3_changes(db) > 0
    }

    private func bindOpt(_ stmt: OpaquePointer?, _ idx: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, idx) }
    }

    func people() throws -> [Person] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT p.id, p.name, COUNT(i.id) AS c, p.last_seen
            FROM people p LEFT JOIN interactions i ON i.person_id = p.id
            GROUP BY p.id ORDER BY c DESC, p.last_seen DESC
            """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var out: [Person] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Person(id: sqlite3_column_int64(stmt, 0),
                              name: String(cString: sqlite3_column_text(stmt, 1)),
                              count: Int(sqlite3_column_int64(stmt, 2)),
                              lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
        }
        return out
    }

    func deletePerson(id: Int64) throws {
        for sql in ["DELETE FROM interactions WHERE person_id = \(id)", "DELETE FROM people WHERE id = \(id)"] {
            try exec(sql)
        }
    }

    /// Move interactions from one person to another (for duplicate merges), then delete the source.
    /// UPDATE OR IGNORE drops rows that would collide with the canonical's UNIQUE(person_id, snippet).
    func mergePerson(from: Int64, into: Int64) throws {
        try exec("UPDATE OR IGNORE interactions SET person_id = \(into) WHERE person_id = \(from)")
        try deletePerson(id: from)
    }

    func interactions(personID: Int64, limit: Int = 50) throws -> [Interaction] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts, direction, topic, sentiment, snippet FROM interactions WHERE person_id = ? ORDER BY ts DESC LIMIT ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, personID)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [Interaction] = []
        func col(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Interaction(ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                                   direction: col(1), topic: col(2), sentiment: col(3),
                                   snippet: String(cString: sqlite3_column_text(stmt, 4))))
        }
        return out
    }

    // MARK: - style samples (Phase 2)

    @discardableResult
    func addStyleSample(ts: Date, source: String, text: String) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO style_samples (ts, source, text) VALUES (?,?,?)", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare addStyleSample: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, text, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Err("step addStyleSample: \(String(cString: sqlite3_errmsg(db)))")
        }
        return sqlite3_changes(db) > 0   // false if it was a duplicate
    }

    func styleSamples(limit: Int = 1000) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT text FROM style_samples ORDER BY ts DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare styleSamples: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    func styleSampleCount() throws -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM style_samples", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func setStyleCard(_ text: String, updated: Date) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO style_card (id, text, updated) VALUES (1,?,?)", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare setStyleCard: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, updated.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Err("step setStyleCard: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func styleCard() throws -> String? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT text FROM style_card WHERE id = 1", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Recent raw memory text blocks — candidate pool for style harvesting.
    func recentMemoryTexts(limit: Int = 200) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT text FROM memories ORDER BY ts DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare recentMemoryTexts: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    /// Insert a memory row, return its id.
    @discardableResult
    func insertMemory(ts: Date, app: String?, text: String) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO memories (ts, app, text) VALUES (?,?,?)", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare insertMemory: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts.timeIntervalSince1970)
        if let app { sqlite3_bind_text(stmt, 2, app, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_text(stmt, 3, text, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Err("step insertMemory: \(String(cString: sqlite3_errmsg(db)))")
        }
        return sqlite3_last_insert_rowid(db)
    }

    func insertEmbedding(memoryID: Int64, vector: [Float]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO embeddings (memory_id, vec) VALUES (?,?)", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare insertEmbedding: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, memoryID)
        _ = vector.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Err("step insertEmbedding: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Load all embeddings (id + vector) for brute-force cosine search.
    /// Fine at v1 scale; swap for sqlite-vec / ANN when the store grows large.
    func allEmbeddings() throws -> [(id: Int64, vec: [Float])] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT memory_id, vec FROM embeddings", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare allEmbeddings: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var out: [(Int64, [Float])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let bytes = sqlite3_column_blob(stmt, 1)
            let count = Int(sqlite3_column_bytes(stmt, 1))
            var vec = [Float](repeating: 0, count: count / MemoryLayout<Float>.size)
            if let bytes { memcpy(&vec, bytes, count) }
            out.append((id, vec))
        }
        return out
    }

    func memory(id: Int64) throws -> Memory? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, ts, app, text FROM memories WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare memory: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let app = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let text = String(cString: sqlite3_column_text(stmt, 3))
        return Memory(id: sqlite3_column_int64(stmt, 0),
                      ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                      app: app, text: text)
    }

    func mostRecentText() throws -> String? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT text FROM memories ORDER BY ts DESC LIMIT 1", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func stats() throws -> (memories: Int, embeddings: Int) {
        func count(_ table: String) -> Int {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
        return (count("memories"), count("embeddings"))
    }
}
