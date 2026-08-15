//
//  HomeView.swift
//  AlfredMacApp
//
//  Ported from the iOS app (Alfred/Alfred/Views/HomeView.swift).
//  The landing page: a greeting in the top left that rotates with the time of
//  day, the date and clock under it, and the windows below — Alfred's Briefing
//  from the Mac's socket, the Daily Brief from the Mac's own calendar, and the
//  To-Do's for the day.
//
//  macOS adaptation: pull-to-refresh becomes a toolbar refresh button that asks
//  the Mac for a fresh briefing. The view also owns the socket/mail startup
//  (the shell's RootView deliberately leaves the live link to the views).
//

import SwiftUI

struct HomeView: View {
    @Binding var selection: AlfredTab

    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    /// The live link to the Mac. Read for `latestBriefing`, so this view
    /// re-renders whenever a fresh briefing lands on the socket.
    private var socket: AlfredWebSocketClient { .shared }

    /// The change row tapped for the drill-in sheet.
    @State private var detailChange: BriefingChange?

    /// Hardcoded while Alfred has exactly one owner. It becomes a setting the moment a second
    /// person installs this.
    private let ownerName = "Carlton"

    /// Same local EventKit store the Calendar tab uses — the briefing is what's on *this* Mac,
    /// including every account macOS has been given.
    @State private var calendar = CalendarStore()
    @State private var reminders = RemindersStore()

    private var allEntries: [CalendarEntry] {
        calendar.days.flatMap(\.entries)
    }

