//
//  RoutineBuilderModal.swift
//  Alfred
//
//  The custom routine builder: name and description up top, an editable,
//  reorderable list of steps in the middle, and the schedule at the bottom.
//  Works for both create and edit — the mode decides what Save does.
//

import SwiftUI

/// A step being composed in the builder. The enum-with-associated-values wire
/// type is awkward to edit field-by-field, so the editor works on this flat
/// draft and converts to the payload only on save.
struct StepDraft: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case briefing, hermes, shell, mail, reminder, browser, scrape, career, understand, nyu

        var id: String { rawValue }

        var title: String {
            switch self {
            case .briefing: return "Briefing"
            case .hermes: return "Ask Alfred"
            case .shell: return "Run command"
            case .mail: return "Mail"
            case .reminder: return "Reminder"
            case .browser: return "Browse web"
            case .scrape: return "Scrape web"
            case .career: return "Job hunt"
            case .understand: return "Knowledge graph"
            case .nyu: return "NYU coursework"
            }
        }

        var icon: String {
            switch self {
            case .briefing: return "sun.max"
            case .hermes: return "bubble.left.and.bubble.right"
            case .shell: return "terminal"
            case .mail: return "envelope"
            case .reminder: return "checklist"
            case .browser: return "globe"
            case .scrape: return "doc.text.magnifyingglass"
            case .career: return "briefcase"
            case .understand: return "point.3.connected.trianglepath.dotted"
            case .nyu: return "graduationcap.fill"
            }
        }

        var blurb: String {
            switch self {
            case .briefing: return "Generate a daily summary, news, mail or calendar briefing"
            case .hermes: return "Ask Alfred anything; his answer becomes the step's output"
            case .shell: return "Run a shell command on your Mac"
            case .mail: return "Check unread mail, or summarize the inbox"
            case .reminder: return "Set a reminder due in a little while"
            case .browser: return "Open a page (or search) and report what it says — read-only, never submits"
            case .scrape: return "Fetch a page or search results as text — lightweight and read-only, no browser needed"
            case .career: return "Scan job boards against your profile, or list applications that went quiet — read-only"
            case .understand: return "Analyze your latest project into a knowledge graph, or report its architecture / onboarding tour"
            case .nyu: return "List assignments due in the next week (plus overdue), or force a Canvas sync — read-only"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .briefing
    var briefingType: String = "daily_summary"
    var prompt: String = ""
    var command: String = ""
    var mailAction: String = "check_unread"
    var reminderTitle: String = ""
    var dueIn: TimeInterval = 3600
    var browserInstruction: String = ""
    var browserURL: String = ""
    var scrapeInstruction: String = ""
    var scrapeURL: String = ""
    var careerAction: String = "scan"
    var understandAction: String = "docs"
    var nyuAction: String = "check_deadlines"

    init(kind: Kind = .briefing) {
        self.kind = kind
    }

    init(payload: RoutineStepPayload) {
        switch payload {
        case .briefing(let type):
            kind = .briefing
            briefingType = type
        case .hermes(let prompt):
            kind = .hermes
            self.prompt = prompt
        case .shell(let command):
            kind = .shell
            self.command = command
        case .mail(let action):
            kind = .mail
            mailAction = action
        case .reminder(let title, let dueIn):
            kind = .reminder
            reminderTitle = title
            self.dueIn = dueIn
        case .browser(let instruction, let url):
            kind = .browser
            browserInstruction = instruction
            browserURL = url ?? ""
        case .scrape(let instruction, let url):
            kind = .scrape
            scrapeInstruction = instruction
            scrapeURL = url ?? ""
        case .career(let action):
            kind = .career
            careerAction = action
        case .understand(let action):
            kind = .understand
            understandAction = action
        case .nyu(let action):
            kind = .nyu
            nyuAction = action
        }
    }

    /// The wire step this draft represents.
    var payload: RoutineStepPayload {
        switch kind {
        case .briefing: return .briefing(type: briefingType)
        case .hermes: return .hermes(prompt: prompt)
        case .shell: return .shell(command: command)
        case .mail: return .mail(action: mailAction)
        case .reminder: return .reminder(title: reminderTitle, dueIn: dueIn)
        case .browser:
            let url = browserURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return .browser(instruction: browserInstruction,
                            url: url.isEmpty ? nil : url)
        case .scrape:
            let url = scrapeURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return .scrape(instruction: scrapeInstruction,
                           url: url.isEmpty ? nil : url)
        case .career:
            return .career(action: careerAction)
        case .understand:
            return .understand(action: understandAction)
        case .nyu:
            return .nyu(action: nyuAction)
        }
    }

    var label: String {
        switch kind {
        case .briefing: return "Briefing — \(briefingType.replacingOccurrences(of: "_", with: " "))"
        case .hermes: return prompt.isEmpty ? "Ask Alfred" : prompt
        case .shell: return command.isEmpty ? "Run command" : command
        case .mail: return "Mail — \(mailAction.replacingOccurrences(of: "_", with: " "))"
        case .reminder: return reminderTitle.isEmpty ? "Reminder" : reminderTitle
        case .browser:
            let label = browserInstruction.isEmpty ? "Browse web" : browserInstruction
            let url = browserURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? label : "\(label) — \(url)"
        case .scrape:
            let label = scrapeInstruction.isEmpty ? "Scrape web" : scrapeInstruction
            let url = scrapeURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? label : "\(label) — \(url)"
        case .career:
            return careerAction == "follow_ups" ? "Job hunt — follow-ups" : "Job hunt — scan jobs"
        case .understand:
            switch understandAction {
            case "docs": return "Knowledge graph — visual docs"
            case "onboarding": return "Knowledge graph — onboarding tour"
            default: return "Knowledge graph — analyze project"
            }
        case .nyu:
            return nyuAction == "sync" ? "NYU — sync Canvas" : "NYU — check deadlines"
        }
    }
}

/// When the routine runs, in builder form.
enum ScheduleKind: String, CaseIterable, Identifiable {
    case onDemand, daily, weekly, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDemand: return "On demand"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .custom: return "Custom"
        }
    }
}

