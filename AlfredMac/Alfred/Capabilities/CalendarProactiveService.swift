import EventKit
import Foundation

// MARK: - Proactive calendar planning

/// The planning half of Alfred's calendar smarts: finding free windows,
/// suggesting meeting times, catching conflicts, and surfacing the next
/// deadline.
///
/// The three core algorithms (`freeSlots`, `conflicts`, `daysUntil`) are pure
/// static functions over `(start, end)` windows, so they're testable without
/// EventKit or a granted calendar permission. The instance methods wrap them
/// with a live read of the user's calendar — each call builds a fresh store,
/// matching `CalendarCapability`'s thread-safety pattern.
// MARK: - Tool-layer seam

/// The surface `ToolHandlers.handleCalendarPlan` needs. A protocol (rather than
/// the concrete struct) so tests and the tool layer can inject a fake and
/// exercise the ISO rendering path without EventKit — which would otherwise
/// hang a headless harness on a TCC permission prompt.
protocol CalendarPlanning {
    func findFreeSlots(for duration: Int, between start: Date, and end: Date) async throws -> [(start: Date, end: Date)]
    func suggestMeetingTime(durationMinutes: Int, attendees: [String], within days: Int, workStart: Int, workEnd: Int) async throws -> Date?
    func detectConflicts(days: Int) async throws -> [(String, String)]
    func getNextDeadline() async throws -> (event: String, daysUntil: Int)?
}

struct CalendarProactiveService: CalendarPlanning {

    // MARK: - Pure planning

    /// The maximal gaps of at least `duration` between `start` and `end`,
    /// given the busy windows. Busy windows are clipped to the range, merged,
    /// and the gaps between them returned. Each gap is as long as it can be —
    /// two adjacent free hours come back as one two-hour slot, not two one-hour
    /// slots, so a caller placing a 60-minute meeting can also see it could
    /// stretch to 90.
    ///
    /// Validation (60-min meeting, events at 9–10, 13–14, 15–16):
    /// freeSlots(60min, 00:00–24:00) → [00:00–09:00, 10:00–13:00, 14:00–15:00, 16:00–24:00]
    static func freeSlots(duration: TimeInterval, from start: Date, to end: Date,
                          busy: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        guard duration > 0, end > start else { return [] }

        // Clip and drop empty windows.
        var clipped: [(start: Date, end: Date)] = busy.compactMap { window in
            let s = max(window.start, start)
            let e = min(window.end, end)
            return e > s ? (s, e) : nil
        }
        clipped.sort { $0.start < $1.start }

        // Merge overlapping or adjacent windows.
        var merged: [(start: Date, end: Date)] = []
        for window in clipped {
            if let last = merged.last, window.start <= last.end {
                merged[merged.count - 1] = (last.start, max(last.end, window.end))
            } else {
                merged.append(window)
            }
        }

        // Walk the gaps.
        var slots: [(start: Date, end: Date)] = []
        var cursor = start
        for window in merged {
            if window.start.timeIntervalSince(cursor) >= duration {
                slots.append((cursor, window.start))
            }
            cursor = max(cursor, window.end)
        }
        if end.timeIntervalSince(cursor) >= duration {
            slots.append((cursor, end))
        }
        return slots
    }

    /// Index pairs of overlapping windows. O(n²) — fine for a day's events.
    static func conflicts(in windows: [(start: Date, end: Date)]) -> [(first: Int, second: Int)] {
        var out: [(Int, Int)] = []
        guard windows.count > 1 else { return out }
        for i in 0..<(windows.count - 1) {
            for j in (i + 1)..<windows.count {
                if windows[i].end > windows[j].start && windows[j].end > windows[i].start {
                    out.append((i, j))
                }
            }
        }
        return out
    }

    /// Whole calendar days from today to the event's day. Tomorrow = 1,
    /// today = 0, yesterday = -1.
    static func daysUntil(_ future: Date, from now: Date = Date()) -> Int {
        let cal = Calendar.current
        let dayA = cal.startOfDay(for: now)
        let dayB = cal.startOfDay(for: future)
        return cal.dateComponents([.day], from: dayA, to: dayB).day ?? 0
    }

    // MARK: - EventKit-backed conveniences