    private var briefing: DailyBriefing {
        DailyBriefing(entries: allEntries)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header

                        SummaryCard {
                            alfredBriefingCard
                        }
                        .padding(.top, 26)

                        if let improvement = socket.latestBriefing?.improvement {
                            SummaryCard {
                                improvementCard(improvement)
                            }
                            .padding(.top, 16)
                        }

                        SummaryCard {
                            dailyBriefCard
                        }
                        .padding(.top, 16)

                        SummaryCard {
                            todosCard
                        }
                        .padding(.top, 16)
                    }
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("")
            .modifier(TabToolbar { refreshToolbar })
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .task { await calendar.load() }
        .task { await calendar.observeChanges() }
        .task { await reminders.load() }
        .task { await reminders.observeChanges() }
        // The live link. Discovery is bounded and the client reconnects on its
        // own, so this never blocks the UI and never needs to be called again.
        .task { await socket.connectToAlfred() }
        .task { MacMailStore.shared.start() }
    }

    /// The macOS stand-in for pull-to-refresh: ask the Mac for a fresh briefing.
    /// TabToolbar only attaches this while Home is the selected tab — macOS
    /// merges every mounted page's toolbar into the one window toolbar.
    @ToolbarContentBuilder
    private var refreshToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await socket.requestBriefing(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(palette.accentBright)
            }
            .accessibilityLabel("Refresh briefing")
        }
    }

    // MARK: - Header

    /// The greeting, anchored to the top left, with the date and the 24-hour clock underneath.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Greeting.text(name: ownerName))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.leading)

            Text(dateLine)
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
        .padding(.horizontal, 20)
    }

    private var dateLine: String {
        let cal = Calendar.current
        let now = Date()
        let day = cal.component(.day, from: now)
        let suffix = day % 10 == 1 && day != 11 ? "st"
            : day % 10 == 2 && day != 12 ? "nd"
            : day % 10 == 3 && day != 13 ? "rd"
            : "th"
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d'\(suffix)', HH:mm"
        return formatter.string(from: now)
    }

    // MARK: - Alfred's Briefing

    /// The top window: what Alfred's Mac generated. Renders straight from the
    /// socket's `latestBriefing`, so a pushed `briefing.update` reflows it with
    /// no network round trip from this view. Falls back to a waiting state when
    /// the Mac hasn't answered yet.
    @ViewBuilder
    private var alfredBriefingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            windowLabel("Alfred's Briefing", icon: "sparkles")

            if let briefing = socket.latestBriefing {
                Text(briefing.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // "Last updated: X minutes ago" — stale briefings read as stale.
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textFaint)
                    Text("Last updated \(relativeMinutes(briefing.generatedAt))")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                    Spacer(minLength: 0)
                }

                if !briefing.changes.isEmpty {
                    changeList(briefing.changes)
                }
            } else {
                waitingState
            }
        }
    }

    /// The self-optimization card: week-over-week rating trend, per-domain
    /// scores, and the learned rules now active in Alfred's prompts.
    @ViewBuilder
    private func improvementCard(_ card: ImprovementCardPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            windowLabel("Alfred Improvement", icon: "chart.line.uptrend.xyaxis")

            let delta = card.weekDelta
            let deltaLine: String = delta > 0.05
                ? String(format: "Average rating up %.1f stars ⬆︎", delta)
                : delta < -0.05
                    ? String(format: "Average rating down %.1f stars ⬇︎", abs(delta))
                    : "Average rating holding steady"
            Text(deltaLine)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(delta >= 0 ? palette.success : palette.danger)

            if !card.perKind.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(card.perKind) { score in
                        HStack {
                            Text(score.displayName)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.textSecondary)
                            Spacer()
                            let starsText: String = score.previous > 0
                                ? String(format: "%.1f → %.1f stars", score.previous, score.current)
                                : String(format: "%.1f stars", score.current)
                            Text(starsText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.textPrimary)
                        }
                    }
                }
            }

            if !card.activeOptimizations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active optimizations (\(card.activeOptimizations.count))\(card.activeOptimizations.count > 3 ? ", shown \(3)" : "")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textFaint)
                    ForEach(card.activeOptimizations.prefix(3), id: \.self) { rule in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(palette.accentBright)
                                .padding(.top, 6)
                            Text(rule)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// "What changed: N items" — a collapsible list of change rows. Tapping a
    /// row opens the drill-in sheet with title + details.
    private func changeList(_ changes: [BriefingChange]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes) { change in
                        Button {
                            detailChange = change
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: change.type))
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.accentBright)
                                    .frame(width: 18)
                                Text(change.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(palette.textFaint)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            } label: {
                sectionLabel("What changed: \(changes.count)", icon: "arrow.triangle.2.circlepath")
            }
        }
        .sheet(item: $detailChange) { change in
            ChangeDetailSheet(change: change)
        }
    }

    /// Empty state: the socket may be silent until the Mac's next hourly
    /// generation, or the app may not be connected yet.
    private var waitingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Waiting for first briefing", icon: "hourglass")
            Text(settings.isConfigured
                 ? "Alfred's next briefing lands here automatically. Use the refresh button to ask for one now."
                 : "Connect to your Mac in Settings, and Alfred's briefings will land here.")
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.leading)
        }
    }

    /// "3 minutes ago", "1 hour ago", "2 days ago" — enough precision for a
    /// card that refreshes hourly.
    private func relativeMinutes(_ timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return "just now" }
        let seconds = max(0, Date().timeIntervalSince1970 - timestamp)
        let minutes = Int(seconds / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        default:
            let hours = minutes / 60
            return hours >= 24
                ? "\(hours / 24) day\(hours / 24 == 1 ? "" : "s") ago"
                : "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
    }

    /// SF Symbol per change type; a neutral dot for anything unknown.
    private func icon(for type: String) -> String {
        switch type {
        case "calendar_added": return "calendar.badge.plus"
        case "calendar_cancelled": return "calendar.badge.minus"
        case "email_received": return "envelope.badge"
        case "reminder_set": return "checklist"
        case "weather_updated": return "cloud.sun"
        default: return "circle.fill"
        }
    }

    // MARK: - Daily Brief

    /// The squared window Jan calls the briefing: what today looks like, in one glance.
    ///
    /// Deliberately not a funnel into Chat. A briefing that needed a network call and a model round
    /// trip to answer "what's today?" would be slower and less reliable than the stores already
    /// being on the device with the answer — and it would be blank the moment the Mac is away.
    @ViewBuilder
    private var dailyBriefCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            windowLabel("Daily Brief", icon: "sun.max")

            switch calendar.access {
            case .granted:
                if briefing.hasContent {
                    VStack(alignment: .leading, spacing: 16) {
                        if !briefing.events.isEmpty {
                            section("Today", icon: "calendar", lines: briefing.events)
                        }
                        if !briefing.assignments.isEmpty {
                            section("Assignments", icon: "text.book.closed", lines: briefing.assignments)
                        }
                        if !briefing.dueThisWeek.isEmpty {
                            section("Due This Week", icon: "graduationcap", lines: briefing.dueThisWeek)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Today", icon: "calendar")
                        Text("Nothing on the schedule today. The day is yours — want to put something on it?")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            case .undetermined:
                Button {
                    Task { await calendar.requestAccess() }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("Today", icon: "calendar")
                            Text("Connect your calendar to see what is on today.")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textFaint)
                    }
                }
                .buttonStyle(.plain)
            case .denied(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Today", icon: "calendar")
                    Text(reason)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    // MARK: - To-Do's

    /// The second window: the day's action items in bullets — assignments and exams due today from
    /// the calendar, plus today's and overdue reminders, whose circles tick them off right here.
    @ViewBuilder
    private var todosCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            windowLabel("To-Do's", icon: "checklist")

            let items = todoItems
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Today", icon: "checkmark.circle")
                    Text("Nothing to do today. Enjoy the clear head.")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items, id: \.self) { line in
                        todoRow(line)
                    }
                }
            }
        }
    }

    /// The day's to-dos, calendar bullets first (sorted by start) then reminders (overdue/today),
    /// deduplicated — an assignment that is also a reminder should only show once.
    private var todoItems: [String] {
        let calendarLines: [String] = briefing.todos
        let endOfToday = Calendar.current.date(
            byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
        let reminderLines: [String] = reminders.items.notCompleted
            .filter { item in
                guard let due = item.dueDate else { return false }
                return due < endOfToday
            }
            .sorted { lhs, rhs in (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture) }
            .map { item in
                var line = item.title
                if let due = item.dueDate {
                    let hour = Calendar.current.component(.hour, from: due)
                    line += ", due \(hour >= 18 ? "tonight" : "at \(hourLabel(due))")"
                }
                return line
            }

        var seen = Set<String>()
        return (calendarLines + reminderLines).filter { seen.insert($0).inserted }
    }

    /// A fixed 12-hour "8:00 PM" style, matching the briefing sentences.
    private func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func todoRow(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(palette.textFaint)
            Text(line)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared

    private func windowLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.accentBright)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private func section(_ title: String, icon: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(title, icon: icon)
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.accentBright)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
        }
    }

}

// MARK: - Change detail sheet

/// Drill-in for one `BriefingChange`: the title, when it happened, and the
/// details the Mac attached. Presented as a sheet so the row tap has a
/// destination instead of being a dead end.
private struct ChangeDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private let change: BriefingChange

    init(change: BriefingChange) {
        self.change = change
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15))
                                .foregroundStyle(palette.accentBright)
                            Text(change.title)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.textPrimary)
                            Spacer(minLength: 0)
                        }

                        if !change.details.isEmpty {
                            Text(change.details)
                                .font(.system(size: 15))
                                .foregroundStyle(palette.textSecondary)
                                .lineSpacing(4)
                                .multilineTextAlignment(.leading)
                        }

                        if change.timestamp > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.textFaint)
                                Text(Date(timeIntervalSince1970: change.timestamp)
                                    .formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textFaint)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.surfaceBorder, lineWidth: 1)
                    )
                    .padding(20)
                }
            }
            .navigationTitle("What changed")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - The squared window

/// The panel every Home state draws on: the same raised surface and squared corners, so the
/// briefing, the empty day, and the permission signpost all read as one window.
private struct SummaryCard<Content: View>: View {
    @Environment(\.palette) private var palette

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1)
            )
            .padding(.horizontal, 20)
    }
}
