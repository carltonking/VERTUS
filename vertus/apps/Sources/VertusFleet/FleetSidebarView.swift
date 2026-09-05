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

            // Fleet activity entry + connection state.
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onShowActivity) {
                    Label("Fleet activity", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

                connectionRow
            }
            .padding(10)
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
                        if state.isRunning {
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
                if let activity = store.latestActivityText(for: agent.id) {
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