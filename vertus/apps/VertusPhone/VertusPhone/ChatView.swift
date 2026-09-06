import SwiftUI
import VertusKit

// MARK: - Roster

/// Every agent with live busy state: running spinner, working-for, degraded,
/// blocked-on-target, unread dot. Tap opens that agent's chat.
struct RosterView: View {
    @EnvironmentObject private var store: FleetStore
    @State private var confirmingStop: String?

    var body: some View {
        List {
            connectionBanner
            if store.agents.isEmpty {
                emptyRow
            }
            ForEach(store.agents) { agent in
                NavigationLink(value: agent.id) {
                    RosterRow(agent: agent, store: store)
                }
                .swipeActions {
                    if let live = store.live[agent.id], live.isRunning || live.queueDepth > 0 {
                        Button("Stop", role: .destructive) {
                            confirmingStop = agent.id
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("VERTUS")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { agentID in
            AgentChatView(agentID: agentID)
        }
        .refreshable { await store.refreshAgents() }
        .confirmationDialog(
            "Stop this agent?",
            isPresented: Binding(
                get: { confirmingStop != nil },
                set: { if !$0 { confirmingStop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop the running turn", role: .destructive) {
                if let id = confirmingStop { Task { try? await store.stopAgent(id) } }
                confirmingStop = nil
            }
            Button("Cancel", role: .cancel) { confirmingStop = nil }
        } message: {
            Text(stopMessage(confirmingStop))
        }
    }

    private func stopMessage(_ id: String?) -> String {
        guard let id, let agent = store.agent(id) else { return "Stop the running turn." }
        let live = store.live[id]
        var text = "This stops the current run" + ((live?.queueDepth ?? 0) > 1 ? " and its queue" : "") + "."
        if agent.computerUse {
            text += " If a computer-use action is mid-flight, the window it was editing may be left half-edited."
        }
        return text
    }

    @ViewBuilder private var connectionBanner: some View {
        if case .failed(let reason) = store.connectionState {
            HStack {
                Image(systemName: "wifi.exclamationmark")
                Text("Hub unreachable — \(reason)")
                Spacer()
            }
            .font(.footnote).foregroundStyle(Color(white: 0.9))
            .listRowBackground(Color(white: 0.16))
        } else if store.hubDegraded {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Hub degraded: \(store.failingSubsystems.joined(separator: ", "))")
                Spacer()
            }
            .font(.footnote).foregroundStyle(Color(white: 0.9))
            .listRowBackground(Color(white: 0.16))
        }
    }

    private var emptyRow: some View {
        VStack(spacing: 6) {
            Text("No agents yet").foregroundStyle(.secondary)
            Text("Create one in the Mac app, or check the server URL in Settings.")
                .font(.footnote).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct RosterRow: View {
    let agent: Agent
    @ObservedObject var store: FleetStore

    var body: some View {
        let live = store.live[agent.id]
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Text(agent.emoji ?? "🤖")
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .background(Color(white: 0.18))
                    .clipShape(Circle())
                if live?.isRunning == true {
                    Circle().fill(Color.white).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if agent.isPrimary {
                        Text("PRIMARY").font(.caption2).bold()
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(white: 0.25)).clipShape(Capsule())
                    }
                }
                statusLine(agent: agent, live: live)
            }
            Spacer()
            if let live, live.unreadCount > 0 {
                Text("\(live.unreadCount)").font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white).foregroundStyle(.black)
                    .clipShape(Capsule())
            }
            if live?.isRunning == true || live?.queueDepth ?? 0 > 0 {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func statusLine(agent: Agent, live: AgentLiveState?) -> some View {
        if let degraded = live?.degraded, !degraded.isEmpty {
            Text("degraded: \(degraded)").font(.caption).foregroundStyle(.red)
        } else if let blocked = live?.blockedSummary {
            Text(blocked).font(.caption).foregroundStyle(.orange)
        } else if let working = store.workingFor(agent.id) {
            Text("working for \(working)").font(.caption).foregroundStyle(.secondary)
        } else if live?.isRunning == true {
            let act = live?.currentActivity ?? "working"
            Text(act).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if let silence = live?.silenceS, silence > 0, live?.isRunning == true {
            Text("\(String(format: "%.0f", silence))s silent").font(.caption).foregroundStyle(.secondary)
        } else if live?.queueDepth ?? 0 > 0 {
            Text("queued (\(live?.queueDepth ?? 0))").font(.caption).foregroundStyle(.secondary)
        } else if live?.isRunning == false, live?.lastError != nil {
            Text("last run errored").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(agent.title.isEmpty ? agent.name : agent.title)
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

// MARK: - Per-agent chat

/// One agent's transcript: history pagination on scroll-back, live deltas
/// from the fleet stream, a composer that never blocks (busy agents queue),
/// a stop control with CUA-aware confirmation, and a run-history list.
struct AgentChatView: View {
    let agentID: String
    @EnvironmentObject private var store: FleetStore
    @State private var prompt = ""
    @State private var showingRuns = false
    @State private var confirmStop = false
    @State private var busyNote: String?

    private var agent: Agent? { store.agent(agentID) }
    private var live: AgentLiveState? { store.live[agentID] }

    var body: some View {
        VStack(spacing: 0) {
            if isConnectionFailure {
                unreachableBanner
            }
            transcript
            Divider()
            composer
        }
        .navigationTitle(agent?.displayName ?? agentID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if live?.isRunning == true {
                    Button {
                        confirmStop = true
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Button {
                    showingRuns = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
        }
        .sheet(isPresented: $showingRuns) {
            NavigationStack { RunHistoryView(agentID: agentID) }
        }
        .task {
            store.foregroundAgentID = agentID
            await store.loadHistory(agentID: agentID)
        }
        .onDisappear {
            if store.foregroundAgentID == agentID {
                store.foregroundAgentID = nil
            }
        }
        .confirmationDialog(
            "Stop this run?",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("Stop the run", role: .destructive) {
                Task {
                    do { _ = try await store.stopAgent(agentID) }
                    catch { busyNote = (error as? VertusError)?.localizedDescription ?? "Could not stop" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let agent, agent.computerUse {
                Text("A computer-use action may be mid-flight — stopping can leave the window it was editing half-edited.")
            } else {
                Text("The running turn will be cancelled. Queued turns are kept.")
            }
        }
        .alert("VERTUS", isPresented: Binding(
            get: { busyNote != nil },
            set: { if !$0 { busyNote = nil } }
        )) {
            Button("OK") { busyNote = nil }
        } message: {
            Text(busyNote ?? "")
        }
    }

    private var isConnectionFailure: Bool {
        if case .failed = store.connectionState { return true }
        return false
    }

    private var unreachableBanner: some View {
        HStack {
            Image(systemName: "wifi.exclamationmark")
            Text("Hub unreachable — check the server is running and the URL in Settings.")
                .font(.footnote)
            Spacer()
        }
        .foregroundStyle(Color(white: 0.9))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(white: 0.16))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let live, live.transcript.isEmpty, !live.isRunning {
                        emptyChat
                    }
                    ForEach(live?.transcript ?? []) { entry in
                        bubble(entry)
                            .id(entry.id)
                    }
                    if live?.isRunning == true, let act = live?.currentActivity, !act.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("\(act)…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                        .id("bottom-activity")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: live?.transcript.count ?? 0) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: live?.isRunning ?? false) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var emptyChat: some View {
        VStack(spacing: 8) {
            Text(agent?.emoji ?? "🤖").font(.largeTitle)
            Text("Ask \(agent?.displayName ?? agentID) anything.")
                .foregroundStyle(.secondary)
            Text("Runs happen on the Mac and sync here — close this screen and the turn keeps going.")
                .font(.footnote).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func bubble(_ entry: TranscriptEntry) -> some View {
        let isUser = entry.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 44) }
            Text(entry.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isUser ? Color(white: 0.85) : Color(white: 0.22))
                .foregroundStyle(isUser ? Color(white: 0.05) : Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: Composer — never disabled; busy agents queue server-side.

    private var composer: some View {
        VStack(spacing: 4) {
            if let live, live.queueDepth > 1 {
                Text("\(live.queueDepth - 1) queued behind the current turn")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                TextField(
                    live?.isRunning == true ? "Ask \(agent?.displayName ?? "…") (queues behind current run)…"
                        : "Ask \(agent?.displayName ?? agentID)…",
                    text: $prompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(white: 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        }
    }

    private func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        Task {
            do {
                _ = try await store.submit(agentID: agentID, text: text, sourceLabel: "phone")
            } catch {
                busyNote = (error as? VertusError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Run history

/// This agent's runs (newest first). Tap a run for detail with parent +
/// children navigation. Also reachable from the roster via the clock.
struct RunHistoryView: View {
    let agentID: String
    @EnvironmentObject private var store: FleetStore
    @State private var runs: [RunRow] = []
    @State private var errorNote: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if runs.isEmpty {
                VStack(spacing: 8) {
                    Text("No runs yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(runs) { run in
                    NavigationLink(value: run.runId) {
                        RunRowView(run: run)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Runs")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { runID in
            RunDetailView(runID: runID)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("VERTUS", isPresented: Binding(
            get: { errorNote != nil },
            set: { if !$0 { errorNote = nil } }
        )) {
            Button("OK") { errorNote = nil }
        } message: {
            Text(errorNote ?? "")
        }
    }

    private func load() async {
        do {
            runs = try await store.client.runs(agentID: agentID, limit: 50)
        } catch {
            errorNote = (error as? VertusError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

struct RunRowView: View {
    let run: RunRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.prompt)
                .font(.subheadline).lineLimit(2)
            HStack(spacing: 8) {
                Text(run.state).font(.caption2).bold()
                    .foregroundStyle(stateColor(run.state))
                if run.isBotInitiated, let from = run.fromAgent {
                    Text("from \(from)").font(.caption2).foregroundStyle(.secondary)
                }
                if run.isRoutine {
                    Text("routine").font(.caption2).foregroundStyle(.secondary)
                }
                if let d = run.duration {
                    Text("\(String(format: "%.0f", d))s").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "done": .green
        case "error", "timeout": .red
        case "cancelled": .orange
        case "running": .white
        default: .gray
        }
    }
}

/// Run detail: the run, its messages, parent + children (navigable).
struct RunDetailView: View {
    let runID: String
    @EnvironmentObject private var store: FleetStore
    @State private var detail: RunDetail?
    @State private var errorNote: String?

    var body: some View {
        Group {
            if let detail {
                List {
                    Section("Run") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.run.prompt).font(.subheadline)
                            Text("state \(detail.run.state) · agent \(detail.run.agentId)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let e = detail.run.error, !e.isEmpty {
                                Text(e).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    if let parent = detail.parent {
                        Section("Parent") {
                            NavigationLink(value: parent.runId) {
                                VStack(alignment: .leading) {
                                    Text(parent.prompt).font(.subheadline).lineLimit(1)
                                    Text(parent.state).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !detail.children.isEmpty {
                        Section("Children (\(detail.children.count))") {
                            ForEach(detail.children) { child in
                                NavigationLink(value: child.runId) {
                                    VStack(alignment: .leading) {
                                        Text(child.prompt).font(.subheadline).lineLimit(1)
                                        Text("\(child.state) · \(child.agentId)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !detail.messages.isEmpty {
                        Section("Messages") {
                            ForEach(detail.messages) { msg in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(msg.role == "user" ? "you" : "assistant")
                                        .font(.caption2).bold().foregroundStyle(.secondary)
                                    Text(msg.text).font(.footnote).textSelection(.enabled)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .navigationDestination(for: String.self) { childID in
                    RunDetailView(runID: childID)
                }
            } else if let errorNote {
                Text(errorNote).foregroundStyle(.secondary).padding()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { detail = try await store.runDetail(runID) }
            catch { errorNote = (error as? VertusError)?.localizedDescription ?? error.localizedDescription }
        }
    }
}