//
//  AlfredTests.swift
//  AlfredTests
//
//  Created by Carlton King on 8/4/26.
//

import Foundation
import Testing
@testable import Alfred

/// The address field is the one place a user can silently misconfigure the app, and every shape
/// below is something a person plausibly pastes. These run against the shipping normaliser.
@Suite("Endpoint normalisation")
struct EndpointTests {
    private let canonical = "https://alfredassistant.vercel.app/api/mac"

    @Test("A bare hostname gets https and the API path")
    func bareHost() {
        #expect(AppSettings.endpoint(forHost: "alfredassistant.vercel.app")?.absoluteString == canonical)
    }

    @Test("Every URL shape of the same deployment resolves identically", arguments: [
        "https://alfredassistant.vercel.app",
        "https://alfredassistant.vercel.app/",
        "https://alfredassistant.vercel.app/api/mac",
        "  alfredassistant.vercel.app  ",
        "https://alfredassistant.vercel.app/api/mac?x=1",
    ])
    func equivalentShapes(_ input: String) {
        #expect(AppSettings.endpoint(forHost: input)?.absoluteString == canonical)
    }

    @Test("localhost over http is allowed, for running against `vercel dev`")
    func localDevelopment() {
        #expect(AppSettings.endpoint(forHost: "http://localhost:3000")?.absoluteString == "http://localhost:3000/api/mac")
    }

    /// Anything unusable must produce nil so the app stays in its "not connected" state rather than
    /// showing a chat box that can only ever fail.
    @Test("Unusable input yields no endpoint", arguments: ["", "   ", "notahost", "ftp://example.com"])
    func rejected(_ input: String) {
        #expect(AppSettings.endpoint(forHost: input) == nil)
    }
}

/// Transcript rows are persisted as JSON, so a change to `Message` that breaks decoding would
/// silently wipe someone's history on next launch.
@Suite("Message persistence")
struct MessageTests {
    @Test("A message survives an encode/decode round trip")
    func roundTrip() throws {
        let original = Message(role: .error, text: "boom", failedPrompt: "what's the weather?")
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
        #expect(decoded.failedPrompt == "what's the weather?")
    }

    @Test("Retry context is absent on ordinary turns")
    func noRetryContextOnNormalTurns() {
        #expect(Message(role: .user, text: "hi").failedPrompt == nil)
        #expect(Message(role: .alfred, text: "hello").failedPrompt == nil)
    }
}

// MARK: - Home briefing

