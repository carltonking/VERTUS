import Foundation

/// Detects "add this to my calendar"-style requests and extracts a single structured event from the
/// on-screen text (Accessibility) via one LLM call, so the caller can create it with
/// `CalendarRemindersCapability.createEvent`. Parsing is defensive — a bad/empty model reply yields nil
/// and the caller falls back to asking the user for the details.
struct CalendarEventCapability {

    struct Extracted {
        let title: String
        let start: Date
        let end: Date?
        let location: String?
        let notes: String?
        let allDay: Bool
    }

    /// True for phrases that mean "CREATE a calendar event" — not "what's on my calendar" (a read).
    static func detect(in query: String) -> Bool {
        let q = query.lowercased()
        guard q.contains("calendar") || q.contains("schedule") else { return false }
        let addVerb = ["add", "put", "create", "schedule", "save", "make", "set up", "new event", "book"]
            .contains { q.contains($0) }
        let read = ["what", "show", "list", "check", "do i have", "upcoming", "what's on", "whats on"]
            .contains { q.contains($0) }
        return addVerb && !read
    }

    /// Extracts an event from the on-screen text (plus the user's phrasing) via one LLM call.
    static func extract(screenText: String, query: String, now: Date, router: LLMRouter) async -> Extracted? {
        let today = Self.isoDate.string(from: now)
        let weekday = Self.weekday.string(from: now)
        let tz = TimeZone.current.identifier

        let system = """
        You extract a single calendar event from on-screen text. Today is \(weekday), \(today) (timezone \
        \(tz)). Use this date reference to resolve relative dates like "tomorrow" / "this Thursday" / \
        "next Monday" — do NOT compute weekdays yourself:
        \(Self.dateReference(from: now))
        Times stay as written ("3pm" → 15:00). Reply with ONE JSON object and nothing else:
        {"found": true|false, "title": string, "date": "YYYY-MM-DD", "start": "HH:mm" (24h) or null, \
        "end": "HH:mm" or null, "allDay": true|false, "location": string or null, "notes": string or null}
        Rules: "found" is false if there's no event. If several events appear, pick the one the user is \
        looking at — the most prominent / foreground one. If a date has no year, use the next FUTURE \
        occurrence. If a start time is present, allDay=false; if only a date is given, allDay=true and \
        start=null. Keep the title short. Never invent details that aren't in the text.
        """
        var user = "ON-SCREEN TEXT:\n\"\"\"\n\(String(screenText.prefix(6000)))\n\"\"\""
        user += "\n\nUSER REQUEST: \(query)"

        guard let raw = try? await router.complete(prompt: user, system: system) else { return nil }
        return parse(raw)
    }

    // MARK: - Parsing

    private static func parse(_ raw: String) -> Extracted? {
        guard let obj = jsonObject(from: raw), (obj["found"] as? Bool) == true,
              let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, let dateStr = obj["date"] as? String else { return nil }

        let allDay = (obj["allDay"] as? Bool) ?? false
        guard let start = combine(date: dateStr, time: allDay ? nil : (obj["start"] as? String)) else { return nil }
        var end: Date? = nil
        if !allDay, let endStr = obj["end"] as? String { end = combine(date: dateStr, time: endStr) }
        return Extracted(title: title, start: start, end: end,
                         location: nonEmpty(obj["location"]), notes: nonEmpty(obj["notes"]), allDay: allDay)
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Pulls the first {…} object out of a model reply (tolerates code fences / stray prose).
    private static func jsonObject(from raw: String) -> [String: Any]? {
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"), lo < hi,
              let data = String(raw[lo...hi]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Combines "YYYY-MM-DD" + optional "HH:mm" into a local-time Date (nil time → start of day).
    private static func combine(date: String, time: String?) -> Date? {
        let d = date.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = d[0]; comps.month = d[1]; comps.day = d[2]
        if let time {
            let t = time.split(separator: ":").compactMap { Int($0) }
            if t.count >= 2 { comps.hour = t[0]; comps.minute = t[1] }
        }
        var cal = Calendar.current
        cal.timeZone = .current
        return cal.date(from: comps)
    }

    /// The next 10 days as "Weekday YYYY-MM-DD" so the model looks dates up instead of doing weekday
    /// math (which it gets wrong — e.g. "this Thursday" landing a day off).
    private static func dateReference(from now: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
        return (0..<10).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: now)
                .map { "\(weekday.string(from: $0)) \(isoDate.string(from: $0))" }
        }.joined(separator: "\n")
    }

    private static let isoDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
