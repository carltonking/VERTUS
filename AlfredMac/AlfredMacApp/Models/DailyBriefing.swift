//
//  DailyBriefing.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Models/DailyBriefing.swift).
//

import Foundation

// MARK: - Greeting

/// The Home tab's greeting. Phrasings are grouped by time of day, and the slot advances every
/// three hours and once per day, so a phrase rarely repeats the same day and each morning reads
/// freshly.
struct Greeting {
    static func text(name: String, at date: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        let pool: [String]
        switch hour {
        case 5..<12:
            pool = [
                "Good morning, \(name).",
                "Morning, \(name) — fresh start.",
                "Rise and shine, \(name).",
                "Good morning, \(name). Ready when you are.",
            ]
        case 12..<17:
            pool = [
                "Good afternoon, \(name).",
                "Happy afternoon, \(name).",
                "Good to see you, \(name).",
                "Afternoon, \(name).",
            ]
        case 17..<21:
            pool = [
                "Good evening, \(name).",
                "Evening, \(name).",
                "How's the day been, \(name)?",
                "Almost there, \(name).",
            ]
        default:
            pool = [
                "Working late, \(name)?",
                "Good night, \(name).",
                "Still going, \(name)?",
                "Late one, \(name).",
            ]
        }
        return pool[(day + hour / 3) % pool.count]
    }
}

// MARK: - Daily briefing

/// The Home tab's summary of the day: meetings and appointments, work due today, and exams coming
/// up this week — each as plain sentences. Reads events in, produces sentences out, knows nothing
/// about the view that draws them.
struct DailyBriefing {
    private(set) var events: [String]
    private(set) var assignments: [String]
    private(set) var dueThisWeek: [String]
    /// One line per actionable item due today — the To-Do's list on the Home tab. Calendar
    /// reminders are kept out of this model (they live in EventKit's separate store) so the
    /// view appends those itself.
    private(set) var todos: [String]

    var hasContent: Bool {
        !(events.isEmpty && assignments.isEmpty && dueThisWeek.isEmpty)
    }

    init(entries: [CalendarEntry], now: Date = Date(), calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday
        let isToday = { (entry: CalendarEntry) -> Bool in
            calendar.startOfDay(for: entry.start) == startOfToday
        }
        let isPending = { (entry: CalendarEntry) -> Bool in
            entry.isAllDay || entry.end > now
        }

        let today = entries
            .filter(isToday)
            .filter(isPending)
            .sorted { $0.start < $1.start }
        let laterThisWeek = entries
            .filter { $0.start >= startOfToday && $0.start < weekEnd && $0.end > now && !isToday($0) }
            .sorted { $0.start < $1.start }

        var events: [String] = []
        var assignments: [String] = []
        var dueThisWeek: [String] = []
        var todos: [String] = []

        for entry in today {
            if Self.isExam(entry) {
                todos.append(Self.todoLine(entry, calendar: calendar))
            } else if Self.isAssignment(entry) {
                assignments.append(Self.assignmentLine(entry, calendar: calendar))
                todos.append(Self.todoLine(entry, calendar: calendar))
            } else {
                events.append(Self.eventLine(entry, calendar: calendar))
            }
        }

        let comingExams = today.filter(Self.isExam) + laterThisWeek.filter(Self.isExam)
        for entry in comingExams {
            dueThisWeek.append(Self.examLine(entry, now: now, calendar: calendar))
        }

        self.events = events
        self.assignments = assignments
        self.dueThisWeek = dueThisWeek
        self.todos = todos
    }

    // MARK: Classification

    private static let assignmentKeywords = [
        "homework", "hw", "assignment", "essay", "paper", "project",
        "lab report", "lab", "reading", "pset", "problem set", "worksheet",
    ]

    /// The order matters: "final exam" must claim a "Final Exam" title before the bare two, and a
    /// title like "exam review" should still read as exam-related.
    private static let examKeywords = [
        "midterm", "final exam", "exam", "final", "quiz", "test", "assessment",
    ]

    private static func isExam(_ entry: CalendarEntry) -> Bool {
        examKeywords.contains { matches(entry.title, keyword: $0) }
    }

    private static func isAssignment(_ entry: CalendarEntry) -> Bool {
        !isExam(entry) && assignmentKeywords.contains { matches(entry.title, keyword: $0) }
    }

