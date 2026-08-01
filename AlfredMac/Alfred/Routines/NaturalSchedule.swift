import Foundation

/// Turns a natural-language schedule into a 5-field cron string that `CronSchedule` understands, so
/// the user can type "every day at 0600", "weekdays at 8am", "mondays at 9:30pm", or "every 30
/// minutes" instead of "0 6 * * *". Returns nil when it can't confidently parse — the caller then
/// falls back to treating the text as raw cron.
enum NaturalSchedule {

    static func cron(from raw: String) -> String? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for junk in ["o'clock", "please", "every single"] {
            s = s.replacingOccurrences(of: junk, with: " ")
        }
        s = s.replacingOccurrences(of: "everyday", with: "every day")

        // ── interval: "every N minutes" / "every minute" ──
        if s.contains("minute") {
            if let n = firstInt(in: s), (1...59).contains(n) { return "*/\(n) * * * *" }
            return "* * * * *"
        }
        // ── interval: "hourly" / "every hour" / "every N hours" ──
        if s == "hourly" || s.contains("hour") {
            if let n = firstInt(in: s), (1...23).contains(n) { return "0 */\(n) * * *" }
            return "0 * * * *"
        }

        // ── daily / weekly at a specific time ──
        guard let (h, m) = parseTime(s) else { return nil }
        return "\(m) \(h) * * \(parseDaysOfWeek(s))"
    }

    // MARK: - Time of day

    private static func parseTime(_ s: String) -> (hour: Int, minute: Int)? {
        if s.contains("noon") { return (12, 0) }
        if s.contains("midnight") { return (0, 0) }

        let pm = s.contains("pm") || s.contains("p.m")
        let am = s.contains("am") || s.contains("a.m")

        // HH:MM (e.g. 6:00, 18:30, 9:30pm)
        if let (h, m) = firstColonTime(in: s) {
            let hour = adjust(h, am: am, pm: pm)
            if valid(hour, m) { return (hour, m) }
        }
        // HHMM (e.g. 0600, 1830)
        if let r = s.range(of: #"\b\d{4}\b"#, options: .regularExpression) {
            let d = String(s[r])
            let hour = adjust(Int(d.prefix(2)) ?? -1, am: am, pm: pm)
            let minute = Int(d.suffix(2)) ?? -1
            if valid(hour, minute) { return (hour, minute) }
        }
        // Bare hour (e.g. "at 6", "6am", "6 pm")
        if let h = firstInt(in: s) {
            let hour = adjust(h, am: am, pm: pm)
            if valid(hour, 0) { return (hour, 0) }
        }
        return nil
    }

    private static func adjust(_ h: Int, am: Bool, pm: Bool) -> Int {
        var hour = h
        if pm && hour < 12 { hour += 12 }
        if am && hour == 12 { hour = 0 }
        return hour
    }

    private static func valid(_ h: Int, _ m: Int) -> Bool { (0...23).contains(h) && (0...59).contains(m) }

    // MARK: - Day of week

    private static func parseDaysOfWeek(_ s: String) -> String {
        if s.contains("weekday") || s.contains("week day") { return "1-5" }
        if s.contains("weekend") { return "0,6" }
        // Full names first, then abbreviations; a Set dedupes overlaps ("mon" inside "monday").
        let names: [(String, Int)] = [
            ("sunday", 0), ("monday", 1), ("tuesday", 2), ("wednesday", 3),
            ("thursday", 4), ("friday", 5), ("saturday", 6),
            ("sun", 0), ("mon", 1), ("tue", 2), ("wed", 3), ("thu", 4), ("fri", 5), ("sat", 6),
        ]
        var days = Set<Int>()
        for (name, n) in names where s.contains(name) { days.insert(n) }
        return days.isEmpty ? "*" : days.sorted().map(String.init).joined(separator: ",")
    }

    // MARK: - Helpers

    private static func firstInt(in s: String) -> Int? {
        guard let r = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    private static func firstColonTime(in s: String) -> (Int, Int)? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})"#) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
              let a = Int(s[r1]), let b = Int(s[r2]) else { return nil }
        return (a, b)
    }
}
