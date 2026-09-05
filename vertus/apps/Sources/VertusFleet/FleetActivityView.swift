import SwiftUI
import VertusKit

/// Newest runs across ALL agents — who is busy with what, and what just
/// finished. Clicking a row selects that agent in the main window.
struct FleetActivityView: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss

    @State private var activity: [FleetActivityItem] = []
    @State private var names: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fleet activity")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Refresh") {
                    Task { await load() }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if loaded && activity.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No runs yet")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Prompt any agent and its runs will show here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(activity) { item in
                    row(item)
                        .onTapGesture {
                            store.selectedAgentID = item.agentId
                            store.foregroundAgentID = item.agentId
                            dismiss()
                        }
                }
            }
        }
        .onAppear {
            Task { await load() }
        }
    }

    private func row(_ item: FleetActivityItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor(item.state))
                .frame(width: 7, height: 7)
            Text(names[item.agentId] ?? item.agentId)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            Text(item.prompt)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            if item.state == "running" || item.state == "queued" {
                Text(item.state)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            if let d = duration(item) {
                Text(String(format: "%.0fs", d))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Text(item.state)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func duration(_ item: FleetActivityItem) -> Double? {
        guard let s = item.startedAt, let e = item.endedAt else { return nil }
        return e - s
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "done": return .green
        case "running", "queued": return .orange
        case "error": return .red
        default: return .gray
        }
    }

    private func load() async {
        do {
            activity = try await store.client.fleetActivity(limit: 50)
            for agent in store.agents {
                names[agent.id] = agent.displayName
            }
            loaded = true
        } catch {
            loaded = true
        }
    }
}