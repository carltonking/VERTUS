import CoreLocation
import EventKit
import Foundation

/// An upcoming timed event that has a location — the input to the departure/travel-time watcher.
struct LocatedEvent: Identifiable, Hashable {
    let id: String              // eventIdentifier + start (recurring-safe)
    let title: String
    let start: Date
    let location: String        // non-empty raw location text
    let coordinate: CLLocation? // from EKStructuredLocation when the calendar provided one; else nil
}

/// A reminder flattened into a UI-friendly value (the Reminders tab renders these instead of
/// raw `EKReminder`s or the text strings the assistant consumes).
struct ReminderItem: Identifiable, Hashable {
    let id: String          // EKReminder.calendarItemIdentifier (stable, global)
    let title: String
    let due: Date?          // resolved from dueDateComponents; nil = undated
    let notes: String?
    let isCompleted: Bool
    let listName: String
}

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

    /// Upcoming timed (non-all-day) events that have a location, within `hours` from now — the input
    /// to the departure watcher. Skips events with no location text; returns the structured coordinate
    /// when the calendar supplied one (else nil → the caller geocodes the text). Requesting access when
    /// already decided does not re-prompt.
    func upcomingTimedEventsWithLocation(withinHours hours: Int = 3) async -> [LocatedEvent] {
        // Only request access when undetermined; when already authorized skip the request (a no-op
        // re-prompt-wise, but still an async round-trip on every 180s DepartureWatcher cycle).
        let granted: Bool
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            granted = true
        case .notDetermined:
            granted = (try? await store.requestFullAccessToEvents()) == true
        default:
            granted = false
        }
        guard granted else { return [] }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: hours, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now }
            .compactMap { e -> LocatedEvent? in
                guard let loc = e.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !loc.isEmpty else { return nil }
                let base = e.eventIdentifier ?? (e.title ?? "event")
                return LocatedEvent(id: "\(base)@\(Int(e.startDate.timeIntervalSince1970))",
                                    title: e.title ?? "Untitled", start: e.startDate,
                                    location: loc, coordinate: e.structuredLocation?.geoLocation)
            }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Create Event

    /// Creates and saves an event on the user's default calendar. `end` defaults to +1h for timed
    /// events; all-day events span the single day. Returns a human-readable confirmation.
    func createEvent(title: String, start: Date, end: Date?, location: String?,
                     notes: String?, allDay: Bool) async throws -> String {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            throw LLMError.networkError("Calendar access denied. Grant it in System Settings → Privacy & Security → Calendars.")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw LLMError.networkError("No default calendar is set — open Calendar and choose one, then try again.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = allDay ? start : (end ?? start.addingTimeInterval(3600))
        if let location, !location.isEmpty { event.location = location }
        if let notes, !notes.isEmpty { event.notes = notes }
        event.calendar = calendar
        try store.save(event, span: .thisEvent)

        let df = DateFormatter()
        df.dateFormat = allDay ? "EEE, MMM d, yyyy" : "EEE, MMM d, yyyy 'at' HH:mm"
        let locStr = (location?.isEmpty == false) ? " · \(location!)" : ""
        return "✅ Added “\(title)” to your calendar — \(df.string(from: start))\(locStr)."
    }

    // MARK: - School events (syllabus) — iCloud calendar + alarms, tagged to match the cloud bot

    /// A writable iCloud (CalDAV) event calendar — events MUST live here (not "On My Mac") to sync to
    /// the iPhone. Prefers one named `name` (the cloud pins "Personal"), then the default, then any.
    func iCloudEventCalendar(named name: String) throws -> EKCalendar {
        let cals = store.calendars(for: .event)
        if let hit = cals.first(where: { $0.title == name && $0.source?.sourceType == .calDAV && $0.allowsContentModifications }) {
            return hit
        }
        if let def = store.defaultCalendarForNewEvents, def.source?.sourceType == .calDAV, def.allowsContentModifications {
            return def
        }
        if let any = cals.first(where: { $0.source?.sourceType == .calDAV && $0.allowsContentModifications }) {
            return any
        }
        throw LLMError.networkError("No iCloud calendar found. Turn on iCloud → Calendars in System Settings so reminders reach your iPhone.")
    }

    /// Create/update one school event (idempotent: search-before-create by the shared url/key).
    @discardableResult
    func upsertSchoolEvent(_ spec: SchoolEventSpec, calendarName: String = "Personal") async throws -> String {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            throw LLMError.networkError("Calendar access denied. Grant it in System Settings → Privacy & Security → Calendars.")
        }
        let calendar = try iCloudEventCalendar(named: calendarName)
        guard let start = syllabusDate(spec.date, time: spec.allDay ? nil : spec.start) else {
            throw LLMError.networkError("Bad date \(spec.date).")
        }
        let lo = Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start
        let hi = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [calendar])
        let existing = store.events(matching: pred).first {
            $0.url?.absoluteString == spec.url || ($0.notes?.contains("k=\(spec.key)") ?? false)
        }
        let event = existing ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = spec.displayTitle
        event.isAllDay = spec.allDay
        event.startDate = start
        if spec.allDay {
            event.endDate = start
        } else {
            let end = spec.end.flatMap { syllabusDate(spec.date, time: $0) } ?? start.addingTimeInterval(3600)
            event.endDate = end > start ? end : start.addingTimeInterval(3600)
        }
        if let loc = spec.location, !loc.isEmpty { event.location = loc }
        event.url = URL(string: spec.url)
        event.notes = [spec.humanNotes, spec.token].compactMap { $0 }.joined(separator: "\n\n")
        event.alarms = spec.alarmOffsets.map { EKAlarm(relativeOffset: $0) }
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    /// Create many school events on one iCloud calendar. Returns (ok, failed).
    func createSchoolEvents(_ specs: [SchoolEventSpec], calendarName: String = "Personal") async throws -> (ok: Int, failed: Int) {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            throw LLMError.networkError("Calendar access denied. Grant it in System Settings → Privacy & Security → Calendars.")
        }
        _ = try iCloudEventCalendar(named: calendarName) // validate the calendar up front
        var ok = 0, failed = 0
        for spec in specs {
            do { _ = try await upsertSchoolEvent(spec, calendarName: calendarName); ok += 1 }
            catch { failed += 1 }
        }
        return (ok, failed)
    }

    /// The courses currently on the calendar, derived from tagged events (the calendar is the store).
    func listSchoolCourses(calendarName: String = "Personal") async throws -> [CourseSummary] {
        guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        let calendar = try iCloudEventCalendar(named: calendarName)
        let now = Date()
        let lo = Calendar.current.date(byAdding: .day, value: -400, to: now) ?? now
        let hi = Calendar.current.date(byAdding: .day, value: 400, to: now) ?? now
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [calendar])
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for e in store.events(matching: pred) {
            guard let notes = e.notes, let tok = SyllabusKeys.parseToken(notes), let c = tok["c"] else { continue }
            counts[c, default: 0] += (tok["t"] == "study" ? 0 : 1) // ensure the key exists; count deadlines only
            if display[c] == nil, let title = e.title,
               let r = title.range(of: "\\[([^\\]]+)\\]", options: .regularExpression) {
                display[c] = String(title[r].dropFirst().dropLast())
            }
        }
        return counts.keys.sorted().map { CourseSummary(code: $0, display: display[$0] ?? $0, count: counts[$0] ?? 0) }
    }

    /// Delete all school events for a course code (matches the token's c=<CODE> field in notes).
    @discardableResult
    func deleteSchoolCourse(code: String, calendarName: String = "Personal") async throws -> Int {
        guard (try? await store.requestFullAccessToEvents()) == true else { return 0 }
        let calendar = try iCloudEventCalendar(named: calendarName)
        let now = Date()
        let lo = Calendar.current.date(byAdding: .day, value: -400, to: now) ?? now
        let hi = Calendar.current.date(byAdding: .day, value: 400, to: now) ?? now
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: [calendar])
        let norm = SyllabusKeys.normCode(code)
        let matches = store.events(matching: pred).filter { $0.notes?.contains("c=\(norm)|") ?? false }
        var n = 0
        for e in matches where (try? store.remove(e, span: .thisEvent, commit: true)) != nil { n += 1 }
        return n
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

    // MARK: - Reminders (structured, for UI)

    /// Fetches reminders as structured `ReminderItem`s for the Reminders tab. Incomplete only by
    /// default. Read path mirrors `readReminders` but returns models instead of formatted text.
    func fetchReminders(includeCompleted: Bool = false) async throws -> [ReminderItem] {
        try await ensureRemindersAccess()
        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return fetched.map { r in
            ReminderItem(
                id: r.calendarItemIdentifier,
                title: r.title ?? "Untitled",
                due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                notes: r.notes,
                isCompleted: r.isCompleted,
                listName: r.calendar?.title ?? ""
            )
        }
    }

    /// Marks a reminder complete/incomplete by identifier, writing back to Apple Reminders.
    func setReminderCompleted(id: String, completed: Bool) async throws {
        try await ensureRemindersAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }

    /// Requests Reminders access only when undetermined (re-requesting an already-resolved status
    /// is unnecessary and, for some EventKit stores, can stall). Throws if denied/restricted.
    private func ensureRemindersAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .denied, .restricted:
            throw LLMError.networkError("Reminders access denied. Grant access in System Settings → Privacy & Security → Reminders.")
        case .notDetermined:
            let granted = try await store.requestFullAccessToReminders()
            guard granted else {
                throw LLMError.networkError("Reminders access denied. Grant access in System Settings → Privacy & Security → Reminders.")
            }
        default:
            return   // .fullAccess / .authorized (legacy) / .writeOnly
        }
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

    // Cached instead of allocating per event/reminder inside the read-loop .map calls.
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private static let hourMinuteFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func formatDateTime(_ date: Date) -> String {
        return "\(Self.monthDayFormatter.string(from: date)) at \(Self.hourMinuteFormatter.string(from: date))"
    }

    private func formatTime(_ date: Date) -> String {
        return Self.hourMinuteFormatter.string(from: date)
    }
}
