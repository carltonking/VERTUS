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

    // Slash commands (skills) — unchanged behavior, now via VertusKit.
    @Published var slashCommands: [SlashCommand] = []
    @Published var slashSuggestions: [SlashCommand] = []
    private var catalogLoaded = false
    private var catalogRetry = false

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
        store.start()
    }

    // MARK: - Store → published mirrors

    private func rewire() {
        cancellables.removeAll()
        store.$agents
            .sink { [weak self] agents in
                self?.agents = agents
                self?.syncBusy()
            }
            .store(in: &cancellables)
        store.$live
            .sink { [weak self] _ in
                self?.rewireStates()
                self?.syncBusy()
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
    /// transcript.
    private func rewireStates() {
        for (id, state) in store.live where stateSubs[id] == nil {
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
        // Mirror with the new-session cut applied: hidden entries drop out,
        // and the re-anchored in-flight reply is truncated to the text that
        // streamed after the cut (still growing in place, same id).
        transcript = state.transcript.compactMap { entry in
            guard let text = viewCut.visibleText(of: entry) else { return nil }
            // An assistant entry with no visible text yet (the reply right
            // after a cut) shows the working bubble instead of an empty pill.
            guard !text.isEmpty || entry.role == "user" else { return nil }
            return Self.map(entry, text: text)
        }
        isStreaming = state.isRunning
        currentActivity = state.currentActivity
        queueDepth = state.queueDepth
        if let last = transcript.last, last.role == "vertus", !last.text.isEmpty {
            turnHasText = true
        }
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
        BarTranscriptEntry(id: e.id, role: e.role == "user" ? "you" : "vertus", text: text)
    }

    // MARK: - Slash commands (skills)

    func ensureSlashCatalog() {
        guard !catalogLoaded else { return }
        catalogLoaded = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let cmds = try await self.store.client.slashCommands()
                await MainActor.run {
                    self.slashCommands = cmds
                        .map { SlashCommand(name: $0.name, description: $0.description) }
                        .sorted { $0.name < $1.name }
                }
            } catch {
                await MainActor.run {
                    if !self.catalogRetry {
                        self.catalogRetry = true
                        self.catalogLoaded = false
                    }
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
        store.selectedAgentID = id
        store.foregroundAgentID = id
        syncSelected()
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
    /// "new session" is a view reset, not a cancellation).
    func reset() {
        transcript.removeAll()
        currentActivity = nil
        turnHasText = false
        isStreaming = false
        sentAtLeastOnce = false
    }

    /// New session — a VIEW reset, never a server-side reset. The hub has no
    /// per-agent session to clear: an agent owns one continuous transcript
    /// and run history, which stay intact (the main window shows it all).
    /// Everything currently on screen is hidden. If a reply is mid-stream
    /// it is NOT discarded: the run keeps going and the reply is re-anchored
    /// so only the text streamed after this click shows (and keeps growing)
    /// in the fresh view.
    func newSession() {
        guard let state = store.live[selectedAgentID] else {
            viewCut.reset()
            reset()
            return
        }
        viewCut.cut(entries: state.transcript, isRunning: state.isRunning)
        reset()
        syncSelected()
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