import EventKit
import Foundation

struct CalendarRemindersCapability {
    private let store: EKEventStore

    init() {
        store = EKEventStore()
    }

    // MARK: - Authorization

    static func authorizationStatus() -> (events: EKAuthorizationStatus, reminders: EKAuthorizationStatus) {
        (EKEventStore.authorizationStatus(for: .event), EKEventStore.authorizationStatus(for: .reminder))
    }

    func requestAuthorization() async throws {
        _ = try await store.requestFullAccessToEvents()
        _ = try await store.requestFullAccessToReminders()
    }

    // MARK: - Read Events

    func readUpcomingEvents(limit: Int = 10) async throws -> String {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw LLMError.networkError("Calendar access denied. Grant access in System Settings → Privacy & Security → Calendars.")
        }

        let now = Date()
        guard let endDate = Calendar.current.date(byAdding: .day, value: 30, to: now) else {
            throw LLMError.networkError("Could not compute event date range.")
        }

        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        guard !events.isEmpty else {
            return "No upcoming events."
        }

        return events.enumerated().map { i, e in
            let start = formatDateTime(e.startDate)
            let end = (!e.isAllDay && e.endDate != nil) ? " – \(formatTime(e.endDate))" : ""
            return "\(i + 1). \(e.title ?? "Untitled") — \(start)\(end) [\(e.calendar.title)]"
        }.joined(separator: "\n")
    }

    // MARK: - Read Reminders

    func readReminders(limit: Int = 10) async throws -> String {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else {
            throw LLMError.networkError("Reminders access denied. Grant access in System Settings → Privacy & Security → Reminders.")
        }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { results in
                continuation.resume(returning: results ?? [])
            }
        }
        let reminders = fetched.prefix(limit)

        guard !reminders.isEmpty else {
            return "No incomplete reminders."
        }

        return reminders.enumerated().map { i, r in
            let title = r.title ?? "Untitled"
            let notes = r.notes.map { " — \($0)" } ?? ""
            let due: String = {
                guard let comps = r.dueDateComponents,
                      let date = Calendar.current.date(from: comps)
                else { return "" }
                return " (due \(formatDateTime(date)))"
            }()
            return "\(i + 1). \(title)\(due)\(notes)"
        }.joined(separator: "\n")
    }

    // MARK: - Create Event

    func createEvent(title: String, startDate: Date, durationMinutes: Double, calendarName: String? = nil) async throws -> String {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw LLMError.networkError("Calendar access denied.")
        }

        let calendar: EKCalendar
        if let name = calendarName {
            guard let found = store.calendars(for: .event).first(where: { $0.title == name }) else {
                let available = store.calendars(for: .event).map(\.title).joined(separator: ", ")
                throw LLMError.networkError("Calendar \"\(name)\" not found. Available: \(available)")
            }
            calendar = found
        } else {
            guard let defaultCal = store.defaultCalendarForNewEvents else {
                throw LLMError.networkError("No default calendar for new events.")
            }
            calendar = defaultCal
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(durationMinutes * 60)
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent)
            return "Created event \"\(title)\" for \(formatDateTime(startDate)) (\(Int(durationMinutes)) min) in \"\(calendar.title)\"."
        } catch {
            throw LLMError.networkError("Failed to create event: \(error.localizedDescription)")
        }
    }

    // MARK: - Create Reminder

    func createReminder(title: String, notes: String? = nil, dueDate: Date? = nil) async throws -> String {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else {
            throw LLMError.networkError("Reminders access denied.")
        }

        guard let defaultList = store.defaultCalendarForNewReminders() else {
            throw LLMError.networkError("No default reminder list found.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = defaultList

        if let notes {
            reminder.notes = notes
        }

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        do {
            try store.save(reminder, commit: true)
            var result = "Created reminder \"\(title)\""
            if let dueDate {
                result += " due \(formatDateTime(dueDate))"
            }
            return result + "."
        } catch {
            throw LLMError.networkError("Failed to create reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func formatDateTime(_ date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        return "\(dateFormatter.string(from: date)) at \(timeFormatter.string(from: date))"
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
