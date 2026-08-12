import AppKit
import EventKit
import Foundation

/// Reads and writes the user's Apple Calendar and Reminders through EventKit.
///
/// This is what makes Alfred's calendar and reminders "the real ones": there is no
/// Alfred-owned copy. Every event lands in the user's existing calendars (iCloud,
/// Exchange, subscribed feeds…) and every reminder in an existing list, so a change
/// made here shows up in Apple Calendar / Reminders on the Mac and, via iCloud, on
/// the iPhone — with no sync step of our own.
///
/// Each call builds a fresh `EKEventStore` around the request, so a store never
/// crosses threads (EventKit objects aren't thread-safe) and nothing goes stale:
/// it reads the same database Apple's apps use. Calendars and reminders are each
/// gated by their own TCC permission — the usage descriptions are already in the
/// app's Info.plist — so the first call asks the user, and a denial surfaces a
/// pointer to System Settings instead of failing opaque.
struct CalendarCapability {

    // MARK: - Events

    /// List events starting within the next `days` days, soonest first. Each line ends
    /// with `id=<eventIdentifier>` so the model can update or delete a specific event.
    func listEvents(days: Int = 7, limit: Int = 30) async throws -> String {
        let store = try await makeStore(for: .event, requireRead: true)
        let calendar = Calendar.current
        let start = Date()
        let end = calendar.date(byAdding: .day, value: max(days, 1), to: start) ?? start

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        let lines = events.enumerated().map { index, event in
            var line = "\(index + 1). [\(Self.title(event))] \(Self.displayRange(event))"
                + " | \(event.calendar.title) | id=\(Self.identifier(event))"
            if event.isAllDay { line += " | all-day" }
            if let location = Self.oneLiner(event.location) { line += " | location=\(location)" }
            if let notes = Self.oneLiner(event.notes) { line += " | notes=\(notes)" }
            return line
        }
        guard !lines.isEmpty else { return "No events in the next \(days) days." }
        return "Upcoming \(days) day(s):\n" + lines.joined(separator: "\n")
    }

    struct NewEvent {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String?
        var notes: String?
        /// Optional calendar identifier or display title; otherwise the default.
        var calendar: String?
    }

