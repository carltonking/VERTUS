import Foundation

struct SyllabusExtract {
    var course: String?
    var code: String?
    var termYear: Int?
    var items: [SyllabusItem]
}

/// Turns raw syllabus text into a structured, year-resolved list of items via the LLM. Mirrors the
/// cloud's api/_lib/extract.ts (same prompt shape, same deterministic year resolution).
enum SyllabusExtractor {
    static func extract(text: String, courseHint: String?, now: Date, router: LLMRouter) async -> SyllabusExtract? {
        let sys = systemPrompt(now: now, courseHint: courseHint)
        let user = "SYLLABUS:\n\"\"\"\n\(String(text.prefix(20000)))\n\"\"\"\n\nExtract every dated item."
        guard let raw = try? await router.complete(prompt: user, system: sys) else { return nil }
        return parse(raw, courseHint: courseHint, now: now)
    }

    // MARK: - Prompt

    private static func systemPrompt(now: Date, courseHint: String?) -> String {
        let today = isoDay(now)
        let year = Int(today.prefix(4)) ?? 2026
        var cal = Calendar(identifier: .gregorian); cal.timeZone = syllabusUserTZ
        let weekday = weekdayName(now)
        var lines = [
            "You extract every dated deliverable from a course syllabus. Today is \(weekday), \(today) (timezone America/New_York).",
        ]
        if let courseHint, !courseHint.isEmpty { lines.append("The user says this is for course: \"\(courseHint)\".") }
        lines.append("Use this date reference to resolve relative dates — do NOT compute weekdays yourself:")
        lines.append(dateReference(now))
        lines.append("Reply with ONE JSON object and nothing else:")
        lines.append("{\"course\": string|null, \"code\": string|null, \"term\": string|null, \"termYear\": number|null, \"items\": [")
        lines.append("  {\"type\": \"assignment|quiz|exam|final|reading|project|other\", \"title\": string, \"date\": \"YYYY-MM-DD\",")
        lines.append("   \"start\": \"HH:mm\"|null, \"end\": \"HH:mm\"|null, \"allDay\": true|false, \"yearMentioned\": true|false,")
        lines.append("   \"weight\": string|null, \"topics\": [string], \"location\": string|null, \"notes\": string|null} ] }")
        lines.append("Rules:")
        lines.append("- ONLY include an item if the syllabus states an EXPLICIT calendar date for it. If a row has no date (or only \"Week 6\" with no date mapping), OMIT it. Never invent or estimate dates.")
        lines.append("- Keep distinguishing numbers in titles (\"Problem Set 3\", \"Midterm 2\", \"Quiz 4\") — never collapse them to a generic name.")
        lines.append("- Set \"code\" to the short course code (e.g. \"CS 101\"), \"term\" to the term as written (\"Fall 2026\") if present, and \"termYear\" to its 4-digit year. Set per-item \"yearMentioned\" true ONLY if that row explicitly names a year; otherwise put \(year) and the app resolves it.")
        lines.append("- A cumulative/end-of-term exam = \"final\". A timed exam has allDay=false; a date-only item has allDay=true and start=null.")
        lines.append("- \"topics\": for exams/finals/readings, the coverage or reading topics as a short list; else []. \"weight\": grade weight as written or null. Keep titles short. Never invent details.")
        return lines.joined(separator: "\n")
    }

