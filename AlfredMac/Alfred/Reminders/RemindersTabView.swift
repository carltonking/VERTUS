import AppKit
import EventKit
import SwiftUI

/// The "Reminders" tab in the menu-bar popover: a simple list of incomplete Apple Reminders
/// (grouped by due day, undated last) with check-off and an inline create form. Read/write goes
/// through `CalendarRemindersCapability` (EventKit).
struct RemindersTabView: View {
    @State private var capability = CalendarRemindersCapability()
    @State private var reminders: [ReminderItem] = []
    @State private var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    @State private var loadError: String?
    @State private var showingAdd = false
    // Cached grouping — recomputed only when `reminders` changes (in load()), not on every body eval
    // or unrelated @State change (showingAdd/status/loadError).
    @State private var dayGroups: [DayGroup] = []
    @State private var undated: [ReminderItem] = []

    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            if status == .denied || status == .restricted {
                deniedState
            } else {
                header
                Divider()
                list
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingAdd) {
            AddReminderSheet(capability: capability, defaultDay: Date()) {
                Task { await load() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Reminders").font(.subheadline.bold())
            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh")
            Button { showingAdd = true } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain).help("New reminder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if reminders.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("No reminders").font(.subheadline.bold())
                Text("Press + to add one, or check items off as you finish.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(dayGroups, id: \.key) { group in
                        sectionHeader(group.title)
                        ForEach(group.items) { reminderRow($0) }
                    }
                    if !undated.isEmpty {
                        sectionHeader("No date")
                        ForEach(undated) { reminderRow($0) }
                    }
                    if let loadError {
                        Text(loadError).font(.caption2).foregroundStyle(.orange).padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 8)
    }

    private func reminderRow(_ r: ReminderItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { toggle(r) } label: {
                Image(systemName: r.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(r.isCompleted ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.caption).strikethrough(r.isCompleted)
                HStack(spacing: 6) {
                    if let due = r.due {
                        Label(timeString(due), systemImage: "clock")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !r.listName.isEmpty {
                        Text(r.listName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let notes = r.notes, !notes.isEmpty {
                    Text(notes).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }

    // MARK: - Permission denied

    private var deniedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Reminders access off").font(.subheadline.bold())
            Text("Enable Reminders for Alfred in System Settings → Privacy & Security → Reminders.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: - Data

    private func load() async {
        do {
            reminders = try await capability.fetchReminders()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        status = EKEventStore.authorizationStatus(for: .reminder)
        recomputeGroups()
    }

    private func toggle(_ r: ReminderItem) {
        Task {
            do {
                try await capability.setReminderCompleted(id: r.id, completed: !r.isCompleted)
            } catch {
                loadError = error.localizedDescription
            }
            await load()
        }
    }

    // MARK: - Grouping

    private struct DayGroup { let key: Double; let title: String; let items: [ReminderItem] }

    /// Recompute the grouped/undated caches from `reminders`. Called whenever reminders changes.
    /// Due-dated reminders grouped by day, earliest first; items within a day sorted by time.
    private func recomputeGroups() {
        let byDay = Dictionary(grouping: reminders.filter { $0.due != nil }) { cal.startOfDay(for: $0.due!) }
        dayGroups = byDay.keys.sorted().map { day in
            let items = (byDay[day] ?? []).sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            return DayGroup(key: day.timeIntervalSince1970, title: dayTitle(day), items: items)
        }
        undated = reminders.filter { $0.due == nil }
    }

    private func dayTitle(_ day: Date) -> String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return Self.dayFormatter.string(from: day)
    }

    private func timeString(_ d: Date) -> String { Self.timeFormatter.string(from: d) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}

// MARK: - Create reminder

private struct AddReminderSheet: View {
    let capability: CalendarRemindersCapability
    let defaultDay: Date
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var hasDue = true
    @State private var due = Date()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Reminder").font(.title3.bold())
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Toggle("Has due date", isOn: $hasDue)
            if hasDue {
                DatePicker("Due", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 360)
        .onAppear {
            // Default a new reminder to 9am today.
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: defaultDay)
            comps.hour = 9
            comps.minute = 0
            due = Calendar.current.date(from: comps) ?? defaultDay
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await capability.createReminder(title: trimmed, notes: nil, dueDate: hasDue ? due : nil)
                onSave()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
