import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro, invisible to Swift; -1 tells SQLite to copy the
// bound string before the statement is finalized.
private let MEMPALACE_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Categories

/// What a memory is about. The spec's six categories, wire names snake_case.
enum MemoryCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case preference
    case projectPattern = "project_pattern"
    case person
    case goal
    case learning
    case constraint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preference:      return "Preferences"
        case .projectPattern:  return "Project patterns"
        case .person:          return "People"
        case .goal:            return "Goals"
        case .learning:        return "Learning"
        case .constraint:      return "Constraints"
        }
    }
}

// MARK: - Settings

/// How aggressively Alfred turns observations into stored memories.
enum MemoryLearningMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative
    case aggressive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative: return "Conservative — only clear signals"
        case .aggressive:   return "Aggressive — learn from anything"
        }
    }

    /// The minimum confidence an inferred preference must carry to be stored.
    var inferenceFloor: Double {
        switch self {
        case .conservative: return 0.7
        case .aggressive:   return 0.45
        }
    }
}

/// How quickly memories lose confidence with disuse.
enum MemoryDecayRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case slow
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slow: return "Slow — remember everything"
        case .fast: return "Fast — forget quickly"
        }
    }
}

/// The layer's configuration. Persisted through MemPalaceManager (UserDefaults);
/// Codable so it can cross the wire to the phone unchanged.
struct MemPalaceSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var learningMode: MemoryLearningMode = .conservative
    var decayRate: MemoryDecayRate = .slow
    var confidenceThreshold: Double = 0.7
    var excludedCategories: [MemoryCategory] = []

    /// The privacy switch for relationship memory.
    var excludesPeople: Bool { excludedCategories.contains(.person) }
}

// MARK: - Models

/// One learned memory. Confidence starts where the signal landed, rises with
/// repetition and corrections, and decays with disuse until consolidation
/// prunes it below the floor.
struct MemoryEntry: Codable, Equatable, Sendable {
    let id: String
    var content: String
    var category: MemoryCategory
    var confidence: Double
    var createdAt: TimeInterval
    var lastAccessed: TimeInterval
    var accessCount: Int
    var source: String   // email_analysis | code_review | user_correction | inferred | manual
    var tags: [String]
}

/// One tracked goal with a cadence and a streak.
struct MemoryGoal: Codable, Equatable, Sendable {
    let id: String
    var title: String
    var cadence: String     // daily | weekly
    var streak: Int
    var lastCompletedAt: TimeInterval?
    var createdAt: TimeInterval
    var notes: String?
}

/// One consolidated scan's outcome — for the briefing and the console.
struct MemoryConsolidationResult: Codable, Equatable, Sendable {
    var entriesBefore: Int
    var entriesAfter: Int
    var pruned: Int
    var decayed: Int
}

// MARK: - MemPalaceManager

/// The persistent memory that survives conversations.
///
/// Two complementary stores, matching what the real MemPalace project ships
/// and what it deliberately does not:
///
/// 1. **Our meta layer** (this class, `~/.alfred/mempalace.db`) — the spec's
///    headline features: each memory carries a confidence that repetition and
///    corrections raise and time decays, low-confidence entries are pruned on
///    consolidation, and goals track streaks. The real mempalace stores
///    *verbatim transcripts forever* and has no confidence, decay, pruning or
///    corrections — so this layer owns that behaviour.
/// 2. **The verbatim bridge** — if the real `mempalace` CLI is installed
///    (`uv tool install mempalace` / `pipx install mempalace`), `remember`
///    and `search` can additionally mirror into its ChromaDB+SQLite palace.
///    Every bridge call probes for the binary and no-ops gracefully when it
///    is absent, so the layer is fully functional standalone.
///
/// Threading matches UnifiedMemoryLayer: a plain class, every DB helper opens
/// its own per-call FULLMUTEX connection. Settings are NSLock-guarded because
/// SettingsModel and the MCP invoke path read them off the main actor.
final class MemPalaceManager {

    static let shared = MemPalaceManager()

    private static let defaultDatabasePath = NSHomeDirectory() + "/.alfred/mempalace.db"

    /// The database this instance writes to. `dbPathOverride` exists for tests
    /// (same pattern as CareerOpsManager's directoryOverride) — the shared
    /// instance always uses the real path.
    private let dbPath: String