    /// Create an event. The caller (tool layer) defaults an omitted end to start +
    /// 1 hour, or + 1 day for all-day.
    func createEvent(_ draft: NewEvent) async throws -> String {
        let store = try await makeStore(for: .event, requireRead: false)
        let event = EKEvent(eventStore: store)
        event.calendar = pickEventCalendar(store, draft.calendar) ?? store.defaultCalendarForNewEvents
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location.flatMap(Self.nonemptyOrNil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = draft.notes.flatMap(Self.nonemptyOrNil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.save(event, span: .thisEvent)
        Self.nudgeCalendarApp()

        return "Added \(Self.summary(event)) in \(event.calendar.title). It's now in Apple Calendar and iCloud. id=\(Self.identifier(event))"
    }

    struct EventUpdate {
        var title: String?
        var start: Date?
        var end: Date?
        var isAllDay: Bool?
        var location: String?
        var notes: String?
        var calendar: String?
    }

    /// Update any of an event's fields; nil leaves each untouched.
    func updateEvent(id: String, changes: EventUpdate) async throws -> String {
        let store = try await makeStore(for: .event, requireRead: true)
        guard let event = store.event(withIdentifier: id) else {
            throw CapabilityError.notFound("event", id)
        }

        event.title = changes.title ?? event.title
        if let location = changes.location { event.location = Self.nonemptyOrNil(location) }
        if let notes = changes.notes { event.notes = Self.nonemptyOrNil(notes) }
        if let isAllDay = changes.isAllDay { event.isAllDay = isAllDay }
        if let start = changes.start { event.startDate = start }
        if let end = changes.end { event.endDate = end }
        if let calendar = changes.calendar, let picked = pickEventCalendar(store, calendar) {
            event.calendar = picked
        }

        try store.save(event, span: .thisEvent)
        Self.nudgeCalendarApp()
        return "Updated \(Self.summary(event)) — now in \(event.calendar.title)."
    }

    func deleteEvent(id: String) async throws -> String {
        let store = try await makeStore(for: .event, requireRead: true)
        guard let event = store.event(withIdentifier: id) else {
            throw CapabilityError.notFound("event", id)
        }
        let what = Self.summary(event)
        try store.remove(event, span: .thisEvent, commit: true)
        Self.nudgeCalendarApp()
        return "Deleted \(what) from the calendar."
    }

    // MARK: - Reminders

    struct NewReminder {
        var title: String
        /// nil = undated; a date becomes the due date/time.
        var due: Date?
        var notes: String?
        /// Optional list identifier or display name; otherwise the default list.
        var list: String?
    }

    /// Outstanding reminders (not completed), soonest due first, undated last.
    func listReminders(includeCompleted: Bool = false, limit: Int = 30) async throws -> String {
        let store = try await makeStore(for: .reminder, requireRead: true)
        let all = Self.fetchReminders(store)
        let sorted = all.sorted { lhs, rhs in
            switch (lhs.dueDateComponents?.date, rhs.dueDateComponents?.date) {
            case (.some(let a), .some(let b)): return a < b
            case (nil, .some): return false
            case (.some, nil): return true
            case (nil, nil): return lhs.title < rhs.title
            }
        }
        let filtered = includeCompleted ? sorted : sorted.filter { !$0.isCompleted }
        let shown = filtered.prefix(limit)

        let lines = shown.enumerated().map { index, r in
            let when = r.dueDateComponents?.date.map { Self.timeLabel($0) } ?? "no due date"
            var line = "\(index + 1). [\(Self.title(r))] due: \(when) | \(r.calendar.title) | id=\(r.calendarItemIdentifier)"
            if r.isCompleted { line += " | completed" }
            if let notes = Self.oneLiner(r.notes) { line += " | notes=\(notes)" }
            return line
        }
        guard !lines.isEmpty else {
            return includeCompleted ? "No reminders." : "No outstanding reminders."
        }
        return (includeCompleted ? "Reminders" : "Outstanding reminders") + ":\n" + lines.joined(separator: "\n")
    }

    func createReminder(_ draft: NewReminder) async throws -> String {
        let store = try await makeStore(for: .reminder, requireRead: false)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = pickReminderList(store, draft.list) ?? store.defaultCalendarForNewReminders()
        reminder.title = draft.title
        reminder.notes = draft.notes.flatMap(Self.nonemptyOrNil)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let when: String
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            when = " due \(Self.timeLabel(due))"
        } else {
            when = " (no due date)"
        }

        try store.save(reminder, commit: true)
        return "Added reminder \"\(Self.title(reminder))\"\(when) to \"\(reminder.calendar.title)\". It's in Apple Reminders. id=\(reminder.calendarItemIdentifier)"
    }

    /// How an update handles a reminder's due date: `.unchanged` keeps it,
    /// `.undated` clears it, `.set(date)` moves it.
    enum DateUpdate {
        case unchanged
        case undated
        case set(Date)
    }

    /// Update a reminder's title/due/notes; `nil` for title/notes leaves them
    /// untouched. Completion is a separate concern handled by markReminder.
    func updateReminder(id: String, title: String?, due: DateUpdate, notes: String?) async throws -> String {
        let store = try await makeStore(for: .reminder, requireRead: true)
        guard let reminder = Self.fetchReminder(id, store: store) else {
            throw CapabilityError.notFound("reminder", id)
        }

        if let title { reminder.title = title }
        switch due {
        case .unchanged:
            break
        case .undated:
            reminder.dueDateComponents = nil
        case .set(let date):
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
        }
        if let notes { reminder.notes = Self.nonemptyOrNil(notes) }
        try store.save(reminder, commit: true)
        return "Updated reminder \"\(Self.title(reminder))\"."
    }

    /// Mark a reminder done or undone.
    func markReminder(id: String, completed: Bool) async throws -> String {
        let store = try await makeStore(for: .reminder, requireRead: true)
        guard let reminder = Self.fetchReminder(id, store: store) else {
            throw CapabilityError.notFound("reminder", id)
        }
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        try store.save(reminder, commit: true)
        return "Marked \"\(Self.title(reminder))\" \(completed ? "complete" : "incomplete")."
    }

    func deleteReminder(id: String) async throws -> String {
        let store = try await makeStore(for: .reminder, requireRead: true)
        guard let reminder = Self.fetchReminder(id, store: store) else {
            throw CapabilityError.notFound("reminder", id)
        }
        let what = Self.title(reminder)
        try store.remove(reminder, commit: true)
        return "Deleted reminder \"\(what)\"."
    }

    // MARK: - Permission

    /// Build a fresh store, first persuading TCC to let this app use the entity.
    ///
    /// The first call for an entity shows the system prompt (the usage descriptions
    /// in Info.plist are what Apple displays there). `.writeOnly` — the half-grant
    /// macOS shares with iOS — is fine for creating but not for reading, so callers
    /// that only write pass `requireRead: false`.
    private func makeStore(for entity: EKEntityType, requireRead: Bool) async throws -> EKEventStore {
        let store = EKEventStore()

        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess, .authorized:
            return store
        case .writeOnly:
            guard !requireRead else {
                throw CapabilityError.denied(Self.writeOnlyMessage(entity))
            }
            return store
        case .notDetermined:
            switch entity {
            case .event:
                _ = try? await store.requestFullAccessToEvents()
            case .reminder:
                _ = try? await store.requestFullAccessToReminders()
            @unknown default:
                break
            }
            let after = EKEventStore.authorizationStatus(for: entity)
            switch after {
            case .fullAccess, .authorized:
                return store
            case .writeOnly:
                guard !requireRead else {
                    throw CapabilityError.denied(Self.writeOnlyMessage(entity))
                }
                return store
            default:
                throw CapabilityError.denied(Self.deniedMessage(entity))
            }
        default:
            throw CapabilityError.denied(Self.deniedMessage(entity))
        }
    }

