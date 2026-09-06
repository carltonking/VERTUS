import AppKit
import SwiftUI
import VertusKit

struct AgentChatView: View {
    let agentID: String
    @ObservedObject var live: AgentLiveState
    @EnvironmentObject private var store: FleetStore

    @State private var prompt = ""
    @State private var oldestMessageID: Int?
    @State private var isLoadingOlder = false
    @State private var submitError: String?
    @State private var runs: [RunRow] = []
    @State private var selectedRun: RunRow?
    @State private var showHistory = false
    @State private var confirmStop = false
    @State private var stopError: String?
    /// Visible wrapped lines in the composer (drives its height; 1 at rest,
    /// grows to 5, then the editor scrolls internally — Bug A6).
    @State private var promptLines: CGFloat = 1
    /// Slash-command (skill) suggestions while the prompt is a bare /token.
    @State private var slashSuggestions: [SlashCommandInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            slashBar
            composer
        }
        .sheet(item: $selectedRun) { run in
            PastRunView(run: run)
                .frame(width: 680, height: 520)
        }
        .sheet(isPresented: $showHistory) {
            historySheet
        }
        .alert("Couldn't send", isPresented: Binding(
            get: { submitError != nil },
            set: { if !$0 { submitError = nil } }
        )) {
            Button("OK") { submitError = nil }
        } message: {
            Text(submitError ?? "")
        }
        .alert("Stop this run?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { stop() }
            Button("Keep running", role: .cancel) { confirmStop = false }
        } message: {
            Text(stopMessage)
        }
        .alert("Couldn't stop", isPresented: Binding(
            get: { stopError != nil },
            set: { if !$0 { stopError = nil } }
        )) {
            Button("OK") { stopError = nil }
        } message: {
            Text(stopError ?? "")
        }
        .onAppear {
            if !live.hasLoadedHistory {
                Task { await store.loadHistory(agentID: agentID) }
            }
            Task { await loadRuns() }
        }
        .onChange(of: agentID) { _ in
            Task {
                if !live.hasLoadedHistory {
                    await store.loadHistory(agentID: agentID)
                }
                await loadRuns()
                await store.ensureSlashCatalog(agentID: agentID)
            }
            slashSuggestions = []
        }
        .onChange(of: prompt) { _ in
            slashSuggestions = store.slashSuggestions(for: prompt)
        }
        .onAppear {
            Task { await store.ensureSlashCatalog(agentID: agentID) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let agent = store.agent(agentID) {
                Text(agent.emoji ?? "")
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let model = agent.model, !model.isEmpty {
                        Text("\(agent.provider ?? "") \(model)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(agentID).font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            if live.isRunning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("working\(live.queueDepth > 0 ? " · \(live.queueDepth) queued" : "")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    // v4: live engine-silence, so the user can judge before
                    // killing a run (the stall limit is the hub's too).
                    if live.silenceS >= 5 {
                        Text("silent \(Int(live.silenceS))s")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
            } else if live.queueDepth > 0 {
                Text("\(live.queueDepth) queued")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if live.isDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .help(live.degraded ?? "degraded")
            }
            if let activity = live.currentActivity, live.isRunning {
                Text(activity)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if live.isRunning {
                Button {
                    confirmStop = true
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop this run")
            }
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Run history for \(store.agent(agentID)?.displayName ?? agentID)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var stopMessage: String {
        let cua = (store.agent(agentID)?.computerUse ?? false)
        return cua
            ? "This agent can drive the desktop. Stopping mid-action may leave a window half-edited (a type or click in flight completes; the turn stops at the next action boundary)."
            : "The run will be stopped. Queued work for this agent is kept."
    }

    private func stop() {
        confirmStop = false
        Task {
            do {
                try await store.stopAgent(agentID)
            } catch {
                stopError = error.localizedDescription
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let oldest = oldestMessageID {
                        Button {
                            loadOlder(before: oldest)
                        } label: {
                            Text(isLoadingOlder ? "Loading…" : "Older messages")
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isLoadingOlder)
                    }
                    ForEach(live.transcript) { entry in
                        FleetBubbleView(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: live.transcriptText) { _ in
                if let last = live.transcript.last {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    if let last = live.transcript.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func loadOlder(before id: Int) {
        isLoadingOlder = true
        Task {
            await store.loadOlderMessages(agentID: agentID, beforeID: id)
            isLoadingOlder = false
        }
    }

    // MARK: - Run history

    /// The old horizontal chip strip above the composer is gone (Bug 3).
    /// History lives behind the header's History button: a proper list,
    /// newest-first, each row opening PastRunView (parent/children tree).
    private var historySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run history")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Refresh") {
                    Task { await loadRuns() }
                }
                Button("Close") { showHistory = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if runs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No runs yet for this agent.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(runs) { run in
                    Button {
                        openHistory(run)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(stateColor(run.state))
                                .frame(width: 7, height: 7)
                            if run.isBotInitiated {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.blue)
                                    .help("bot-initiated")
                            } else if run.isRoutine {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.purple)
                                    .help("routine-initiated")
                            }
                            Text(run.prompt)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(run.state)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            if let d = run.duration {
                                Text(String(format: "%.0fs", d))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 560, height: 420)
    }

    /// Dismiss the history list, then present the run detail sheet on the
    /// parent (two sheets on one view cannot overlap; the tick lets the
    /// dismissal settle first).
    private func openHistory(_ run: RunRow) {
        showHistory = false
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            selectedRun = run
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "done": return .green
        case "running", "queued": return .orange
        case "error": return .red
        case "cancelled": return .gray          // distinct: user-stopped
        case "timeout": return .purple          // distinct: stall/hard limit
        default: return .gray
        }
    }

    private func loadRuns() async {
        do {
            runs = try await store.client.runs(agentID: agentID, limit: 20)
        } catch {
            // Runs are auxiliary; the transcript is the primary view.
        }
    }

    // MARK: - Composer
    // Submit returns immediately; the composer clears and NEVER blocks or
    // disables — busy agents queue server-side and queue depth is shown.
    // The editor is the panel's PromptTextEditor (Bug A1/A6): ONE line at
    // rest, grows with content up to 5 lines, then scrolls internally;
    // Return sends, Shift+Return inserts a newline. No second editor.

    /// The composer's line height for the given font (matches the editor's
    /// real line fragments — see NotchPanelMetrics.promptLineHeight).
    private var composerLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: composerFontSize))
    }

    private let composerFontSize: CGFloat = 13

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PromptTextEditor(text: $prompt,
                             onSubmit: submit,
                             onLinesChange: { promptLines = $0 },
                             maxLines: 5,
                             fontSize: composerFontSize)
                .frame(maxWidth: .infinity)
                .frame(height: max(promptLines, 1) * composerLineHeight, alignment: .topLeading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.13)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.08))
                )
            Button(action: { submit(prompt) }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(prompt.isEmpty ? Color.white.opacity(0.3) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send (always available; busy agents queue)")
        }
        .padding(10)
    }

    /// Slash-command (skill) suggestions above the composer while the
    /// prompt is a bare /token — same catalog and matching as the QuickBar
    /// dropdown, for the SELECTED agent (skills are per-agent). Clicking
    /// completes into the composer; the hub expands /commands server-side
    /// when the turn is submitted (same path the CLI uses).
    @ViewBuilder
    private var slashBar: some View {
        if !slashSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(slashSuggestions.prefix(4)) { cmd in
                    Button {
                        prompt = cmd.name + " "
                        slashSuggestions = []
                    } label: {
                        HStack(spacing: 6) {
                            Text(cmd.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(cmd.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    /// Send (Return, Shift+Return, or the mouse). `raw` is what the editor
    /// handed over — the binding is already cleared by then, so the caller
    /// (button) passes `prompt` and the editor passes its own text.
    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        Task {
            do {
                try await store.submit(agentID: agentID, text: text)
            } catch {
                submitError = error.localizedDescription
            }
        }
    }
}

// MARK: - Bubble

struct FleetBubbleView: View {
    let entry: TranscriptEntry
    @State private var hovering = false

    private var isUser: Bool { entry.role == "user" }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text((try? AttributedString(markdown: entry.text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(entry.text))
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isUser ? Color.accentColor.opacity(0.85) : Color(white: 0.17))
                    )
                if entry.isDelta {
                    Text("live")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            if !isUser { Spacer(minLength: 60) }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Past run viewer

struct PastRunView: View {
    @State private var runID: String
    @State private var detail: RunDetail?
    @State private var loaded = false
    @State private var loadError: String?
    @EnvironmentObject private var store: FleetStore

    init(run: RunRow) {
        _runID = State(initialValue: run.runId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Run · \(detail?.run.state ?? "…")")
                    .font(.system(size: 13, weight: .semibold))
                if let d = detail {
                    if d.run.isBotInitiated, let from = d.run.fromAgent {
                        Text("for \(store.displayName(for: from))")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                    if let kind = d.run.runKind, kind != "user" {
                        Text(kind.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.18)))
                            .foregroundStyle(.blue)
                    }
                }
                Spacer()
                Text(detail?.run.prompt.prefix(60) ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            Divider()
            // Delegation tree: who asked (parent) and who was asked (children)
            if let detail {
                delegationTree(detail)
                Divider()
            }
            if loaded {
                if let detail {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(detail.messages, id: \.id) { msg in
                                FleetBubbleView(entry: TranscriptEntry(runId: msg.runId,
                                                                       role: msg.role,
                                                                       text: msg.text,
                                                                       messageID: msg.id))
                            }
                        }
                        .padding(14)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { Task { await load(runID) } }
    }

    /// Parent + children as navigable chips: clicking one loads that run's
    /// detail in place, so a delegation chain is traceable end to end.
    @ViewBuilder
    private func delegationTree(_ detail: RunDetail) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let parent = detail.parent {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("delegated by")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    treeChip(run: parent)
                }
            }
            if !detail.children.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("delegated to")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ForEach(detail.children) { child in
                        treeChip(run: child)
                    }
                }
            }
            if detail.parent == nil && detail.children.isEmpty {
                Text("Not part of a delegation chain.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func treeChip(run: RunRow) -> some View {
        Button {
            Task { await load(run.runId) }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(stateColor(run.state))
                    .frame(width: 5, height: 5)
                Text("\(store.displayName(for: run.agentId)) · \(run.state)")
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.16)))
        }
        .buttonStyle(.plain)
        .help(run.prompt)
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "done": return .green
        case "running", "queued": return .orange
        case "error": return .red
        case "cancelled": return .gray
        case "timeout": return .purple
        default: return .gray
        }
    }

    private func load(_ id: String) async {
        runID = id
        loaded = false
        loadError = nil
        do {
            detail = try await store.client.runDetail(id)
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}