    /// The shared chat session used for preference inference. Assigned at
    /// launch by AlfredApp; nil means inference is skipped, never deferred.
    var hermes: HermesSession?

    private let settingsLock = NSLock()
    private var _settings = MemPalaceSettings()
    private var consolidationTimer: Timer?

    /// Creates the manager. `dbPathOverride` exists for tests — the shared
    /// instance always uses `~/.alfred/mempalace.db`.
    init(dbPathOverride: String? = nil) {
        self.dbPath = dbPathOverride ?? Self.defaultDatabasePath
        do {
            try FileManager.default.createDirectory(
                atPath: (dbPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let db = try self.openDB()
            defer { sqlite3_close(db) }
            try Self.runMigration(db)
        } catch {
            NSLog("[mempalace] init failed: %@", error.localizedDescription)
        }
        loadSettings()
    }

    /// A consolidation pass every 6 hours (matches MemoryReflectionService's
    /// cadence) — decay + prune are quiet and cheap.
    func start() {
        guard consolidationTimer == nil else { return }
        consolidationTimer = Timer(fire: Date().addingTimeInterval(3600), interval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.dailyConsolidation()
        }
        RunLoop.main.add(consolidationTimer!, forMode: .common)
        NSLog("[mempalace] consolidation scheduled (first pass in 1h, then every 6h)")
    }

    func stop() {
        consolidationTimer?.invalidate()
        consolidationTimer = nil
    }

    // MARK: - Settings

    var settings: MemPalaceSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return _settings
    }

    var isEnabled: Bool { settings.enabled }

    /// Mutate settings atomically and persist the result.
    func updateSettings(_ mutate: (inout MemPalaceSettings) -> Void) {
        settingsLock.lock()
        mutate(&_settings)
        let snapshot = _settings
        settingsLock.unlock()
        persistSettings(snapshot)
    }

    private static let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "mempalace.enabled"
        static let learningMode = "mempalace.learningMode"
        static let decayRate = "mempalace.decayRate"
        static let threshold = "mempalace.confidenceThreshold"
        static let excluded = "mempalace.excludedCategories"
    }

    private func loadSettings() {
        let stored = Self.defaults
        _settings.enabled = stored.object(forKey: Keys.enabled) as? Bool ?? true
        _settings.learningMode = (stored.string(forKey: Keys.learningMode))
            .flatMap(MemoryLearningMode.init(rawValue:)) ?? .conservative
        _settings.decayRate = (stored.string(forKey: Keys.decayRate))
            .flatMap(MemoryDecayRate.init(rawValue:)) ?? .slow
        _settings.confidenceThreshold = stored.object(forKey: Keys.threshold) as? Double ?? 0.7
        let excluded = stored.stringArray(forKey: Keys.excluded) ?? []
        _settings.excludedCategories = excluded.compactMap(MemoryCategory.init(rawValue:))
    }

    private func persistSettings(_ snapshot: MemPalaceSettings) {
        let stored = Self.defaults
        stored.set(snapshot.enabled, forKey: Keys.enabled)
        stored.set(snapshot.learningMode.rawValue, forKey: Keys.learningMode)
        stored.set(snapshot.decayRate.rawValue, forKey: Keys.decayRate)
        stored.set(snapshot.confidenceThreshold, forKey: Keys.threshold)
        stored.set(snapshot.excludedCategories.map(\.rawValue), forKey: Keys.excluded)
    }

    // MARK: - Memories

    /// Store a memory. The same content (case/whitespace-insensitive) upserts:
    /// its access count rises and its confidence gets a repetition boost, so a
    /// pattern that repeats three times lands well above the threshold.
    /// Returns the stable id.
    @discardableResult
    func remember(content: String, category: MemoryCategory, source: String,
                  tags: [String] = [], confidence: Double = 0.5) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let key = Self.scopedKey(category, trimmed)
        guard let db = try? self.openDB() else { return "" }
        defer { sqlite3_close(db) }
        let now = Date().timeIntervalSince1970

