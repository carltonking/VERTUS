import AppKit
import Combine
import Foundation
import VertusKit

/// QuickBar client, refactored onto VertusKit. The bar now runs the SAME
/// fleet-wide SSE stream as the Fleet app (its own process cursor), holds
/// per-agent live state in a FleetStore, and submits fire-and-forget: busy
/// agents queue server-side, the panel closing never abandons a run.
@MainActor
final class QuickBarViewModel: ObservableObject {
    // Mirrors of the store, in the bar's own types (the view is untouched).
    @Published var transcript: [BarTranscriptEntry] = []
    @Published var isStreaming = false
    @Published var currentActivity: String?
    /// Did the in-flight turn produce any reply text yet? Drives the
    /// "working" bubble (see the view's comments).
    @Published var turnHasText = false
    @Published var promptLines: CGFloat = 1
    @Published var sentAtLeastOnce = false

    // Fleet affordances.
    @Published var agents: [Agent] = []
    @Published var selectedAgentID: String
    @Published var queueDepth = 0
    /// Agents currently running or queued, for the compact fleet strip.
    @Published var busyAgents: [BusyAgentInfo] = []
    @Published var streamLabel = "offline"

    /// The new-session view cut over the store mirror (see BarViewCut): the
    /// hub keeps the agent's full transcript; this only hides entries from
    /// THIS panel view. Pure logic, unit-tested in VertusKitTests.
    private let viewCut = BarViewCut()

    // Slash commands (skills) — mirrored from the store's per-agent
    // catalog; refreshed whenever the selected agent changes.
    @Published var slashCommands: [SlashCommand] = []
    @Published var slashSuggestions: [SlashCommand] = []
    private var catalogAgent: String?

    let store: FleetStore
    private var cancellables: Set<AnyCancellable> = []
    private var stateSubs: [String: AnyCancellable] = [:]
    private weak var selectedLive: AgentLiveState?

    /// One entry in the busy strip.
    struct BusyAgentInfo: Identifiable, Equatable {
        let id: String
        let emoji: String
        let name: String
        let running: Bool
        /// "waiting on <target> (held by <agent>)" while this agent's turn is
        /// gated on a declared screen target another run holds; nil otherwise.
        let blockedSummary: String?
        /// Name of the bot this agent is working FOR (bot-initiated run), or
        /// nil for user-initiated work — shown as a marker in the strip.
        let workingFor: String?
    }

    /// The merged app owns ONE store (one fleet stream, one cursor) and
    /// injects it into both the main window and the panel — the pre-merge
    /// bar built its own second stream here.
    init(store: FleetStore) {
        self.store = store
        self.selectedAgentID = UserDefaults.standard.string(forKey: "vertus.bar.agent") ?? "primary"
        store.selectedAgentID = selectedAgentID
        store.foregroundAgentID = selectedAgentID
        rewire()
        // Arm the demo BEFORE store.start(): the store's first syncs can
        // fire before the view's onAppear, and with demoWorking still false
        // they would overwrite the seeded streaming state (the Working
        // indicator would never show).
        if CommandLine.arguments.contains("--demo-working") {
            demoWorking = true
            isStreaming = true
            currentActivity = "working…"
            turnHasText = false
            sentAtLeastOnce = true
        }
        store.start()
    }

    // MARK: - Store → published mirrors

    private func rewire() {
        store.$agents
            .sink { [weak self] agents in
                self?.agents = agents
                self?.syncBusy()
            }
            .store(in: &cancellables)
        // NOTE (bar-mirror bug): @Published delivers the NEW value to
        // subscribers BEFORE committing it to the property — a sink that
        // re-reads store.live sees the STALE (pre-mutation) dict and would
        // never subscribe to the freshly-seeded AgentLiveState instances
        // (the bar showed nothing while the window, which re-reads store.live
        // at SwiftUI body evaluation, worked fine). Use the received value,
        // and hop to the main actor so any store re-reads see the commit.
        store.$live
            .sink { [weak self] live in
                Task { @MainActor in
                    guard let self else { return }
                    self.rewireStates(live)
                    self.syncBusy()
                }
            }
            .store(in: &cancellables)
        store.$connectionState
            .sink { [weak self] state in
                switch state {
                case .connected: self?.streamLabel = "stream: connected"
                case .connecting: self?.streamLabel = "stream: connecting…"
                case .reconnecting(let a): self?.streamLabel = "stream: reconnecting (\(a))…"
                case .failed(let m): self?.streamLabel = "stream: \(m)"
                case .idle: self?.streamLabel = "stream: idle"
                }
            }
            .store(in: &cancellables)
    }

