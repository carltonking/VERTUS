import Foundation
import CryptoKit

// Swift side of the syllabus feature's shared contract. These functions MUST produce byte-identical
// output to the cloud bot's api/_lib/keys.ts + study.ts so both platforms read/write the same tagged
// iCloud events and never duplicate. Parity is covered by SyllabusContractTests.

/// User timezone — pinned to match the cloud (USER_TZ). Events/times are interpreted here.
let syllabusUserTZ = TimeZone(identifier: "America/New_York") ?? .current

enum SyllabusItemType: String, CaseIterable, Codable {
    case assignment, quiz, exam, final, reading, project, other

    var emoji: String {
        switch self {
        case .assignment: return "📝"
        case .quiz: return "🧠"
        case .exam: return "✍️"
        case .final: return "🎓"
        case .reading: return "📖"
        case .project: return "🛠️"
        case .other: return "📌"
        }
    }
}

/// One dated syllabus item (mirror of the cloud SyllabusItem).
struct SyllabusItem: Identifiable, Equatable {
    var id = UUID()
    var type: SyllabusItemType
    var title: String
    var date: String          // YYYY-MM-DD, year resolved
    var start: String?        // HH:mm or nil
    var end: String?
    var allDay: Bool
    var weight: String?
    var topics: [String]
    var location: String?
    var notes: String?
    var include: Bool = true   // review checkbox
}

/// A course currently present on the calendar (derived from tagged events — the calendar is the store).
struct CourseSummary: Identifiable, Equatable {
    var id: String { code }
    let code: String     // normalized (token c=)
    let display: String  // pretty label from the event title's [CODE], else the code
    let count: Int       // number of deadline items (excludes study blocks)
}

/// A concrete event to create on the calendar (deadline or generated study block).
struct SchoolEventSpec {
    let key: String
    let displayTitle: String   // "📝 [CS 101] Problem Set 3"
    let date: String
    let start: String?
    let end: String?
    let allDay: Bool
    let location: String?
    let humanNotes: String?
    let url: String
    let token: String
    let alarmOffsets: [TimeInterval]  // seconds relative to the event start (midnight for all-day)
}

// MARK: - Identity / normalization (mirror of keys.ts)

enum SyllabusKeys {
    static func normCode(_ code: String) -> String {
        code.uppercased().replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
    }

