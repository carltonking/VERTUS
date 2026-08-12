//
//  RoutinesView.swift
//  Alfred
//
//  The Routines tab: scheduled workflows Alfred runs for you, triggered from
//  the phone. Lists everything the Mac knows, offers the template library as
//  one-tap adds, lets you build your own, and shows a live banner while a
//  routine is running.
//
//  Everything goes over the WebSocket as JSON-RPC — routines.list / .run /
//  .create / .update / .delete — and the Mac pushes routine.started /
//  .progress / .completed notifications that drive the running banner.
//

import SwiftUI

/// Create or edit. `.edit` carries the routine being changed so the builder
/// can prefill; `id` drives the sheet presentation.
enum RoutineBuilderMode: Identifiable {
    case create
    case edit(RoutineSummary)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let routine): return "edit-\(routine.id)"
        }
    }
}

/// What's currently running, from the pushed lifecycle notifications.
private struct RunningState {
    var id: UUID
    var text: String
}

struct RoutinesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    private var socket: AlfredWebSocketClient { .shared }

    @State private var routines: [RoutineSummary] = []
    @State private var loading = false
    @State private var showBuilder = false
    @State private var builderMode: RoutineBuilderMode?
    @State private var detailRoutine: RoutineSummary?
    @State private var running: RunningState?
    @State private var resultFlash: String?

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                content
            }
            .navigationTitle("Routines")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        builderMode = .create
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(palette.accentBright)
                    }
                    .disabled(!settings.isConfigured)
                    .accessibilityLabel("New routine")
                }
            }
        }
        .sheet(item: $builderMode) { mode in
            RoutineBuilderModal(mode: mode) { _ in
                Task { await reload() }
            }
        }
        .sheet(item: $detailRoutine) { routine in
            RoutineDetailSheet(routine: routine) { edited in
                detailRoutine = nil
                builderMode = .edit(edited)
            }
        }
        .task { await reload() }
        .task { await observeRoutineEvents() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            notConnected
        } else if routines.isEmpty && !loading {
            emptyState
        } else {
            routineList
        }
    }

    private var notConnected: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "bolt.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text("Not connected")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)
            Text("Routines run on your Mac. Connect in Settings and they'll show up here.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "bolt")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [palette.accentSoft, palette.accent],
                        startPoint: .top, endPoint: .bottom))
            Text("No routines yet")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)
            Text("Add one from the templates below, or build your own with the + button.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private var routineList: some View {
        List {
            if let running {
                runningBanner(running)
            }
            if let flash = resultFlash {
                resultFlashRow(flash)
            }

            Section("Quick add") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(RoutineTemplatesPayload.names, id: \.self) { name in
                            templateChip(name)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section("My routines") {
                ForEach(routines) { routine in
                    routineRow(routine)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    let toDelete = offsets.map { routines[$0] }
                    Task {
                        for routine in toDelete {
                            _ = await socket.deleteRoutine(id: routine.id)
                        }
                        await reload()
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await reload() }
    }

    // MARK: - Live status

    /// The running banner: shows while a routine is executing on the Mac, fed
    /// by pushed routine.started / routine.progress notifications.
    private func runningBanner(_ state: RunningState) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(palette.accentBright)
            Text(state.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(palette.accent.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// One-line acknowledgement of the last completed run.
    private func resultFlashRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: text.contains("✗") ? "xmark.circle" : "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(text.contains("✗") ? palette.danger : palette.success)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Templates

    private func templateChip(_ name: String) -> some View {
        Button {
            Task { await addTemplate(name) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: RoutineTemplatesPayload.icon(for: name))
                    .font(.system(size: 17))
                    .foregroundStyle(palette.accentBright)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 104, height: 74)
            .background(palette.surface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func addTemplate(_ name: String) async {
        _ = await socket.addRoutineTemplate(named: name)
        await reload()
    }

    // MARK: - Routine row

    private func routineRow(_ routine: RoutineSummary) -> some View {
        HStack(spacing: 12) {
            Button {
                detailRoutine = routine
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(routine.name)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        if !routine.enabled {
                            Text("paused")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.textFaint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(palette.surfaceBorder.opacity(0.5))
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle(routine))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                    statusLine(routine)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { routine.enabled },
                set: { newValue in toggle(routine, to: newValue) }))
            .labelsHidden()
            .tint(palette.accent)

            Button {
                runNow(routine)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 34, height: 34)
                    .background(palette.surface.opacity(0.8))
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(palette.surfaceBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(routine.name)")
        }
        .padding(14)
        .background(palette.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    /// "Daily at 8:00 AM · Next 8:00 AM" or "On demand".
    private func subtitle(_ routine: RoutineSummary) -> String {
        var parts: [String] = [routine.schedule.displayText]
        if routine.nextFireAt > 0 {
            parts.append("Next \(timeText(routine.nextFireAt))")
        }
        return parts.joined(separator: " · ")
    }

    /// Last run outcome, when there is one: "✓ 3/5 steps · 12s ago".
    @ViewBuilder
    private func statusLine(_ routine: RoutineSummary) -> some View {
        if let result = routine.lastResult {
            HStack(spacing: 5) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(result.success ? palette.success : palette.danger)
                Text("\(result.stepsCompleted)/\(result.stepsTotal) steps · \(timeAgo(result.completedAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            }
        }
    }

    // MARK: - Actions

    private func runNow(_ routine: RoutineSummary) {
        // Optimistic banner so the tap has instant feedback; the pushed
        // notifications refine it. The Mac broadcasts routine.started within
        // a beat anyway.
        running = RunningState(id: routine.id, text: "Starting \(routine.name)…")
        Task {
            _ = await socket.runRoutine(id: routine.id)
            await reload()
        }
    }

    private func toggle(_ routine: RoutineSummary, to enabled: Bool) {
        Task {
            if let updated = await socket.updateRoutine(id: routine.id, enabled: enabled),
               let index = routines.firstIndex(where: { $0.id == updated.id }) {
                routines[index] = updated
            }
        }
    }

    private func reload() async {
        guard settings.isConfigured else { return }
        loading = true
        defer { loading = false }
        routines = await socket.listRoutines()
    }

    /// Consume the pushed routine lifecycle events.
    private func observeRoutineEvents() async {
        for await update in socket.updates() {
            switch update {
            case .routineStarted(let id, let name):
                running = RunningState(id: UUID(uuidString: id) ?? UUID(), text: "Running \(name)…")
            case .routineProgress(let id, let name, let step, let total, _):
                running = RunningState(
                    id: UUID(uuidString: id) ?? UUID(),
                    text: "\(name): step \(step) of \(total)…")
            case .routineCompleted(let id, let name, let success, _, _):
                if let running, running.id.uuidString == id {
                    self.running = nil
                }
                resultFlash = success ? "\(name) finished ✓" : "\(name) hit a problem ✗"
                // Pick up the refreshed lastResult.
                await reload()
            default:
                break
            }
        }
    }

    // MARK: - Formatting

    private func timeText(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .omitted, time: .shortened)
    }

    private func timeAgo(_ timestamp: TimeInterval) -> String {
        // An unset timestamp would read as "millions of hours ago".
        guard timestamp > 0 else { return "just now" }
        let minutes = Int(max(0, Date().timeIntervalSince1970 - timestamp) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes)m ago"
        default: return "\(minutes / 60)h ago"
        }
    }
}

// MARK: - Detail sheet

/// Drill-in for one routine: its steps, schedule, and the last run's full
/// output with a per-step breakdown. "Edit" hands off to the builder.
private struct RoutineDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private let routine: RoutineSummary
    private let onEdit: (RoutineSummary) -> Void

    init(routine: RoutineSummary, onEdit: @escaping (RoutineSummary) -> Void) {
        self.routine = routine
        self.onEdit = onEdit
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        sectionCard("Steps", icon: "list.bullet") {
                            VStack(spacing: 0) {
                                ForEach(Array(routine.steps.enumerated()), id: \.offset) { index, step in
                                    HStack(spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(palette.textFaint)
                                            .frame(width: 20)
                                        Image(systemName: step.icon)
                                            .font(.system(size: 13))
                                            .foregroundStyle(palette.accentBright)
                                            .frame(width: 20)
                                        Text(step.label)
                                            .font(.system(size: 14))
                                            .foregroundStyle(palette.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 7)
                                    if index < routine.steps.count - 1 {
                                        Divider().overlay(palette.surfaceBorder.opacity(0.6))
                                    }
                                }
                            }
                        }

                        sectionCard("Schedule", icon: "clock") {
                            Text(routine.schedule.displayText)
                                .font(.system(size: 14))
                                .foregroundStyle(palette.textSecondary)
                        }

                        if let result = routine.lastResult {
                            resultCard(result)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onEdit(routine)
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(palette.accentBright)
                    }
                    .accessibilityLabel("Edit routine")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !routine.description.isEmpty {
                Text(routine.description)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(routine.enabled ? "Enabled" : "Paused")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(routine.enabled ? palette.success : palette.textFaint)
        }
    }

    private func sectionCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentBright)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    /// The last run: verdict, duration, full output, per-step outcomes.
    @ViewBuilder
    private func resultCard(_ result: RoutineResultPayload) -> some View {
        sectionCard("Last run", icon: result.success ? "checkmark.circle" : "xmark.circle") {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.success
                     ? "Completed \(result.stepsCompleted)/\(result.stepsTotal) steps"
                     : "Finished with issues — \(result.stepsCompleted)/\(result.stepsTotal) steps")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(result.success ? palette.success : palette.danger)

                if result.duration > 0 {
                    Text(String(format: "%.1fs", result.duration))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(palette.textFaint)
                }

                if !result.stepResults.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.stepResults, id: \.index) { step in
                            HStack(spacing: 8) {
                                Image(systemName: step.success ? "checkmark" : "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(step.success ? palette.success : palette.danger)
                                    .frame(width: 14)
                                Text(step.label)
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                if !result.output.isEmpty {
                    Text(result.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.backgroundTop.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}
