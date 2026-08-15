//
//  CalendarStore.swift
//  Alfred
//
//  The Mac's own calendar, read and written through EventKit.
//
//  The store is the app's read side (the month/week/day/list views) and its
//  write side: creating, editing, and deleting events lands straight into
//  EventKit, and the Calendar tab watches for changes everywhere else so the
//  screen stays honest whether the change came from Alfred or from Apple
//  Calendar on another device.
//
//  Ported from the iOS app. EventKit's macOS 14 API (`requestFullAccessToEvents`,
//  `authorizationStatus(for:)`) matches the iOS 17 API, so the store is
//  unchanged except for wording that no longer assumes a phone.
//

import EventKit
import Foundation
import Observation
import SwiftUI

// MARK: - What the views draw

/// One event, flattened out of EventKit.
///
/// `EKEvent` is a live object owned by its `EKEventStore` — it faults in properties on access and
/// isn't safe to pass around freely. Converting at the boundary means the views never touch
/// EventKit, and a row can't blow up later because the store behind it moved on.
struct CalendarEntry: Identifiable, Hashable, Sendable {
    let id: String
    let eventIdentifier: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
    let calendarID: String
    let calendarName: String
    let calendarColorHex: String?
    /// Minutes before start an alarm goes off, when one exists. `0` means "at the start".
    let alarmMinutesBefore: Int?
}

/// A day with something in it. Days with no events are simply absent rather than rendered empty —
/// a fortnight of blank headers buries the three days that actually matter.
struct CalendarDay: Identifiable, Hashable {
    let date: Date
    let entries: [CalendarEntry]

    var id: Date { date }
}

/// A writable calendar, for the picker in the event editor.
struct AppCalendar: Identifiable, Hashable {
    let id: String
    let title: String
    let colorHex: String?
}

/// A group of calendars under one account (iCloud, Google, Exchange, "On My Mac"…), for the
/// Accounts & Calendars screen. The account is whatever EventKit's source is called.
struct CalendarAccount: Identifiable, Hashable {
    let id: String
    let title: String
    let calendars: [AppCalendar]
}

// MARK: - The store

@MainActor
@Observable
final class CalendarStore {
    /// EventKit's answer reduced to the three cases the UI draws differently. `writeOnly` collapses into
    /// `denied` with its own wording: it isn't a refusal, it's a half-grant that still can't read,
    /// and telling someone to "allow access" when they already did is a dead end.
    enum Access: Equatable {
        case undetermined
        case granted
        case denied(reason: String)
    }

    /// How far ahead the tab looks. A month is enough to answer "what's coming up" without the
    /// list becoming something you scroll rather than read.
    static let horizonDays = 30

    private(set) var access: Access
    private(set) var days: [CalendarDay] = []
    private(set) var calendars: [AppCalendar] = []
    private(set) var accounts: [CalendarAccount] = []
    private(set) var isLoading = false

