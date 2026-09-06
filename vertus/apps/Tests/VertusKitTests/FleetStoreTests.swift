import XCTest
@testable import VertusKit

/// VertusKit tests against the hermetic StubHub (raw sockets, real client
/// path). FleetStore is @MainActor; the test class is too.
@MainActor
final class FleetStoreTests: XCTestCase {
    private var hub: StubHub!
    private var store: FleetStore!
    private var uiDir: URL!

    override func setUp() async throws {
        hub = StubHub()
        try hub.start()
        uiDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vertus-ui-\(UUID().uuidString)", isDirectory: true)
        setenv("VERTUS_UI_DIR", uiDir.path, 1)
        let config = ServerConfig(baseURL: "http://127.0.0.1:\(hub.port)", token: "test-token")
        let cursor = StreamCursor(processName: "test-\(UUID().uuidString)")
        let client = VertusHTTPClient(config: config)
        let stream = FleetStream(config: config, cursor: cursor)
        store = FleetStore(client: client, stream: stream)
        store.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    override func tearDown() async throws {
        store.stop()
        hub.stop()
        try? FileManager.default.removeItem(at: uiDir)
    }

    // MARK: - Helpers

    private func makeAgent(_ name: String) async throws -> Agent {
        try await store.createAgent(name: name)
    }

    private func waitUntil(timeout: TimeInterval = 6,
                           _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    // MARK: - 1. Fleet stream demultiplexes three agents

    func testFleetStreamDemultiplexesThreeAgents() async throws {
        let a = try await makeAgent("alpha")
        let b = try await makeAgent("beta")
        let c = try await makeAgent("gamma")

        // Interleave deltas for all three in one stream.
        hub.inject(type: "text", agentID: a.id, runID: "r-a", payload: ["text": "A1"])
        hub.inject(type: "text", agentID: b.id, runID: "r-b", payload: ["text": "B1"])
        hub.inject(type: "text", agentID: a.id, runID: "r-a", payload: ["text": "A2"])
        hub.inject(type: "text", agentID: c.id, runID: "r-c", payload: ["text": "C1"])
        hub.inject(type: "activity", agentID: b.id, runID: "r-b", payload: ["text": "thinking…"])
        hub.inject(type: "text", agentID: b.id, runID: "r-b", payload: ["text": "B2"])
        hub.inject(type: "done", agentID: a.id, runID: "r-a")
        hub.inject(type: "done", agentID: c.id, runID: "r-c")
        hub.inject(type: "done", agentID: b.id, runID: "r-b")

        let ok = await waitUntil {
            let sa = self.store.live[a.id]
            let sb = self.store.live[b.id]
            let sc = self.store.live[c.id]
            return sa?.transcriptText == "A1A2"
                && sb?.transcriptText == "B1B2"
                && sc?.transcriptText == "C1"
                && sa?.isRunning == false
                && sb?.isRunning == false
                && sc?.isRunning == false
        }
        XCTAssertTrue(ok, "transcripts: \(store.live.mapValues(\.transcriptText))")

        // No cross-agent leakage.
        let sa = store.live[a.id]
        XCTAssertFalse(sa!.transcript.contains { $0.text.contains("B") || $0.text.contains("C") })
        let sb = store.live[b.id]
        XCTAssertFalse(sb!.transcript.contains { $0.text.contains("A") || $0.text.contains("C") })
    }

    // MARK: - 2. since= resume after a forced disconnect: no gap, no duplicate

    func testResumeAfterForcedDisconnectNoGapNoDuplicate() async throws {
        let a = try await makeAgent("alpha")
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "1"])
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "2"])
        let got2 = await waitUntil { self.store.live[a.id]?.transcriptText == "12" }
        XCTAssertTrue(got2)

        // Drop the connection; the client reconnects with since=<cursor>.
        hub.dropAllSSE()

        // Emit more events while disconnected: they only land in the log.
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "3"])
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "4"])
        hub.inject(type: "done", agentID: a.id, runID: "r1")

        // The reconnect replays (cursor, ∞) — gap filled exactly once.
        let ok = await waitUntil(timeout: 8) {
            let t = self.store.live[a.id]?.transcriptText
            return t == "1234" && self.store.live[a.id]?.isRunning == false
        }
        XCTAssertTrue(ok, "transcript: \(String(describing: store.live[a.id]?.transcriptText))")
        // The single assistant entry carries the whole run: no duplicate text.
        let entries = store.live[a.id]!.transcript
        XCTAssertEqual(entries.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(entries.last?.text, "1234")
    }

    // MARK: - 3. lagged marker triggers reconnect and recovers the span

    func testLaggedTriggersReconnectAndRecoversSpan() async throws {
        let a = try await makeAgent("alpha")
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "1"])
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "2"])
        let got2 = await waitUntil { self.store.live[a.id]?.transcriptText == "12" }
        XCTAssertTrue(got2)

        // Overflow: the hub drops the subscriber, so 3/4/5 land in the log
        // and the client never sees them; the lagged marker says so.
        hub.dropAllSSE()
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "3"])
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "4"])
        hub.inject(type: "text", agentID: a.id, runID: "r1", payload: ["text": "5"])
        hub.inject(type: "lagged", agentID: a.id, payload: ["last_seq": 7])
        hub.inject(type: "done", agentID: a.id, runID: "r1")

        // Reconnect (since=cursor) replays 3/4/5 exactly once; the replayed
        // lagged marker triggers a further immediate reconnect that finds
        // nothing new.
        let ok = await waitUntil(timeout: 8) {
            self.store.live[a.id]?.transcriptText == "12345"
                && self.store.live[a.id]?.isRunning == false
        }
        XCTAssertTrue(ok, "transcript: \(String(describing: store.live[a.id]?.transcriptText))")
        let entries = store.live[a.id]!.transcript
        XCTAssertEqual(entries.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(entries.last?.text, "12345")
    }

    // MARK: - 4. Busy agent queues rather than blocking

    func testBusyAgentQueuesRatherThanBlocks() async throws {
        let a = try await makeAgent("alpha")

        // First turn: real submit (creates a stub run row) then activity.
        let run1 = try await store.submit(agentID: a.id, text: "first prompt")
        hub.inject(type: "activity", agentID: a.id, runID: run1, payload: ["text": "working…"])
        hub.inject(type: "text", agentID: a.id, runID: run1, payload: ["text": "busy…"])
        let running = await waitUntil { self.store.live[a.id]?.isRunning == true }
        XCTAssertTrue(running, "agent should be running after the first turn")

        // While busy: a second submit must NOT throw and must NOT wait for
        // the first turn — the hub queues it and queue depth is shown.
        hub.forceQueueDepth = 1
        let run2 = try await store.submit(agentID: a.id, text: "second prompt")
        XCTAssertFalse(run2.isEmpty)
        XCTAssertNotEqual(run2, run1)
        // The user entry is on screen even though the agent is busy.
        let last = store.live[a.id]!.transcript.last
        XCTAssertEqual(last?.role, "user")
        XCTAssertEqual(last?.text, "second prompt")
        // Two prompt POSTs reached the hub.
        let prompts = hub.received.filter { $0.method == "POST" && $0.path == "/api/prompt" }
        XCTAssertEqual(prompts.count, 2)
    }

    // MARK: - 5. History pagination merges with live deltas, no boundary dup

    func testHistoryPaginationMergesWithoutDuplicatingBoundary() async throws {
        let a = try await makeAgent("alpha")

        // Run 1: submit (user row written at enqueue), stream, finish.
        let run1 = try await store.submit(agentID: a.id, text: "first prompt")
        hub.inject(type: "text", agentID: a.id, runID: run1, payload: ["text": "reply one"])
        hub.inject(type: "done", agentID: a.id, runID: run1)
        let done1 = await waitUntil { self.store.live[a.id]?.isRunning == false }
        XCTAssertTrue(done1)

        // Run 2: submit and stream, but DON'T finish — the live tail.
        let run2 = try await store.submit(agentID: a.id, text: "second prompt")
        hub.inject(type: "text", agentID: a.id, runID: run2, payload: ["text": "reply two"])
        let deltas = await waitUntil {
            self.store.live[a.id]?.transcriptText.contains("reply two") == true
        }
        XCTAssertTrue(deltas)

        // Fresh history load (the page contains the in-flight run's user row
        // AND run1's folded rows): nothing may duplicate.
        await store.loadHistory(agentID: a.id, limit: 10)
        let t = store.live[a.id]!.transcript
        XCTAssertEqual(t.filter { $0.role == "user" }.count, 2, "user entries: \(t)")
        XCTAssertEqual(t.filter { $0.role == "assistant" }.count, 2, "assistant entries: \(t)")
        XCTAssertEqual(t[0].role, "user")
        XCTAssertEqual(t[0].text, "first prompt")
        XCTAssertEqual(t[1].text, "reply one")
        XCTAssertEqual(t[2].text, "second prompt")
        XCTAssertEqual(t[3].text, "reply two")

        // Run 2 finishes (its folded row is what a fresh window reads).
        hub.inject(type: "done", agentID: a.id, runID: run2)
        _ = await waitUntil {
            self.store.live[a.id]?.knownRunsForTest.contains(run2) == true
        }

        // Run 3 (older than run 2): a tiny page-1 (limit 2) makes the newest
        // rows only; scroll-back must prepend the older pages without dupes.
        let run3 = try await store.submit(agentID: a.id, text: "third prompt")
        hub.inject(type: "text", agentID: a.id, runID: run3, payload: ["text": "reply three"])
        hub.inject(type: "done", agentID: a.id, runID: run3)
        _ = await waitUntil {
            self.store.live[a.id]?.knownRunsForTest.contains(run3) == true
        }

        // Reset the transcript the way a fresh window would: newest page only.
        store.live[a.id]!.resetForFreshWindow()
        await store.loadHistory(agentID: a.id, limit: 2)   // newest 2 rows
        var after = store.live[a.id]!.transcript
        XCTAssertTrue(after.contains { $0.text == "third prompt" }, "\(after.map(\.text))")
        let oldest = after.map(\.messageID).compactMap { $0 }.min()!

        await store.loadOlderMessages(agentID: a.id, beforeID: oldest, limit: 10)
        after = store.live[a.id]!.transcript
        let texts = after.map(\.text)
        XCTAssertEqual(texts, ["first prompt", "reply one", "second prompt", "reply two", "third prompt", "reply three"],
                       "merged order after scroll-back: \(texts)")
    }

    // MARK: - 6. Agent CRUD round-trips; 409s surface as typed errors

    func testAgentCRUDRoundTripsAndTyped409s() async throws {
        // Create with the full v2 field set.
        let created = try await store.createAgent(
            name: "ada",
            title: "Ada Lovelace",
            description: "analyst",
            persona: "You are Ada.",
            model: "model-x",
            provider: "provider-y",
            color: "#123456",
            emoji: "🦊",
            autonomy: "trusted"
        )
        XCTAssertEqual(created.name, "ada")
        XCTAssertEqual(created.title, "Ada Lovelace")
        XCTAssertEqual(created.persona, "You are Ada.")
        XCTAssertEqual(created.model, "model-x")
        XCTAssertEqual(created.provider, "provider-y")
        XCTAssertEqual(created.color, "#123456")
        XCTAssertEqual(created.emoji, "🦊")
        XCTAssertEqual(created.autonomy, "trusted")
        XCTAssertEqual(created.schemaVersion, 2)
        XCTAssertTrue(created.isPrimary, "first agent is primary")

        // List round-trip.
        let listed = try await store.client.listAgents()
        XCTAssertTrue(listed.contains { $0.id == created.id })

        // PATCH round-trip.
        let (updated, pending1) = try await store.updateAgent(
            created.id, title: "Countess", persona: "You are Ada, countess.",
            model: "model-z"
        )
        XCTAssertEqual(updated.title, "Countess")
        XCTAssertEqual(updated.persona, "You are Ada, countess.")
        XCTAssertEqual(updated.model, "model-z")
        XCTAssertFalse(pending1)

        hub.respawnPending = true
        let (_, pending2) = try await store.updateAgent(created.id, description: "x")
        XCTAssertTrue(pending2, "PATCH during a turn reports a pending respawn")

        // DELETE succeeds for a non-primary agent.
        let second = try await makeAgent("grace")
        let deleted = try await store.deleteAgent(second.id)
        XCTAssertEqual(deleted.deleted, second.id)
        XCTAssertTrue(deleted.archivedTo.contains(".trash"))
        let after = try await store.client.listAgents()
        XCTAssertFalse(after.contains { $0.id == second.id })

        // DELETE on the primary agent → typed 409 with the hub's message.
        do {
            _ = try await store.deleteAgent(created.id)
            XCTFail("primary delete should have thrown")
        } catch let error as VertusError {
            guard case .conflict(let message) = error else {
                return XCTFail("expected conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("primary"), "message: \(message)")
        }
    }

    // MARK: - 8. Cancellation (supervision)

    func testCancelAgentStopsActiveRunAndSurfacesIdle409() async throws {
        let agent = try await makeAgent("doc")
        // A run in flight (the stub flips it running on the first text event).
        let runID = try await store.submit(agentID: agent.id, text: "busy")
        hub.inject(type: "text", agentID: agent.id, runID: runID, payload: ["text": "d1"])

        let cancelled = try await store.stopAgent(agent.id)
        XCTAssertEqual(cancelled, runID, "agent cancel returns the active run id")
        // The stub emitted the cancelled event; the store must treat it as a
        // terminal event (running cleared, no error).
        let ok = await waitUntil {
            self.store.live[agent.id]?.isRunning == false
        }
        XCTAssertTrue(ok, "cancelled event clears the running marker")
        XCTAssertNil(store.live[agent.id]?.lastError, "cancel is not an error")

        // Idle agent → typed 409 with the hub's message.
        do {
            _ = try await store.stopAgent(agent.id)
            XCTFail("idle cancel should have thrown")
        } catch let error as VertusError {
            guard case .conflict(let message) = error else {
                return XCTFail("expected conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("idle"), "message: \(message)")
        }
    }

    func testCancelRunDrainsQueue() async throws {
        let agent = try await makeAgent("doc")
        let run1 = try await store.submit(agentID: agent.id, text: "first")
        hub.inject(type: "text", agentID: agent.id, runID: run1, payload: ["text": "d1"])
        let run2 = try await store.submit(agentID: agent.id, text: "second")
        let run3 = try await store.submit(agentID: agent.id, text: "third")

        // Without drain: only the target run is cancelled.
        _ = try await store.stopRun(run1)
        let runs = try await store.client.runs(agentID: agent.id)
        let state = { (rid: String) in runs.first { $0.runId == rid }?.state }
        XCTAssertEqual(state(run1), "cancelled")
        XCTAssertEqual(state(run2), "queued", "a plain cancel keeps the queue")
        XCTAssertEqual(state(run3), "queued")

        // With drain: everything still queued for that agent is cancelled.
        _ = try await store.stopRun(run2, drainQueue: true)
        let runs2 = try await store.client.runs(agentID: agent.id)
        let state2 = { (rid: String) in runs2.first { $0.runId == rid }?.state }
        XCTAssertEqual(state2(run2), "cancelled")
        XCTAssertEqual(state2(run3), "cancelled", "drain_queue clears the pending queue")
    }

    func testCancelTerminalRunIsConflict() async throws {
        let agent = try await makeAgent("doc")
        let runID = try await store.submit(agentID: agent.id, text: "fast")
        hub.inject(type: "done", agentID: agent.id, runID: runID)
        do {
            _ = try await store.stopRun(runID)
            XCTFail("terminal cancel should have thrown")
        } catch let error as VertusError {
            guard case .conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
    }

    func testStatusCarriesSupervisionFields() async throws {
        let agent = try await makeAgent("doc")
        let status = try await store.client.status(agent.id)
        XCTAssertEqual(status.stallTimeoutS ?? 0, 180, "v4 stall limit decodes")
        XCTAssertEqual(status.hardTimeoutS ?? 0, 3600)
        XCTAssertNil(status.degraded)
        XCTAssertEqual(status.silenceS ?? 0, 0)
        XCTAssertFalse(status.isBusy)
    }
}