struct RoutineBuilderModal: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private var socket: AlfredWebSocketClient { .shared }

    let mode: RoutineBuilderMode
    /// Called with the saved routine so the parent can refresh.
    let onSaved: (RoutineSummary) -> Void

    @State private var name: String
    @State private var description: String
    @State private var steps: [StepDraft]
    @State private var scheduleKind: ScheduleKind
    @State private var dailyTime: Date
    @State private var weeklyDay: Int
    @State private var weeklyTime: Date
    @State private var cronText: String
    @State private var editMode: EditMode = .inactive
    @State private var editingStep: StepDraft?
    @State private var saving = false
    @State private var errorText: String?

    init(mode: RoutineBuilderMode, onSaved: @escaping (RoutineSummary) -> Void) {
        self.mode = mode
        self.onSaved = onSaved

        let routine: RoutineSummary?
        switch mode {
        case .create:
            routine = nil
        case .edit(let existing):
            routine = existing
        }

        _name = State(initialValue: routine?.name ?? "")
        _description = State(initialValue: routine?.description ?? "")
        _steps = State(initialValue: (routine?.steps ?? []).map(StepDraft.init(payload:)))

        switch routine?.schedule {
        case .daily(let hour, let minute):
            _scheduleKind = State(initialValue: .daily)
            _dailyTime = State(initialValue: Self.time(hour: hour, minute: minute))
            _weeklyDay = State(initialValue: 1)
            _weeklyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            _cronText = State(initialValue: "0 9 * * *")
        case .weekly(let dow, let hour, let minute):
            _scheduleKind = State(initialValue: .weekly)
            _dailyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            _weeklyDay = State(initialValue: dow)
            _weeklyTime = State(initialValue: Self.time(hour: hour, minute: minute))
            _cronText = State(initialValue: "0 9 * * *")
        case .custom(let cron):
            _scheduleKind = State(initialValue: .custom)
            _dailyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            _weeklyDay = State(initialValue: 1)
            _weeklyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            _cronText = State(initialValue: cron)
        default:
            _scheduleKind = State(initialValue: .onDemand)
            _dailyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            _weeklyDay = State(initialValue: 1)
            _weeklyTime = State(initialValue: Self.time(hour: 9, minute: 0))
            _cronText = State(initialValue: "0 9 * * *")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    if let errorText {
                        Section {
                            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.danger)
                        }
                    }

                    Section("Basics") {
                        TextField("Name", text: $name)
                        TextField("Description", text: $description, axis: .vertical)
                            .lineLimit(2...3)
                    }

                    Section {
                        HStack {
                            Text("Steps")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.textPrimary)
                            Spacer()
                            if !steps.isEmpty {
                                Button(editMode == .active ? "Done" : "Reorder") {
                                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                                }
                                .font(.system(size: 13))
                                .foregroundStyle(palette.accentBright)
                            }
                        }
                        .listRowBackground(Color.clear)

                        if steps.isEmpty {
                            Text("No steps yet — add one below.")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.textFaint)
                        } else {
                            ForEach($steps) { $step in
                                Button {
                                    editingStep = step
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: step.kind.icon)
                                            .font(.system(size: 13))
                                            .foregroundStyle(palette.accentBright)
                                            .frame(width: 22)
                                        Text(step.label)
                                            .font(.system(size: 14))
                                            .foregroundStyle(palette.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Image(systemName: "pencil")
                                            .font(.system(size: 10))
                                            .foregroundStyle(palette.textFaint)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .onMove { indices, newOffset in
                                steps.move(fromOffsets: indices, toOffset: newOffset)
                            }
                            .onDelete { offsets in
                                steps.remove(atOffsets: offsets)
                            }
                        }

                        addStepMenu
                    } header: {
                        Text("Steps")
                    }
                    .environment(\.editMode, $editMode)

                    Section("Schedule") {
                        Picker("When", selection: $scheduleKind) {
                            ForEach(ScheduleKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch scheduleKind {
                        case .onDemand:
                            Text("Runs only when you tap Run Now.")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.textFaint)
                        case .daily:
                            DatePicker("Time", selection: $dailyTime, displayedComponents: .hourAndMinute)
                        case .weekly:
                            Picker("Day", selection: $weeklyDay) {
                                ForEach(1...7, id: \.self) { day in
                                    Text(Calendar.current.weekdaySymbols[(day - 1 + 7) % 7])
                                        .tag(day)
                                }
                            }
                            DatePicker("Time", selection: $weeklyTime, displayedComponents: .hourAndMinute)
                        case .custom:
                            TextField("e.g. 0 8 * * 1-5", text: $cronText)
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 13, design: .monospaced))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(modeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(palette.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save()
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .foregroundStyle(palette.accentBright)
                    .disabled(saving)
                }
            }
        }
        .sheet(item: $editingStep) { step in
            StepEditorSheet(step: step) { edited in
                if let index = steps.firstIndex(where: { $0.id == edited.id }) {
                    steps[index] = edited
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Step add

    private var addStepMenu: some View {
        Menu {
            ForEach(StepDraft.Kind.allCases) { kind in
                Button {
                    steps.append(StepDraft(kind: kind))
                } label: {
                    Label(kind.title, systemImage: kind.icon)
                }
            }
        } label: {
            Label("Add step", systemImage: "plus.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accentBright)
        }
    }

    // MARK: - Save

    private var modeTitle: String {
        switch mode {
        case .create: return "New routine"
        case .edit: return "Edit routine"
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorText = "Give the routine a name."
            return
        }
        guard !steps.isEmpty else {
            errorText = "Add at least one step."
            return
        }
        // Per-kind validation: a step with an empty payload would fail on the
        // Mac, so catch it here where the offending row is visible.
        for step in steps {
            switch step.kind {
            case .hermes where step.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                errorText = "The Ask Alfred step needs a prompt."
                return
            case .shell where step.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                errorText = "The Run command step needs a command."
                return
            case .reminder where step.reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                errorText = "The reminder step needs a title."
                return
            case .browser where step.browserInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                errorText = "The Browse web step needs an instruction (what to look up)."
                return
            case .scrape where step.scrapeInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                errorText = "The Scrape web step needs an instruction (what to look up)."
                return
            default:
                break
            }
        }
        saving = true
        Task {
            let schedule = schedulePayload
            let saved: RoutineSummary?
            switch mode {
            case .create:
                saved = await socket.createRoutine(
                    name: trimmedName,
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    steps: steps.map(\.payload),
                    schedule: schedule)
            case .edit(let existing):
                saved = await socket.updateRoutine(
                    id: existing.id,
                    name: trimmedName,
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    steps: steps.map(\.payload),
                    schedule: schedule)
            }
            saving = false
            if let saved {
                onSaved(saved)
                dismiss()
            } else {
                errorText = "Couldn't reach your Mac. Is it awake and connected?"
            }
        }
    }

    /// The schedule the builder's controls describe.
    private var schedulePayload: RoutineSchedulePayload {
        switch scheduleKind {
        case .onDemand:
            return .onDemand
        case .daily:
            let (h, m) = Self.hourMinute(dailyTime)
            return .daily(hour: h, minute: m)
        case .weekly:
            let (h, m) = Self.hourMinute(weeklyTime)
            return .weekly(dayOfWeek: weeklyDay, hour: h, minute: m)
        case .custom:
            let cleaned = cronText.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? .onDemand : .custom(cronExpression: cleaned)
        }
    }

    private static func time(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private static func hourMinute(_ date: Date) -> (hour: Int, minute: Int) {
        let cal = Calendar.current
        return (cal.component(.hour, from: date), cal.component(.minute, from: date))
    }
}

// MARK: - Step editor

/// Edit one step's payload. Fields depend on the kind, so the sheet switches
/// on it. `onSave` hands the finished draft back to the builder.
private struct StepEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var step: StepDraft
    private let onSave: (StepDraft) -> Void

    init(step: StepDraft, onSave: @escaping (StepDraft) -> Void) {
        _step = State(initialValue: step)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section("Step details") {
                        switch step.kind {
                        case .briefing:
                            Picker("Briefing", selection: $step.briefingType) {
                                Text("Daily summary").tag("daily_summary")
                                Text("News").tag("news")
                                Text("Mail").tag("mail")
                                Text("Calendar").tag("calendar")
                            }
                            .pickerStyle(.inline)
                        case .hermes:
                            TextField("What should Alfred do or answer?", text: $step.prompt, axis: .vertical)
                                .lineLimit(3...6)
                        case .shell:
                            TextField("e.g. open -a Notes", text: $step.command)
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 13, design: .monospaced))
                        case .mail:
                            Picker("Action", selection: $step.mailAction) {
                                Text("Check unread").tag("check_unread")
                                Text("Summarize unread").tag("send_summary")
                            }
                            .pickerStyle(.inline)
                        case .reminder:
                            TextField("Reminder title", text: $step.reminderTitle)
                            Picker("Due in", selection: $step.dueIn) {
                                Text("15 minutes").tag(TimeInterval(15 * 60))
                                Text("1 hour").tag(TimeInterval(3600))
                                Text("3 hours").tag(TimeInterval(3 * 3600))
                                Text("12 hours").tag(TimeInterval(12 * 3600))
                                Text("Tomorrow").tag(TimeInterval(24 * 3600))
                            }
                            .pickerStyle(.inline)
                        case .browser:
                            TextField("What should Alfred look up?", text: $step.browserInstruction, axis: .vertical)
                                .lineLimit(2...4)
                            TextField("URL (optional — leave blank to search)", text: $step.browserURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .font(.system(size: 13, design: .monospaced))
                        case .scrape:
                            TextField("What should Alfred fetch?", text: $step.scrapeInstruction, axis: .vertical)
                                .lineLimit(2...4)
                            TextField("URL (optional — leave blank to search)", text: $step.scrapeURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .font(.system(size: 13, design: .monospaced))
                        case .career:
                            Picker("Action", selection: $step.careerAction) {
                                Text("Scan job boards").tag("scan")
                                Text("List follow-ups due").tag("follow_ups")
                            }
                            .pickerStyle(.inline)
                        case .understand:
                            Picker("Action", selection: $step.understandAction) {
                                Text("Visual docs — architecture report").tag("docs")
                                Text("Onboarding tour").tag("onboarding")
                                Text("Analyze the project").tag("analyze")
                            }
                            .pickerStyle(.inline)
                        case .nyu:
                            Picker("Action", selection: $step.nyuAction) {
                                Text("Check deadlines — due this week + overdue").tag("check_deadlines")
                                Text("Sync Canvas first, then report").tag("sync")
                            }
                            .pickerStyle(.inline)
                        }
                    }

                    Section {
                        Text(step.kind.blurb)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textFaint)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(step.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(palette.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onSave(step)
                        dismiss()
                    }
                    .foregroundStyle(palette.accentBright)
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
