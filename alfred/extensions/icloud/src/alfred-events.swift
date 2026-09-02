// ALFRED EventKit helper — calendar read/write bridge for the ALFRED CLI.
//
// Runs as a small CLI: reads JSON-friendly args from argv, prints JSON to stdout.
// Mutations (create/cancel) are HARD-SANDBOXED to a single calendar (default "ALFRED"),
// enforced here in native code so no tool call can ever touch a real calendar.
//
// Build: swiftc -O -o alfred-events alfred-events.swift

import EventKit
import Foundation

// ── Tiny CLI error ────────────────────────────────────────────────────────────
struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func json(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
          let str = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return str
}

func emit(_ obj: Any) -> Never {
    print(json(obj))
    exit(0)
}

// ── Argument parsing ──────────────────────────────────────────────────────────
final class Args {
    private let flags: [String: String]
    init(_ argv: ArraySlice<String>) {
        var map: [String: String] = [:]
        var it = argv.makeIterator()
        while let key = it.next() {
            guard key.hasPrefix("--"), key.count > 2 else { continue }
            let name = String(key.dropFirst(2))
            if let value = it.next() {
                map[name] = value
            }
        }
        flags = map
    }
    func str(_ name: String, default d: String? = nil) throws -> String {
        if let v = flags[name], !v.isEmpty { return v }
        if let d { return d }
        throw CLIError(message: "missing --\(name)")
    }
    func opt(_ name: String) -> String? {
        guard let v = flags[name], !v.isEmpty else { return nil }
        return v
    }
    func int(_ name: String, default d: Int) throws -> Int {
        if let v = flags[name], let n = Int(v) { return n }
        return d
    }
}

// ── EventKit plumbing ─────────────────────────────────────────────────────────
let store = EKEventStore()

func authorize() -> Bool {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
        return true
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { g, _ in granted = g; sem.signal() }
        } else {
            store.requestAccess(to: .event) { g, _ in granted = g; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 60)
        return granted
    case .denied, .restricted:
        return false
    case .writeOnly:
        return false
    @unknown default:
        return false
    }
}

func requireAccess() {
    guard authorize() else {
        fail("Calendar access denied or not yet granted.\n\nOn first use macOS shows a prompt — click Allow (System Settings → Privacy & Security → Calendar).\nIf there is no prompt, launch:\n  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars'\nand enable access for the app that runs the terminal (Terminal/iTerm).")
    }
}

// ── Date helpers ──────────────────────────────────────────────────────────────
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let isoFractionFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

let timeFormatters: [DateFormatter] = {
    let specs = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
    var fs: [DateFormatter] = []
    for s in specs {
        let f = DateFormatter()
        f.dateFormat = s
        f.locale = Locale(identifier: "en_US_POSIX")
        fs.append(f)
    }
    return fs
}()

/// Returns (date, isAllDay)
func parseDate(_ raw: String) -> (Date?, Bool) {
    for f in timeFormatters { if let d = f.date(from: raw) { return (d, false) } }
    if let d = isoFractionFormatter.date(from: raw) { return (d, false) }
    if let d = isoFormatter.date(from: raw) { return (d, false) }
    if let d = dayFormatter.date(from: raw) { return (d, true) }
    return (nil, false)
}

func fmtDate(_ date: Date, allDay: Bool) -> String {
    if allDay { return dayFormatter.string(from: date) }
    return isoFormatter.string(from: date)
}

// ── Calendar helpers ──────────────────────────────────────────────────────────
/// The ONLY calendar this binary may write to. Resolved from (in order):
/// ALFRED_CALENDAR env (set by the extension), ~/.pi/agent/icloud.json, or default "ALFRED".
func allowedCalendarName() -> String {
    if let env = ProcessInfo.processInfo.environment["ALFRED_CALENDAR"], !env.isEmpty {
        return env
    }
    let configPath = NSString(string: "~/.pi/agent/icloud.json").expandingTildeInPath
    if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let name = obj["calendarName"] as? String, !name.isEmpty {
        return name
    }
    return "ALFRED"
}

