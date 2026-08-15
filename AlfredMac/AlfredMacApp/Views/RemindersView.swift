//
//  RemindersView.swift
//  AlfredMacApp
//
//  The Reminders tab: Apple Reminders in miniature — a checklist where tapping the circle marks
//  a reminder done, sections keep today's and overdue items on top, and the + button opens the
//  same editor as tapping a row. Reads and writes the Mac's own reminders through EventKit.
//  Ported from the iOS app (Alfred/Alfred/Views/Calendar/RemindersView.swift).
//
//  Deviation from iOS: swipe-to-delete becomes a right-click context menu (macOS has no swipe
//  actions), and the access-denied button opens the macOS Reminders privacy pane.
//

import SwiftUI

struct RemindersView: View {
    @Environment(\.palette) private var palette

    @State private var store = RemindersStore()
    @State private var editingItem: ReminderItem?
    @State private var isEditorPresented = false

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                switch store.access {
                case .undetermined:
                    PermissionPrompt { await store.requestAccess() }
                case .denied(let reason):
                    AccessDenied(reason: reason)
                case .granted:
                    if store.items.isEmpty {
                        NothingScheduled(isLoading: store.isLoading)
                    } else {
                        list
                    }
                }
            }
            .navigationTitle("Reminders")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .modifier(TabToolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        editingItem = nil
                        isEditorPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New reminder")
                }
            })
        }
        .task { await store.load() }
        .task { await store.observeChanges() }
        .sheet(isPresented: $isEditorPresented) {
            ReminderEditorView(store: store, editing: editingItem) { _ in
                Task { await store.load() }
            }
        }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                ForEach(overdue) { row($0) }
            } header: {
                if !overdue.isEmpty { Text("Overdue") }
            }

            Section {
                ForEach(today) { row($0) }
            } header: {
                if !today.isEmpty { Text("Today") }
            }

            Section {
                ForEach(upcoming) { row($0) }
            } header: {
                if !upcoming.isEmpty { Text("Upcoming") }
            }

            Section {
                ForEach(noDate) { row($0) }
            } header: {
                if !noDate.isEmpty { Text("No date") }
            }

            Section {
                ForEach(completed) { row($0) }
            } header: {
                if !completed.isEmpty { Text("Completed") }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .refreshable { await store.load() }
    }

    private func row(_ item: ReminderItem) -> some View {
        Button {
            editingItem = item
            isEditorPresented = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                completionCircle(item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 16))
                        .foregroundStyle(item.isCompleted ? palette.textFaint : palette.textPrimary)
                        .strikethrough(item.isCompleted, color: palette.textFaint)
                        .multilineTextAlignment(.leading)

                    if let due = item.dueDate {
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(isOverdue(due) ? palette.danger : palette.textFaint)
                    }

                    if let notes = item.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textFaint)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // macOS has no swipe actions — delete lives on the context menu.
        .contextMenu {
            Button(role: .destructive) {
                try? store.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The tap target that completes a reminder without opening the editor.
    private func completionCircle(_ item: ReminderItem) -> some View {
        Button {
            try? store.setCompleted(item, !item.isCompleted)
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(item.isCompleted ? palette.textFaint : palette.textSecondary, lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                if item.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.success)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .accessibilityLabel(item.isCompleted ? "Mark not done" : "Mark done")
    }

    // MARK: Sections

    private var overdue: [ReminderItem] {
        store.items.notCompleted.filter { item in
            guard let due = item.dueDate else { return false }
            return due < calendar.startOfDay(for: Date())
        }
    }

    private var today: [ReminderItem] {
        store.items.notCompleted.filter { item in
            guard let due = item.dueDate else { return false }
            return calendar.isDateInToday(due)
        }
    }

    private var upcoming: [ReminderItem] {
        store.items.notCompleted.filter { item in
            guard let due = item.dueDate else { return false }
            return due > calendar.startOfDay(for: Date()) && !calendar.isDateInToday(due)
        }
    }

    private var noDate: [ReminderItem] {
        store.items.notCompleted.filter { $0.dueDate == nil }
    }

    private var completed: [ReminderItem] {
        store.items.completed.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
    }

    private var items: [ReminderItem] { store.items }

    private func isOverdue(_ due: Date) -> Bool {
        due < Date() && !Calendar.current.isDateInToday(due)
    }
}

extension Array where Element == ReminderItem {
    var notCompleted: [ReminderItem] { filter { !$0.isCompleted } }
    var completed: [ReminderItem] { filter(\.isCompleted) }
}

// MARK: - Editor

struct ReminderEditorView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: RemindersStore
    /// The reminder being edited, or nil for a new one.
    let editing: ReminderItem?
    let onChanged: (ReminderItem?) -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate: Date = Date().addingTimeInterval(3600)
    @State private var saveError: String?

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section {
                        TextField("Title", text: $title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                    }

                    Section {
                        Toggle("Due date", isOn: $hasDueDate)
                            .tint(palette.accent)
                        if hasDueDate {
                            DatePicker("Due", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                        }
                    }

                    Section {
                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(2...6)
                            .foregroundStyle(palette.textPrimary)
                    }

                    if isEditing {
                        Section {
                            Button(role: .destructive) {
                                guard let editing else { return }
                                do {
                                    try store.delete(editing)
                                    onChanged(nil)
                                    dismiss()
                                } catch {
                                    saveError = "Deleting failed: \(error.localizedDescription)"
                                }
                            } label: {
                                Text("Delete Reminder")
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(palette.danger)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(isEditing ? "Edit Reminder" : "New Reminder")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let editing {
                    title = editing.title == "(untitled)" ? "" : editing.title
                    notes = editing.notes ?? ""
                    hasDueDate = editing.dueDate != nil
                    dueDate = editing.dueDate ?? Date().addingTimeInterval(3600)
                }
            }
            .alert("Couldn't save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        let draft = RemindersStore.ReminderDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(untitled)" : title,
            dueDate: hasDueDate ? dueDate : nil,
            notes: notes
        )

        do {
            try store.save(draft, editing: editing)
            onChanged(nil)
            dismiss()
        } catch {
            saveError = "Saving failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Shared states (calendar tab's, generalised)

/// Permission asker. This and AccessDenied are deliberately small duplicates of the Calendar
/// tab's versions rather than a shared generic: the copy differs (reminders vs calendars), and
/// a shared parameterised component would leak that difference into every call site.
private struct PermissionPrompt: View {
    @Environment(\.palette) private var palette

    let request: () async -> Void

    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checklist")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [palette.accentSoft, palette.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Text("Keep track of things")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 18)

            Text("Alfred reads and manages your reminders — everything the Reminders app already holds. Nothing leaves the device.")
                .font(.system(size: 16))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 36)

            Button {
                isRequesting = true
                Task {
                    await request()
                    isRequesting = false
                }
            } label: {
                Text(isRequesting ? "Waiting…" : "Connect Reminders")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.backgroundTop)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(palette.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)
            .padding(.top, 28)
            .padding(.horizontal, 36)

            Spacer()
            Spacer()
        }
    }
}

private struct AccessDenied: View {
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    let reason: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checklist")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.textFaint)

            Text("Reminders are off")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 18)

            Text(reason)
                .font(.system(size: 16))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 36)

            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    openURL(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accentBright)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.surfaceBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 28)
            .padding(.horizontal, 36)

            Spacer()
            Spacer()
        }
    }
}

private struct NothingScheduled: View {
    @Environment(\.palette) private var palette

    let isLoading: Bool

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            if isLoading {
                ProgressView()
                    .tint(palette.accent)
            } else {
                Image(systemName: "checklist")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(palette.textFaint)

                Text("No reminders yet")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer()
            Spacer()
        }
    }
}
