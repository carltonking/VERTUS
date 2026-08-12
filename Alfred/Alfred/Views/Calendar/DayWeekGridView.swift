//
//  DayWeekGridView.swift
//  Alfred
//
//  The Day and Week views share one skeleton: a vertical hour ruler on the left, one or seven
//  columns of hours, events drawn as coloured blocks positioned by their start and duration, and
//  an all-day strip above the timed grid. Built with plain SwiftUI (no UIKit interop), so it stays
//  cheap and themeable.
//

import SwiftUI

struct DayWeekGridView: View {
    @Environment(\.palette) private var palette

    let store: CalendarStore
    let days: [Date]
    let showsAllDayStrip: Bool
    let onSelect: (CalendarEntry) -> Void
    let onTapSlot: (Date) -> Void

    /// One hour of grid height. Apple's grid is ~50-60pt; 56 keeps hour labels from crowding.
    private let hourHeight: CGFloat = 56
    /// How many hours tall the scrolled grid is. 24 flat; the ruler scrolls with the content.
    private let hourCount = 24

    private let calendar = Calendar.current

    /// All-day events from every day in the strip, in day order. They land in one shared row,
    /// labelled by their day, rather than clipped into columns the way timed events are.
    private var allDayEvents: [CalendarEntry] {
        days.flatMap { day in
            store.days
                .first { calendar.isDate($0.date, inSameDayAs: day) }
                .map { $0.entries.filter(\.isAllDay) } ?? []
        }
    }