    private static func deniedMessage(_ entity: EKEntityType) -> String {
        let name = entity == .event ? "Calendar" : "Reminders"
        return "Alfred doesn't have \(name) access. Grant it in System Settings → Privacy & Security → \(name), then try again."
    }

    private static func writeOnlyMessage(_ entity: EKEntityType) -> String {
        let name = entity == .event ? "Calendar" : "Reminders"
        return "Alfred can add to your \(name.lowercased()) but not read it. Switch to Full Access in System Settings → Privacy & Security → \(name)."
    }

    // MARK: - Conversion

    /// Tell Calendar.app to reload its store so a write shows up immediately.
    ///
    /// EventKit `save` is synchronous: the change is committed to the local
    /// Calendar database before it returns, so Alfred's side has no latency to
    /// remove. The lag the user sees lives in Calendar.app's UI, which waits for
    /// its own refresh cycle (or a sync round-trip) before repainting. The app
    /// exposes one scriptable command — `reload calendars` — that forces that
    /// repaint right now. Fire-and-forget: it adds nothing to the reply path,
    /// and if Calendar.app isn't running there's nothing to refresh (it reads
    /// the same database fresh on next launch anyway).
    private static func nudgeCalendarApp() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iCal")
        guard !running.isEmpty else { return }

        let script = "tell application \"Calendar\" to reload calendars"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        do {
            try task.run()
        } catch {
            NSLog("[calendar] reload calendars nudge failed: %@", error.localizedDescription)
        }
    }

    /// "Wed Aug 6 · 9:00 AM–10:30 AM" — the date alone for all-day events.
    private static func displayRange(_ event: EKEvent) -> String {
        let cal = Calendar.current
        if event.isAllDay {
            return event.startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        let startDay = event.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if cal.isDate(event.startDate, inSameDayAs: event.endDate) {
            return "\(startDay) · \(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened))"
        }
        let end = event.endDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return "\(startDay) \(event.startDate.formatted(date: .omitted, time: .shortened)) – \(end)"
    }

    private static func summary(_ event: EKEvent) -> String {
        "\(quote(title(event))) \(displayRange(event))"
    }

    static func title(_ event: EKEvent) -> String {
        (event.title?.isEmpty == false) ? event.title! : "(untitled)"
    }
    static func title(_ reminder: EKReminder) -> String {
        (reminder.title?.isEmpty == false) ? reminder.title! : "(untitled)"
    }
    /// `eventIdentifier` can be nil for some subscribed feeds; the calendar item
    /// identifier is always present and equally stable for updates.
    static func identifier(_ event: EKEvent) -> String {
        event.eventIdentifier ?? event.calendarItemIdentifier
    }
    static func quote(_ s: String) -> String { "\"\(s)\"" }

    private static var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func timeLabel(_ date: Date) -> String { timeFormatter.string(from: date) }

    private static func oneLiner(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let singleLine = s.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\r", with: "")
        return singleLine.count > 60 ? String(singleLine.prefix(60)) + "…" : singleLine
    }

    private static func nonemptyOrNil(_ s: String) -> String? { s.isEmpty ? nil : s }

    // MARK: - Date parsing (ISO 8601; floating treated as local)

    /// Parses the forms a model is most likely to produce: ISO-8601 with or without
    /// a timezone, "yyyy-MM-dd HH:mm", or a bare date. Floating times mean local time.
    static func parseISO(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // ISO-8601 formatters are picky: .withFractionalSeconds makes the plain
        // "09:30:00" form unparseable, so try the non-fractional matcher first
        // and fall back to the fractional one.
        if let d = plainISO.date(from: trimmed) { return d }
        if let d = fractionalISO.date(from: trimmed) { return d }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: trimmed) { return d }
        }
        return nil
    }

    private static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Fetch helpers

    /// fetchReminders hands results to a completion callback, so a synchronous
    /// method bridges it with a semaphore. The MCP call already runs on a
    /// background thread — nothing here ever touches the main thread.
    private static func fetchReminders(_ store: EKEventStore) -> [EKReminder] {
        let predicate = store.predicateForReminders(in: nil)
        var fetched: [EKReminder] = []
        let sema = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: predicate) { reminders in
            fetched = reminders ?? []
            sema.signal()
        }
        sema.wait()
        return fetched
    }

    private static func fetchReminder(_ id: String, store: EKEventStore) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    /// Match `needle` against a calendar list: identifier first, then a
    /// case-insensitive display-title match.
    private func pickEventCalendar(_ store: EKEventStore, _ needle: String?) -> EKCalendar? {
        guard let needle else { return nil }
        let calendars = store.calendars(for: .event)
        if let id = calendars.first(where: { $0.calendarIdentifier == needle }) { return id }
        return calendars.first { $0.title.compare(needle, options: .caseInsensitive) == .orderedSame }
    }

    private func pickReminderList(_ store: EKEventStore, _ needle: String?) -> EKCalendar? {
        guard let needle else { return nil }
        let lists = store.calendars(for: .reminder)
        if let id = lists.first(where: { $0.calendarIdentifier == needle }) { return id }
        return lists.first { $0.title.compare(needle, options: .caseInsensitive) == .orderedSame }
    }
}

// MARK: - Errors

enum CapabilityError: LocalizedError {
    case denied(String)
    case notFound(String, String)

    var errorDescription: String? {
        switch self {
        case .denied(let message): return message
        case .notFound(let kind, let id): return "No \(kind) found with id \(id). It may have been deleted."
        }
    }
}