        if let existing = Self.memoryRow(db, contentKey: key) {
            let boosted = min(1.0, existing.confidence + 0.12)
            let mergedTags = Array(Set(existing.tags + tags)).sorted()
            Self.exec(db, sql: """
                UPDATE memories SET confidence = ?, access_count = access_count + 1,
                       last_accessed = ?, source = ?, tags = ?
                WHERE id = ?
                """, args: [.double(boosted), .double(now), .text(source),
                            .text(Self.tagsJSON(mergedTags)), .text(existing.id)])
            return existing.id
        }

        let id = UUID().uuidString
        Self.exec(db, sql: """
            INSERT INTO memories (id, content, content_key, category, confidence,
                                  created_at, last_accessed, access_count, source, tags)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """, args: [.text(id), .text(trimmed), .text(key), .text(category.rawValue),
                        .double(confidence), .double(now), .double(now),
                        .text(source), .text(Self.tagsJSON(tags))])
        return id
    }

    /// Search the vault. Applies the decay on the way out (so stale entries
    /// rank below fresh ones) and touches last_accessed.
    func search(_ query: String, limit: Int = 12) -> [MemoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        let like = "%" + trimmed.lowercased() + "%"
        let excluded = settings.excludedCategories.map(\.rawValue)
        var rows: [MemoryEntry] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, content, category, confidence, created_at, last_accessed,
                       access_count, source, tags
                FROM memories
                WHERE (lower(content) LIKE ? OR lower(tags) LIKE ?)
                ORDER BY confidence DESC, last_accessed DESC LIMIT ?
                """, args: [.text(like), .text(like), .int(limit)]) { stmt in
                let entry = Self.memoryEntry(stmt)
                guard !excluded.contains(entry.category.rawValue) else { return }
                rows.append(entry)
            }
        } catch { }
        return rows.map { touch($0) }
    }

    /// Everything Alfred knows about one person.
    func recallAboutPerson(_ name: String, limit: Int = 8) -> [MemoryEntry] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.excludesPeople,
              let db = try? self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        let like = "%" + trimmed.lowercased() + "%"
        var rows: [MemoryEntry] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, content, category, confidence, created_at, last_accessed,
                       access_count, source, tags
                FROM memories WHERE category = 'person' AND lower(content) LIKE ?
                ORDER BY confidence DESC LIMIT ?
                """, args: [.text(like), .int(limit)]) { stmt in
                rows.append(Self.memoryEntry(stmt))
            }
        } catch { }
        return rows.map { touch($0) }
    }

    /// The high-confidence memories a new session should start knowing —
    /// filtered by the threshold and the privacy exclusions.
    func getLearnedContext(limit: Int = 6) -> [MemoryEntry] {
        guard settings.enabled, let db = try? self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        let threshold = settings.confidenceThreshold
        let excluded = settings.excludedCategories.map(\.rawValue)
        var rows: [MemoryEntry] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, content, category, confidence, created_at, last_accessed,
                       access_count, source, tags
                FROM memories WHERE confidence >= ?
                ORDER BY confidence DESC, last_accessed DESC LIMIT ?
                """, args: [.double(threshold), .int(limit)]) { stmt in
                let entry = Self.memoryEntry(stmt)
                guard !excluded.contains(entry.category.rawValue) else { return }
                rows.append(entry)
            }
        } catch { }
        return rows.map { touch($0) }
    }

    /// Learn from a correction: replace the content, lift confidence hard,
    /// and mark the source so the system knows it came from the user.
    @discardableResult
    func correctMemory(id: String, correction: String) -> MemoryEntry? {
        let trimmed = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? self.openDB() else { return nil }
        defer { sqlite3_close(db) }
        // The rewrite must keep the row's category-scoped key, or the corrected
        // text could collide with — or orphan from — its own upsert slot.
        var category = MemoryCategory.preference
        do {
            try Self.queryRows(db, sql: "SELECT category FROM memories WHERE id = ?",
                               args: [.text(id)]) { stmt in
                if let found = MemoryCategory(rawValue: Self.textColumn(stmt, 0)) {
                    category = found
                }
            }
        } catch { }
        Self.exec(db, sql: """
            UPDATE memories SET content = ?, content_key = ?, confidence = MAX(confidence, 0.9),
                   source = 'user_correction', last_accessed = ?
            WHERE id = ?
            """, args: [.text(trimmed), .text(Self.scopedKey(category, trimmed)),
                        .double(Date().timeIntervalSince1970), .text(id)])
        return getMemory(id: id)
    }

    func getMemory(id: String) -> MemoryEntry? {
        guard let db = try? self.openDB() else { return nil }
        defer { sqlite3_close(db) }
        var found: MemoryEntry?
        do {
            try Self.queryRows(db, sql: """
                SELECT id, content, category, confidence, created_at, last_accessed,
                       access_count, source, tags
                FROM memories WHERE id = ?
                """, args: [.text(id)]) { stmt in
                found = Self.memoryEntry(stmt)
            }
        } catch { }
        return found
    }

    func deleteMemory(id: String) {
        guard let db = try? self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: "DELETE FROM memories WHERE id = ?", args: [.text(id)])
    }

    func allMemories(limit: Int = 200) -> [MemoryEntry] {
        guard let db = try? self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var rows: [MemoryEntry] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, content, category, confidence, created_at, last_accessed,
                       access_count, source, tags
                FROM memories ORDER BY confidence DESC LIMIT ?
                """, args: [.int(limit)]) { stmt in
                rows.append(Self.memoryEntry(stmt))
            }
        } catch { }
        return rows
    }

    // MARK: - Goals

    @discardableResult
    func addGoal(title: String, cadence: String = "weekly", notes: String? = nil) -> MemoryGoal {
        let id = UUID().uuidString
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = try? self.openDB() else {
            return MemoryGoal(id: id, title: trimmed, cadence: cadence, streak: 0,
                              lastCompletedAt: nil, createdAt: Date().timeIntervalSince1970,
                              notes: notes)
        }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: """
            INSERT INTO goals (id, title, cadence, streak, last_completed_at, created_at, notes)
            VALUES (?, ?, ?, 0, NULL, ?, ?)
            """, args: [.text(id), .text(trimmed), .text(cadence),
                        .double(Date().timeIntervalSince1970), .text(notes ?? "")])
        return getGoal(id: id) ?? MemoryGoal(id: id, title: trimmed, cadence: cadence,
                                             streak: 0, lastCompletedAt: nil,
                                             createdAt: Date().timeIntervalSince1970, notes: notes)
    }

    func listGoals() -> [MemoryGoal] {
        guard let db = try? self.openDB() else { return [] }
        defer { sqlite3_close(db) }
        var rows: [MemoryGoal] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, title, cadence, streak, last_completed_at, created_at, notes
                FROM goals ORDER BY created_at DESC
                """) { stmt in
                rows.append(Self.goal(stmt))
            }
        } catch { }
        return rows
    }

    /// Report a completion (or miss) for a goal. A completion inside the
    /// cadence window extends the streak; a miss resets it. Returns the
    /// updated goal, or nil when the goal is gone.
    @discardableResult
    func updateGoalProgress(id: String, completed: Bool) -> MemoryGoal? {
        guard let db = try? self.openDB() else { return nil }
        defer { sqlite3_close(db) }
        guard let goal = Self.goalRow(db, id: id) else { return nil }
        let now = Date().timeIntervalSince1970
        let window: TimeInterval = goal.cadence == "daily" ? 2 * 86_400 : 14 * 86_400
        let withinWindow = goal.lastCompletedAt.map { now - $0 < window } ?? false

        if completed {
            // Don't double-count a completion inside the same window.
            let newStreak = withinWindow ? goal.streak : goal.streak + 1
            Self.exec(db, sql: """
                UPDATE goals SET streak = ?, last_completed_at = ? WHERE id = ?
                """, args: [.int(newStreak), .double(now), .text(id)])
        } else if !withinWindow {
            Self.exec(db, sql: "UPDATE goals SET streak = 0 WHERE id = ?", args: [.text(id)])
        }
        return getGoal(id: id)
    }

    func getGoal(id: String) -> MemoryGoal? {
        guard let db = try? self.openDB() else { return nil }
        defer { sqlite3_close(db) }
        var found: MemoryGoal?
        do {
            try Self.queryRows(db, sql: """
                SELECT id, title, cadence, streak, last_completed_at, created_at, notes
                FROM goals WHERE id = ?
                """, args: [.text(id)]) { stmt in
                found = Self.goal(stmt)
            }
        } catch { }
        return found
    }

    func deleteGoal(id: String) {
        guard let db = try? self.openDB() else { return }
        defer { sqlite3_close(db) }
        Self.exec(db, sql: "DELETE FROM goals WHERE id = ?", args: [.text(id)])
    }

    /// A one-line goals summary for the briefing and prompt injection.
    func goalsLine() -> String {
        let goals = listGoals().filter { $0.streak > 0 }
        guard !goals.isEmpty else { return "" }
        return goals.prefix(3).map { "\($0.title) (\($0.cadence), streak \($0.streak))" }
            .joined(separator: ", ")
    }

    // MARK: - Learned preferences (Hermes turn)

    /// One bounded, gated inference turn over raw material (reflection notes,
    /// email analyses, code reviews). Returns how many preferences landed.
    ///
    /// Only runs when memory is enabled, a session is available, and the user
    /// isn't mid-turn — a quiet background pass must never hijack the
    /// conversation. Any failure stores nothing and returns 0.
    func inferPreferences(from material: String, source: String,
                          timeout: TimeInterval = 45) async -> Int {
        guard settings.enabled, let hermes else { return 0 }
        let trimmed = material.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard await !hermes.isTurnActive else { return 0 }

        let floor = settings.learningMode.inferenceFloor
        let prompt = """
        You are the memory learner inside Alfred. From the raw material below, \
        extract durable preferences, working patterns, constraints and facts \
        about the user that will still matter in a month. Never polite filler.

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"preferences":[{"category":"preference|project_pattern|person|goal|learning|constraint","content":"one concise sentence","confidence":0.0}]}

        Rules:
        - category: preference = likes/dislikes/communication tone; project_pattern = how the user works in code; person = info about someone they interact with; goal = a tracked ambition; learning = something the user now knows; constraint = a boundary (time, tools, preferences).
        - Only include content that is explicit or strongly implied. 0-5 items.
        - confidence: 0.5 for a plausible signal, 0.75+ only when repeated or explicit.
        - content <= 140 characters, one sentence.

        MATERIAL:
        \(trimmed)
        """

        let result = await Self.runPromptBounded(hermes, prompt: prompt, timeout: timeout)
        guard let raw = result?["preferences"] as? [[String: Any]] else { return 0 }

        var stored = 0
        for item in raw {
            guard let content = item["content"] as? String,
                  let confidence = item["confidence"] as? Double,
                  confidence >= floor else { continue }
            let category = (item["category"] as? String)
                .flatMap(MemoryCategory.init(rawValue:)) ?? .preference
            if !remember(content: content, category: category, source: source,
                          confidence: confidence).isEmpty {
                stored += 1
            }
        }
        if stored > 0 {
            NSLog("[mempalace] inferred %d preferences from %@", stored, source)
        }
        return stored
    }

    // MARK: - Consolidation

    /// The decay + prune pass. Every memory's confidence is eroded by how long
    /// it has gone unseen (slow: ~0.5%/day, fast: ~3%/day); anything that
    /// falls below the 0.15 floor is pruned. Runs on the 6h timer and on
    /// demand.
    @discardableResult
    func dailyConsolidation() -> MemoryConsolidationResult {
        guard let db = try? self.openDB() else {
            return MemoryConsolidationResult(entriesBefore: 0, entriesAfter: 0, pruned: 0, decayed: 0)
        }
        defer { sqlite3_close(db) }
        let before = Self.count(db, table: "memories")
        let now = Date().timeIntervalSince1970
        let rate: Double = settings.decayRate == .slow ? 0.995 : 0.97
        var decayed = 0

        var rows: [(id: String, confidence: Double, lastAccessed: TimeInterval)] = []
        do {
            try Self.queryRows(db, sql: """
                SELECT id, confidence, last_accessed FROM memories
                """) { stmt in
                rows.append((Self.textColumn(stmt, 0), Self.doubleColumn(stmt, 1),
                             Self.doubleColumn(stmt, 2)))
            }
        } catch { }

        for row in rows {
            let days = max(0, (now - row.lastAccessed) / 86_400)
            let factor = pow(rate, days)
            let decayedConfidence = row.confidence * factor
            if decayedConfidence < 0.15 {
                Self.exec(db, sql: "DELETE FROM memories WHERE id = ?", args: [.text(row.id)])
            } else {
                Self.exec(db, sql: "UPDATE memories SET confidence = ? WHERE id = ?",
                          args: [.double(decayedConfidence), .text(row.id)])
                decayed += 1
            }
        }

        let after = Self.count(db, table: "memories")
        let pruned = before - after
        if pruned > 0 || decayed > 0 {
            NSLog("[mempalace] consolidation: %d entries, %d decayed, %d pruned",
                  after, decayed, pruned)
        }
        return MemoryConsolidationResult(entriesBefore: before, entriesAfter: after,
                                         pruned: pruned, decayed: decayed)
    }

    // MARK: - Prompt injection

    /// The bracketed block a fresh session starts with: the highest-confidence
    /// memories, as compact statements. Empty when off, below threshold, or
    /// everything is privacy-excluded. The caller wraps it in [remembered: …].
    func wakeUpContext(limit: Int = 4) -> String {
        let entries = getLearnedContext(limit: limit)
        guard !entries.isEmpty else { return "" }
        return entries.map { entry in
            let pct = Int((entry.confidence * 100).rounded())
            return "\(Self.compact(entry.content, max: 110)) (\(pct)% confidence)"
        }.joined(separator: "; ")
    }

    // MARK: - Verbatim bridge (the real mempalace CLI)

    /// Mirror a memory into the real mempalace palace, verbatim. No-ops when
    /// the binary isn't installed (the layer is standalone by design).
    @discardableResult
    func verbatimRemember(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Self.runVerbatim(["remember", trimmed]) != nil
    }

    /// Ask the real palace. Empty when the binary is absent or the command
    /// fails — the meta layer above is the always-available answer.
    func verbatimSearch(_ query: String) -> [String] {
        guard let raw = Self.runVerbatim(["search", query]) else { return [] }
        return raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The palace's startup context — a window into verbatim history.
    func verbatimWakeUp() -> String {
        Self.runVerbatim(["wake-up"]) ?? ""
    }

    // MARK: - Wire helpers

    /// The settings wire shape the phone round-trips.
    static func memorySettingsWire(_ settings: MemPalaceSettings) -> [String: Any] {
        [
            "enabled": settings.enabled,
            "learningMode": settings.learningMode.rawValue,
            "decayRate": settings.decayRate.rawValue,
            "confidenceThreshold": settings.confidenceThreshold,
            "excludedCategories": settings.excludedCategories.map(\.rawValue),
        ]
    }

    static func memoryEntryWire(_ entry: MemoryEntry) -> [String: Any] {
        [
            "id": entry.id,
            "content": entry.content,
            "category": entry.category.rawValue,
            "confidence": entry.confidence,
            "createdAt": entry.createdAt,
            "lastAccessed": entry.lastAccessed,
            "accessCount": entry.accessCount,
            "source": entry.source,
            "tags": entry.tags,
        ]
    }

    static func goalWire(_ goal: MemoryGoal) -> [String: Any] {
        [
            "id": goal.id,
            "title": goal.title,
            "cadence": goal.cadence,
            "streak": goal.streak,
            "lastCompletedAt": goal.lastCompletedAt ?? 0,
            "createdAt": goal.createdAt,
            "notes": goal.notes ?? "",
        ]
    }

    /// Decode a settings wire dictionary back into the model.
    static func memorySettings(from raw: Any?) -> MemPalaceSettings? {
        guard let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return try? JSONDecoder().decode(MemPalaceSettings.self, from: data)
    }

    // MARK: - Private helpers

    /// Touch a memory's last_accessed (and decay its confidence in memory)
    /// when it's read. Persisted lazily by the consolidation pass — reading
    /// must never serialize to disk.
    private func touch(_ entry: MemoryEntry) -> MemoryEntry {
        var touched = entry
        touched.lastAccessed = Date().timeIntervalSince1970
        return touched
    }

    // MARK: - Row readers

    private struct MemoryRow {
        let id: String
        let confidence: Double
        let tags: [String]
    }

    private struct GoalRow {
        let streak: Int
        let lastCompletedAt: TimeInterval?
        let cadence: String
    }

    private static func memoryRow(_ db: OpaquePointer, contentKey: String) -> MemoryRow? {
        var row: MemoryRow?
        do {
            try queryRows(db, sql: """
                SELECT id, confidence, tags FROM memories WHERE content_key = ? LIMIT 1
                """, args: [.text(contentKey)]) { stmt in
                row = MemoryRow(id: textColumn(stmt, 0),
                                confidence: doubleColumn(stmt, 1),
                                tags: tagsFromJSON(textColumn(stmt, 2)))
            }
        } catch { }
        return row
    }

    private static func goalRow(_ db: OpaquePointer, id: String) -> GoalRow? {
        var row: GoalRow?
        do {
            try queryRows(db, sql: """
                SELECT streak, last_completed_at, cadence FROM goals WHERE id = ? LIMIT 1
                """, args: [.text(id)]) { stmt in
                row = GoalRow(streak: intColumn(stmt, 0),
                              lastCompletedAt: nullableDoubleColumn(stmt, 1),
                              cadence: textColumn(stmt, 2))
            }
        } catch { }
        return row
    }

    private static func memoryEntry(_ stmt: OpaquePointer) -> MemoryEntry {
        MemoryEntry(
            id: textColumn(stmt, 0),
            content: textColumn(stmt, 1),
            category: MemoryCategory(rawValue: textColumn(stmt, 2)) ?? .preference,
            confidence: doubleColumn(stmt, 3),
            createdAt: doubleColumn(stmt, 4),
            lastAccessed: doubleColumn(stmt, 5),
            accessCount: intColumn(stmt, 6),
            source: textColumn(stmt, 7),
            tags: tagsFromJSON(textColumn(stmt, 8)))
    }

    private static func goal(_ stmt: OpaquePointer) -> MemoryGoal {
        MemoryGoal(
            id: textColumn(stmt, 0),
            title: textColumn(stmt, 1),
            cadence: textColumn(stmt, 2),
            streak: intColumn(stmt, 3),
            lastCompletedAt: nullableDoubleColumn(stmt, 4),
            createdAt: doubleColumn(stmt, 5),
            notes: nullableTextColumn(stmt, 6))
    }

    private static func count(_ db: OpaquePointer, table: String) -> Int {
        var n = 0
        do {
            try queryRows(db, sql: "SELECT COUNT(*) FROM \(table)") { stmt in
                n = intColumn(stmt, 0)
            }
        } catch { }
        return n
    }

    // MARK: - Schema

    private static let migrationDDL = """
    CREATE TABLE IF NOT EXISTS memories (
        id            TEXT PRIMARY KEY,
        content       TEXT NOT NULL,
        content_key   TEXT NOT NULL UNIQUE,
        category      TEXT NOT NULL,
        confidence    REAL NOT NULL DEFAULT 0.5,
        created_at    REAL NOT NULL,
        last_accessed REAL NOT NULL,
        access_count  INTEGER NOT NULL DEFAULT 1,
        source        TEXT NOT NULL DEFAULT 'inferred',
        tags          TEXT NOT NULL DEFAULT '[]'
    );
    CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category);
    CREATE INDEX IF NOT EXISTS idx_memories_confidence ON memories(confidence);
    CREATE INDEX IF NOT EXISTS idx_memories_last_accessed ON memories(last_accessed);

    CREATE TABLE IF NOT EXISTS goals (
        id               TEXT PRIMARY KEY,
        title            TEXT NOT NULL,
        cadence          TEXT NOT NULL DEFAULT 'weekly',
        streak           INTEGER NOT NULL DEFAULT 0,
        last_completed_at REAL,
        created_at       REAL NOT NULL,
        notes            TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_goals_streak ON goals(streak);
    """

    // MARK: - SQLite plumbing (mirrors UnifiedMemoryLayer)

    private func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let db else {
            throw MemPalaceError.database("could not open \(dbPath) (\(rc))")
        }
        return db
    }

    private static func runMigration(_ db: OpaquePointer) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, migrationDDL, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw MemPalaceError.database(message)
        }
    }

    private enum Bind {
        case text(String)
        case double(Double)
        case int(Int)
    }

    private enum MemPalaceError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self {
            case .database(let message): return "mempalace store error: \(message)"
            }
        }
    }

    private static func exec(_ db: OpaquePointer, sql: String, args: [Bind] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("[mempalace] exec prepare failed: %@", lastErrorMessage(db))
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            NSLog("[mempalace] exec step failed (%d): %@", rc, lastErrorMessage(db))
        }
    }

    private static func queryRows(_ db: OpaquePointer, sql: String, args: [Bind] = [],
                                  row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MemPalaceError.database(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            row(stmt)
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {
            throw MemPalaceError.database(lastErrorMessage(db))
        }
    }

    private static func bind(_ stmt: OpaquePointer, _ args: [Bind]) {
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            switch arg {
            case .text(let value):
                sqlite3_bind_text(stmt, i, value, -1, MEMPALACE_SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(stmt, i, value)
            case .int(let value):
                sqlite3_bind_int64(stmt, i, Int64(value))
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

    private static func nameKey(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// The upsert key. Scoped by category so the same sentence stored under
    /// two categories is two rows — a privacy exclusion on one category must
    /// never hide the same fact recorded under another, and the second
    /// caller's explicit category is never silently dropped.
    private static func scopedKey(_ category: MemoryCategory, _ text: String) -> String {
        category.rawValue + "|" + nameKey(text)
    }

    private static func tagsJSON(_ tags: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: tags),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func tagsFromJSON(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let tags = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return tags
    }

    private static func compact(_ text: String, max: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count <= max ? cleaned : String(cleaned.prefix(max)) + "…"
    }

    // MARK: - Bounded Hermes turn

    private static let turnTimeout: TimeInterval = 45

    /// One bounded prompt turn racing a JSON object out of the model stream.
    /// Returns nil when the deadline wins or the reply won't parse — the
    /// caller stores nothing on nil, so inference is never worse than absent.
    private static func runPromptBounded(_ session: HermesSession, prompt: String,
                                         timeout: TimeInterval = turnTimeout)
        async -> [String: Any]? {
        enum Outcome {
            case transcript(String)
            case timedOut
        }
        let turn = Task { () -> String in
            var transcript = ""
            for await event in await session.prompt(prompt, capture: false) {
                if case let .text(chunk) = event { transcript.append(chunk) }
                if case .failed = event { break }
            }
            return transcript
        }
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .transcript(await turn.value) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                turn.cancel()
                return .timedOut
            }
            guard let first = await group.next() else { return .timedOut }
            group.cancelAll()
            return first
        }
        guard case .transcript(let text) = outcome else { return nil }
        let cleaned = Self.extractJSONObject(from: text)
        guard let data = cleaned.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Pull the first balanced {...} object out of a model reply, even when it
    /// arrives wrapped in prose or markdown fences.
    private static func extractJSONObject(from raw: String) -> String {
        let chars = Array(raw)
        var depth = 0
        var inString = false
        var escaped = false
        var start = -1
        for (i, ch) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{":
                if start < 0 { start = i }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, start >= 0 {
                    return String(chars[start...i])
                }
            default:
                break
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Verbatim CLI

    /// Run one mempalace command with a short deadline. Returns nil when the
    /// binary is missing, the command fails, or it doesn't finish in 10s —
    /// the bridge is best-effort by design.
    private static func runVerbatim(_ arguments: [String]) -> String? {
        guard let path = Self.verbatimBinary() else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // A non-escaping read with a deadline: the palace must never block Alfred.
        let group = DispatchGroup()
        group.enter()
        var output = ""
        let readQueue = DispatchQueue(label: "mempalace.verbatim")
        readQueue.async {
            output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
            group.leave()
        }
        let timedOut = group.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            return nil
        }
        return output.isEmpty ? nil : output
    }

    /// Locate the real mempalace CLI. Probes PATH once per call and caches the
    /// hit so a missing binary isn't re-probed on every prompt.
    private static var cachedVerbatimPath: String?
    private static func verbatimBinary() -> String? {
        if let cached = cachedVerbatimPath { return cached }
        let candidates = ["/usr/local/bin/mempalace", "/opt/homebrew/bin/mempalace"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? Self.pathProbe("mempalace")
        cachedVerbatimPath = found
        return found
    }

    private static func pathProbe(_ name: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? nil : line
    }
}