    static func normTitle(_ title: String, code: String? = nil) -> String {
        // NFKD (decomposedStringWithCompatibilityMapping); the [^a-z0-9] filter then drops combining marks.
        var t = title.decomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let code, !code.isEmpty {
            let nc = code.decomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !nc.isEmpty {
                let e = NSRegularExpression.escapedPattern(for: nc)
                t = t.replacingOccurrences(of: "^\(e)\\s+|\\s+\(e)$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return t
    }

    private static func sha12(_ src: String) -> String {
        let digest = SHA256.hash(data: Data(src.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// Stable per-item key (date INCLUDED — matches keys.ts, avoids same-title collisions).
    static func itemKey(_ code: String, _ type: String, _ title: String, _ date: String) -> String {
        sha12("\(normCode(code))|\(type)|\(normTitle(title, code: code))|\(date)")
    }

    static func studyKey(_ code: String, _ examKey: String, _ offset: Int) -> String {
        sha12("\(normCode(code))|study|\(examKey)|D-\(offset)")
    }

    static func batchId(_ code: String, _ termYear: Int?) -> String {
        "\(normCode(code))-\(termYear.map(String.init) ?? "x")"
    }

    static func schoolURL(_ code: String, _ type: String, _ key: String) -> String {
        "alfred://school/\(normCode(code))/\(type)/\(key)"
    }

    /// Only ICS-non-escapable chars, matching keys.ts tokenVal.
    private static func tokenVal(_ s: String) -> String {
        s.replacingOccurrences(of: "[|\\]\\[~=;,\\\\\r\n]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func schoolToken(key: String, code: String, type: String, batch: String,
                            weight: String? = nil, topics: [String] = [], linkedExamKey: String? = nil) -> String {
        var parts = ["k=\(key)", "c=\(normCode(code))", "t=\(type)", "b=\(batch)"]
        if let weight, !weight.isEmpty { parts.append("w=\(tokenVal(weight))") }
        if let linkedExamKey, !linkedExamKey.isEmpty { parts.append("x=\(linkedExamKey)") }
        let tp = topics.map(tokenVal).filter { !$0.isEmpty }
        if !tp.isEmpty { parts.append("tp=\(tp.joined(separator: "~"))") }
        return "[alfred|v1|\(parts.joined(separator: "|"))]"
    }

    /// Parse the `[alfred|v1|...]` token out of a notes/description string.
    static func parseToken(_ text: String) -> [String: String]? {
        guard let r = text.range(of: "\\[alfred\\|v1\\|[^\\]]*\\]", options: .regularExpression) else { return nil }
        let inner = text[r].dropFirst("[alfred|v1|".count).dropLast()
        var out: [String: String] = [:]
        for kv in inner.split(separator: "|") {
            if let eq = kv.firstIndex(of: "=") {
                out[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
        }
        return out
    }
}

// MARK: - Event building (deadline items → SchoolEventSpec)

enum SyllabusEvents {
    static func alarmOffsets(type: SyllabusItemType, allDay: Bool) -> [TimeInterval] {
        let isExam = (type == .exam || type == .final)
        if allDay {
            // Relative to midnight of the day. 9am morning-of = +9h; 9am day-before = -15h; ~week = -6d15h.
            return isExam ? [-572400, -54000, 32400] : [-54000, 32400]
        }
        return isExam ? [-7 * 86400, -86400, -2 * 3600] : [-86400, -3600]
    }

    static func deadlineSpec(_ item: SyllabusItem, code: String, batch: String) -> SchoolEventSpec {
        let key = SyllabusKeys.itemKey(code, item.type.rawValue, item.title, item.date)
        let human = [
            item.weight.map { "Weight: \($0)" },
            item.topics.isEmpty ? nil : "Topics: \(item.topics.joined(separator: ", "))",
            item.notes,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let token = SyllabusKeys.schoolToken(key: key, code: code, type: item.type.rawValue, batch: batch,
                                             weight: item.weight, topics: item.topics)
        return SchoolEventSpec(
            key: key,
            displayTitle: "\(item.type.emoji) [\(code)] \(item.title)",
            date: item.date, start: item.start, end: item.end, allDay: item.allDay,
            location: item.location,
            humanNotes: human.isEmpty ? nil : human,
            url: SyllabusKeys.schoolURL(code, item.type.rawValue, key),
            token: token,
            alarmOffsets: alarmOffsets(type: item.type, allDay: item.allDay)
        )
    }
}

// MARK: - Study schedule (mirror of study.ts planStudySessions)

enum StudyPlanner {
    static let offsets: [SyllabusItemType: [Int]] = [
        .final: [14, 10, 7, 4, 2, 1],
        .exam: [7, 4, 2, 1],
        .quiz: [2, 1],
    ]

    static func sessions(for exam: SyllabusItem, code: String, batch: String, now: Date) -> [SchoolEventSpec] {
        guard let offs = offsets[exam.type] else { return [] }
        let examKey = SyllabusKeys.itemKey(code, exam.type.rawValue, exam.title, exam.date)
        let today = isoDay(now)
        let nowHour = hour(now)
        let startHour = 17 + ((Int(examKey.prefix(2), radix: 16) ?? 0) % 4) // 17..20, stable per exam
        let start = String(format: "%02d:00", startHour)
        let end = String(format: "%02d:30", startHour + 1)
        let teach = max(1, offs.count - 2)
        let per = exam.topics.isEmpty ? 0 : Int(ceil(Double(exam.topics.count) / Double(teach)))

        var out: [SchoolEventSpec] = []
        for (i, d) in offs.enumerated() {
            let date = subtractDays(exam.date, d)
            if date < today || (date == today && startHour <= nowHour) { continue }

            let focus: String
            if exam.topics.isEmpty {
                focus = "Prep for \(exam.title)"
            } else if i < teach {
                let lo = i * per
                let chunk = lo < exam.topics.count ? Array(exam.topics[lo..<min(lo + per, exam.topics.count)]) : []
                focus = chunk.isEmpty ? "Review: \(exam.topics.joined(separator: ", "))" : "Focus: \(chunk.joined(separator: ", "))"
            } else {
                focus = "Review: \(exam.topics.joined(separator: ", "))"
            }

            let k = SyllabusKeys.studyKey(code, examKey, d)
            let token = SyllabusKeys.schoolToken(key: k, code: code, type: "study", batch: batch, linkedExamKey: examKey)
            out.append(SchoolEventSpec(
                key: k,
                displayTitle: "🔁 [\(code)] Study: \(exam.title)",
                date: date, start: start, end: end, allDay: false, location: nil,
                humanNotes: focus,
                url: SyllabusKeys.schoolURL(code, "study", k),
                token: token,
                alarmOffsets: [-30 * 60]
            ))
        }
        return out
    }

    private static func subtractDays(_ date: String, _ n: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = isoParse(date), let r = cal.date(byAdding: .day, value: -n, to: d) else { return date }
        return isoFormat(r)
    }
    private static func isoDay(_ now: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = syllabusUserTZ
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private static func hour(_ now: Date) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = syllabusUserTZ
        return cal.component(.hour, from: now)
    }
}

// MARK: - Date helpers (UTC-noon anchored, matching the cloud's string math)

func isoParse(_ s: String) -> Date? {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let p = s.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
    return cal.date(from: c)
}
func isoFormat(_ d: Date) -> String {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Build a concrete Date from an item's date (+optional HH:mm) in the user timezone.
func syllabusDate(_ dateStr: String, time: String?) -> Date? {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = syllabusUserTZ
    let p = dateStr.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
    if let time, case let tp = time.split(separator: ":").compactMap({ Int($0) }), tp.count == 2 {
        c.hour = tp[0]; c.minute = tp[1]
    } else {
        c.hour = 0; c.minute = 0
    }
    return cal.date(from: c)
}
