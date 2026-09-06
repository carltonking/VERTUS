import Combine
import Foundation

// MARK: - Per-agent live state

/// Observable per-agent state: transcript, running flags, activity, queue
/// depth, last run. One instance per agent id, owned by FleetStore.
public final class AgentLiveState: ObservableObject, Identifiable {
    @Published public private(set) var transcript: [TranscriptEntry] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var queueDepth = 0
    @Published public private(set) var currentActivity: String?
    @Published public private(set) var lastRunID: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var unreadCount = 0
    @Published public private(set) var hasLoadedHistory = false
    /// Declared screen targets this agent's turn is blocked on, each naming
    /// its holder. Empty while the agent runs or is idle.
    @Published public private(set) var blockedOnTarget: [BlockedTarget] = []
    /// v4: readable reason while the agent's gateway is failing/thrashing.
    @Published public private(set) var degraded: String?
    /// v4: seconds since the engine last emitted anything (status polling).
    @Published public private(set) var silenceS: Double = 0

    /// "waiting on Safari (held by doc)" — shown in the roster.
    public var blockedSummary: String? {
        blockedOnTarget.first.map { "waiting on \($0.summary)" }
    }

    public var isBlocked: Bool { !blockedOnTarget.isEmpty }

    public var isDegraded: Bool { degraded != nil }

    public let agentID: String
    public var id: String { agentID }

    /// Runs whose live stream has been fully consumed (terminal event seen)
    /// or whose folded message rows were loaded from history. Events replayed
    /// by since= for these runs are skipped — they are already in the
    /// transcript. Guarded by the main actor (FleetStore is @MainActor).
    private(set) var knownRuns: Set<String> = []

    init(agentID: String) {
        self.agentID = agentID
    }

    func markKnown(_ runID: String) { knownRuns.insert(runID) }

    /// Append a live text delta to the newest assistant entry of the same
    /// run, or open a new one.
    func appendDelta(runID: String, text: String) {
        if var last = transcript.last, last.role == "assistant", last.runId == runID {
            last.text += text
            transcript[transcript.count - 1] = last
        } else {
            transcript.append(TranscriptEntry(runId: runID, role: "assistant",
                                              text: text, isDelta: true))
        }
    }

    func appendLocalUserEntry(runID: String, text: String) {
        transcript.append(TranscriptEntry(runId: runID, role: "user", text: text))
    }

    /// Merge a history page (newest-first) into the transcript with the
    /// dedupe rule: any (runId, role) already present is skipped — that run's
    /// text is already on screen (live deltas or an earlier page). The
    /// current in-flight run's user entry and partial deltas are therefore
    /// never duplicated by the boundary fetch.
    /// Returns the id of the oldest message in the page (scroll-back cursor).
    func mergeHistoryPage(_ rows: [MessageRow]) -> Int? {
        let present = Set(transcript.map { "\($0.runId)|\($0.role)" })
        var oldestID: Int?
        var additions: [TranscriptEntry] = []
        for row in rows {
            if oldestID == nil || row.id < oldestID! { oldestID = row.id }
            guard !present.contains("\(row.runId)|\(row.role)") else { continue }
            additions.append(TranscriptEntry(runId: row.runId, role: row.role,
                                             text: row.text, messageID: row.id))
            markKnown(row.runId)
        }
        guard !additions.isEmpty else { return oldestID }
        // Newest-first page → ascending, prepended above the live tail. The
        // (runId, role) dedupe already ran; every surviving row is absent
        // from the transcript.
        transcript = additions.reversed() + transcript
        return oldestID
    }

