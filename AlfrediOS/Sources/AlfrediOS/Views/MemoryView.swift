import SwiftUI
import AlfredCore

/// Read-only look at AlfredCore's `MemoryStore`: recent vault notes plus
/// keyword search.
struct MemoryView: View {
    private let store = MemoryStore.shared
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Recent notes") { rows(store.recent()) }
                } else {
                    Section("Matches") { rows(store.search(query)) }
                }
            }
            .searchable(text: $query, prompt: "Search memory")
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { store.refresh() }
        }
    }

    private func rows(_ notes: [MemoryNote]) -> some View {
        ForEach(notes, id: \.id) { note in
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.headline)
                Text(note.body)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                Text(note.category)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