    /// Subscribe to every live state's objectWillChange so ANY agent's
    /// activity updates the busy strip, and the selected agent's updates the
    /// transcript. Iterates the dict DELIVERED by the publisher (see the
    /// rewire() note) — reading store.live here would see the pre-mutation
    /// value and skip every newly-seeded state.
    private func rewireStates(_ live: [String: AgentLiveState]) {
        for (id, state) in live where stateSubs[id] == nil {
            stateSubs[id] = state.objectWillChange
                .sink { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if id == self.selectedAgentID { self.syncSelected() }
                        self.syncBusy()
                    }
                }
        }
    }

    private func syncSelected() {
        guard let state = store.live[selectedAgentID] else { return }
        selectedLive = state
        // Mirror with the new-session cut applied (PanelMirrorPolicy — the
        // exact filter is unit-tested in VertusKitTests): hidden entries
        // drop out, and the re-anchored in-flight reply is truncated to the
        // text that streamed after the cut (still growing in place, same
        // id). An assistant entry with no visible text yet is represented
        // by the in-window Working indicator instead of an empty pill.
        transcript = PanelMirrorPolicy.visible(entries: state.transcript, cut: viewCut)
            .map { Self.map($0.source, text: $0.text) }
        if !demoWorking {
            isStreaming = state.isRunning
            currentActivity = state.currentActivity
            // Derived, not accumulated: has the CURRENT run (state.lastRunID)
            // produced visible text? A run started by another surface must not
            // inherit "has text" from an older conversation — otherwise the
            // in-window Working indicator would hide while the agent works
            // with nothing on screen. First delta of THIS run flips it
            // (WorkingIndicatorPolicy). Skipped in demo mode: the seed owns
            // the indicator state (turnHasText = false) so the --demo-working
            // capture is deterministic regardless of live hub state.
            let last = transcript.last
            turnHasText = WorkingIndicatorPolicy.currentRunHasVisibleText(
                lastEntryRunID: last?.runId,
                currentRunID: state.lastRunID,
                lastEntryIsReply: last?.role == "vertus",
                lastEntryText: last?.text ?? ""
            )
        }
        queueDepth = state.queueDepth
    }

    private func syncBusy() {
        busyAgents = store.live
            .filter { $0.value.isRunning || $0.value.queueDepth > 0 || $0.value.isBlocked }
            .map { id, state in
                let agent = agents.first { $0.id == id }
                return BusyAgentInfo(id: id,
                                     emoji: agent?.emoji ?? "",
                                     name: agent?.displayName ?? id,
                                     running: state.isRunning,
                                     blockedSummary: state.blockedSummary,
                                     workingFor: store.workingFor(id))
            }
            .sorted { $0.name < $1.name }
    }

    private static func map(_ e: VertusKit.TranscriptEntry, text: String) -> BarTranscriptEntry {
        BarTranscriptEntry(id: e.id, role: e.role == "user" ? "you" : "vertus",
                           text: text, runId: e.runId)
    }

    // MARK: - Slash commands (skills)

    func ensureSlashCatalog() {
        let id = selectedAgentID
        // Skills are per-agent: each agent home materializes its own set, so
        // the catalog is refetched whenever the selection changes.
        guard catalogAgent != id else { return }
        catalogAgent = id
        Task { [weak self] in
            guard let self else { return }
            await self.store.ensureSlashCatalog(agentID: id)
            await MainActor.run {
                // Mirror what the store actually holds; on a fetch failure it
                // retries next call (catalogAgent stays unset there).
                self.slashCommands = self.store.slashCommands
                    .map { SlashCommand(name: $0.name, description: $0.description) }
                    .sorted { $0.name < $1.name }
                if self.slashCommands.isEmpty {
                    self.catalogAgent = nil   // allow retry on next keystroke
                }
            }
        }
    }

    func updateSlashSuggestions(for prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !prompt.contains(" ") else {
            if !slashSuggestions.isEmpty { slashSuggestions = [] }
            return
        }
        let query = String(trimmed.dropFirst()).lowercased()
        let matches = slashCommands.filter { cmd in
            let bare = cmd.name.dropFirst().lowercased()
            return query.isEmpty || bare.hasPrefix(query) || bare.contains(query)
        }
        if matches.map(\.name) != slashSuggestions.map(\.name) {
            slashSuggestions = matches
        }
        ensureSlashCatalog()
    }

    func completeSlash(_ command: SlashCommand) -> String {
        slashSuggestions = []
        return command.name + " "
    }

    static let slashVisibleRows = 4
    static let slashRowHeight: CGFloat = 22
    var slashRowHeight: CGFloat { Self.slashRowHeight }

    var slashMenuSpace: CGFloat {
        slashSuggestions.isEmpty
            ? 0
            : CGFloat(min(slashSuggestions.count, Self.slashVisibleRows)) * Self.slashRowHeight + 16
    }

    // MARK: - Agent selection

    func selectAgent(_ id: String) {
        guard id != selectedAgentID else { return }
        selectedAgentID = id
        UserDefaults.standard.set(id, forKey: "vertus.bar.agent")
        turnHasText = false
        // A switch to another agent starts an uncut view of that agent.
        viewCut.reset()
        catalogAgent = nil            // refetch skills for the new agent
        slashSuggestions = []
        store.selectedAgentID = id
        store.foregroundAgentID = id
        syncSelected()
        ensureSlashCatalog()
    }

    // MARK: - Stop (supervision)

    /// Stop whatever the agent is doing now (the active run only; the
    /// agent's queue is preserved). Surfaces errors as the busy strip's
    /// stream label so the panel never needs a second UI surface.
    func stopAgent(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.stopAgent(id)
            } catch {
                await MainActor.run {
                    self.streamLabel = "stop failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Sending (fire and forget)

    /// Submit a prompt. NEVER blocks and NEVER refuses a busy agent — the
    /// hub queues server-side and `queueDepth` reflects it. Closing the
    /// panel does not abandon the run (it never did server-side).
    func send(_ text: String) {
        let id = selectedAgentID
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentAtLeastOnce = true
        turnHasText = false
        currentActivity = "queued…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.submit(agentID: id, text: trimmed)
            } catch {
                await MainActor.run {
                    self.appendAssistant("⚠️ \(error.localizedDescription)")
                }
            }
        }
    }

    /// Clear the local view (the server-side run keeps going — the bar's
    /// "new session" is a view reset, not a cancellation). The cut is applied
    /// against the store's live transcript FIRST, so the next mirror sync
    /// keeps hiding the pre-reset history instead of letting it pop back.
    func reset() {
        if let state = store.live[selectedAgentID] {
            viewCut.cut(entries: state.transcript, isRunning: state.isRunning)
        }
        transcript.removeAll()
        currentActivity = nil
        turnHasText = false
        isStreaming = false
        sentAtLeastOnce = false
    }

    /// New session on the bar: stop whatever the selected agent is doing now,
    /// then reset the bar's local conversation context so the user starts a fresh
    /// conversation with Vertus. This does NOT open the Vertus app or any new
    /// macOS window — it stays in the notch panel, clears the transcript/activity
    /// state on the bar, and leaves the agent idle so the next prompt is a clean
    /// conversation start.
    ///
    /// The stop is best-effort: if the agent is already idle the call is a no-op
    /// (the hub returns 409), and we still reset the local view so the bar is a
    /// blank slate either way.
    func newSession() {
        let id = selectedAgentID
        Task { [weak self] in
            guard let self else { return }
            // Best-effort: stop the active turn on the hub so the new
            // conversation starts from idle. If the agent is already idle we
            // still want the local reset — ignore the error.
            do {
                try await self.store.stopAgent(id)
            } catch {
                // 409 idle (and any other failure) is fine here: the user
                // asked for a fresh conversation, and the local reset below
                // is the part they see.
            }
            self.reset()
        }
    }

    // MARK: - Demo seeds (--demo-output / --demo-long)

    func seedDemoOutput() {
        sentAtLeastOnce = true
        transcript.append(BarTranscriptEntry(role: "you", text: "Show me the new chat bubbles!"))
        transcript.append(BarTranscriptEntry(
            role: "vertus",
            text: "Done — your prompts sit on the right, my replies on the "
                + "left, and the bar hugs the conversation."
        ))
    }

    func seedLongOutput() {
        sentAtLeastOnce = true
        let lines = (1...24).map { "Line \($0): VERTUS output row number \($0) with enough text to wrap comfortably." }
        transcript.append(BarTranscriptEntry(role: "vertus", text: lines.joined(separator: "\n")))
    }

    /// --demo-working: the in-window Working indicator, deterministically
    /// — streaming with no text yet (no hub involved). The session window
    /// must show the logo spinner + "Working"; it is replaced in place by
    /// the reply on the first text delta (or disappears at turn end).
    /// While set, syncSelected leaves the streaming/activity/turnHasText
    /// mirrors alone — otherwise live store updates (an actual run on the
    /// hub) would immediately trample the seeded Working state.
    private var demoWorking = false

    func seedDemoWorking() {
        demoWorking = true
        sentAtLeastOnce = true
        isStreaming = true
        currentActivity = "working…"
        turnHasText = false
    }

    // MARK: - Transcript helpers

    @MainActor
    private func appendAssistant(_ text: String) {
        transcript.append(BarTranscriptEntry(role: "vertus", text: text))
        turnHasText = true
    }
}

// MARK: - Output helpers

extension QuickBarViewModel {
    var vertusOutput: String {
        transcript.filter { $0.role == "vertus" }.map { $0.text }.joined()
    }

    var hasOutput: Bool {
        transcript.contains { $0.role == "vertus" }
    }

    var hasAssistantText: Bool {
        transcript.contains { $0.role == "vertus" && !$0.text.isEmpty }
    }

    var isThinking: Bool { isStreaming && !turnHasText }

    var transcriptText: String {
        transcript.map(\.text).joined()
    }
}

// MARK: - Slash commands

struct SlashCommand: Identifiable, Equatable {
    let name: String
    let description: String
    var id: String { name }
}