/// The Home tab's summary sentences. Built from CalendarEntry values on a fixed UTC calendar so the
/// dates, weekdays, and times are deterministic.
@Suite("Home daily briefing")
struct DailyBriefingTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func entry(
        _ title: String,
        day: Int,
        hour: Int,
        minute: Int = 0,
        location: String? = nil,
        allDay: Bool = false
    ) -> CalendarEntry {
        let start = date(month: 8, day: day, hour: hour, minute: minute)
        return CalendarEntry(
            id: "\(title)@\(day)",
            eventIdentifier: title,
            title: title,
            start: start,
            end: allDay ? start : start.addingTimeInterval(3600),
            isAllDay: allDay,
            location: location,
            notes: nil,
            url: nil,
            calendarID: "school",
            calendarName: "School",
            calendarColorHex: nil,
            alarmMinutesBefore: nil
        )
    }

    /// Noon on Thursday, 6 August 2026.
    private var now: Date { date(month: 8, day: 6, hour: 12) }

    /// The full weekday name the briefing derives for exams ("Friday", "Saturday") — pinned the same
    /// way the app does, so the assertion can't drift with the machine's locale.
    private func weekdayName(_ start: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: start)
    }

    @Test("A homework due tonight reads as an assignment sentence")
    func homeworkTonight() {
        let briefing = DailyBriefing(entries: [entry("Calculus II Homework", day: 6, hour: 20)],
                                     now: now, calendar: utc)
        #expect(briefing.assignments == ["You have your Calculus II homework due tonight at 8:00 PM."])
        #expect(briefing.events.isEmpty)
        #expect(briefing.dueThisWeek.isEmpty)
    }

    @Test("An essay due this afternoon reads as due today")
    func essayToday() {
        let briefing = DailyBriefing(entries: [entry("English Essay", day: 6, hour: 15)],
                                     now: now, calendar: utc)
        #expect(briefing.assignments == ["You have your English essay due today at 3:00 PM."])
    }

    @Test("A meeting keeps its time and location")
    func meetingWithLocation() {
        let briefing = DailyBriefing(entries: [entry("Meeting with Dr. Lee", day: 6, hour: 14, location: "Room 4-201")],
                                     now: now, calendar: utc)
        #expect(briefing.events == ["You have Meeting with Dr. Lee at 2:00 PM, in Room 4-201."])
    }

    @Test("An exam later in the week lands in the due-this-week section")
    func examLaterThisWeek() {
        let exam = entry("Chemistry Final Exam", day: 8, hour: 9, location: "Hall A")
        let briefing = DailyBriefing(entries: [exam], now: now, calendar: utc)
        #expect(briefing.events.isEmpty)
        #expect(briefing.assignments.isEmpty)
        #expect(briefing.dueThisWeek == ["You have a final exam for Chemistry on \(weekdayName(exam.start)) at 9:00 AM, in Hall A."])
    }

    @Test("An exam today is mentioned as today, not as a weekday")
    func examToday() {
        let briefing = DailyBriefing(entries: [entry("Statistics Midterm", day: 6, hour: 15, location: "Room 101")],
                                     now: now, calendar: utc)
        #expect(briefing.dueThisWeek == ["You have a midterm for Statistics today at 3:00 PM, in Room 101."])
        #expect(briefing.events.isEmpty)
    }

    @Test("A past meeting is skipped")
    func pastMeetingSkipped() {
        let briefing = DailyBriefing(entries: [entry("Morning Meeting", day: 6, hour: 9)],
                                     now: now, calendar: utc)
        #expect(briefing.events.isEmpty)
        #expect(briefing.assignments.isEmpty)
        #expect(briefing.dueThisWeek.isEmpty)
        #expect(!briefing.hasContent)
    }

    @Test("An all-day event reads as all day")
    func allDayEvent() {
        let briefing = DailyBriefing(entries: [entry("Spring Break", day: 6, hour: 0, allDay: true)],
                                     now: now, calendar: utc)
        #expect(briefing.events == ["You have Spring Break all day."])
    }

    @Test("To-dos list today's assignments and exams as action bullets")
    func todosBullets() {
        let briefing = DailyBriefing(entries: [
            entry("Calculus II Homework", day: 6, hour: 20),
            entry("Statistics Midterm", day: 6, hour: 15, location: "Room 101"),
        ], now: now, calendar: utc)
        #expect(briefing.todos == [
            "Statistics midterm, due at 3:00 PM",
            "Calculus II homework, due tonight",
        ])
    }

    @Test("Nothing on the calendar means no content")
    func empty() {
        let briefing = DailyBriefing(entries: [], now: now, calendar: utc)
        #expect(!briefing.hasContent)
    }
}

// MARK: - Greeting

/// The greeting rotates on a per-day, per-three-hour slot.
@Suite("Greeting rotation")
struct GreetingTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(month: Int, day: Int, hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test("The greeting matches the time of day")
    func timeOfDay() {
        let morning = [
            "Good morning, Carlton.",
            "Morning, Carlton — fresh start.",
            "Rise and shine, Carlton.",
            "Good morning, Carlton. Ready when you are.",
        ]
        let afternoon = [
            "Good afternoon, Carlton.",
            "Happy afternoon, Carlton.",
            "Good to see you, Carlton.",
            "Afternoon, Carlton.",
        ]
        let evening = [
            "Good evening, Carlton.",
            "Evening, Carlton.",
            "How's the day been, Carlton?",
            "Almost there, Carlton.",
        ]
        let night = [
            "Working late, Carlton?",
            "Good night, Carlton.",
            "Still going, Carlton?",
            "Late one, Carlton.",
        ]

        #expect(morning.contains(Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 8), calendar: utc)))
        #expect(afternoon.contains(Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 14), calendar: utc)))
        #expect(evening.contains(Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 19), calendar: utc)))
        #expect(night.contains(Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 23), calendar: utc)))
    }

    @Test("The slot holds for three hours, then advances")
    func threeHourCycle() {
        #expect(Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 6), calendar: utc)
            == Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 8), calendar: utc))
        #expect(Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 6), calendar: utc)
            != Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 9), calendar: utc))
    }

    @Test("A different day brings a different greeting")
    func dayShift() {
        #expect(Greeting.text(name: "Carlton", at: date(month: 8, day: 6, hour: 8), calendar: utc)
            != Greeting.text(name: "Carlton", at: date(month: 8, day: 7, hour: 8), calendar: utc))
    }
}