    /// Free windows of at least `duration` minutes between two dates, from the
    /// real calendar.
    func findFreeSlots(for duration: Int, between start: Date, and end: Date) async throws -> [(start: Date, end: Date)] {
        let store = try await authorizedStore()
        let events = fetch(store, from: start, to: end)
        let busy = events.compactMap { event -> (start: Date, end: Date)? in
            guard let s = event.startDate, let e = event.endDate else { return nil }
            return (s, e)
        }
        return Self.freeSlots(duration: TimeInterval(duration * 60), from: start, to: end, busy: busy)
    }

    /// Propose a meeting time: the earliest free window of `durationMinutes`
    /// within the next `days`, restricted to the user's usual working hours.
    ///
    /// `attendees` is accepted for the API shape the spec asks for, but without
    /// a shared calendar there is no way to read *their* free/busy — the
    /// proposal is "a slot that works for you". CalDAV-side attendee matching
    /// is a server feature, not this one.
    func suggestMeetingTime(durationMinutes: Int, attendees: [String] = [],
                            within days: Int = 7, workStart: Int = 9, workEnd: Int = 18) async throws -> Date? {
        let cal = Calendar.current
        let now = Date()
        let windowEnd = cal.date(byAdding: .day, value: max(1, days), to: now) ?? now

        let store = try await authorizedStore()
        let events = fetch(store, from: now, to: windowEnd)
        let busy = events.compactMap { event -> (start: Date, end: Date)? in
            guard let s = event.startDate, let e = event.endDate else { return nil }
            return (s, e)
        }

        let duration = TimeInterval(durationMinutes * 60)
        // Walk day by day so the work-hour window applies per day rather than
        // one giant 7-day range (which would happily propose 2am).
        var cursor = cal.startOfDay(for: now)
        while cursor < windowEnd {
            // The day's window is workStart→workEnd, clamped to *now* on the
            // current day so a 20:00 request never gets today's 9am slot back.
            let workDayStart = cal.date(bySettingHour: workStart, minute: 0, second: 0, of: cursor) ?? cursor
            let workDayEnd = cal.date(bySettingHour: workEnd, minute: 0, second: 0, of: cursor) ?? windowEnd
            let dayStart = max(max(cursor, now), workDayStart)
            let dayEnd = min(windowEnd, workDayEnd)
            if dayEnd > dayStart {
                let slots = Self.freeSlots(duration: duration, from: dayStart, to: dayEnd, busy: busy)
                if let first = slots.first { return first.start }
            }
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? windowEnd
        }
        return nil
    }

    /// Pairs of (titleA, titleB) for overlapping events in the next 7 days.
    func detectConflicts(days: Int = 7) async throws -> [(String, String)] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: now) ?? now
        let store = try await authorizedStore()
        let events = fetch(store, from: now, to: end)
        // Keep original indexes so conflict pairs map back to the right titles
        // even when an event with missing dates is dropped.
        let windows = events.enumerated().compactMap { index, event -> (index: Int, start: Date, end: Date)? in
            guard let s = event.startDate, let e = event.endDate else { return nil }
            return (index, s, e)
        }
        return Self.conflicts(in: windows.map { (start: $0.start, end: $0.end) }).map { pair in
            (CalendarCapability.title(events[windows[pair.0].index]),
             CalendarCapability.title(events[windows[pair.1].index]))
        }
    }

    /// The next upcoming timed event and how many days away it is.
    func getNextDeadline() async throws -> (event: String, daysUntil: Int)? {
        let now = Date()
        let end = Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now
        let store = try await authorizedStore()
        let upcoming = fetch(store, from: now, to: end)
            .filter { !$0.isAllDay && $0.startDate != nil }
            .sorted { ($0.startDate ?? $0.endDate ?? now) < ($1.startDate ?? $1.endDate ?? now) }
        guard let next = upcoming.first, let start = next.startDate else { return nil }
        return (CalendarCapability.title(next), Self.daysUntil(start, from: now))
    }

    // MARK: - EventKit plumbing

    /// Fresh store with Calendar read access — the same authorization dance
    /// `CalendarCapability` performs (usage descriptions already in Info.plist).
    private func authorizedStore() async throws -> EKEventStore {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return store
        case .notDetermined:
            _ = try? await store.requestFullAccessToEvents()
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized:
                return store
            default:
                throw CapabilityError.denied(
                    "Alfred doesn't have Calendar access. Grant it in System Settings → Privacy & Security → Calendar, then try again.")
            }
        default:
            throw CapabilityError.denied(
                "Alfred doesn't have Calendar access. Grant it in System Settings → Privacy & Security → Calendar, then try again.")
        }
    }

    private func fetch(_ store: EKEventStore, from start: Date, to end: Date) -> [EKEvent] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    }
}
