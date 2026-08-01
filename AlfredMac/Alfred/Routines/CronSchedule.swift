import Foundation

/// Minimal 5-field cron schedule: `minute hour day-of-month month day-of-week`.
///
/// Supports `*`, single values, lists (`a,b`), ranges (`a-b`), and steps (`*/n`, `a-b/n`).
/// Day-of-week: `0` or `7` = Sunday. Follows standard cron OR-semantics between
/// day-of-month and day-of-week when BOTH are restricted (non-`*`).
struct CronSchedule: Equatable {
    private let minutes: Set<Int>
    private let hours: Set<Int>
    private let daysOfMonth: Set<Int>
    private let months: Set<Int>
    private let daysOfWeek: Set<Int>   // normalized 0-6 (0 = Sunday)
    private let domRestricted: Bool
    private let dowRestricted: Bool

    init?(_ expression: String) {
        let fields = expression
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard fields.count == 5,
              let mins = Self.parseField(fields[0], min: 0, max: 59),
              let hrs = Self.parseField(fields[1], min: 0, max: 23),
              let doms = Self.parseField(fields[2], min: 1, max: 31),
              let mons = Self.parseField(fields[3], min: 1, max: 12),
              let dowsRaw = Self.parseField(fields[4], min: 0, max: 7)
        else { return nil }

        self.minutes = mins
        self.hours = hrs
        self.daysOfMonth = doms
        self.months = mons
        self.daysOfWeek = Set(dowsRaw.map { $0 == 7 ? 0 : $0 })   // 7 → 0 (Sunday)
        self.domRestricted = fields[2] != "*"
        self.dowRestricted = fields[4] != "*"
    }

    /// True when `date` (evaluated in `timeZone`) matches all cron fields, to minute resolution.
    func matches(_ date: Date, in timeZone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return matches(date, calendar: cal)
    }

    /// Same test against a preconfigured calendar, so callers in a loop (nextDate) don't rebuild one.
    private func matches(_ date: Date, calendar cal: Calendar) -> Bool {
        let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = c.minute, let hour = c.hour, let day = c.day,
              let month = c.month, let weekday = c.weekday else { return false }
        let cronDow = weekday - 1   // Calendar 1=Sun..7=Sat → cron 0=Sun..6=Sat

        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else {
            return false
        }

        let domMatch = daysOfMonth.contains(day)
        let dowMatch = daysOfWeek.contains(cronDow)

        if domRestricted && dowRestricted { return domMatch || dowMatch }
        if domRestricted { return domMatch }
        if dowRestricted { return dowMatch }
        return true
    }

    /// The next minute strictly after `date` that matches. Searches up to ~366 days.
    func nextDate(after date: Date, in timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard var candidate = cal.date(bySetting: .second, value: 0, of: date) else { return nil }
        if candidate <= date {
            candidate = cal.date(byAdding: .minute, value: 1, to: candidate) ?? candidate
        }
        // Worst-case gap between valid occurrences is ~4 years (Feb-29 leap day), plus slack.
        let limit = 60 * 24 * 366 * 4 + 60 * 24 * 2
        var step = 0
        while step < limit {
            if matches(candidate, calendar: cal) { return candidate }
            guard let next = cal.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
            candidate = next
            step += 1
        }
        return nil
    }

    // MARK: - Field parsing

    private static func parseField(_ field: String, min: Int, max: Int) -> Set<Int>? {
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            guard let values = parsePart(String(part), min: min, max: max) else { return nil }
            result.formUnion(values)
        }
        return result.isEmpty ? nil : result
    }

    private static func parsePart(_ part: String, min: Int, max: Int) -> Set<Int>? {
        var rangePart = part
        var step = 1
        var hasStep = false
        if let slash = part.firstIndex(of: "/") {
            rangePart = String(part[part.startIndex..<slash])
            guard let s = Int(part[part.index(after: slash)...]), s > 0 else { return nil }
            step = s
            hasStep = true
        }

        let lo: Int
        let hi: Int
        if rangePart == "*" {
            lo = min; hi = max
        } else if let dash = rangePart.firstIndex(of: "-") {
            guard let a = Int(rangePart[rangePart.startIndex..<dash]),
                  let b = Int(rangePart[rangePart.index(after: dash)...]) else { return nil }
            lo = a; hi = b
        } else {
            guard let v = Int(rangePart) else { return nil }
            lo = v
            // Standard cron: "N/step" means N..max step (every `step` starting at N).
            hi = hasStep ? max : v
        }
        guard lo >= min, hi <= max, lo <= hi else { return nil }

        var values = Set<Int>()
        var v = lo
        while v <= hi {
            values.insert(v)
            v += step
        }
        return values
    }
}
