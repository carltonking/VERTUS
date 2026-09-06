import SwiftUI
import VertusKit

/// Fleet memory view: the hub's canonical store (fleet_memory.py), browsed
/// and edited by a human. Shared entries are fleet-wide; agent entries are
/// that bot's private notes. Every bot tool-call write and every human edit
/// lands here live via the memory_changed fleet event (FleetStore refreshes
/// the index on each one), attributed by writer.
struct MemoryView: View {
    @EnvironmentObject private var store: FleetStore

    enum Scope: String, CaseIterable, Identifiable {
        case shared = "Shared"
        case agent = "Agent"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .shared
    @State private var agentID: String?
    @State private var query = ""
    @State private var selectedPath: String?
    @State private var content: MemoryContent?
    @State private var loaded = false
    @State private var errorText: String?
    @State private var editingPath: String?
    @State private var editText = ""
    @State private var newPath = ""
    @State private var newText = ""

    private var entries: [MemoryEntry] {
        let all = query.isEmpty
            ? store.memoryEntries
            : store.memoryEntries.filter {
                $0.path.localizedCaseInsensitiveContains(query)
                    || ($0.writer ?? "").localizedCaseInsensitiveContains(query)
            }
        switch scope {
        case .shared:
            return all.filter { $0.scope == "shared" }
        case .agent:
            let target = agentID ?? store.agents.first?.id
            return all.filter { $0.scope == "agent" && $0.agentId == target }
        }
    }

    var body: some View {
        HSplitView {
            // Left: scope picker + entry list.
            VStack(alignment: .leading, spacing: 8) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)

                if scope == .agent {
                    Picker("Agent", selection: $agentID) {
                        ForEach(store.agents) { a in
                            Text("\(a.emoji ?? "") \(a.name)").tag(Optional(a.id))
                        }
                    }
                }

                TextField("Search memory…", text: $query)
                    .textFieldStyle(.roundedBorder)

                List(selection: $selectedPath) {
                    ForEach(entries) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.path)
                                    .font(.system(size: 12, weight: .medium))
                                Text(writerLabel(entry))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.writer == "human" {
                                Text("you")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.25))
                                    .cornerRadius(4)
                            }
                        }
                        .tag(entry.path)
                    }
                }
                .onChange(of: selectedPath) { _ in loadSelected() }
                .onChange(of: scope) { _ in selectedPath = nil; content = nil }
                .onChange(of: agentID) { _ in selectedPath = nil; content = nil }

                HStack(spacing: 8) {
                    TextField("new-file.md", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                    Button("New") { startCreate() }
                        .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10)
            .frame(minWidth: 260, idealWidth: 300)

            // Right: content view / editor.
            Group {
                if let editingPath {
                    editorPane(editingPath)
                } else if let content {
                    contentPane(content)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Select a memory entry")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Shared memory is read/written by every bot; agent memory is that bot's own.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 700, minHeight: 420)
        .task {
            if !loaded {
                loaded = true
                agentID = store.agents.first?.id
                await store.refreshMemory()
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - Panes

    private func contentPane(_ c: MemoryContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(c.path).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Edit") { beginEdit(c) }
                Button("Delete", role: .destructive) { delete(c) }
            }
            ScrollView {
                Text(c.content)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color.black.opacity(0.25))
            .cornerRadius(6)
        }
    }

    private func editorPane(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(path).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { editingPath = nil }
                Button("Save") { saveEdit(path) }
            }
            TextEditor(text: $editText)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func loadSelected() {
        guard let path = selectedPath,
              let entry = entries.first(where: { $0.path == path }) else { return }
        Task {
            do {
                content = try await store.client.memoryContent(
                    scope: entry.scope, agentID: entry.agentId, path: entry.path)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func beginEdit(_ c: MemoryContent) {
        editingPath = c.path
        editText = c.content
    }

    private func startCreate() {
        editingPath = newPath
        editText = ""
    }

    private func saveEdit(_ path: String) {
        Task {
            do {
                let entry = entries.first(where: { $0.path == path })
                let scope = entry?.scope ?? (self.scope == .shared ? "shared" : "agent")
                let agent = entry?.agentId ?? (scope == "agent" ? agentID : nil)
                _ = try await store.client.writeMemory(scope: scope, agentID: agent,
                                                       path: path, content: editText)
                editingPath = nil
                newPath = ""
                await store.refreshMemory()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func delete(_ c: MemoryContent) {
        Task {
            do {
                try await store.client.deleteMemory(scope: c.scope, agentID: c.agentId,
                                                    path: c.path)
                content = nil
                selectedPath = nil
                await store.refreshMemory()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func writerLabel(_ e: MemoryEntry) -> String {
        switch e.writer {
        case nil, "", "external": return "external"
        case "human": return "edited by you"
        case let w: return "written by \(w)"
        }
    }
}