    /// Calendars the user has turned off in the Accounts & Calendars screen. Persisted: a
    /// cluttered month is the user's own choice and should survive relaunches.
    private(set) var hiddenCalendarIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "alfred.hiddenCalendars") ?? []
    )

    /// One store for the app's lifetime — EventKit only delivers `.EKEventStoreChanged` to live
    /// instances, so a per-fetch store would silently stop the calendar updating itself.
    private let store = EKEventStore()

    init() {
        access = Self.currentAccess()
    }

    // MARK: Permission

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .undetermined
        case .fullAccess:
            return .granted
        case .writeOnly:
            return .denied(reason: "Alfred can add events to your calendar but not read them. "
                + "Switch Calendars to Full Access in System Settings to see them here.")
        case .denied:
            return .denied(reason: "Calendar access is turned off for Alfred.")
        case .restricted:
            return .denied(reason: "Calendar access is restricted on this Mac, so Alfred can't read it.")
        @unknown default:
            return .denied(reason: "macOS gave an answer about calendar access this app doesn't recognise.")
        }
    }

    /// Ask macOS for access, then load. Only ever called from an explicit tap: the tab shell builds
    /// every page up front, so requesting on appear would throw the system prompt at launch from a
    /// tab the user hasn't opened.
    func requestAccess() async {
        guard access == .undetermined else { return }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // The thrown error says nothing the status doesn't; re-reading it covers both the
            // refusal and the rare failure identically.
        }
        access = Self.currentAccess()
        refreshCalendars()
        await load()
    }

    // MARK: Reading

    /// Reload if we're allowed to. Safe to call on every appearance — it's a no-op before access is
    /// granted, so it never nags.
    func load() async {
        await load(from: Calendar.current.startOfDay(for: Date()),
                   to: Calendar.current.startOfDay(for: Date().addingTimeInterval(
                       TimeInterval(Self.horizonDays) * 86_400)))
    }

    /// The window the last load was asked for, so `observeChanges` can repeat exactly the request
    /// that produced what's on screen instead of snapping back to a default horizon mid-session.
    private var loadedWindow: (from: Date, to: Date)?
    /// Load every event intersecting `[from, to)`, grouped by day. The calendar views pick their
    /// own windows (a month grid asks for a month; a week grid asks for a week) rather than
    /// accepting whatever fixed horizon the Home briefing chose.
    func load(from: Date, to: Date) async {
        loadedWindow = (from, to)

        // Re-check each time: access can be revoked in Settings while the app is backgrounded, and
        // a stale `.granted` would show a list frozen at whatever it held when permission died.
        access = Self.currentAccess()
        guard access == .granted else {
            days = []
            // Bump the generation and clear the flag so a fetch that was already in flight
            // when access died can't publish a list after this.
            pendingLoad += 1
            isLoading = false
            return
        }

        isLoading = true

        // The window is widened, not the grouping: an event crossing the edge is still the
        // window's business, but a day in the middle never lists one that hasn't started yet.
        let widenedFrom = from.addingTimeInterval(-86_400)
        let widenedTo = to.addingTimeInterval(86_400)

        // The fetch runs off the main actor — a big account or a burst of syncs otherwise
        // freezes the UI for the whole synchronous `events(matching:)`. EventKit objects aren't
        // Sendable, so a throwaway store is created and used entirely inside the fetch and only
        // the flattened value types come back. The persistent main-actor store stays the only
        // one that writes and the only one that watches `.EKEventStoreChanged`, so moving reads
        // off the main thread can't make the calendar stop updating itself.
        pendingLoad += 1
        let generation = pendingLoad
        let entries = await Self.fetchEntries(
            from: widenedFrom,
            to: widenedTo,
            hiddenCalendarIDs: hiddenCalendarIDs
        )

        // A newer load has superseded this one — a fast page through months shouldn't let an
        // older result land late and swap the screen backwards.
        guard pendingLoad == generation else { return }
        days = Self.group(entries, using: Calendar.current)
        isLoading = false
    }

    /// How many loads have been started. Only the newest may publish its result.
    private var pendingLoad = 0

    /// Fetch and flatten a window's events off the main actor.
    nonisolated private static func fetchEntries(
        from: Date,
        to: Date,
        hiddenCalendarIDs: Set<String>
    ) async -> [CalendarEntry] {
        await Task.detached(priority: .userInitiated) {
            let store = EKEventStore()
            let visible = store.calendars(for: .event)
                .filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
            let predicate = store.predicateForEvents(
                withStart: from,
                end: to,
                calendars: visible.isEmpty ? nil : visible
            )
            return store.events(matching: predicate).map(entry(from:))
        }.value
    }

    /// Refetch the writable EventKit object behind a flattened entry, so an edit can be applied to
    /// the real event instead of rebuilt from the flattened copy. Returns nil if it's gone.
    func liveEvent(for entry: CalendarEntry) -> EKEvent? {
        guard access == .granted else { return nil }

        if let exact = store.event(withIdentifier: entry.eventIdentifier) { return exact }

        // Some subscribed feeds don't hold identifiers EventKit can refetch with. Fall back to
        // scanning the entry's own window for something with the same identity.
        let predicate = store.predicateForEvents(
            withStart: entry.start.addingTimeInterval(-60),
            end: entry.end.addingTimeInterval(60),
            calendars: nil
        )
        return store.events(matching: predicate).first { $0.eventIdentifier == entry.eventIdentifier }
    }

    /// The calendars the user can put new events into, with their account colours. Loaded on
    /// demand; EventKit returns them fresh each call and there's nothing to cache.
    func refreshCalendars() {
        calendars = store.calendars(for: .event).map { calendar in
            AppCalendar(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                colorHex: calendar.cgColor.hexString
            )
        }
        accounts = Self.accounts(from: store.calendars(for: .event))
    }

    /// The calendar new events default to — usually the user's primary iCloud one.
    func defaultCalendar() -> AppCalendar? {
        guard let fallback = store.defaultCalendarForNewEvents else { return calendars.first }
        return AppCalendar(
            id: fallback.calendarIdentifier,
            title: fallback.title,
            colorHex: fallback.cgColor.hexString
        )
    }

    // MARK: Visibility

    func isCalendarHidden(_ id: String) -> Bool {
        hiddenCalendarIDs.contains(id)
    }

    func setCalendarHidden(_ id: String, _ hidden: Bool) {
        if hidden {
            hiddenCalendarIDs.insert(id)
        } else {
            hiddenCalendarIDs.remove(id)
        }
        UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "alfred.hiddenCalendars")
        // The visible window changed under the views' feet — reload the window they're showing
        // rather than waiting for a notification that may never come.
        Task { await load(from: loadedWindow?.from ?? Calendar.current.startOfDay(for: Date()),
                          to: loadedWindow?.to ?? Date()) }
    }

    /// Group every calendar (writable or not) under its account, for the Accounts screen. Reads
    /// are the point here, so subscribed/read-only feeds must appear alongside iCloud ones.
    private static func accounts(from all: [EKCalendar]) -> [CalendarAccount] {
        let grouped = Dictionary(grouping: all) { $0.source.title }
        return grouped.keys.sorted().map { title in
            let list = grouped[title, default: []].sorted { $0.title < $1.title }.map { calendar in
                AppCalendar(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    colorHex: calendar.cgColor.hexString
                )
            }
            return CalendarAccount(id: title, title: title, calendars: list)
        }
    }

    // MARK: Writing

    /// The fields the event editor edits, as a plain value so a draft can sit in a sheet's `@State`
    /// and only touch EventKit when Save is pressed.
    struct EventDraft {
        var title: String
        var location: String
        var notes: String
        var isAllDay: Bool
        var starts: Date
        var ends: Date
        var calendarID: String
        /// Minutes before start; nil means no alarm, 0 means at the start.
        var alarmMinutesBefore: Int?
    }

    /// Create or update. Passing an entry makes it an edit of that entry; nil makes it a new event
    /// in `draft.calendarID`'s calendar.
    @discardableResult
    func save(_ draft: EventDraft, editing entry: CalendarEntry?) throws -> CalendarEntry? {
        guard access == .granted else { return nil }

        let event: EKEvent
        if let entry, let live = liveEvent(for: entry) {
            event = live
        } else {
            event = EKEvent(eventStore: store)
            guard let calendar = store.calendar(withIdentifier: draft.calendarID) else { return nil }
            event.calendar = calendar
        }

        event.title = draft.title
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.isAllDay = draft.isAllDay
        event.startDate = draft.starts
        event.endDate = draft.ends
        event.alarms = draft.alarmMinutesBefore.map { [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))] }

        try store.save(event, span: .thisEvent)
        return Self.entry(from: event)
    }

    func delete(_ entry: CalendarEntry) throws {
        guard access == .granted, let live = liveEvent(for: entry) else { return }
        try store.remove(live, span: .thisEvent)
    }

    // MARK: Conversion

    private nonisolated static func entry(from event: EKEvent) -> CalendarEntry {
        // eventIdentifier is nil for some subscribed/birthday events, and a recurring event repeats
        // the same identifier at every occurrence — so the start date is folded in to keep rows
        // distinct in a ForEach.
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first alarm is the one EventKit displays as the event's alert. Relative offsets are
        // what Apple Calendar creates; absolute alarms are left alone rather than misdescribed.
        var alarmMinutes: Int? = nil
        if let alarm = event.alarms?.first {
            let offset = alarm.relativeOffset
            if offset <= 0 {
                alarmMinutes = Int((-offset / 60).rounded())
            }
        }

        return CalendarEntry(
            id: "\(base)@\(event.startDate.timeIntervalSinceReferenceDate)",
            eventIdentifier: base,
            title: (event.title?.isEmpty == false) ? event.title! : "(no title)",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: (location?.isEmpty == false) ? location : nil,
            notes: (notes?.isEmpty == false) ? notes : nil,
            url: event.url,
            calendarID: event.calendar.calendarIdentifier,
            calendarName: event.calendar.title,
            calendarColorHex: event.calendar.cgColor.hexString,
            alarmMinutesBefore: alarmMinutes
        )
    }

    private static func group(_ entries: [CalendarEntry], using calendar: Calendar) -> [CalendarDay] {
        let buckets = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.start) }

        return buckets.keys.sorted().map { day in
            let sorted = buckets[day, default: []].sorted { lhs, rhs in
                // All-day events head the day: they're context for everything under them, not a
                // 00:00 appointment competing with the 9am one.
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.title < rhs.title
            }
            return CalendarDay(date: day, entries: sorted)
        }
    }

    /// EventKit's own notification that something changed — an event added on another device, a new
    /// account synced. Without this the tab would keep showing whatever it read when it opened.
    ///
    /// macOS fires `.EKEventStoreChanged` in bursts — a calendar syncing can produce several within
    /// a second — so notifications are debounced: each one cancels the reload the previous one
    /// scheduled, and only the quiet 0.4s after the burst actually hits EventKit.
    func observeChanges() async {
        let changes = NotificationCenter.default.notifications(named: .EKEventStoreChanged)
        var pending: Task<Void, Never>?
        for await _ in changes {
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                if let window = self.loadedWindow {
                    await self.load(from: window.from, to: window.to)
                } else {
                    await self.load()
                }
            }
        }
    }
}

// MARK: - Colour helpers

extension CGColor {
    /// "#RRGGBB" — calendars carry their colour as a CGColor with a wide-gamut space and alpha,
    /// none of which survives a hex round-trip exactly, but the difference is invisible on screen.
    var hexString: String {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let components = converted(to: colorSpace, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return "#888888" }
        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

extension Color {
    /// Parses "#RRGGBB". Unknown strings fall back to a neutral grey rather than trapping the view.
    init(calendarHex: String) {
        let cleaned = calendarHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .gray
            return
        }
        self.init(hex: value)
    }
}
