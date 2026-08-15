//
//  RoutinesView.swift
//  AlfredMacApp
//
//  The Routines tab: scheduled workflows Alfred runs for you, triggered from
//  the Mac. Lists everything the Mac knows, offers the template library as
//  one-tap adds, lets you build your own, and shows a live banner while a
//  routine is running. Ported from the iOS app
//  (Alfred/Alfred/Views/RoutinesView.swift).
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
    /// True once the Mac has answered a fetch — the empty state only shows
    /// after a real answer, not during the first (possibly slow) connect.
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                content
            }
            .navigationTitle("Routines")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .modifier(TabToolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        builderMode = .create
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(palette.accentBright)
                    }
                    .disabled(!linkAvailable)
                    .accessibilityLabel("New routine")
                }
            })
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
        .onChange(of: settings.routinesEnabled) { _, enabled in
            // Re-enabling shows the Mac's current list, not the snapshot from
            // whenever the tab last fetched.
            if enabled { Task { await reload() } }
        }
        .onChange(of: socket.state) { _, state in
            // The socket can land after this tab's first fetch (discovery is
            // async), and RootView keeps tabs alive so .task won't re-run on a
            // tab switch. Once the link is up, pull the real list.
            if state == .connected { Task { await reload() } }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !settings.routinesEnabled {
            turnedOff
        } else if !linkAvailable {
            notConnected
        } else if routines.isEmpty && !loading && hasLoaded {
            emptyState
        } else if routines.isEmpty && !hasLoaded && socket.isConnected {
            loadingPlaceholder
        } else if routines.isEmpty && !hasLoaded {
            // A socket host exists but the Mac hasn't answered — say so
            // instead of spinning forever on a placeholder.
            notConnected
        } else {
            routineList
        }
    }

    // MARK: - Link state

    /// These tabs talk to the Mac only over the live socket — the relay's
    /// configured state (host + token) is irrelevant here. A socket host
    /// (pinned or discovered) or an active connection is what matters.
    private var linkAvailable: Bool {
        socket.isConnected || settings.socketURL != nil
    }

    /// Brief spinner while the first fetch is in flight — distinct from the
    /// empty state, so a slow first connect doesn't read as "no routines".
    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(palette.accentBright)
            Text("Loading from your Mac…")
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when the Settings toggle is off — a pointer back, not a dead end.
    private var turnedOff: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "bolt.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text("Routines are off")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)
            Text("Turn them back on in Settings and your Mac's routines will show up here.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
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

    /// Last run outcome, when there is one: "✓ 3/5 steps · 12s ago". While a run
    /// is in flight the card shows a live spinner instead, so the row that was
    /// told to run is the row visibly running.
    @ViewBuilder
    private func statusLine(_ routine: RoutineSummary) -> some View {
        if let running, running.id == routine.id {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(palette.accentBright)
                Text("Running…")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.accentBright)
            }
        } else if let result = routine.lastResult {
            HStack(spacing: 5) {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(result.success ? palette.success : palette.danger)
                Text("\(result.stepsCompleted)/\(result.stepsTotal) steps · \(timeAgo(result.completedAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            }
        } else {
            Text(routine.lastRun > 0 ? "Last run \(timeAgo(routine.lastRun))" : "Never run")
                .font(.system(size: 12))
                .foregroundStyle(palette.textFaint)
        }
    }

    // MARK: - Actions

    private func runNow(_ routine: RoutineSummary) {
        // Optimistic banner so the tap has instant feedback; the pushed
        // notifications refine it. The Mac broadcasts routine.started within
        // a beat anyway.
        running = RunningState(id: routine.id, text: "Starting \(routine.name)…")
        Task {
            let result = await socket.runRoutine(id: routine.id)
            if result == nil {
                // The Mac never accepted the run — drop the optimistic banner
                // rather than leaving a spinner that can never resolve.
                running = nil
            }
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
        guard linkAvailable else {
            NSLog("[routines] reload skipped — no live link (socket %@, host %@)",
                  socket.isConnected ? "connected" : "down", settings.socketHost)
            return
        }
        // Once the Mac has answered, never wipe a good list with a dead-socket
        // [] (listRoutines returns [] on failure too) — keep showing last-known
        // data until the link is back.
        if hasLoaded && !socket.isConnected {
            NSLog("[routines] socket down — keeping last-known list")
            return
        }
        loading = true
        defer { loading = false }
        routines = await socket.listRoutines()
        hasLoaded = true
        NSLog("[routines] reload — %d routines from Mac", routines.count)
    }

    /// Consume the pushed routine lifecycle events.
    private func observeRoutineEvents() async {
        NSLog("[routines] observing routine lifecycle events")
        for await update in socket.updates() {
            switch update {
            case .routineStarted(let id, let name):
                NSLog("[routines] event routine.started — %@ (%@)", name, id)
                running = RunningState(id: UUID(uuidString: id) ?? UUID(), text: "Running \(name)…")
            case .routineProgress(let id, let name, let step, let total, _):
                NSLog("[routines] event routine.progress — %@ step %d/%d", name, step, total)
                running = RunningState(
                    id: UUID(uuidString: id) ?? UUID(),
                    text: "\(name): step \(step) of \(total)…")
            case .routineCompleted(let id, let name, let success, _, _):
                NSLog("[routines] event routine.completed — %@ success=%@", name, success ? "ok" : "fail")
                if let running, running.id.uuidString == id {
                    self.running = nil
                }
                resultFlash = success ? "\(name) finished ✓" : "\(name) hit a problem ✗"
                // Pick up the refreshed lastResult.
                await reload()
            case .routinesChanged:
                NSLog("[routines] event routines.changed — refreshing list")
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
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
                ToolbarItem(placement: .automatic) {
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
