import SwiftUI
import VertusKit

/// Create/edit an agent. Every v2 editable field is exposed; identity fields
/// (model/provider/color/emoji) treat an empty string as "unset → inherit
/// fleet default".
struct AgentEditorView: View {
    let mode: FleetRootView.EditorMode
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var title = ""
    @State private var agentDescription = ""
    @State private var persona = ""
    @State private var model = ""
    @State private var provider = ""
    @State private var color = ""
    @State private var emoji = ""
    @State private var autonomy = "ask"

    @State private var saving = false
    @State private var errorText: String?
    @State private var respawnPending = false

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEdit ? "Edit agent" : "New agent")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Create") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || (name.trimmingCharacters(in: .whitespaces).isEmpty && !isEdit))
            }
            .padding(12)

            Divider()

            Form {
                TextField("Name", text: $name)
                    .disabled(isEdit)
                TextField("Title (display name)", text: $title)
                TextField("Description", text: $agentDescription)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Persona (system identity — written to the agent's SOUL.md)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $persona)
                        .font(.system(size: 11.5))
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13)))
                }
                HStack {
                    TextField("Model (blank = inherit)", text: $model)
                    TextField("Provider (blank = inherit)", text: $provider)
                }
                HStack {
                    TextField("Color (#RRGGBB)", text: $color)
                    TextField("Emoji", text: $emoji)
                }
                Picker("Autonomy", selection: $autonomy) {
                    Text("ask — confirm before acting").tag("ask")
                    Text("trusted — act on its own").tag("trusted")
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)

            if respawnPending {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Saved — the change applies from the next turn (this agent is busy right now).")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 520, height: 560)
        .onAppear {
            if case .edit(let agent) = mode {
                name = agent.name
                title = agent.title
                agentDescription = agent.description
                persona = agent.persona
                model = agent.model ?? ""
                provider = agent.provider ?? ""
                color = agent.color ?? ""
                emoji = agent.emoji ?? ""
                autonomy = agent.autonomy
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if isEdit, case .edit(let agent) = mode {
                let (_, pending) = try await store.updateAgent(
                    agent.id,
                    title: emptyAsNil(title),
                    description: emptyAsNil(agentDescription),
                    persona: emptyAsNil(persona),
                    model: emptyAsNil(model),
                    provider: emptyAsNil(provider),
                    color: emptyAsNil(color),
                    emoji: emptyAsNil(emoji),
                    autonomy: autonomy
                )
                respawnPending = pending
                if !pending { dismiss() }
            } else {
                _ = try await store.createAgent(
                    name: name.trimmingCharacters(in: .whitespaces),
                    title: emptyAsNil(title),
                    description: emptyAsNil(agentDescription),
                    persona: emptyAsNil(persona),
                    model: emptyAsNil(model),
                    provider: emptyAsNil(provider),
                    color: emptyAsNil(color),
                    emoji: emptyAsNil(emoji),
                    autonomy: autonomy
                )
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func emptyAsNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}