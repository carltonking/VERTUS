//
//  RemindersStore.swift
//  Alfred
//
//  The phone's reminders, read and written through EventKit — EventKit keeps reminders in the
//  same store object as events but gates them behind their own permission, so this store asks for
//  and manages that one separately. A single EKEventStore per permission keeps the change
//  notifications flowing the same way CalendarStore relies on them.
//
//  Only the default reminder list is used when creating: that's the list Apple Calendar offers a
//  new reminder into, and inventing list management here would be scope nobody asked for.
//

import EventKit
import Foundation
import Observation

// MARK: - What the views draw

/// One reminder, flattened out of EventKit for the same reason CalendarEntry is: EKReminder is a
/// live object that faults in on access, and views shouldn't hold onto live store objects.
struct ReminderItem: Identifiable, Hashable {
    let id: String
    let title: String
    let dueDate: Date?
    let notes: String?
    let isCompleted: Bool
    let completionDate: Date?
    let listName: String
    let listColorHex: String?
}

// MARK: - The store

@MainActor
@Observable
final class RemindersStore {
    enum Access: Equatable {
        case undetermined
        case granted
        case denied(reason: String)
    }

    private(set) var access: Access
    private(set) var items: [ReminderItem] = []
    private(set) var isLoading = false

    private let store = EKEventStore()

    init() {
        access = Self.currentAccess()
    }

    // MARK: Permission

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined:
            return .undetermined
        case .fullAccess:
            return .granted
        case .writeOnly:
            return .denied(reason: "Alfred can add reminders but not read them. "
                + "Switch Reminders to Full Access in Settings to see them here.")
        case .denied:
            return .denied(reason: "Reminders access is turned off for Alfred.")
        case .restricted:
            return .denied(reason: "Reminders access is restricted on this device, so Alfred can't read them.")
        @unknown default:
            return .denied(reason: "iOS gave an answer about reminders access this app doesn't recognise.")
        }
    }

    func requestAccess() async {
        guard access == .undetermined else { return }
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            // Mirrors CalendarStore: the thrown error adds nothing the status doesn't already say.
        }
        access = Self.currentAccess()
        await load()
    }

    // MARK: Reading

    func load() async {
        access = Self.currentAccess()
        guard access == .granted else {
            items = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        // fetchReminders hands results to a completion callback, not a return value, and the
        // flattened items are all Sendable value types — so the bridge is just a continuation.
        let fetched: [ReminderItem] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { reminders in
                let flattened = (reminders ?? []).map(Self.item(from:))
                Task { @MainActor in continuation.resume(returning: flattened) }
            }
        }

        items = fetched.sorted { lhs, rhs in
            if let l = lhs.dueDate, let r = rhs.dueDate { return l < r }
            return lhs.dueDate != nil
        }
    }

    func observeChanges() async {
        // Reminders and events share the .EKEventStoreChanged notification, so one observation
        // stream covers the whole store this tab reads from.
        let changes = NotificationCenter.default.notifications(named: .EKEventStoreChanged)
        for await _ in changes {
            await load()
        }
    }

    // MARK: Writing

    /// The fields the reminder editor edits, kept separate from live EKReminder objects.
    struct ReminderDraft {
        var title: String
        var dueDate: Date?
        var notes: String
    }

    /// Create or update a reminder. Passing an item makes it an edit of that item; nil creates a
    /// new one in the default reminder list.
    func save(_ draft: ReminderDraft, editing item: ReminderItem?) throws {
        guard access == .granted else { return }

        let reminder: EKReminder
        if let item, let live = liveItem(for: item) {
            reminder = live
        } else {
            reminder = EKReminder(eventStore: store)
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        reminder.title = draft.title
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        if let due = draft.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
        } else {
            reminder.dueDateComponents = nil
        }

        try store.save(reminder, commit: true)
    }

    func delete(_ item: ReminderItem) throws {
        guard access == .granted, let live = liveItem(for: item) else { return }
        try store.remove(live, commit: true)
    }

    /// Flip a reminder between done and not done. Completion is a stored property, not a derived
    /// one, so EventKit needs both the flag and the timestamp written together.
    func setCompleted(_ item: ReminderItem, _ completed: Bool) throws {
        guard access == .granted, let live = liveItem(for: item) else { return }
        live.isCompleted = completed
        live.completionDate = completed ? Date() : nil
        try store.save(live, commit: true)
    }

    /// Refetch the live EKReminder behind a flattened item, by the stable calendarItemIdentifier.
    private func liveItem(for item: ReminderItem) -> EKReminder? {
        store.calendarItem(withIdentifier: item.id) as? EKReminder
    }

    private static func item(from reminder: EKReminder) -> ReminderItem {
        ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: (reminder.title?.isEmpty == false) ? reminder.title! : "(untitled)",
            dueDate: reminder.dueDateComponents?.date,
            notes: reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            listName: reminder.calendar.title,
            listColorHex: reminder.calendar.cgColor.hexString
        )
    }
}
