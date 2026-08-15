//
//  CalendarView.swift
//  AlfredMacApp
//
//  The Calendar tab: Apple Calendar's four views — List, Day, Week, Month —
//  over the Mac's own EventKit store, with full create/edit/delete. Ported
//  from the iOS app (Alfred/Alfred/Views/Calendar/CalendarView.swift) — same
//  segmented mode switch, chevrons and Today for paging, tapping an event
//  opens its detail. The iOS design has no persistent sidebar, so the port
//  keeps the single-pane layout rather than inventing a split view.
//
//  Deviation from iOS: the "Open Settings" button on the access-denied screen
//  opens macOS's Calendar privacy pane instead of the iOS settings app.
//

import SwiftUI

enum CalendarMode: String, CaseIterable, Identifiable {
    case list, day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

struct CalendarView: View {
    @Environment(\.palette) private var palette

    @State private var store = CalendarStore()

    /// Which of the four views is showing. Held here rather than in the views so the segmented
    /// control and the content agree without an extra binding hop.
    @State private var mode: CalendarMode = .month

    /// The date being paged around. Its meaning depends on the mode: the day for Day, the week's
    /// anchor for Week, the first of the month for Month, today for List.
    @State private var anchor = Date()

    /// The day a month grid has selected, and what a new event is dated to.
    @State private var selectedDate = Date()

    /// Which event's detail sheet is up.
    @State private var detailEntry: CalendarEntry?

    /// A new-event draft already dates from its target slot; an edit carries its entry with it.
    @State private var editingEntry: CalendarEntry?
    @State private var draftDate: Date?
    @State private var isEditorPresented = false
    @State private var isAccountsPresented = false

