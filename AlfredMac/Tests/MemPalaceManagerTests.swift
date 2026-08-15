import XCTest
import SQLite3
@testable import Alfred

// SQLITE_TRANSIENT is a C macro, invisible to Swift; -1 tells SQLite to copy the
// bound string before the statement is finalized.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Deterministic tests for MemPalaceManager — no model involved. Each test
/// gets a throwaway database in the temp dir, mirroring
/// CareerOpsManagerTests' directoryOverride pattern.
final class MemPalaceManagerTests: XCTestCase {

    private var manager: MemPalaceManager!
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mempalace-test-\(UUID().uuidString)")
            .appendingPathComponent("mempalace.db")
            .path
        // Settings live in UserDefaults; reset so test order never matters.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "mempalace.enabled")
        defaults.removeObject(forKey: "mempalace.learningMode")
        defaults.removeObject(forKey: "mempalace.decayRate")
        defaults.removeObject(forKey: "mempalace.confidenceThreshold")
        defaults.removeObject(forKey: "mempalace.excludedCategories")
        manager = MemPalaceManager(dbPathOverride: dbPath)
        manager.updateSettings { $0.enabled = true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            atPath: (dbPath as NSString).deletingLastPathComponent)
        manager = nil
        dbPath = nil
        super.tearDown()
    }

    // MARK: - remember / repetition boost

    func testRememberCreatesEntry() {
        let id = manager.remember(content: "Prefers async code patterns",
                                  category: .preference, source: "manual",
                                  confidence: 0.6)
        XCTAssertFalse(id.isEmpty)
        let entry = manager.getMemory(id: id)
        XCTAssertEqual(entry?.content, "Prefers async code patterns")
        XCTAssertEqual(entry?.category, .preference)
        XCTAssertEqual(entry?.accessCount, 1)
        XCTAssertEqual(entry?.confidence ?? 0, 0.6, accuracy: 0.001)
    }

    /// The spec's headline: a pattern that repeats 3+ times lands with high
    /// confidence. Each repeat adds +0.12, so 0.5 → 0.74 at three stores.
    func testRepetitionBoostCrossesThreshold() {
        let id = manager.remember(content: "Casual tone with friends",
                                  category: .preference, source: "email_analysis",
                                  confidence: 0.5)
        for _ in 0..<2 {
            manager.remember(content: "  casual tone with friends  ",
                             category: .preference, source: "email_analysis",
                             confidence: 0.5)
        }
        let entry = manager.getMemory(id: id)
        XCTAssertEqual(entry?.accessCount, 3)
        XCTAssertEqual(entry?.confidence ?? 0, 0.74, accuracy: 0.001)
        // Same id — the upsert path, not a duplicate row.
        XCTAssertEqual(manager.allMemories().count, 1)
    }

    func testRememberIgnoresBlankContent() {
        let id = manager.remember(content: "   ", category: .preference,
                                  source: "manual", confidence: 0.5)
        XCTAssertTrue(id.isEmpty)
        XCTAssertTrue(manager.allMemories().isEmpty)
    }

    /// The same sentence under two categories is two rows: excluding one
    /// category must not hide the fact recorded under the other.
    func testSameContentUnderTwoCategoriesStaysDistinct() {
        let asPerson = manager.remember(content: "Sarah prefers bullet points",
                                        category: .person, source: "email_analysis",
                                        confidence: 0.9)
        let asPreference = manager.remember(content: "Sarah prefers bullet points",
                                            category: .preference, source: "inferred",
                                            confidence: 0.8)
        XCTAssertNotEqual(asPerson, asPreference)
        XCTAssertEqual(manager.allMemories().count, 2)
        XCTAssertEqual(manager.recallAboutPerson("sarah").count, 1)
        XCTAssertEqual(manager.getLearnedContext().count, 2)

        // Excluding people hides only the person copy.
        manager.updateSettings { $0.excludedCategories = [.person] }
        XCTAssertTrue(manager.recallAboutPerson("sarah").isEmpty)
        XCTAssertEqual(manager.getLearnedContext().count, 1)
        XCTAssertEqual(manager.getLearnedContext().first?.category, .preference)
    }

    // MARK: - search / recallAboutPerson

    func testSearchFindsByContentAndTag() {
        _ = manager.remember(content: "Loves functional programming",
                             category: .preference, source: "manual",
                             tags: ["swift", "fp"], confidence: 0.8)
        _ = manager.remember(content: "Prefers dark mode everywhere",
                             category: .preference, source: "manual", confidence: 0.8)

        let byContent = manager.search("functional")
        XCTAssertEqual(byContent.count, 1)
        XCTAssertEqual(byContent.first?.content, "Loves functional programming")

        let byTag = manager.search("fp")
        XCTAssertEqual(byTag.count, 1)
    }

    func testRecallAboutPerson() {
        _ = manager.remember(content: "Sarah prefers bullet points",
                             category: .person, source: "email_analysis", confidence: 0.8)
        _ = manager.remember(content: "Uses pytest", category: .projectPattern,
                             source: "code_review", confidence: 0.8)

        let about = manager.recallAboutPerson("sarah")
        XCTAssertEqual(about.count, 1)
        XCTAssertEqual(about.first?.category, .person)
    }

    /// Privacy: excluded categories never leak into recall or learned context.
    func testExcludedCategoryHidesPersonMemory() {
        manager.updateSettings { $0.excludedCategories = [.person] }
        _ = manager.remember(content: "Sarah prefers bullet points",
                             category: .person, source: "email_analysis", confidence: 0.9)

        XCTAssertTrue(manager.recallAboutPerson("sarah").isEmpty)
        XCTAssertTrue(manager.getLearnedContext().isEmpty)
        // Search still hides it too.
        XCTAssertTrue(manager.search("sarah").isEmpty)
    }

    // MARK: - corrections

    /// "Actually, I prefer X over Y" — the correction replaces the content and
    /// lifts confidence to at least 0.9, and marks the source.
    func testCorrectMemoryBoostsAndReplaces() {
        let id = manager.remember(content: "Prefers coffee", category: .preference,
                                  source: "inferred", confidence: 0.5)
        let corrected = manager.correctMemory(id: id, correction: "Actually, prefers tea, not coffee")
        XCTAssertEqual(corrected?.content, "Actually, prefers tea, not coffee")
        XCTAssertEqual(corrected?.confidence ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(corrected?.source, "user_correction")
    }

    // MARK: - learned context threshold

    func testLearnedContextOnlyAboveThreshold() {
        _ = manager.remember(content: "Clear signal", category: .preference,
                             source: "manual", confidence: 0.9)
        _ = manager.remember(content: "Weak signal", category: .preference,
                             source: "manual", confidence: 0.4)
        let context = manager.getLearnedContext()
        XCTAssertEqual(context.count, 1)
        XCTAssertEqual(context.first?.content, "Clear signal")
    }

    func testLearnedContextEmptyWhenDisabled() {
        _ = manager.remember(content: "Clear signal", category: .preference,
                             source: "manual", confidence: 0.9)
        manager.updateSettings { $0.enabled = false }
        XCTAssertTrue(manager.getLearnedContext().isEmpty)
        XCTAssertTrue(manager.wakeUpContext().isEmpty)
    }

    // MARK: - decay / consolidation

    func testSlowDecayErodesSlowly() {
        let id = manager.remember(content: "Old but true", category: .learning,
                                  source: "manual", confidence: 0.9)
        // Simulate 30 days of disuse: rewrite last_accessed directly via a
        // second manager hitting the same DB (cheap, deterministic).
        let old = Date().timeIntervalSince1970 - 30 * 86_400
        rewriteLastAccessed(id: id, to: old)

        let result = manager.dailyConsolidation()
        let entry = manager.getMemory(id: id)
        // 0.9 * 0.995^30 ≈ 0.774
        XCTAssertEqual(entry?.confidence ?? 0, 0.9 * pow(0.995, 30), accuracy: 0.005)
        XCTAssertEqual(result.decayed, 1)
        XCTAssertEqual(result.pruned, 0)
    }

    func testFastDecayPrunesStale() {
        let id = manager.remember(content: "Very stale", category: .learning,
                                  source: "manual", confidence: 0.5)
        manager.updateSettings { $0.decayRate = .fast }
        let old = Date().timeIntervalSince1970 - 40 * 86_400
        rewriteLastAccessed(id: id, to: old)

        let result = manager.dailyConsolidation()
        // 0.5 * 0.97^40 ≈ 0.144 < 0.15 floor → pruned.
        XCTAssertEqual(result.pruned, 1)
        XCTAssertNil(manager.getMemory(id: id))
    }

    func testRecentMemorySurvivesFastDecay() {
        let id = manager.remember(content: "Fresh", category: .learning,
                                  source: "manual", confidence: 0.9)
        manager.updateSettings { $0.decayRate = .fast }
        let result = manager.dailyConsolidation()
        XCTAssertEqual(result.pruned, 0)
        XCTAssertNotNil(manager.getMemory(id: id))
    }

    // MARK: - goals

    func testGoalStreakExtendsAndResets() {
        let goal = manager.addGoal(title: "Exercise 3x/week", cadence: "weekly")
        XCTAssertEqual(goal.streak, 0)

        let completed = manager.updateGoalProgress(id: goal.id, completed: true)
        XCTAssertEqual(completed?.streak, 1)

        // A second completion in the same window doesn't double count.
        let again = manager.updateGoalProgress(id: goal.id, completed: true)
        XCTAssertEqual(again?.streak, 1)

        // A real miss: the window lapses with no completion, then a miss is
        // reported → the streak resets.
        let old = Date().timeIntervalSince1970 - 15 * 86_400
        rewriteGoalCompletion(id: goal.id, to: old)
        let missed = manager.updateGoalProgress(id: goal.id, completed: false)
        XCTAssertEqual(missed?.streak, 0)
    }

    func testGoalStreakExtendsAcrossWindows() {
        let goal = manager.addGoal(title: "Read daily", cadence: "daily")

        // Completion now, then a completion >2 days later — each extends.
        _ = manager.updateGoalProgress(id: goal.id, completed: true)
        var updated = manager.getGoal(id: goal.id)
        XCTAssertEqual(updated?.streak, 1)

        let old = Date().timeIntervalSince1970 - 3 * 86_400
        rewriteGoalCompletion(id: goal.id, to: old)
        updated = manager.updateGoalProgress(id: goal.id, completed: true)
        XCTAssertEqual(updated?.streak, 2)
    }

    func testDeleteGoal() {
        let goal = manager.addGoal(title: "Learn Rust", cadence: "weekly")
        manager.deleteGoal(id: goal.id)
        XCTAssertNil(manager.getGoal(id: goal.id))
        XCTAssertTrue(manager.listGoals().isEmpty)
    }

    func testGoalsLine() {
        let goal = manager.addGoal(title: "Exercise", cadence: "weekly")
        _ = manager.updateGoalProgress(id: goal.id, completed: true)
        XCTAssertTrue(manager.goalsLine().contains("Exercise"))
        XCTAssertTrue(manager.goalsLine().contains("streak 1"))
    }

    // MARK: - settings round trip

    func testSettingsDefaults() {
        XCTAssertTrue(manager.settings.enabled)
        XCTAssertEqual(manager.settings.learningMode, .conservative)
        XCTAssertEqual(manager.settings.decayRate, .slow)
        XCTAssertEqual(manager.settings.confidenceThreshold, 0.7, accuracy: 0.001)
        XCTAssertTrue(manager.settings.excludedCategories.isEmpty)
    }

    func testSettingsMutationPersists() {
        manager.updateSettings {
            $0.enabled = false
            $0.learningMode = .aggressive
            $0.decayRate = .fast
            $0.confidenceThreshold = 0.5
            $0.excludedCategories = [.person, .constraint]
        }
        // A fresh manager on the same DB reads the same UserDefaults? No —
        // settings live in UserDefaults, so a fresh instance sees them.
        let fresh = MemPalaceManager(dbPathOverride: dbPath)
        XCTAssertFalse(fresh.settings.enabled)
        XCTAssertEqual(fresh.settings.learningMode, .aggressive)
        XCTAssertEqual(fresh.settings.decayRate, .fast)
        XCTAssertEqual(fresh.settings.confidenceThreshold, 0.5, accuracy: 0.001)
        XCTAssertEqual(fresh.settings.excludedCategories, [.person, .constraint])
    }

    // MARK: - wire helpers

    func testWireShapes() {
        let entry = manager.remember(content: "Prefers async", category: .preference,
                                     source: "manual", tags: ["swift"], confidence: 0.8)
        guard let stored = manager.getMemory(id: entry) else {
            return XCTFail("missing entry")
        }
        let wire = MemPalaceManager.memoryEntryWire(stored)
        XCTAssertEqual(wire["id"] as? String, stored.id)
        XCTAssertEqual(wire["category"] as? String, "preference")
        XCTAssertEqual(wire["confidence"] as? Double ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(wire["tags"] as? [String], ["swift"])

        let goal = manager.addGoal(title: "Run", cadence: "daily")
        let goalWire = MemPalaceManager.goalWire(goal)
        XCTAssertEqual(goalWire["cadence"] as? String, "daily")
        XCTAssertEqual(goalWire["streak"] as? Int, 0)

        let settingsWire = MemPalaceManager.memorySettingsWire(manager.settings)
        XCTAssertEqual(settingsWire["enabled"] as? Bool, true)
        XCTAssertEqual(settingsWire["learningMode"] as? String, "conservative")
        let decoded = MemPalaceManager.memorySettings(from: settingsWire)
        XCTAssertEqual(decoded, manager.settings)
    }

    func testWakeUpContextFormat() {
        _ = manager.remember(content: "Prefers functional programming over OOP",
                             category: .preference, source: "manual", confidence: 0.95)
        let context = manager.wakeUpContext()
        XCTAssertTrue(context.contains("Prefers functional programming"))
        XCTAssertTrue(context.contains("95% confidence"))
    }

    // MARK: - Helpers

    private func rewriteLastAccessed(id: String, to date: TimeInterval) {
        let dbPath = self.dbPath!
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "UPDATE memories SET last_accessed = ? WHERE id = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_double(stmt, 1, date)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func rewriteGoalCompletion(id: String, to date: TimeInterval) {
        let dbPath = self.dbPath!
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "UPDATE goals SET last_completed_at = ? WHERE id = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_double(stmt, 1, date)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}
