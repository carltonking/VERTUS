//
//  NYUView.swift
//  AlfredMacApp
//
//  The Courses tab: everything the NYU integration knows, surfaced from the
//  Mac's Canvas sync.
//
//    • Status card — configured?, last sync, and Sync Now (a force sync that
//      also proves the token works).
//    • Assignments — every tracked assignment sorted by due date, with the
//      overdue/due-soon label and a tap-to-set-status action (submitted /
//      in progress / not started). Marking submitted cancels the Mac's
//      pending deadline reminders for it.
//    • Grades — per-course current score with the improving/declining trend,
//      plus professor, schedule and the projected final when Canvas has one.
//
//  Ported from Alfred/Alfred/Views/NYUView.swift — identical, minus the
//  iOS-only navigation-bar chrome.
//
//  Everything comes from the Mac over the socket (`nyu.*`); this app never
//  holds the Canvas token beyond sending it once in Settings.

import SwiftUI

struct NYUView: View {
    @Environment(\.palette) private var palette
    private var socket: AlfredWebSocketClient { .shared }

    @State private var status: NYUStatusPayload?
    @State private var assignments: [NYUAssignmentPayload] = []
    @State private var grades: [NYUCoursePayload] = []
    @State private var busy = false
    @State private var syncing = false
    @State private var message: String?
    @State private var errorText: String?
    @State private var selectedSection = 0

    var body: some View {
        ZStack {
            palette.background
            ScrollView {
                VStack(spacing: 14) {
                    statusCard

                    if let message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }

                    if status?.isConfigured == true {
                        sectionPicker
                        sectionContent
                    } else {
                        unconfiguredCard
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Courses")
        .preferredColorScheme(.dark)
        .task { await loadAll() }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.accentBright)
                Text("NYU COURSEWORK")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }

            if let status {
                HStack(spacing: 14) {
                    stat("\(status.courseCount)", "courses")
                    stat("\(status.assignmentCount)", "assignments")
                    stat("\(status.dueThisWeek)", "due this week")
                    stat("\(status.overdueCount)", "overdue")
                }
            }

            Button {
                Task { await syncNow() }
            } label: {
                HStack {
                    Spacer()
                    if syncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(syncing ? "Syncing…" : "Sync Now")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.vertical, 8)
                .foregroundStyle(palette.backgroundTop)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.accentBright))
            }
            .buttonStyle(.plain)
            .disabled(syncing)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(palette.textFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusLine: String {
        guard let status else { return "…" }
        if !status.enabled { return "Off" }
        if !status.tokenSet { return "Token missing" }
        if status.lastSyncAt > 0 {
            let when = Date(timeIntervalSince1970: status.lastSyncAt)
                .formatted(date: .abbreviated, time: .shortened)
            return "Synced " + when
        }
        return "Not synced yet"
    }

    // MARK: - Sections

    private var sectionPicker: some View {
        Picker("Section", selection: $selectedSection) {
            Text("Assignments").tag(0)
            Text("Grades").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var sectionContent: some View {
        if selectedSection == 0 {
            assignmentsList
        } else {
            gradesList
        }
    }

    private var assignmentsList: some View {
        VStack(spacing: 8) {
            if assignments.isEmpty {
                emptyCard("No assignments yet", "Sync to pull the semester from Canvas.")
            } else {
                ForEach(assignments) { assignment in
                    AssignmentRowView(assignment: assignment, palette: palette) { newStatus in
                        await setStatus(assignment, newStatus)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var gradesList: some View {
        VStack(spacing: 8) {
            if grades.isEmpty {
                emptyCard("No grades yet", "Canvas hasn't posted scores, or nothing has been graded.")
            } else {
                ForEach(grades) { course in
                    GradeRowView(course: course, palette: palette)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func emptyCard(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(palette.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    private var unconfiguredCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set up NYU tracking")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("Turn on NYU Coursework in Settings and paste a Canvas personal access token (canvas.nyu.edu → Profile → Settings → Approved Integrations). Alfred will pull your assignments, grades and class times, put what's due in the Briefing, and remind you 24h and 1h before deadlines.")
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    private func loadAll() async {
        busy = true
        defer { busy = false }
        let status = await socket.nyuStatus()
        self.status = status
        if status?.isConfigured == true {
            async let a = socket.nyuAssignments()
            async let g = socket.nyuGrades()
            assignments = await a
            grades = await g
        }
    }

    private func syncNow() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        message = nil
        if let result = await socket.nyuSyncNow() {
            message = result.success ? result.message : nil
            errorText = result.success ? nil : result.message
            await loadAll()
        } else {
            errorText = "Couldn't reach the Mac."
        }
    }

    private func setStatus(_ assignment: NYUAssignmentPayload, _ newStatus: String) async {
        if let updated = await socket.nyuUpdateAssignment(id: assignment.id, status: newStatus) {
            if let index = assignments.firstIndex(where: { $0.id == assignment.id }) {
                assignments[index] = updated
            }
        }
    }
}

// MARK: - Row views

private struct AssignmentRowView: View {
    let assignment: NYUAssignmentPayload
    let palette: Palette
    let onSetStatus: (String) async -> Void

    @State private var showActions = false

    var body: some View {
        Button {
            showActions = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top) {
                    Text(assignment.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Text(assignment.statusPayload.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor.opacity(0.14)))
                }
                Text(assignment.courseName)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
                if assignment.isOverdue {
                    Text(assignment.dueLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.danger)
                } else if assignment.daysUntil > 0 {
                    Text(assignment.dueLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                } else {
                    Text(assignment.dueLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .confirmationDialog("Set status", isPresented: $showActions, titleVisibility: .visible) {
            if assignment.statusPayload != .submitted {
                Button("Mark submitted") {
                    Task { await onSetStatus("submitted") }
                }
            }
            if assignment.statusPayload != .inProgress {
                Button("Mark in progress") {
                    Task { await onSetStatus("in_progress") }
                }
            }
            if assignment.statusPayload != .notStarted {
                Button("Mark not started") {
                    Task { await onSetStatus("not_started") }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var statusColor: Color {
        switch assignment.statusPayload {
        case .graded: return palette.accentBright
        case .submitted: return palette.accent
        case .inProgress: return palette.textSecondary
        case .notStarted: return palette.danger
        }
    }
}

private struct GradeRowView: View {
    let course: NYUCoursePayload
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    if !course.schedule.isEmpty {
                        Text(course.schedule)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textFaint)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    Text(course.scoreLabel)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                    Text(trendIcon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(trendColor)
                }
            }
            if !course.professor.isEmpty {
                Text("Prof. " + course.professor)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
            }
            if course.currentScore > 0 && course.projectedScore > 0 {
                Text("Projected: " + String(format: "%.1f", course.projectedScore))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    private var trendIcon: String {
        switch course.trend {
        case "improving": return "arrow.up.right"
        case "declining": return "arrow.down.right"
        default: return "minus"
        }
    }

    private var trendColor: Color {
        switch course.trend {
        case "improving": return palette.accentBright
        case "declining": return palette.danger
        default: return palette.textFaint
        }
    }
}