    /// Timed events for one day, sorted by start.
    private func timedEvents(on day: Date) -> [CalendarEntry] {
        store.days
            .first { calendar.isDate($0.date, inSameDayAs: day) }
            .map { $0.entries.filter { !$0.isAllDay } } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showsAllDayStrip && !allDayEvents.isEmpty {
                    allDayStrip
                }

                HStack(alignment: .top, spacing: 0) {
                    ruler
                    dayColumns
                }
            }
        }
    }

    // MARK: Ruler

    private var ruler: some View {
        VStack(spacing: 0) {
            ForEach(0..<hourCount, id: \.self) { hour in
                Text(timeLabel(hour))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.textFaint)
                    .frame(width: 40, height: hourHeight, alignment: .topLeading)
                    .padding(.top, -6)
            }
        }
        .padding(.top, showsAllDayStrip && !allDayEvents.isEmpty ? 0 : 10)
    }

    private func timeLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "h a"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter.string(from: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date())
    }

    // MARK: Day columns

    private var dayColumns: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                dayColumn(day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayColumn(_ day: Date) -> some View {
        VStack(spacing: 0) {
            Text(dayHeader(day))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(calendar.isDateInToday(day) ? palette.accentBright : palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(palette.surface.opacity(0.4))

            ZStack(alignment: .topLeading) {
                hourLines(day)
                eventBlocks(day)
                nowLine(day)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .overlay(alignment: .top) {
            // A hairline between days, like iCal's vertical column dividers.
            Rectangle()
                .fill(palette.surfaceBorder.opacity(0.6))
                .frame(width: 0.5)
        }
    }

    private func dayHeader(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        let weekday = day.formatted(.dateTime.weekday(.abbreviated))
        let number = day.formatted(.dateTime.day())
        return "\(weekday) \(number)"
    }

    private func hourLines(_ day: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<hourCount, id: \.self) { hour in
                Rectangle()
                    .fill(palette.surfaceBorder.opacity(0.5))
                    .frame(height: 0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: hourHeight, alignment: .bottom)
            }
        }
        .padding(.top, 4)
    }

    private func eventBlocks(_ day: Date) -> some View {
        let events = timedEvents(on: day)
        let layout = Self.layout(events, calendar: calendar)
        return ZStack(alignment: .topLeading) {
            ForEach(layout) { placed in
                EventBlock(event: placed.event, palette: palette)
                    .frame(width: placed.width, height: placed.height)
                    .offset(x: placed.x, y: placed.y)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(placed.event) }
            }
        }
    }

    /// Where in the day's column an event starts, in points. The calendar's 00:00 is the grid's
    /// top, so the offset is minutes-from-midnight scaled to the hour height.
    private func yOffset(for date: Date, on day: Date) -> CGFloat {
        let start = calendar.startOfDay(for: day)
        let minutes = calendar.dateComponents([.minute], from: start, to: date).minute ?? 0
        return CGFloat(max(0, minutes)) / 60 * hourHeight + 4
    }

    /// How tall an event's block is. Minimum height keeps a five-minute meeting tappable.
    private func blockHeight(for event: CalendarEntry) -> CGFloat {
        let minutes = calendar.dateComponents([.minute], from: event.start, to: event.end).minute ?? 0
        return max(CGFloat(minutes) / 60 * hourHeight - 2, 18)
    }

    /// Layout math for a day's events: overlapping events are split into columns so they sit side
    /// by side like iCal, instead of stacking on top of one another. Non-overlapping events get
    /// the full column width. Overlap is transitive — three events all over one another get three
    /// columns each a third wide, even though no single pair fills the day.
    private static func layout(_ events: [CalendarEntry], calendar: Calendar) -> [PlacedEvent] {
        guard !events.isEmpty else { return [] }
        let sorted = events.sorted { $0.start < $1.start }
        let dayStart = calendar.startOfDay(for: sorted[0].start)

        // Column assignment per event, via interval-graph colouring: walk events in start order;
        // each takes the lowest column number no overlapping, earlier event already holds. The
        // cluster's column count is then the max column assigned inside it.
        var columns = Array(repeating: 0, count: sorted.count)
        var clusterStart: [Int] = Array(repeating: 0, count: sorted.count)
        var clusterColumns = Array(repeating: 1, count: sorted.count)
        var cluster = 0

        for i in 0..<sorted.count {
            if i > 0 {
                // Same cluster while the previous event is still running; a new one otherwise.
                if sorted[i - 1].end > sorted[i].start { clusterStart[i] = clusterStart[i - 1] }
                else { cluster += 1; clusterStart[i] = i }
            }

            // First free column among the events that overlap this one and started before it.
            var taken: Set<Int> = []
            for j in 0..<i where sorted[j].end > sorted[i].start {
                taken.insert(columns[j])
            }
            var col = 0
            while taken.contains(col) { col += 1 }
            columns[i] = col
            clusterColumns[clusterStart[i]] = max(clusterColumns[clusterStart[i]], col + 1)
        }

        let hourHeight: CGFloat = 56
        return sorted.enumerated().map { index, event in
            let columnsInCluster = clusterColumns[clusterStart[index]]
            let width = 1.0 / CGFloat(columnsInCluster)
            let x = CGFloat(columns[index]) * width
            let minutes = calendar.dateComponents([.minute], from: dayStart, to: event.start).minute ?? 0
            let y = CGFloat(max(0, minutes)) / 60 * hourHeight + 4
            let duration = calendar.dateComponents([.minute], from: event.start, to: event.end).minute ?? 0
            let height = max(CGFloat(duration) / 60 * hourHeight - 2, 18)
            return PlacedEvent(event: event, x: x, y: y, width: width, height: height)
        }
    }

    private func nowLine(_ day: Date) -> some View {
        // The red now-line only makes sense on today's column; other days get none.
        guard calendar.isDateInToday(day) else {
            return AnyView(EmptyView())
        }
        let now = Date()
        let minutes = calendar.dateComponents([.minute], from: calendar.startOfDay(for: now), to: now).minute ?? 0
        let y = CGFloat(minutes) / 60 * hourHeight + 4
        return AnyView(
            Rectangle()
                .fill(palette.danger)
                .frame(height: 1.5)
                .offset(y: y)
                .overlay(
                    Circle()
                        .fill(palette.danger)
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: y - 2),
                    alignment: .topLeading
                )
        )
    }

    // MARK: All-day strip

    private var allDayStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All-day")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textFaint)
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allDayEvents) { event in
                        Button { onSelect(event) } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(calendarHex: event.calendarColorHex ?? "#888888"))
                                    .frame(width: 8, height: 8)
                                Text(event.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(palette.surface.opacity(0.7))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Layout result

/// One event positioned in a day column: width and x are fractions of the column, y and height
/// are points from the column's top.
private struct PlacedEvent: Identifiable {
    let event: CalendarEntry
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var id: String { event.id }
}

// MARK: - Event block

/// A timed event as a coloured rectangle in the hour grid.
private struct EventBlock: View {
    let event: CalendarEntry
    let palette: Palette

    private var color: Color {
        event.calendarColorHex.map { Color(calendarHex: $0) } ?? palette.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(event.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}
