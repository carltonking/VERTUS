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

    // MARK: - 1b. Leading newline in the first streamed delta is trimmed
    // (bug: a "\n\n" preamble from the model rendered as a blank line above
    // the text inside every live assistant bubble; folded history rows were
    // already normalized, so only the live path showed the gap)

    func testLeadingNewlineInFirstDeltaIsTrimmed() async throws {
        let a = try await makeAgent("alpha")
        // The model's first delta commonly begins with a blank-line preamble.
        hub.inject(type: "text", agentID: a.id, runID: "r-a", payload: ["text": "\n\nSir, here is the answer."])
        hub.inject(type: "text", agentID: a.id, runID: "r-a", payload: ["text": " It continues here."])
        hub.inject(type: "done", agentID: a.id, runID: "r-a")

        let ok = await waitUntil {
            let s = self.store.live[a.id]
            return s?.transcriptText == "Sir, here is the answer. It continues here."
        }
        XCTAssertTrue(ok, "transcript: \(String(describing: store.live[a.id]?.transcriptText))")
        // Mid-stream leading space (word separation) must survive untouched.
        let entry = store.live[a.id]!.transcript.last!
        XCTAssertTrue(entry.text.contains("answer. It"), "word-joining space was trimmed: \(entry.text)")
    }

    func testWhitespaceOnlyFirstDeltaOpensNoBlankEntry() async throws {
        let a = try await makeAgent("alpha")
        // A first delta that is entirely whitespace must not open an empty
        // entry — the next real delta starts the bubble.
        hub.inject(type: "text", agentID: a.id, runID: "r-a", payload: ["text": "\n\n"])
        hub.inject(type: "text", agentID: a.id, runID: "r-a", payload: ["text": "Hi"])
        hub.inject(type: "done", agentID: a.id, runID: "r-a")

        let ok = await waitUntil {
            let s = self.store.live[a.id]
            return s?.transcriptText == "Hi"
        }
        XCTAssertTrue(ok, "transcript: \(String(describing: store.live[a.id]?.transcriptText))")
        let entries = store.live[a.id]!.transcript.filter { $0.role == "assistant" }
        XCTAssertEqual(entries.count, 1, "whitespace-only delta created a blank entry")
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

    // MARK: - 11. Message bus wire surface (threads, messages, run tree)

    func testThreadsAndMessagesDecodeAndMarkRead() async throws {
        let a = try await makeAgent("alpha")
        let b = try await makeAgent("beta")
        hub.addBotThread([
            "thread_id": "t-1", "subject": "delegation",
            "participants": [a.id, b.id],
            "created_at": 100.0, "last_message_at": 200.0, "unread": 2,
        ])
        hub.addBotMessage([
            "msg_id": "m-1", "from_agent": a.id, "to_agent": b.id,
            "thread_id": "t-1", "body": "do the thing", "kind": "handoff",
            "depth": 1, "status": "delivered", "run_id": "r-child",
            "created_at": 200.0, "read_at": nil as Any? ?? NSNull(),
        ])
        await store.refreshThreads()
        XCTAssertEqual(store.threads.count, 1)
        let thread = store.threads[0]
        XCTAssertEqual(thread.subject, "delegation")
        XCTAssertEqual(thread.participants.sorted(), [a.id, b.id].sorted())
        XCTAssertEqual(thread.unread, 2)

        let msgs = try await store.botMessages(threadID: "t-1")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].kind, "handoff")
        XCTAssertEqual(msgs[0].depth, 1)
        XCTAssertEqual(msgs[0].fromAgent, a.id)

        await store.markThreadRead("t-1")
        XCTAssertEqual(store.threads[0].unread, 0, "mark-read refreshes the list")
    }

    func testRunDetailDecodesDelegationTree() async throws {
        let a = try await makeAgent("alpha")
        let b = try await makeAgent("beta")
        let parentRun: [String: Any] = [
            "run_id": "r-parent", "agent_id": a.id, "prompt": "do it",
            "remote": 0, "source": "local", "state": "done",
            "created_at": 1.0, "started_at": 1.0, "ended_at": 2.0,
            "error": nil as Any?, "gateway_respawns": 0,
            "from_agent": nil as Any?, "run_kind": "user",
        ]
        let childRun: [String: Any] = [
            "run_id": "r-child", "agent_id": b.id, "prompt": "the task",
            "remote": 0, "source": "bot:\(a.id)", "state": "done",
            "created_at": 2.0, "started_at": 2.0, "ended_at": 3.0,
            "error": nil as Any?, "gateway_respawns": 0,
            "from_agent": a.id, "thread_id": "t-1", "run_kind": "handoff",
            "parent_run_id": "r-parent",
        ]
        hub.addRun(parentRun)
        hub.addRun(childRun)

        let child = try await store.runDetail("r-child")
        XCTAssertEqual(child.run.runKind, "handoff")
        XCTAssertTrue(child.run.isBotInitiated)
        XCTAssertEqual(child.parent?.runId, "r-parent")
        XCTAssertTrue(child.children.isEmpty)

        let parent = try await store.runDetail("r-parent")
        XCTAssertEqual(parent.children.count, 1)
        XCTAssertEqual(parent.children[0].runId, "r-child")
        XCTAssertNil(parent.parent)
    }

    func testWorkingForDerivesFromActivity() async throws {
        let a = try await makeAgent("alpha")
        let b = try await makeAgent("beta")
        // B is mid-turn on a handoff from A.
        hub.addRun([
            "run_id": "r-live", "agent_id": b.id, "prompt": "task",
            "remote": false, "source": "bot:\(a.id)", "state": "running",
            "created_at": 5.0, "started_at": 5.0, "ended_at": nil as Any?,
            "error": nil as Any?, "gateway_respawns": 0,
            "from_agent": a.id, "thread_id": "t-1", "run_kind": "handoff",
            "parent_run_id": nil as Any?,
        ])
        await store.refreshActivity()
        XCTAssertEqual(store.workingFor(b.id), "alpha", "busy bot-initiated run names the boss")
        XCTAssertNil(store.workingFor(a.id), "user-initiated/idle agents have no boss")
        // A run for another agent that is NOT busy must not mask the marker.
        hub.addRun([
            "run_id": "r-stale", "agent_id": b.id, "prompt": "old",
            "remote": false, "source": "local", "state": "done",
            "created_at": 4.0, "started_at": 4.0, "ended_at": 5.0,
            "error": nil as Any?, "gateway_respawns": 0,
            "from_agent": nil as Any?, "run_kind": "user",
            "parent_run_id": nil as Any?,
        ])
        await store.refreshActivity()
        XCTAssertEqual(store.workingFor(b.id), "alpha")
    }

    // MARK: VERTUS_HUB_URL precedence (VERTUS_HUB_URL > UserDefaults > default)

    func testHubURLPrecedence() throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "vertus.baseURL")
        defer { if let prior { defaults.set(prior, forKey: "vertus.baseURL") } else { defaults.removeObject(forKey: "vertus.baseURL") } }

        defaults.set("http://defaults-host:1111", forKey: "vertus.baseURL")

        // Env wins over defaults.
        let env = ServerConfig.load(environment: ["VERTUS_HUB_URL": "http://env-host:2222"])
        XCTAssertEqual(env.baseURL, "http://env-host:2222")

        // Defaults win over the built-in default.
        let defs = ServerConfig.load(environment: [:])
        XCTAssertEqual(defs.baseURL, "http://defaults-host:1111")

        // Neither present -> built-in default.
        defaults.removeObject(forKey: "vertus.baseURL")
        let fallback = ServerConfig.load(environment: [:])
        XCTAssertEqual(fallback.baseURL, "http://127.0.0.1:8787")
    }

    // MARK: Hub health

    func testHubHealthDecodesRealPayload() throws {
        let json: [String: Any] = [
            "status": "degraded",
            "time": 1234,
            "uptime_s": 3600,
            "subsystems": [
                "store": ["ok": true, "reason": "writer round-trip 0.4ms"],
                "routines": ["ok": false, "reason": "scheduler thread dead"],
            ],
            "agents": 2,
            "running_runs": 1,
            "degraded_agents": [["agent_id": "scout", "reason": "gateway down"]],
            "scheduler_next_fire": 1788658061,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let health = try JSONDecoder.vertus().decode(HubHealth.self, from: data)
        XCTAssertEqual(health.status, "degraded")
        XCTAssertEqual(health.failingSubsystems, ["routines"])
        XCTAssertFalse(health.isHealthy)
        XCTAssertEqual(health.agents, 2)
        XCTAssertEqual(health.degradedAgents?.first?.agentId, "scout")
    }

    func testHubHealthToleratesLegacyShapes() throws {
        // The stub hub answers {"ok": true} — old shape, no new keys.
        let legacy = try JSONDecoder.vertus().decode(HubHealth.self, from:
            JSONSerialization.data(withJSONObject: ["ok": true]))
        XCTAssertEqual(legacy.status, "ok")
        XCTAssertTrue(legacy.isHealthy)
        // Historical real shape {"status", "time"} only.
        let historical = try JSONDecoder.vertus().decode(HubHealth.self, from:
            JSONSerialization.data(withJSONObject: ["status": "ok", "time": 9]))
        XCTAssertEqual(historical.status, "ok")
        XCTAssertEqual(historical.time, 9)
    }

    // MARK: Routines

    func testRoutineCRUDRoundTrip() async throws {
        let agent = try await makeAgent("alpha")

        let created = try await store.createRoutine(
            agentID: agent.id, name: "Nightly scan", prompt: "scan for drift",
            intervalS: 3600,
            trigger: RoutineTrigger(type: "run_completed", agentId: agent.id))
        XCTAssertEqual(created.schedule?.intervalS, 3600)
        XCTAssertEqual(created.trigger?.type, "run_completed")
        XCTAssertEqual(created.humanSchedule, "every 1h")
        XCTAssertTrue(created.enabled)

        await store.refreshRoutines()
        let listed = store.routines(for: agent.id)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].routineId, created.routineId)

        let patched = try await store.updateRoutine(created.routineId, enabled: false)
        XCTAssertFalse(patched.enabled)

        try await store.deleteRoutine(created.routineId)
        await store.refreshRoutines()
        XCTAssertTrue(store.routines.isEmpty)
    }

    func testRunNowFiresAndAttributesRun() async throws {
        let agent = try await makeAgent("alpha")
        let routine = try await store.createRoutine(
            agentID: agent.id, name: "R", prompt: "do it",
            intervalS: 86400)  // far future: run-now must ignore the schedule
        let runID = try await store.runRoutineNow(routine.routineId)
        XCTAssertEqual(runID, "run-1")
        let runs = try await store.client.runs(agentID: agent.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].runKind, "routine")
        XCTAssertTrue(runs[0].isRoutine)
        // Routine row records the fire.
        await store.refreshRoutines()
        XCTAssertEqual(store.routines.first?.lastRunId, runID)
        // Never-concurrent: the queued run blocks a second run-now → 409.
        do {
            _ = try await store.runRoutineNow(routine.routineId)
            XCTFail("second run-now should 409 while the first run is active")
        } catch VertusError.conflict(let message) {
            XCTAssertTrue(message.contains("already running"))
        }
    }

    func testRoutineHistoryAndDisabledByFailures() async throws {
        let agent = try await makeAgent("alpha")
        let routine = try await store.createRoutine(
            agentID: agent.id, name: "Fragile", prompt: "x",
            intervalS: 60)
        _ = try await store.runRoutineNow(routine.routineId)
        let history = try await store.client.routineHistory(routine.routineId)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].routineId, routine.routineId)

        // A routine disabled after failures decodes and flags loudly.
        let disabled = try JSONDecoder.vertus().decode(Routine.self, from:
            JSONSerialization.data(withJSONObject: routineJson(
                routineId: routine.routineId, agentId: agent.id,
                failureCount: 3, enabled: false)))
        XCTAssertTrue(disabled.disabledByFailures)
        XCTAssertEqual(disabled.humanSchedule, "every 1m")
        let fine = try JSONDecoder.vertus().decode(Routine.self, from:
            JSONSerialization.data(withJSONObject: routineJson(
                routineId: "r2", agentId: agent.id,
                failureCount: 1, enabled: false)))
        XCTAssertFalse(fine.disabledByFailures, "1 failure is not a disable")
    }

    private func routineJson(routineId: String, agentId: String,
                             failureCount: Int, enabled: Bool) -> [String: Any] {
        [
            "routine_id": routineId,
            "agent_id": agentId,
            "name": "R",
            "prompt": "p",
            "schedule": ["interval_s": 60],
            "trigger": NSNull(),
            "enabled": enabled,
            "created_at": 1.0,
            "last_run_at": NSNull(),
            "last_run_id": NSNull(),
            "next_run_at": 61.0,
            "failure_count": failureCount,
        ]
    }

    // MARK: - 14. Memory (hub-owned canonical store)

    /// List / read / write / delete round-trip through the real client path,
    /// plus the event-driven refresh: a write fans out memory_changed and the
    /// store re-fetches the index without a manual refresh.
    func testMemoryListReadWriteDeleteRoundTrip() async throws {
        let alpha = try await makeAgent("alpha")
        hub.seedMemory(scope: "shared", agentID: nil, path: "profile.md",
                       content: "The user is Carlton.", writer: "external")
        await store.refreshMemory()

        let seeded = try await waitUntil {
            self.store.memoryEntries.contains {
                $0.scope == "shared" && $0.path == "profile.md"
                    && $0.writer == "external"
            }
        }
        XCTAssertTrue(seeded, "seeded entry should list after refreshMemory")

        // Write through the client — the emitted memory_changed event must
        // refresh the store's index by itself.
        let write = try await store.client.writeMemory(
            scope: "agent", agentID: alpha.id, path: "notes/todo.md",
            content: "ship the fleet")
        XCTAssertEqual(write.written, "notes/todo.md")
        XCTAssertEqual(write.scope, "agent")
        XCTAssertEqual(write.agentId, alpha.id)

        let listed = await waitUntil {
            self.store.memoryEntries.contains {
                $0.scope == "agent" && $0.agentId == alpha.id
                    && $0.path == "notes/todo.md"
            }
        }
        XCTAssertTrue(listed, "write should appear in the store via memory_changed")

        // Read back the content.
        let content = try await store.client.memoryContent(
            scope: "agent", agentID: alpha.id, path: "notes/todo.md")
        XCTAssertEqual(content.content, "ship the fleet")

        // Delete; the store's index empties again via the delete event.
        try await store.client.deleteMemory(scope: "agent", agentID: alpha.id,
                                            path: "notes/todo.md")
        let gone = await waitUntil {
            !self.store.memoryEntries.contains {
                $0.scope == "agent" && $0.agentId == alpha.id
                    && $0.path == "notes/todo.md"
            }
        }
        XCTAssertTrue(gone, "deleted entry should leave the store's index")
    }

    /// Search hits across scopes with a snippet; shared vs per-agent scoping
    /// is respected by the list endpoint.
    func testMemorySearchAndScoping() async throws {
        let alpha = try await makeAgent("alpha")
        let beta = try await makeAgent("beta")
        hub.seedMemory(scope: "shared", agentID: nil, path: "profile.md",
                       content: "The user is Carlton King.", writer: "human")
        hub.seedMemory(scope: "agent", agentID: alpha.id, path: "private.md",
                       content: "alpha's favorite color is blue.", writer: "alpha")
        hub.seedMemory(scope: "agent", agentID: beta.id, path: "private.md",
                       content: "beta prefers green.", writer: "beta")
        await store.refreshMemory()

        let hits = try await store.client.searchMemory("Carlton")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].scope, "shared")
        XCTAssertEqual(hits[0].path, "profile.md")

        let shared = try await store.client.memoryEntries(scope: "shared")
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared[0].scope, "shared")

        let alphaOnly = try await store.client.memoryEntries(scope: "agent",
                                                             agentID: alpha.id)
        XCTAssertEqual(alphaOnly.count, 1)
        XCTAssertEqual(alphaOnly[0].agentId, alpha.id)
        XCTAssertEqual(alphaOnly[0].path, "private.md")

        let all = try await store.client.memoryEntries(scope: "all")
        XCTAssertEqual(all.count, 3)
    }

    /// A memory_changed event with no run_id (bot write, detected by the hub
    /// watcher) refreshes the store and carries attribution. In the real hub
    /// the event is emitted only after the file is written and indexed, so
    /// the stub seeds the file first, exactly like the hub's write path.
    func testMemoryChangedEventCarriesAttribution() async throws {
        _ = try await makeAgent("alpha")
        await store.refreshMemory()

        hub.seedMemory(scope: "shared", agentID: nil, path: "notes/from-bot.md",
                       content: "alpha learned something", writer: "alpha")
        hub.inject(type: "memory_changed",
                   payload: ["scope": "shared", "agent_id": "",
                             "path": "notes/from-bot.md", "action": "write",
                             "writer": "alpha"])

        let seen = await waitUntil {
            self.store.memoryEntries.contains {
                $0.scope == "shared" && $0.path == "notes/from-bot.md"
                    && $0.writer == "alpha"
            }
        }
        XCTAssertTrue(seen, "memory_changed should refresh the store's index")
        // Memory events must not disturb run-scoped state: no transcript
        // text, no running flag.
        if let live = store.live.first(where: { $0.key == "alpha" })?.value {
            XCTAssertEqual(live.transcriptText, "", "memory events must not add transcript text")
            XCTAssertFalse(live.isRunning, "memory events must not touch run state")
        }
    }
}