func guardWritableCalendar(_ requested: String) -> String {
    let allowed = allowedCalendarName()
    guard requested.caseInsensitiveCompare(allowed) == .orderedSame else {
        fail("refusing: this helper may only write to calendar '\(allowed)' (passed '\(requested)'). Real calendars are off-limits to ALFRED.")
    }
    return allowed
}

func findCalendar(_ title: String) -> EKCalendar? {
    store.calendars(for: .event).first {
        $0.title.caseInsensitiveCompare(title) == .orderedSame
    }
}

func calendarSource() -> EKSource? {
    // Prefer an account source (iCloud/CalDAV); fall back to the default for new events.
    let sources = store.sources
    if let def = store.defaultCalendarForNewEvents?.source { return def }
    for s in sources where s.sourceType == .calDAV && s.title.lowercased().contains("icloud") { return s }
    return sources.first { $0.sourceType == .calDAV } ?? sources.first
}

func ensureCalendar(_ title: String) -> (calendar: EKCalendar, created: Bool) {
    if let existing = findCalendar(title) {
        return (existing, false)
    }
    let calendar = EKCalendar(for: .event, eventStore: store)
    calendar.title = title
    calendar.cgColor = CGColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1.0)
    if let source = calendarSource() {
        calendar.source = source
    }
    do {
        try store.saveCalendar(calendar, commit: true)
        return (calendar, true)
    } catch {
        fail("Could not create calendar '\(title)': \(error.localizedDescription)")
    }
}

/// All events a calendar contributes across store.calendars(for: .event).
func calendarSet() -> [EKCalendar] {
    store.calendars(for: .event)
}

// ── Subcommands ───────────────────────────────────────────────────────────────
func cmdListCalendars() -> Never {
    requireAccess()
    let items: [[String: Any]] = store.calendars(for: .event).map { cal in
        [
            "title": cal.title,
            "source": cal.source?.title ?? "local",
            "editable": cal.allowsContentModifications,
        ]
    }.sorted { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }
    emit(["calendars": items, "count": items.count])
}

func cmdEvents(_ args: Args) throws -> Never {
    requireAccess()
    let fromRaw = args.opt("from") ?? dayFormatter.string(from: Date())
    let toRaw = args.opt("to") ?? dayFormatter.string(from: Date().addingTimeInterval(7 * 86400))
    let (fromRawDate, fromAllDay) = parseDate(fromRaw)
    let (toRawDate, toAllDay) = parseDate(toRaw)
    guard let from = fromRawDate, let to = toRawDate else {
        throw CLIError(message: "could not parse --from/--to (use yyyy-MM-dd or ISO datetimes)")
    }
    let start = Calendar.current.startOfDay(for: from)
    let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
    let maxCount = try args.int("max", default: 50)

    let calendars: [EKCalendar]
    if let wanted = args.opt("calendar") {
        guard let cal = findCalendar(wanted) else {
            throw CLIError(message: "calendar '\(wanted)' not found (use list_calendars to see titles)")
        }
        calendars = [cal]
    } else {
        calendars = calendarSet()
    }

    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    let events = store.events(matching: predicate)
        .sorted { $0.startDate < $1.startDate }
        .prefix(maxCount)

    let items: [[String: Any]] = events.map { ev in
        var dict: [String: Any] = [
            "id": ev.eventIdentifier ?? "",
            "calendar": ev.calendar?.title ?? "?",
            "title": ev.title ?? "",
            "start": fmtDate(ev.startDate, allDay: ev.isAllDay),
            "end": fmtDate(ev.endDate, allDay: ev.isAllDay),
            "allDay": ev.isAllDay,
        ]
        if let loc = ev.location, !loc.isEmpty { dict["location"] = loc }
        if let notes = ev.notes, !notes.isEmpty { dict["notes"] = notes }
        if let url = ev.url { dict["url"] = url.absoluteString }
        if let occ = ev.occurrenceDate { dict["occurrence"] = isoFormatter.string(from: occ) }
        return dict
    }
    emit(["events": items, "count": items.count, "from": fmtDate(start, allDay: fromAllDay), "to": fmtDate(end, allDay: toAllDay)])
}

