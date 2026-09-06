import SwiftUI
import VertusKit

/// Roster: every agent with emoji/color, a live busy indicator, a one-line
/// "what it's doing now" from the latest activity event, and an unread
/// marker when a background run produced output the user hasn't looked at.
struct FleetSidebarView: View {
    @EnvironmentObject private var store: FleetStore
    var onNewAgent: () -> Void
    var onEditAgent: (Agent) -> Void
    var onShowActivity: () -> Void

    @State private var confirmDelete: Agent?
    @State private var errorText: String?
    @State private var showScreens = false
    @State private var showThreads = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedAgentID) {
                Section("Agents") {
                    ForEach(store.agents) { agent in
                        rosterRow(agent)
                            .tag(agent.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Fleet activity + screens + connection state.
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onShowActivity) {
                    Label("Fleet activity", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

                Button {
                    showScreens = true
                    Task { await store.refreshScreens() }
                } label: {
                    Label("Screens", systemImage: "display")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

                Button {
                    showThreads = true
                    Task { await store.refreshThreads() }
                } label: {
                    Label("Bot threads", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

                connectionRow
            }
            .padding(10)
        }
        .sheet(isPresented: $showScreens) {
            FleetScreensSheetView()
                .environmentObject(store)
                .frame(width: 560, height: 460)
        }
        .sheet(isPresented: $showThreads) {
            ThreadsView()
                .environmentObject(store)
                .frame(width: 780, height: 520)
        }
        .alert("Delete agent?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Delete", role: .destructive) { delete(confirmDelete) }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text(confirmDelete.map { "Move \($0.rosterLabel)'s directory to the trash and remove it from the fleet? Its run history is kept." } ?? "")
        }
        .alert("Error", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    onNewAgent()
                } label: {
                    Label("New agent", systemImage: "plus")
                }
            }
        }
        .onAppear {
            Task { await store.refreshAgents() }
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            Text(connectionText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private var connectionColor: Color {
        switch store.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var connectionText: String {
        switch store.connectionState {
        case .connected: return "stream connected"
        case .connecting: return "connecting…"
        case .reconnecting(let attempt): return "reconnecting (\(attempt))…"
        case .failed(let m): return "offline: \(m)"
        case .idle: return "stream idle"
        }
    }

    private func rosterRow(_ agent: Agent) -> some View {
        HStack(spacing: 8) {
            // Emoji avatar on the agent's color.
            ZStack {
                Circle()
                    .fill(color(for: agent))
                    .frame(width: 26, height: 26)
                Text(agent.emoji ?? "")
                    .font(.system(size: 13))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(agent.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if let state = store.live[agent.id] {
                        if state.isDegraded {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.red)
                        } else if state.isBlocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        } else if state.isRunning {
                            busyDot(color: .orange)
                        } else if state.queueDepth > 0 {
                            busyDot(color: .yellow)
                        }
                    }
                    if let state = store.live[agent.id], state.unreadCount > 0 {
                        Text("\(state.unreadCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.blue))
                    }
                }
                // Degraded wins: the reason IS the one-liner. Then the
                // blocked-target summary, then "working for X" (bot-initiated
                // turn), then the live activity line.
                if let state = store.live[agent.id], state.isDegraded, let reason = state.degraded {
                    Text(reason)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if let state = store.live[agent.id], state.isBlocked, let summary = state.blockedSummary {
                    Text(summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let boss = store.workingFor(agent.id) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.blue)
                        Text("working for \(boss)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                } else if let activity = store.latestActivityText(for: agent.id) {
                    Text(activity)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button("Edit…") { onEditAgent(agent) }
                Button(SharedUIState.mutedAgentIDs().contains(agent.id) ? "Unmute notifications" : "Mute notifications") {
                    SharedUIState.setMuted(!SharedUIState.mutedAgentIDs().contains(agent.id), agentID: agent.id)
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = agent }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit…") { onEditAgent(agent) }
            Button("Delete…", role: .destructive) { confirmDelete = agent }
        }
    }

    private func busyDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.8), radius: 2)
    }

    private func color(for agent: Agent) -> Color {
        guard let hex = agent.color?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return Color(white: 0.2)
        }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    private func delete(_ agent: Agent?) {
        guard let agent else { return }
        Task {
            do {
                try await store.deleteAgent(agent.id)
            } catch {
                // 409s (primary, busy) surface as readable sentences.
                errorText = error.localizedDescription
            }
        }
    }
}

/// Fleet screens roster: declared targets, who runs each, who waits, and the
/// honest caveat — targets are declarations for conflict gating, not a
/// sandbox the hub enforces.
struct FleetScreensSheetView: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Screens")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Refresh") {
                    Task { await store.refreshScreens() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            if let screens = store.screens {
                if screens.screens.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "display")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("No declared screen targets.")
                            .font(.system(size: 13))
                        Text("Agents that declare cua_targets appear here; the rest run fully parallel.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(screens.screens) { entry in
                        screenRow(entry)
                    }
                }

                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(screens.caveat ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(10)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func screenRow(_ entry: FleetScreenEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.target)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                if entry.running != nil {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
            }
            Text("declared by: \(entry.declaredBy.compactMap { store.displayName(for: $0) }.joined(separator: ", "))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let running = entry.running {
                Text("▶ \(store.displayName(for: running.agentId)) — run since \(Self.sinceText(running.since))")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
            if !entry.waiting.isEmpty {
                Text("waiting: \(entry.waiting.compactMap { store.displayName(for: $0) }.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private static func sinceText(_ ts: Double) -> String {
        let elapsed = Date().timeIntervalSince1970 - ts
        if elapsed < 60 { return "\(Int(elapsed))s" }
        return "\(Int(elapsed / 60))m"
    }
}