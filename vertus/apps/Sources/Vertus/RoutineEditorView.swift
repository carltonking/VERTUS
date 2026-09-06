import SwiftUI
import VertusKit

/// Create/edit ONE routine. Schedule = interval seconds (the only syntax the
/// hub accepts — cron is deliberately unsupported). Trigger vocabulary is
/// two types with an optional target filter.
struct RoutineEditorView: View {
    let agentID: String
    let routine: Routine?
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var scheduleEnabled = true
    @State private var intervalText = "3600"
    @State private var triggerEnabled = false
    @State private var triggerType = "run_completed"
    @State private var triggerTarget = ""

    @State private var saving = false
    @State private var errorText: String?

    private var isEdit: Bool { routine != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEdit ? "Edit routine" : "New routine")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Create") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                          || prompt.trimmingCharacters(in: .whitespaces).isEmpty
                          || (!scheduleEnabled && !triggerEnabled))
            }
            .padding(12)

            Divider()

            Form {
                TextField("Name", text: $name)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt — the turn's text when this routine fires")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(.system(size: 11.5))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13)))
                }
                Toggle("Fire on a schedule", isOn: $scheduleEnabled)
                if scheduleEnabled {
                    HStack {
                        TextField("Interval (seconds)", text: $intervalText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .disabled(saving)
                        Text("the only schedule syntax — interval seconds, one syntax, never two")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Fire on an event", isOn: $triggerEnabled)
                if triggerEnabled {
                    Picker("Event", selection: $triggerType) {
                        Text("another agent's run finishes").tag("run_completed")
                        Text("a bot message arrives").tag("bot_message")
                    }
                    TextField(triggerType == "run_completed"
                              ? "Agent whose run triggers it (blank = any run)"
                              : "Sender agent (blank = any bot)",
                              text: $triggerTarget)
                }
                Text("At least one of schedule / event must be on. A routine never fires while its own previous turn is still running, and 3 consecutive failures disable it automatically.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 420)
        .onAppear {
            guard let routine else { return }
            name = routine.name
            prompt = routine.prompt
            if let interval = routine.schedule?.intervalS {
                scheduleEnabled = true
                intervalText = String(interval)
            } else {
                scheduleEnabled = false
            }
            if let trigger = routine.trigger {
                triggerEnabled = true
                triggerType = trigger.type
                triggerTarget = trigger.agentId ?? trigger.fromAgent ?? ""
            } else {
                triggerEnabled = false
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
            let interval = Int(intervalText.trimmingCharacters(in: .whitespaces))
            if scheduleEnabled, interval == nil {
                errorText = "Interval must be a whole number of seconds"
                return
            }
            let trigger: RoutineTrigger?
            if triggerEnabled {
                let target = triggerTarget.trimmingCharacters(in: .whitespaces)
                if triggerType == "run_completed" {
                    trigger = RoutineTrigger(type: "run_completed",
                                             agentId: target.isEmpty ? nil : target,
                                             threadId: nil)
                } else {
                    trigger = RoutineTrigger(type: "bot_message",
                                             agentId: nil,
                                             fromAgent: target.isEmpty ? nil : target,
                                             threadId: nil)
                }
            } else {
                trigger = nil
            }
            if let routine {
                _ = try await store.updateRoutine(
                    routine.id,
                    name: name.trimmingCharacters(in: .whitespaces),
                    prompt: prompt.trimmingCharacters(in: .whitespaces),
                    intervalS: scheduleEnabled ? interval : nil,
                    trigger: trigger,
                    clearSchedule: !scheduleEnabled,
                    clearTrigger: !triggerEnabled
                )
            } else {
                _ = try await store.createRoutine(
                    agentID: agentID,
                    name: name.trimmingCharacters(in: .whitespaces),
                    prompt: prompt.trimmingCharacters(in: .whitespaces),
                    intervalS: scheduleEnabled ? interval : nil,
                    trigger: trigger
                )
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// The routines block inside the bot editor: per-agent list with toggle,
/// run-now, delete, and a loud disabled-by-failures state.
struct RoutineListView: View {
    let agentID: String
    @EnvironmentObject private var store: FleetStore
    @State private var editing: Routine?
    @State private var creating = false
    @State private var errorText: String?

    private var rows: [Routine] {
        store.routines(for: agentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Routines")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            if rows.isEmpty {
                Text("No routines yet — scheduled or event-triggered work runs while you're away.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { routine in
                    routineRow(routine)
                }
            }
        }
        .sheet(isPresented: $creating) {
            RoutineEditorView(agentID: agentID, routine: nil)
                .environmentObject(store)
        }
        .sheet(item: $editing) { routine in
            RoutineEditorView(agentID: agentID, routine: routine)
                .environmentObject(store)
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

    @ViewBuilder
    private func routineRow(_ routine: Routine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if routine.disabledByFailures {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(routine.name)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { routine.enabled },
                    set: { enabled in
                        Task {
                            do {
                                _ = try await store.updateRoutine(routine.id, enabled: enabled)
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(routine.disabledByFailures)
                Button {
                    Task {
                        do {
                            try await store.runRoutineNow(routine.id)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!routine.enabled)
                Button {
                    editing = routine
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                Button {
                    Task {
                        do {
                            try await store.deleteRoutine(routine.id)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Text("\(routine.humanSchedule)\(routine.humanTrigger.isEmpty ? "" : " · \(routine.humanTrigger)")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if routine.disabledByFailures {
                Text("Disabled after \(routine.failureCount) consecutive failures — fix it, then re-enable.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            } else if let next = routine.nextRunAt {
                let when = Date(timeIntervalSince1970: next)
                Text("Next fire \(when.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let last = routine.lastRunAt {
                Text("Last fired \(Date(timeIntervalSince1970: last).formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13)))
    }
}