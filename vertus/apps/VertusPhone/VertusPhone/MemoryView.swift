import SwiftUI
import VertusKit

/// Browse shared and per-agent memory (hub-owned canonical store), read any
/// entry, and edit text entries. Live-updates via the fleet stream
/// (memory_changed events refresh the store index). Attribution: each row
/// shows which bot (or the human) last wrote it.
struct MemoryView: View {
    @EnvironmentObject private var store: FleetStore
    @State private var searchText = ""
    @State private var agentIDs: [String] = []

    var body: some View {
        List {
            if store.memoryEntries.isEmpty && searchText.isEmpty {
                emptyState
            }
            if !searchText.isEmpty {
                searchResults
            } else {
                sharedSection
                agentSections
            }
        }
        .listStyle(.plain)
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search memory")
        .refreshable { await store.refreshMemory() }
        .task { agentIDs = store.agents.map(\.id) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain").font(.largeTitle).foregroundStyle(.secondary)
            Text("No memory files yet")
                .foregroundStyle(.secondary)
            Text("Bots store learned facts here as they work.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }

    private var sharedSection: some View {
        let shared = store.memoryEntries.filter { $0.scope == "shared" }
        return Section("Shared (all agents)") {
            if shared.isEmpty {
                Text("Empty").font(.footnote).foregroundStyle(.tertiary)
            } else {
                ForEach(shared) { entry in
                    MemoryRowView(entry: entry)
                }
            }
        }
    }

    @ViewBuilder private var agentSections: some View {
        ForEach(agentIDs, id: \.self) { agentID in
            let entries = store.memoryEntries.filter {
                $0.scope == "agent" && $0.agentId == agentID
            }
            if !entries.isEmpty {
                Section("Agent · \(store.displayName(for: agentID))") {
                    ForEach(entries) { entry in
                        MemoryRowView(entry: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        Section("Results") {
            ForEach(searchHits) { entry in
                MemoryRowView(entry: entry)
            }
        }
    }

    private var searchHits: [MemoryEntry] {
        let q = searchText.lowercased()
        return store.memoryEntries.filter {
            $0.path.lowercased().contains(q)
                || ($0.writer ?? "").lowercased().contains(q)
        }
    }
}

struct MemoryRowView: View {
    @EnvironmentObject private var store: FleetStore
    let entry: MemoryEntry
    @State private var content: MemoryContent?
    @State private var showEditor = false
    @State private var errorNote: String?

    var body: some View {
        NavigationLink {
            MemoryContentView(entry: entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.subheadline).lineLimit(1)
                HStack(spacing: 8) {
                    if let writer = entry.writer, !writer.isEmpty {
                        Text("by \(writer)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let size = entry.size {
                        Text("\(size) B").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Read one memory file; edit text content in place (human-initiated PUT —
/// the hub broadcasts the change on the fleet stream, so every surface
/// updates live with attribution).
struct MemoryContentView: View {
    let entry: MemoryEntry
    @EnvironmentObject private var store: FleetStore
    @State private var content: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var errorNote: String?
    @State private var saving = false

    var body: some View {
        Group {
            if let content {
                ScrollView {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            } else if let errorNote {
                Text(errorNote).foregroundStyle(.secondary).padding()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if content != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") {
                        draft = content ?? ""
                        editing = true
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .navigationTitle("Edit")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editing = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(saving ? "Saving…" : "Save") {
                                save()
                            }
                            .disabled(saving)
                        }
                    }
            }
        }
        .alert("VERTUS", isPresented: Binding(
            get: { errorNote != nil },
            set: { if !$0 { errorNote = nil } }
        )) {
            Button("OK") { errorNote = nil }
        } message: {
            Text(errorNote ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let c = try await store.client.memoryContent(
                scope: entry.scope, agentID: entry.agentId, path: entry.path)
            content = c.content
        } catch {
            errorNote = (error as? VertusError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await store.client.writeMemory(
                    scope: entry.scope, agentID: entry.agentId,
                    path: entry.path, content: draft)
                editing = false
                content = draft
                await store.refreshMemory()
            } catch {
                errorNote = (error as? VertusError)?.localizedDescription ?? error.localizedDescription
            }
            saving = false
        }
    }
}