    func bumpUnread() { unreadCount += 1 }
    func clearUnread() { unreadCount = 0 }
    func setActivity(_ text: String?) { currentActivity = text }
    func setRunning(_ running: Bool) { isRunning = running }
    func setQueueDepth(_ depth: Int) { queueDepth = depth }
    func setBlockedTargets(_ targets: [BlockedTarget]) { blockedOnTarget = targets }
    func setDegraded(_ reason: String?) { degraded = reason }
    func setSilence(_ seconds: Double) { silenceS = seconds }
    func setLastRun(_ runID: String?) { lastRunID = runID }
    func setError(_ message: String?) { lastError = message }
    func setHistoryLoaded() { hasLoadedHistory = true }

    /// Joined transcript text (drives auto-scroll follow in any client).
    public var transcriptText: String {
        transcript.map(\.text).joined()
    }

    /// Test support: simulate a fresh window that never saw the live tail.
    func resetForFreshWindow() {
        transcript = []
        knownRuns.removeAll()
    }

    /// Test support: expose the fully-consumed run set.
    var knownRunsForTest: Set<String> { knownRuns }
}

// MARK: - FleetStore

/// The one place both apps hold fleet state. A single fleet SSE stream
/// (FleetStream) feeds every agent's AgentLiveState; the store owns the
/// run-dedup rules that make since= replay gap-free AND duplicate-free.
@MainActor
public final class FleetStore: ObservableObject {
    @Published public private(set) var agents: [Agent] = []
    @Published public private(set) var connectionState: FleetStream.ConnectionState = .idle
    @Published public private(set) var lastSyncError: String?
    /// Declared-target roster from GET /api/fleet/screens (refreshScreens).
    @Published public private(set) var screens: FleetScreensResponse?
    /// Agent currently displayed in the foreground window (drives unread +
    /// notification suppression; written to the shared UI file too).
    @Published public var foregroundAgentID: String? {
        didSet { SharedUIState.setForegroundAgentID(foregroundAgentID) }
    }
    /// Agent selected in the sidebar / bar picker.
    @Published public var selectedAgentID: String? {
        didSet {
            if let id = selectedAgentID { live[id]?.clearUnread() }
        }
    }

    public let client: VertusHTTPClient
    public let stream: FleetStream

    @Published public private(set) var live: [String: AgentLiveState] = [:]
    /// Fired when a background run reaches a terminal state (any agent that
    /// is not foregrounded). Fleet app wires this to User Notifications.
    public var onBackgroundCompletion: ((Agent, WireEvent) -> Void)?

    private var statusPollTask: Task<Void, Never>?
    private var statusPolling = false
    private var latestByAgent: [String: WireEvent] = [:]

    public init(client: VertusHTTPClient, stream: FleetStream) {
        self.client = client
        self.stream = stream
        stream.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        stream.onLagged = { [weak self] _ in
            Task { @MainActor in self?.onLagged() }
        }
        // Mirror the stream's connection state into the store.
        stream.$connectionState
            .receive(on: RunLoop.main)
            .assign(to: &$connectionState)
    }

    // MARK: - Lifecycle

    public func start() {
        stream.start()
        pollStatusIfNeeded()
        Task { await refreshAgents() }
        Task { await refreshScreens() }
    }

    /// GET /api/fleet/screens (called on start, on status-poll cycles, and
    /// on demand). Best-effort: the roster is a live convenience, not state.
    public func refreshScreens() async {
        do {
            screens = try await client.fleetScreens()
        } catch {
            // Keep the last known roster; never surface noise for a busy UI.
        }
    }

    public func stop() {
        stream.stop()
        statusPollTask?.cancel()
        statusPollTask = nil
    }