    private static func dateReference(_ now: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = syllabusUserTZ
        var out: [String] = []
        for i in 0..<10 {
            if let d = cal.date(byAdding: .day, value: i, to: now) {
                out.append("\(weekdayName(d)) \(isoDay(d))")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func weekdayName(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = syllabusUserTZ; f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEEE"
        return f.string(from: d)
    }
    private static func isoDay(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = syllabusUserTZ
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Parse

    private static func parse(_ raw: String, courseHint: String?, now: Date) -> SyllabusExtract? {
        guard let obj = firstJSONObject(raw) else { return nil }
        let course = strOrNil(obj["course"])
        let code = courseHint ?? strOrNil(obj["code"])
        let term = strOrNil(obj["term"])
        let termYear = intOrNil(obj["termYear"]) ?? yearFromTerm(term)
        let season = seasonOf(term)
        let rawItems = (obj["items"] as? [[String: Any]]) ?? (obj["items"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let items = rawItems.compactMap { coerce($0, termYear: termYear, season: season, now: now) }
        if items.isEmpty && course == nil { return nil }
        return SyllabusExtract(course: course, code: code, termYear: termYear, items: items)
    }

    private static func coerce(_ o: [String: Any], termYear: Int?, season: String?, now: Date) -> SyllabusItem? {
        guard let title = strOrNil(o["title"]), let date = strOrNil(o["date"]),
              date.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return nil }
        let start = (o["allDay"] as? Bool == true) ? nil : timeOrNil(o["start"])
        let allDay = (o["allDay"] as? Bool == true) || start == nil
        let type = SyllabusItemType(rawValue: (o["type"] as? String) ?? "other") ?? .other
        let topics = (o["topics"] as? [Any])?.compactMap { strOrNil($0) } ?? []
        return SyllabusItem(
            type: type, title: title,
            date: resolveYear(date, yearMentioned: o["yearMentioned"] as? Bool == true, termYear: termYear, season: season, now: now),
            start: start, end: allDay ? nil : timeOrNil(o["end"]), allDay: allDay,
            weight: strOrNil(o["weight"]), topics: topics,
            location: strOrNil(o["location"]), notes: strOrNil(o["notes"])
        )
    }

    private static func resolveYear(_ dateStr: String, yearMentioned: Bool, termYear: Int?, season: String?, now: Date) -> String {
        if yearMentioned { return dateStr }
        if let ty = termYear, ty >= 1000, ty <= 9999 {
            let mo = Int(dateStr.dropFirst(5).prefix(2)) ?? 0
            var y = ty
            if season == "fall" && mo <= 6 { y = ty + 1 }
            else if season == "spring" && mo >= 8 { y = ty - 1 }
            return "\(String(format: "%04d", y))-\(dateStr.dropFirst(5))"
        }
        return snapYear(dateStr, now: now)
    }

    /// Past no-year date → next future occurrence of that month/day (mirror of snapYear).
    private static func snapYear(_ dateStr: String, now: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = syllabusUserTZ
        let tc = cal.dateComponents([.year, .month, .day], from: now)
        let p = dateStr.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let ty = tc.year, let tm = tc.month, let td = tc.day else { return dateStr }
        func key(_ y: Int, _ m: Int, _ d: Int) -> Int { y * 10000 + m * 100 + d }
        let todayKey = key(ty, tm, td)
        if key(p[0], p[1], p[2]) >= todayKey { return dateStr }
        for yr in ty...(ty + 3) where key(yr, p[1], p[2]) >= todayKey {
            return String(format: "%04d-%02d-%02d", yr, p[1], p[2])
        }
        return dateStr
    }

    private static func seasonOf(_ term: String?) -> String? {
        guard let t = term?.lowercased() else { return nil }
        if t.contains("fall") || t.contains("autumn") { return "fall" }
        if t.contains("spring") { return "spring" }
        if t.contains("summer") { return "summer" }
        if t.contains("winter") { return "winter" }
        return nil
    }
    private static func yearFromTerm(_ term: String?) -> Int? {
        guard let term, let r = term.range(of: "20\\d{2}", options: .regularExpression) else { return nil }
        return Int(term[r])
    }

    // MARK: - JSON helpers

    private static func firstJSONObject(_ raw: String) -> [String: Any]? {
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"), lo < hi else { return nil }
        let slice = String(raw[lo...hi])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }
    private static func strOrNil(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    private static func intOrNil(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    private static func timeOrNil(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces),
              s.range(of: "^\\d{1,2}:\\d{2}$", options: .regularExpression) != nil else { return nil }
        return s
    }
}
