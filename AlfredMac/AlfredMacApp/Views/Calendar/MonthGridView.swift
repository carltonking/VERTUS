//
//  MonthGridView.swift
//  AlfredMacApp
//
//  The Month view: a six-row grid of day cells like Apple Calendar, with the day's events as
//  coloured dots under its number, and the selected day's full agenda beneath the grid. Tapping a
//  cell selects it; tapping the agenda row opens the event; tapping empty grid space starts a new
//  event on that day. Ported from the iOS app
//  (Alfred/Alfred/Views/Calendar/MonthGridView.swift).
//

import SwiftUI

struct MonthGridView: View {
    @Environment(\.palette) private var palette

    let store: CalendarStore
    /// The first-of-month anchor the grid is built around.
    let monthAnchor: Date
    @Binding var selectedDate: Date
    let onSelectEvent: (CalendarEntry) -> Void
    let onTapSlot: (Date) -> Void

    private let calendar = Calendar.current

    /// The 42 cells (6 rows × 7 days) Apple Calendar always draws, so the month never jumps as
    /// weekdays shift. Cells from neighbouring months are dimmed and non-interactive.
    private var cells: [Date] {
        guard let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthAnchor)) else { return [] }

        let leading = calendar.component(.weekday, from: firstOfMonth)
        let offset = (leading - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -offset, to: firstOfMonth) ?? firstOfMonth

        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var monthDates: Set<Date> {
        Set(cells.map(calendar.startOfDay(for:)))
    }

    /// All events in the month, keyed by their day.
    private var eventsByDay: [Date: [CalendarEntry]] {
        var buckets: [Date: [CalendarEntry]] = [:]
        for day in store.days {
            let key = calendar.startOfDay(for: day.date)
            buckets[key, default: []].append(contentsOf: day.entries)
        }
        return buckets
    }

    private var selectedDayEvents: [CalendarEntry] {
        let key = calendar.startOfDay(for: selectedDate)
        return eventsByDay[key, default: []]
    }

    private var today: Date {
        calendar.startOfDay(for: Date())
    }

    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { index in
            let weekday = ((index + calendar.firstWeekday - 1) % 7) + 1
            return symbols[weekday - 1]
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                weekdayHeader

                // One row per week: six rows whether or not the month needs them, like iCal.
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            cell(cells[row * 7 + col])
                        }
                    }
                }

                agenda
                    .padding(.top, 18)
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    // MARK: Grid

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textFaint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
            }
        }
        .padding(.bottom, 2)
    }

    private func cell(_ date: Date) -> some View {
        let dayStart = calendar.startOfDay(for: date)
        let isThisMonth = monthDates.contains(dayStart)
        let isSelected = calendar.isDate(dayStart, inSameDayAs: selectedDate)
        let isToday = calendar.isDate(dayStart, inSameDayAs: today)
        let dayEvents = eventsByDay[dayStart, default: []]

        return Button {
            selectedDate = dayStart
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday ? .semibold : .regular))
                    .foregroundStyle(dayText(isToday: isToday, isSelected: isSelected, isThisMonth: isThisMonth))
                    .frame(width: 34, height: 34)
                    .background(cellBackground(isSelected: isSelected, isToday: isToday))
                    .clipShape(Circle())

                dots(dayEvents, isSelected: isSelected, isThisMonth: isThisMonth)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isThisMonth)
        .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))")
    }

    private func dayText(isToday: Bool, isSelected: Bool, isThisMonth: Bool) -> Color {
        if isSelected { return palette.backgroundTop }
        if isToday { return palette.accentBright }
        return isThisMonth ? palette.textPrimary : palette.textFaint
    }

    @ViewBuilder
    private func cellBackground(isSelected: Bool, isToday: Bool) -> some View {
        if isSelected {
            palette.accentGradient
        } else if isToday {
            Circle().fill(palette.accent.opacity(0.16))
        }
    }

    /// Up to three coloured dots, like iCal: the dot count is the calendar count, not the event
    /// count, so a day with five events in one calendar shows one dot.
    @ViewBuilder
    private func dots(_ events: [CalendarEntry], isSelected: Bool, isThisMonth: Bool) -> some View {
        if isThisMonth {
            let calendars = Array(Set(events.compactMap(\.calendarColorHex))).prefix(3)
            if !calendars.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(calendars.enumerated()), id: \.offset) { _, hex in
                        Circle()
                            .fill(Color(calendarHex: hex))
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
    }

    // MARK: Agenda

    /// The selected day's events, iCal's "agenda" below the grid. The day header is repeated here
    /// so the list still makes sense after the grid has scrolled out of view.
    private var agenda: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(calendar.isDateInToday(selectedDate) ? "Today"
                     : selectedDate.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                Text(selectedDate.formatted(.dateTime.month(.wide).day().year()))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textFaint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)

            if selectedDayEvents.isEmpty {
                Text("Nothing scheduled.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(selectedDayEvents) { entry in
                        Button { onSelectEvent(entry) } label: {
                            EntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