    /// Re-fetch the roster (after CRUD, on connect, on demand).
    public func refreshAgents() async {
        do {
            agents = try await client.listAgents()
            // Seed live state for every roster agent (cheap, never spawns a
            // bridge on the hub: it's a plain registry read).
            for agent in agents where live[agent.id] == nil {
                live[agent.id] = AgentLiveState(agentID: agent.id)
            }
            if selectedAgentID == nil { selectedAgentID = agents.first?.id }
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    public func agent(_ id: String) -> Agent? {
        agents.first { $0.id == id }
    }

    // MARK: - Event intake (main actor)

    private func handle(_ event: WireEvent) {
        guard let agentID = event.agentId else { return }
        let state = liveState(for: agentID)
        guard let runID = event.runId else { return }

        // Dedup rule: events for a fully-consumed run are never replayed into
        // the transcript (already there, folded or delta-tagged).
        guard !state.knownRuns.contains(runID) else { return }

        switch event.type {
        case "text":
            if let text = event.text, !text.isEmpty {
                state.appendDelta(runID: runID, text: text)
            }
            state.setRunning(true)
            state.setLastRun(runID)
            noteActivity(agentID: agentID, event: event)
            pollStatusIfNeeded()
        case "activity":
            if let text = event.text { state.setActivity(text) }
            state.setRunning(true)
            state.setLastRun(runID)
            pollStatusIfNeeded()
        case "done", "error", "cancelled":
            state.markKnown(runID)
            state.setRunning(false)
            state.setQueueDepth(0)
            state.setActivity(nil)
            if event.type == "error" {
                state.setError(event.message ?? "run failed")
            }
            // Background completion notification + unread (a cancelled
            // background run still deserves the unread marker — the user
            // asked for it and it stopped).
            if foregroundAgentID != agentID, let agent = agent(agentID) {
                state.bumpUnread()
                onBackgroundCompletion?(agent, event)
            }
        case "lagged":
            break // FleetStream reconnects; the replay covers the gap
        default:
            break
        }
    }

    private func noteActivity(agentID: String, event: WireEvent) {
        latestByAgent[agentID] = event
    }

    /// Latest wire event per agent — the sidebar's one-liner "what it's
    /// doing now" reads the newest activity/text event.
    public func latestActivityText(for agentID: String) -> String? {
        guard let event = latestByAgent[agentID] else { return nil }
        return event.text
    }

    /// Human label for an agent id (display name, else raw id) — roster and
    /// screens views render holder/waiter ids through this.
    public func displayName(for agentID: String) -> String {
        agents.first { $0.id == agentID }?.displayName ?? agentID
    }

    private func onLagged() {
        // The stream is reconnecting with since=<cursor>; surface state.
        lastSyncError = "stream lagged — reconnecting"
    }

    private func liveState(for agentID: String) -> AgentLiveState {
        if let s = live[agentID] { return s }
        let s = AgentLiveState(agentID: agentID)
        live[agentID] = s
        return s
    }

    // MARK: - Actions

    /// Submit a prompt. Returns immediately with the run_id; busy agents
    /// queue server-side (queueDepth shows via status polling). Never blocks
    /// and never disables the composer.
    @discardableResult
    public func submit(agentID: String, text: String,
                       sourceLabel: String = "local") async throws -> String {
        let acceptance = try await client.prompt(agentID: agentID, text: text,
                                                 sourceLabel: sourceLabel)
        let state = liveState(for: agentID)
        state.appendLocalUserEntry(runID: acceptance.runId, text: text)
        state.setRunning(true)
        state.setQueueDepth(1)
        state.setLastRun(acceptance.runId)
        pollStatusIfNeeded()
        return acceptance.runId
    }

    // MARK: - History

    /// Load the newest page of an agent's folded messages and merge it into
    /// the transcript (deduped against live entries). Idempotent.
    public func loadHistory(agentID: String, limit: Int = 50) async {
        let state = liveState(for: agentID)
        do {
            let rows = try await client.messages(agentID: agentID, limit: limit)
            _ = state.mergeHistoryPage(rows)
            state.setHistoryLoaded()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    /// Scroll-back: fetch the page older than `oldestMessageID` and prepend.
    public func loadOlderMessages(agentID: String, beforeID: Int, limit: Int = 50) async {
        let state = liveState(for: agentID)
        do {
            let rows = try await client.messages(agentID: agentID, limit: limit,
                                                 before: beforeID)
            _ = state.mergeHistoryPage(rows)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    // MARK: - Status polling

    /// Poll /status for busy agents (2s) so queueDepth and gateway liveness
    /// stay current even when SSE is quiet. Stops when nothing is busy.
    private func pollStatusIfNeeded() {
        guard !statusPolling else { return }
        statusPolling = true
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = self.live.values.filter { $0.isRunning || $0.queueDepth > 0 }
                if busy.isEmpty {
                    self.statusPolling = false
                    return
                }
                for state in busy {
                    do {
                        let status = try await self.client.status(state.agentID)
                        state.setQueueDepth(status.queueDepth)
                        state.setBlockedTargets(status.blockedOnTarget ?? [])
                        state.setDegraded(status.degraded)
                        state.setSilence(status.silenceS ?? 0)
                        if status.state == "running" {
                            state.setRunning(true)
                        } else if !status.isBusy {
                            state.setRunning(false)
                            state.setActivity(nil)
                        }
                    } catch {
                        // Hub briefly down; keep the last known state.
                    }
                }
                await self.refreshScreens()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self?.statusPolling = false
        }
    }

    // MARK: - CRUD passthrough (typed errors surface in the UI)

    public func createAgent(name: String, title: String? = nil,
                            description: String? = nil, persona: String? = nil,
                            model: String? = nil, provider: String? = nil,
                            color: String? = nil, emoji: String? = nil,
                            autonomy: String? = nil, computerUse: Bool? = nil,
                            cuaTargets: [String]? = nil,
                            clearTargets: Bool = false) async throws -> Agent {
        let agent = try await client.createAgent(name: name, title: title,
                                                 description: description,
                                                 persona: persona, model: model,
                                                 provider: provider, color: color,
                                                 emoji: emoji, autonomy: autonomy,
                                                 computerUse: computerUse,
                                                 cuaTargets: cuaTargets,
                                                 clearTargets: clearTargets)
        await refreshAgents()
        return agent
    }

    public func updateAgent(_ id: String, title: String? = nil,
                            description: String? = nil, persona: String? = nil,
                            model: String? = nil, provider: String? = nil,
                            color: String? = nil, emoji: String? = nil,
                            autonomy: String? = nil, computerUse: Bool? = nil,
                            cuaTargets: [String]? = nil,
                            clearTargets: Bool = false) async throws -> (Agent, Bool) {
        let (agent, pending) = try await client.updateAgent(id, title: title,
                                                            description: description,
                                                            persona: persona,
                                                            model: model,
                                                            provider: provider,
                                                            color: color,
                                                            emoji: emoji,
                                                            autonomy: autonomy,
                                                            computerUse: computerUse,
                                                            cuaTargets: cuaTargets,
                                                            clearTargets: clearTargets)
        await refreshAgents()
        // A PATCH may have changed cua_targets/autonomy; the in-memory copy
        // returned is authoritative for the caller's editor state.
        return (agent, pending)
    }

    public func deleteAgent(_ id: String) async throws -> DeleteResult {
        let result = try await client.deleteAgent(id)
        live.removeValue(forKey: id)
        if selectedAgentID == id {
            selectedAgentID = agents.first { $0.id != id }?.id
        }
        await refreshAgents()
        return result
    }

    // MARK: - Cancellation (supervision)

    /// Stop whatever the agent is doing now (the active run). Returns the
    /// cancelled run id; throws the hub's typed error (409 when idle).
    @discardableResult
    public func stopAgent(_ id: String) async throws -> String {
        let runID = try await client.cancelAgent(id)
        live[id]?.setRunning(false)
        return runID
    }

    /// Cancel one run; `drainQueue` also clears the agent's pending queue.
    @discardableResult
    public func stopRun(_ runID: String, drainQueue: Bool = false) async throws -> String {
        let (cancelled, _) = try await client.cancelRun(runID, drainQueue: drainQueue)
        return cancelled
    }
}