func cmdEnsureCalendar(_ args: Args) throws -> Never {
    let allowed = guardWritableCalendar(try args.str("name"))
    requireAccess()
    let (_, created) = ensureCalendar(allowed)
    emit(["calendar": allowed, "created": created])
}

func cmdCreateEvent(_ args: Args) throws -> Never {
    let allowed = guardWritableCalendar(try args.str("calendar"))
    requireAccess()
    let title = try args.str("title")
    let startRaw = try args.str("start")
    let endRaw = try args.str("end")
    let (startDate, isAllDay) = parseDate(startRaw)
    let (endDate, _) = parseDate(endRaw)
    guard let start = startDate, let end = endDate else {
        throw CLIError(message: "could not parse --start/--end (use yyyy-MM-dd for all-day, or ISO datetimes)")
    }
    let calendar = ensureCalendar(allowed).calendar  // sandbox: only the allowed calendar exists as a write target
    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = title
    event.startDate = start
    event.endDate = end
    event.isAllDay = isAllDay
    if let loc = args.opt("location") { event.location = loc }
    if let notes = args.opt("notes") { event.notes = notes }
    let minutes = try args.int("alarm-minutes", default: 10)
    if minutes > 0 {
        event.addAlarm(EKAlarm(relativeOffset: -Double(minutes) * 60))
    }
    do {
        try store.save(event, span: .thisEvent, commit: true)
    } catch {
        throw CLIError(message: "failed to create event: \(error.localizedDescription)")
    }
    emit([
        "id": event.eventIdentifier ?? "",
        "calendar": calendar.title,
        "title": title,
        "start": fmtDate(start, allDay: isAllDay),
        "end": fmtDate(end, allDay: isAllDay),
        "allDay": isAllDay,
        "alarmMinutes": minutes,
    ])
}

func cmdCancelEvent(_ args: Args) throws -> Never {
    let allowed = guardWritableCalendar(try args.str("calendar"))
    requireAccess()
    let eventId = try args.str("id")
    guard let event = store.event(withIdentifier: eventId) else {
        throw CLIError(message: "no event found with id \(eventId)")
    }
    let calName = event.calendar?.title ?? "?"
    guard calName.caseInsensitiveCompare(allowed) == .orderedSame else {
        throw CLIError(message: "refusing to cancel: event lives in calendar '\(calName)', but mutations are sandboxed to '\(allowed)'. Use Calendar app for other calendars.")
    }
    do {
        try store.remove(event, span: .thisEvent, commit: true)
    } catch {
        throw CLIError(message: "failed to cancel event: \(error.localizedDescription)")
    }
    emit(["cancelled": true, "id": eventId, "calendar": allowed, "title": event.title ?? ""])
}

func cmdAuthStatus() -> Never {
    let status: String
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined: status = "notDetermined"
    case .fullAccess: status = "fullAccess"
    case .writeOnly: status = "writeOnly"
    case .denied: status = "denied"
    case .restricted: status = "restricted"
    @unknown default: status = "unknown"
    }
    emit(["status": status, "granted": status == "fullAccess", "allowedCalendar": allowedCalendarName()])
}

// ── Main ──────────────────────────────────────────────────────────────────────
let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else {
    fail("usage: alfred-events <list-calendars|events|ensure-calendar|create-event|cancel-event> [--flag value ...]")
}
let args = Args(raw.dropFirst())

do {
    switch command {
    case "list-calendars": cmdListCalendars()
    case "auth-status": cmdAuthStatus()
    case "events": try cmdEvents(args)
    case "ensure-calendar": try cmdEnsureCalendar(args)
    case "create-event": try cmdCreateEvent(args)
    case "cancel-event": try cmdCancelEvent(args)
    default: fail("unknown command: \(command)")
    }
} catch let e as CLIError {
    fail(e.message)
} catch {
    fail("error: \(error.localizedDescription)")
}