//
//  EventDetailView.swift
//  Alfred
//
//  The sheet that opens when you tap an event: iCal-style detail — coloured calendar header,
//  time, location, notes, alert — with Edit handing off to the editor. Closing re-uses the
//  flattened entry the row was drawn from; the underlying event may have moved on, so the store's
//  change notification refreshes the list underneath either way.
//

import SwiftUI

struct EventDetailView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let store: CalendarStore
    let entry: CalendarEntry
    let onEdit: () -> Void

    private let calendar = Calendar.current

    private var calendarColor: Color {
        entry.calendarColorHex.map { Color(calendarHex: $0) } ?? palette.accent
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        rows
                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit") { onEdit() }
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(calendarColor)
                .frame(width: 44, height: 6)

            Text(entry.title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.bottom, 18)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            detailRow(icon: "clock", title: timeLine)
            if let location = entry.location {
                detailRow(icon: "mappin.and.ellipse", title: location)
            }
            detailRow(icon: "calendar", title: entry.calendarName)
            if let notes = entry.notes {
                detailRow(icon: "text.alignleft", title: notes)
            }
            if let alarm = entry.alarmMinutesBefore {
                detailRow(icon: "bell", title: Self.alarmText(alarm))
            }
            if let url = entry.url {
                detailRow(icon: "link", title: url.absoluteString) {
                    openURL(url)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(palette.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func detailRow(icon: String, title: String, action: (() -> Void)? = nil) -> some View {
        let row = HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(calendarColor)
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.surfaceBorder.opacity(0.6))
                .frame(height: 0.5)
        }

        if let action {
            Button(action: action, label: { row })
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button { openInCalendar() } label: {
                Text("Open in Calendar")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.accentBright)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.surfaceBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Text("Editing, deleting, and changing the calendar are done from the Edit screen.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textFaint)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 18)
    }

    /// Jumps to the event in Apple's Calendar app. The `x-apple-calevent` scheme opens an event
    /// by its identifier when the store knows it; for the odd subscribed feed that doesn't hold
    /// one, Calendar simply opens to today.
    private func openInCalendar() {
        let scheme = "x-apple-calevent://"
        guard let encoded = entry.eventIdentifier
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: scheme + encoded) else { return }
        openURL(url)
    }

    private var timeLine: String {
        if entry.isAllDay {
            // Multi-day all-day entries span dates; a single-day one is just "All day".
            if !calendar.isDate(entry.start, inSameDayAs: entry.end) {
                let start = entry.start.formatted(.dateTime.month(.abbreviated).day())
                let end = entry.end.formatted(.dateTime.month(.abbreviated).day())
                return "\(start) – \(end), all day"
            }
            return "All day"
        }
        let start = entry.start.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(entry.start, inSameDayAs: entry.end) {
            let end = entry.end.formatted(date: .omitted, time: .shortened)
            return "\(start) – \(end)"
        }
        // A multi-day appointment: Apple Calendar spells out both ends rather than dropping the
        // date from the second one.
        let end = entry.end.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
        return "\(start) – \(end)"
    }

    static func alarmText(_ minutesBefore: Int) -> String {
        switch minutesBefore {
        case 0: return "At time"
        case 5: return "5 minutes before"
        case 15: return "15 minutes before"
        case 30: return "30 minutes before"
        case 60: return "1 hour before"
        default: return "\(minutesBefore) minutes before"
        }
    }
}
