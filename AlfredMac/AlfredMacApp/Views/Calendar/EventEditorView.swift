//
//  EventEditorView.swift
//  AlfredMacApp
//
//  The create/edit sheet. One form for both jobs: a new event arrives with sensible defaults
//  (now, one hour, the default calendar, no alarm) and an existing one arrives pre-filled from
//  its flattened entry. The draft only touches EventKit when Save is pressed, so Cancel is free.
//  Ported from the iOS app (Alfred/Alfred/Views/Calendar/EventEditorView.swift).
//

import SwiftUI

struct EventEditorView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: CalendarStore
    /// The entry being edited, or nil for a new event.
    let editing: CalendarEntry?
    /// The date a new event should start from (the tapped slot in the grid, or today).
    let defaultDate: Date
    let onSaved: (CalendarEntry?) -> Void
    let onDeleted: () -> Void

    @State private var title = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var isAllDay = false
    @State private var starts: Date = Date()
    @State private var ends: Date = Date().addingTimeInterval(3600)
    @State private var calendarID = ""
    @State private var alarmMinutesBefore: Int? = nil

    @State private var saveError: String?

    /// Alarm choices, iCal's standard menu. nil is "none".
    private let alarmChoices: [Int?] = [nil, 0, 5, 15, 30, 60, 1440]

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    titleSection
                    timeSection
                    calendarSection
                    notesSection
                    if isEditing {
                        deleteSection
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(isEditing ? "Edit Event" : "New Event")
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                store.refreshCalendars()
                if let editing {
                    title = editing.title == "(no title)" ? "" : editing.title
                    location = editing.location ?? ""
                    notes = editing.notes ?? ""
                    isAllDay = editing.isAllDay
                    starts = editing.start
                    ends = editing.end
                    calendarID = editing.calendarID
                    alarmMinutesBefore = editing.alarmMinutesBefore
                } else {
                    seedNewEvent()
                }
            }
            .alert("Couldn't save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        Section {
            TextField("Title", text: $title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    private var timeSection: some View {
        Section {
            Toggle("All-day", isOn: $isAllDay)
                .tint(palette.accent)

            DatePicker("Starts", selection: $starts, displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                .onChange(of: starts) { adjustEndsIfNeeded() }

            DatePicker("Ends", selection: $ends, displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])

            Picker("Alert", selection: $alarmMinutesBefore) {
                Text("None").tag(Int?.none)
                ForEach(alarmChoices.compactMap { $0 }, id: \.self) { minutes in
                    Text(EventDetailView.alarmText(minutes)).tag(Int?.some(minutes))
                }
            }
        }
    }

    private var calendarSection: some View {
        Section {
            Picker("Calendar", selection: $calendarID) {
                ForEach(store.calendars) { cal in
                    Label(cal.title, systemImage: "circle.fill")
                        .foregroundStyle(cal.colorHex.map { Color(calendarHex: $0) } ?? palette.accent)
                        .tag(cal.id)
                }
            }

            TextField("Location", text: $location)
                .foregroundStyle(palette.textPrimary)
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...6)
                .foregroundStyle(palette.textPrimary)
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                guard let editing else { return }
                do {
                    try store.delete(editing)
                    onDeleted()
                    dismiss()
                } catch {
                    saveError = "Deleting failed: \(error.localizedDescription)"
                }
            } label: {
                Text("Delete Event")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(palette.danger)
            }
        }
    }

    // MARK: Behaviour

    private func seedNewEvent() {
        let minuteAligned = Calendar.current.date(
            bySettingHour: Calendar.current.component(.hour, from: defaultDate),
            minute: Calendar.current.component(.minute, from: defaultDate),
            second: 0,
            of: defaultDate
        ) ?? defaultDate
        starts = minuteAligned
        ends = minuteAligned.addingTimeInterval(3600)
        calendarID = store.defaultCalendar()?.id ?? store.calendars.first?.id ?? ""
        alarmMinutesBefore = nil
    }

    /// Keep ends after starts while typing: an event that ends before it starts would be saved
    /// and then silently shuffled by EventKit, which is worse than quietly following the start.
    private func adjustEndsIfNeeded() {
        if ends <= starts {
            ends = starts.addingTimeInterval(3600)
        }
    }

    private func save() {
        guard !calendarID.isEmpty else {
            saveError = "No calendar is available to save into."
            return
        }

        let draft = CalendarStore.EventDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no title)" : title,
            location: location,
            notes: notes,
            isAllDay: isAllDay,
            starts: starts,
            ends: ends,
            calendarID: calendarID,
            alarmMinutesBefore: alarmMinutesBefore
        )

        do {
            let saved = try store.save(draft, editing: editing)
            onSaved(saved)
            dismiss()
        } catch {
            saveError = "Saving failed: \(error.localizedDescription)"
        }
    }
}