    /// Used by the editor to rebuild the picker list after the store refreshes.
    @State private var calendarsVersion = 0

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
                    content
                }
            }
            .navigationTitle(title)
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .modifier(TabToolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        store.refreshCalendars()
                        isAccountsPresented = true
                    } label: {
                        Image(systemName: "list.bullet.circle")
                    }
                    .accessibilityLabel("Calendars & accounts")
                }
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        presentNewEvent(on: appropriateNewEventDate)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New event")
                }
            })
        }
        .task { await store.load() }
        .task { await store.observeChanges() }
        .onChange(of: mode) { reload() }
        .onChange(of: anchor) { reload() }
        .sheet(isPresented: $isEditorPresented) {
            EventEditorView(
                store: store,
                editing: editingEntry,
                defaultDate: draftDate ?? Date(),
                onSaved: { saved in
                    detailEntry = saved
                    reload()
                },
                onDeleted: {
                    detailEntry = nil
                    reload()
                }
            )
        }
        .sheet(item: $detailEntry) { entry in
            EventDetailView(store: store, entry: entry, onEdit: {
                presentEdit(entry)
            })
        }
        .sheet(isPresented: $isAccountsPresented) {
            AccountsCalendarsView(store: store)
        }
    }

    // MARK: Paging

    private var title: String {
        switch mode {
        case .list:
            return "Calendar"
        case .day:
            return anchor.formatted(.dateTime.month(.abbreviated).day().weekday(.wide))
        case .week:
            let span = weekSpan
            return "\(span.start.formatted(.dateTime.month(.abbreviated))) \(span.start.formatted(.dateTime.day())) – \(span.end.formatted(.dateTime.month(.abbreviated))) \(span.end.formatted(.dateTime.day()))"
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The [start, end] of the week containing the anchor, using the user's first-weekday setting.
    private var weekSpan: (start: Date, end: Date) {
        let weekday = calendar.component(.weekday, from: anchor)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: anchor) ?? anchor)
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return (start, end)
    }

    private var appropriateNewEventDate: Date {
        switch mode {
        case .list, .month: return selectedDate
        case .day: return anchor
        case .week:
            // A new event from a week grid lands on the selected day if it's in view, else today.
            let span = weekSpan
            let target = (selectedDate >= span.start && selectedDate <= span.end) ? selectedDate : Date()
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: target) ?? target
        }
    }

    private func presentNewEvent(on date: Date) {
        editingEntry = nil
        draftDate = date
        isEditorPresented = true
    }

    private func presentEdit(_ entry: CalendarEntry) {
        editingEntry = entry
        draftDate = entry.start
        isEditorPresented = true
    }

    private func reload() {
        // Re-query the store for the new window. The window is widened a day each side by the
        // store itself so crossing events stay visible.
        let (from, to) = window
        Task { await store.load(from: from, to: to) }
    }

    /// The date window the current mode cares about.
    private var window: (from: Date, to: Date) {
        let cal = calendar
        switch mode {
        case .list:
            return (cal.startOfDay(for: Date()),
                    cal.date(byAdding: .day, value: CalendarStore.horizonDays, to: cal.startOfDay(for: Date())) ?? Date())
        case .day:
            return (cal.startOfDay(for: anchor),
                    cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: anchor)) ?? anchor)
        case .week:
            return (weekSpan.start, cal.date(byAdding: .day, value: 1, to: weekSpan.end) ?? weekSpan.end)
        case .month:
            let first = startOfMonth(anchor)
            let next = cal.date(byAdding: .month, value: 1, to: first) ?? first
            return (first, next)
        }
    }

    private func startOfMonth(_ date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? date
    }

    private func page(by unit: Calendar.Component, value: Int) {
        anchor = calendar.date(byAdding: unit, value: value, to: anchor) ?? anchor
    }

    private func goToday() {
        let today = Date()
        anchor = today
        selectedDate = today
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            modeSwitcher
            pageHeader
            Divider().overlay(palette.surfaceBorder)

            switch mode {
            case .list:
                ListAgendaView(store: store, onSelect: { detailEntry = $0 })
            case .day:
                DayWeekGridView(
                    store: store,
                    days: [anchor],
                    showsAllDayStrip: true,
                    onSelect: { detailEntry = $0 },
                    onTapSlot: { date in presentNewEvent(on: date) }
                )
            case .week:
                DayWeekGridView(
                    store: store,
                    days: daysInWeek,
                    showsAllDayStrip: true,
                    onSelect: { detailEntry = $0 },
                    onTapSlot: { date in presentNewEvent(on: date) }
                )
            case .month:
                MonthGridView(
                    store: store,
                    monthAnchor: anchor,
                    selectedDate: $selectedDate,
                    onSelectEvent: { detailEntry = $0 },
                    onTapSlot: { date in presentNewEvent(on: date) }
                )
            }
        }
    }

    private var daysInWeek: [Date] {
        let span = weekSpan
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: span.start) }
    }

    private var modeSwitcher: some View {
        Picker("View", selection: $mode) {
            ForEach(CalendarMode.allCases) { m in
                Text(m.title).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            Button { page(by: .day, value: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Earlier")

            Spacer()

            Button("Today") { goToday() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accentBright)
                .accessibilityLabel("Jump to today")

            Spacer()

            Button { page(by: .day, value: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Later")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - The list view

private struct ListAgendaView: View {
    @Environment(\.palette) private var palette

    let store: CalendarStore
    let onSelect: (CalendarEntry) -> Void

    var body: some View {
        if store.days.isEmpty {
            NothingScheduled(isLoading: store.isLoading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(store.days) { day in
                        Section {
                            VStack(spacing: 8) {
                                ForEach(day.entries) { entry in
                                    Button { onSelect(entry) } label: {
                                        EntryRow(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            DayHeader(date: day.date)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .refreshable { await store.load() }
        }
    }
}

// MARK: - Shared row pieces

/// The day heading above a list section, Apple style: weekday on the left, date on the right.
struct DayHeader: View {
    @Environment(\.palette) private var palette

    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(isToday ? palette.accentBright : palette.textPrimary)

            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                .font(.system(size: 13))
                .foregroundStyle(palette.textFaint)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private var title: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }
}

/// One event row, used by the list view and the month view's selected-day agenda.
struct EntryRow: View {
    @Environment(\.palette) private var palette

    let entry: CalendarEntry

    /// The bar that carries the event's calendar colour — Apple Calendar's signature visual.
    private var colorBar: Color {
        entry.calendarColorHex.map { Color(calendarHex: $0) } ?? palette.accent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if entry.isAllDay {
                    Text("All day")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accentBright)
                } else {
                    Text(entry.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.accentBright)
                    Text(entry.end.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                }
            }
            .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .multilineTextAlignment(.leading)

                if let location = entry.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                }

                Text(entry.calendarName)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(colorBar)
                .frame(width: 4)
                .padding(.vertical, 10)
        }
        .padding(.leading, 8)
    }
}

// MARK: - The three states before there's a list

/// Asks before macOS does. The system prompt can only ever be shown once, so spending a screen to
/// explain what Alfred wants it for is the difference between a considered Allow and a reflexive
/// Don't Allow that can afterwards only be undone in System Settings.
private struct PermissionPrompt: View {
    @Environment(\.palette) private var palette

    let request: () async -> Void

    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "calendar")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [palette.accentSoft, palette.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Text("See what's coming up")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 18)

            Text("Alfred reads and manages your calendar — every account you've added on this Mac. Nothing leaves the device.")
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
                Text(isRequesting ? "Waiting…" : "Connect Calendar")
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

/// Access was refused, or granted only for writing. The fix lives in System Settings, so this is a
/// signpost rather than another attempt — macOS will not show the prompt a second time.
private struct AccessDenied: View {
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    let reason: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.textFaint)

            Text("Calendar is off")
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
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
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

/// Granted, but genuinely nothing scheduled. Kept distinct from the permission states on purpose:
/// an empty month and a locked-out app look identical if you only draw one blank screen.
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
                Image(systemName: "calendar")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(palette.textFaint)

                Text("Nothing scheduled here")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer()
            Spacer()
        }
    }
}