    /// Whole-word match, so "hw" can't hide inside "what" and "lab" tolerates "lab report".
    private static func matches(_ title: String, keyword: String) -> Bool {
        var searchStart = title.startIndex
        while searchStart < title.endIndex,
              let range = title.range(of: keyword, options: .caseInsensitive, range: searchStart..<title.endIndex) {
            let beforeOK = range.lowerBound == title.startIndex
                || !title[title.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == title.endIndex
                || !title[range.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// The title with the matched keyword stripped out: "Calculus II Homework" becomes
    /// (subject: "Calculus II", kind: "homework") for phrasing like "your Calculus II homework".
    private static func splitTitle(_ title: String, keywords: [String]) -> (subject: String, kind: String?) {
        for keyword in keywords {
            var searchStart = title.startIndex
            while searchStart < title.endIndex,
                  let range = title.range(of: keyword, options: .caseInsensitive, range: searchStart..<title.endIndex) {
                let beforeOK = range.lowerBound == title.startIndex
                    || !title[title.index(before: range.lowerBound)].isLetter
                let afterOK = range.upperBound == title.endIndex
                    || !title[range.upperBound].isLetter
                if beforeOK && afterOK {
                    let subject = title.replacingCharacters(in: range, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                    return (subject.isEmpty ? title : subject, keyword.lowercased())
                }
                searchStart = range.upperBound
            }
        }
        return (title, nil)
    }

    // MARK: Wording

    private static func eventLine(_ entry: CalendarEntry, calendar: Calendar) -> String {
        if entry.isAllDay { return "You have \(entry.title) all day." }
        var line = "You have \(entry.title) at \(timeText(entry.start, calendar: calendar))"
        if let location = entry.location, !location.isEmpty {
            line += ", in \(location)"
        }
        return line + "."
    }

    private static func assignmentLine(_ entry: CalendarEntry, calendar: Calendar) -> String {
        let (subject, kind) = splitTitle(entry.title, keywords: assignmentKeywords)
        let time = timeText(entry.start, calendar: calendar)
        let dueWhen = calendar.component(.hour, from: entry.start) >= 18 ? "tonight" : "today"
        guard let kind else {
            return "You have \(entry.title) due \(dueWhen) at \(time)."
        }
        return "You have your \(subject) \(kind) due \(dueWhen) at \(time)."
    }

    private static func examLine(_ entry: CalendarEntry, now: Date, calendar: Calendar) -> String {
        let (subject, kind) = splitTitle(entry.title, keywords: examKeywords)
        let subjectText = subject.isEmpty ? entry.title : subject
        let day = calendar.startOfDay(for: entry.start) == calendar.startOfDay(for: now)
            ? "today"
            : "on \(weekdayName(entry.start, calendar: calendar))"
        var line = "You have \(examKindText(kind)) for \(subjectText) \(day) at \(timeText(entry.start, calendar: calendar))"
        if let location = entry.location, !location.isEmpty {
            line += ", in \(location)"
        }
        return line + "."
    }

    private static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private static func examKindText(_ kind: String?) -> String {
        switch kind {
        case "final", "final exam": return "a final exam"
        case "midterm": return "a midterm"
        case "quiz": return "a quiz"
        case "test": return "a test"
        case "assessment": return "an assessment"
        default: return "an exam"
        }
    }

    /// The To-Do's phrasing: short, imperative where it can be, with the subject first so the
    /// bullet scans like a task ("Calculus II homework, due tonight") rather than a sentence.
    private static func todoLine(_ entry: CalendarEntry, calendar: Calendar) -> String {
        let keywords = Self.isExam(entry) ? examKeywords : assignmentKeywords
        let (subject, kind) = splitTitle(entry.title, keywords: keywords)
        let subjectText = subject.isEmpty ? entry.title : subject
        let kindText: String
        if let kind {
            kindText = Self.isExam(entry)
                ? examKindText(kind).replacingOccurrences(of: "a ", with: "")
                : kind
        } else {
            kindText = ""
        }
        var line = subjectText
        if !kindText.isEmpty { line += " \(kindText)" }
        if !entry.isAllDay {
            let hour = calendar.component(.hour, from: entry.start)
            let dueWhen = hour >= 18 ? "tonight" : "at \(timeText(entry.start, calendar: calendar))"
            line += ", due \(dueWhen)"
        }
        return line
    }

    /// A fixed 12-hour "8:00 PM" style, so the sentences read the same no matter the phone's 12/24-hour
    /// or locale settings — and so the tests can pin exact strings.
    private static func timeText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
