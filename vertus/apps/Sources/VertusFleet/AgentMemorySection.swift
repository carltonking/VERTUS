import SwiftUI
import VertusKit

/// The editing agent's private memory, shown in the bot editor. Read-only
/// here (editing happens in the Memory view): it exists so you can see what
/// the bot has learned without leaving the editor. Refreshes on appear and
/// on every memory_changed event via the store's index.
struct AgentMemorySection: View {
    let agentID: String
    @EnvironmentObject private var store: FleetStore
    @State private var visible = false

    private var entries: [MemoryEntry] {
        store.memoryEntries.filter { $0.scope == "agent" && $0.agentId == agentID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Private memory")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !entries.isEmpty {
                    Text("\(entries.count) file\(entries.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if entries.isEmpty {
                Text("No private memory yet. When this bot writes notes, they land here (hub-owned, mirrored from the engine's memories dir).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(entry.path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(entry.writer == "human" ? "you" : (entry.writer ?? "external"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if !visible {
                visible = true
                Task { await store.refreshMemory() }
            }
        }
    }
}