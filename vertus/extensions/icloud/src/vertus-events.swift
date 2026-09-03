// VERTUS EventKit helper — calendar read/write bridge for the VERTUS CLI.
//
// Runs as a small CLI: reads JSON-friendly args from argv, prints JSON to stdout.
// Mutations (create/cancel) are HARD-SANDBOXED to a single calendar (default "VERTUS"),
// enforced here in native code so no tool call can ever touch a real calendar.
//
// Build: swiftc -O -o vertus-events vertus-events.swift

import CoreLocation
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

func authorize(writeOnly: Bool = false) -> Bool {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
        return true
    case .writeOnly:
        if !writeOnly { return false } // reads need full access
        // "Add Only" is enough for writes, but it hides real calendars and
        // cannot create the dedicated VERTUS calendar. Opportunistically ask
        // for the Full Access upgrade (single prompt); if the user declines,
        // keep working with what we have.
        if #available(macOS 14.0, *) {
            let sem = DispatchSemaphore(value: 0)
            store.requestFullAccessToEvents { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 60)
        }
        return true
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        if #available(macOS 14.0, *) {
            if writeOnly {
                store.requestWriteOnlyAccessToEvents { g, _ in granted = g; sem.signal() }
            } else {
                store.requestFullAccessToEvents { g, _ in granted = g; sem.signal() }
            }
        } else {
            store.requestAccess(to: .event) { g, _ in granted = g; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 60)
        return granted
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}

func requireAccess() {
    guard authorize() else {
        let writeOnlyHint = EKEventStore.authorizationStatus(for: .event) == .writeOnly
            ? "\n\nCalendar access for this app is currently set to \"Add Only\" — reading needs \"Full Access\".\nFix: System Settings → Privacy & Security → Calendar → set this app to Full Access."
            : ""
        fail("Calendar access denied or not yet granted.\n\nOn first use macOS shows a prompt — click Allow (System Settings → Privacy & Security → Calendar).\nIf there is no prompt, launch:\n  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars'\nand enable access for the app that runs the terminal (Terminal/iTerm).\(writeOnlyHint)")
    }
}

/// Mutations only need write access — full access is only for reading.
func requireWriteAccess() {
    guard authorize(writeOnly: true) else {
        fail("Calendar write access denied or not yet granted.\n\nOn first use macOS shows a prompt — click Allow (System Settings → Privacy & Security → Calendar).\nIf there is no prompt, launch:\n  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars'\nand enable access for the app that runs the terminal (Terminal/iTerm).")
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
/// VERTUS_CALENDAR env (set by the extension), ~/.pi/agent/icloud.json, or default "VERTUS".
func allowedCalendarName() -> String {
    if let env = ProcessInfo.processInfo.environment["VERTUS_CALENDAR"], !env.isEmpty {
        return env
    }
    let configPath = NSString(string: "~/.pi/agent/icloud.json").expandingTildeInPath
    if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let name = obj["calendarName"] as? String, !name.isEmpty {
        return name
    }
    return "VERTUS"
}

func guardWritableCalendar(_ requested: String) -> String {
    let allowed = allowedCalendarName()
    guard requested.caseInsensitiveCompare(allowed) == .orderedSame else {
        fail("refusing: this helper may only write to calendar '\(allowed)' (passed '\(requested)'). Real calendars are off-limits to VERTUS.")
    }
    return allowed
}

func findCalendar(_ title: String) -> EKCalendar? {
    store.calendars(for: .event).first {
        $0.title.caseInsensitiveCompare(title) == .orderedSame
    }
}

func calendarSourceCandidates() -> [EKSource] {
    let sources = store.sources
    var candidates: [EKSource] = []
    // iCloud first (accepts new calendars, syncs to the user's devices),
    // then any other CalDAV account, then Subscribed/Local as last resorts.
    // The default-calendar source is intentionally LAST: it is often the
    // school Exchange account, which refuses calendar creation.
    candidates.append(contentsOf: sources.filter { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
    candidates.append(contentsOf: sources.filter { $0.sourceType == .calDAV && !$0.title.lowercased().contains("icloud") })
    candidates.append(contentsOf: sources.filter { $0.sourceType == .subscribed })
    candidates.append(contentsOf: sources.filter { $0.sourceType == .local })
    if let def = store.defaultCalendarForNewEvents?.source, !candidates.contains(def) {
        candidates.append(def)
    }
    return candidates
}

func ensureCalendar(_ title: String) -> (calendar: EKCalendar, created: Bool) {
    if let existing = findCalendar(title) {
        return (existing, false)
    }
    let calendar = EKCalendar(for: .event, eventStore: store)
    calendar.title = title
    calendar.cgColor = CGColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1.0)
    // Try each candidate source; some accounts (e.g. school Exchange) refuse
    // calendar creation, so the first that accepts wins.
    var lastError: Error?
    for source in calendarSourceCandidates() {
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
            return (calendar, true)
        } catch {
            lastError = error
        }
    }
    fail("Could not create calendar '\(title)': \(lastError?.localizedDescription ?? "no writable account source found")\n\nIf Calendar access is set to \"Add Only\", the system hides real accounts and refuses calendar creation.\nFix: System Settings → Privacy & Security → Calendar → set this app to Full Access.")
}

/// All events a calendar contributes across store.calendars(for: .event).
func calendarSet() -> [EKCalendar] {
    store.calendars(for: .event)
}

// ── Location resolution (Apple Calendar's "selected place") ──────────────────
/// Plain `event.location` stores display text only; Calendar shows a real place
/// card (with map + "Alert when I need to leave") only when the event carries an
/// `EKStructuredLocation` with a geocoded coordinate. This geocodes the address
/// the same way Calendar's location bar does when you pick a suggestion.
/// Format: "Place Title | street address, city, state zip" — or just an address.
func resolveStructuredLocation(_ raw: String) -> (title: String, address: String, latitude: Double, longitude: Double)? {
    let parts = raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    let placeTitle = parts.count > 1 ? parts[0] : ""
    let address = (parts.count > 1 ? parts[1] : parts[0])
    guard !address.isEmpty else { return nil }

    // CLGeocoder is callback-based; bridge to sync with a semaphore (one-shot CLI).
    let sem = DispatchSemaphore(value: 0)
    var resolved: (title: String, address: String, latitude: Double, longitude: Double)?
    let geocoder = CLGeocoder()
    geocoder.geocodeAddressString(address) { placemarks, _ in
        if let p = placemarks?.first, let loc = p.location {
            // Calendar renders the selected place as title (bold) + address (subtitle).
            let title = placeTitle.isEmpty ? (p.name ?? address) : placeTitle
            let subtitle = [p.thoroughfare, p.subThoroughfare, p.locality, p.administrativeArea, p.postalCode]
                .compactMap { $0 }.joined(separator: " ")
            resolved = (title: title, address: subtitle.isEmpty ? address : subtitle,
                        latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 8.0)
    geocoder.cancelGeocode()
    return resolved
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
        if let sl = ev.structuredLocation {
            var slDict: [String: Any] = ["title": sl.title ?? ""]
            if let geo = sl.geoLocation {
                slDict["latitude"] = geo.coordinate.latitude
                slDict["longitude"] = geo.coordinate.longitude
            }
            dict["structuredLocation"] = slDict
        }
        if let notes = ev.notes, !notes.isEmpty { dict["notes"] = notes }
        if let url = ev.url { dict["url"] = url.absoluteString }
        if let occ = ev.occurrenceDate { dict["occurrence"] = isoFormatter.string(from: occ) }
        return dict
    }
    emit(["events": items, "count": items.count, "from": fmtDate(start, allDay: fromAllDay), "to": fmtDate(end, allDay: toAllDay)])
}

func cmdEnsureCalendar(_ args: Args) throws -> Never {
    let allowed = guardWritableCalendar(try args.str("name"))
    requireWriteAccess()
    let (_, created) = ensureCalendar(allowed)
    emit(["calendar": allowed, "created": created])
}

func cmdCreateEvent(_ args: Args) throws -> Never {
    let allowed = guardWritableCalendar(try args.str("calendar"))
    requireWriteAccess()
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
    // Apple Calendar "selected place": geocode the address and attach it as a
    // structured location with a coordinate, so Calendar shows the place card
    // with map, weather, and "Alert when I need to leave" — exactly as if the
    // address had been typed and a suggestion picked in the location bar.
    var resolvedTitle: String?
    if let raw = args.opt("structured-location") {
        if let sl = resolveStructuredLocation(raw) {
            let structured = EKStructuredLocation(title: sl.title)
            structured.geoLocation = CLLocation(latitude: sl.latitude, longitude: sl.longitude)
            event.structuredLocation = structured
            resolvedTitle = sl.title
            if args.opt("location") == nil { event.location = sl.address }
        } else {
            // Never fail the whole event for a geocode miss — fall back to text.
            if args.opt("location") == nil { event.location = raw.components(separatedBy: "|").last?.trimmingCharacters(in: .whitespaces) ?? raw }
        }
    }
    if let notes = args.opt("notes") { event.notes = notes }
    let minutes = try args.int("alarm-minutes", default: 10)
    if minutes > 0 {
        event.addAlarm(EKAlarm(relativeOffset: -Double(minutes) * 60))
    }
    // Recurrence: --frequency daily|weekly|monthly|yearly [--interval N] [--until yyyy-MM-dd]
    var recurrenceDesc: String?
    if let freqRaw = args.opt("frequency") {
        let freq: EKRecurrenceFrequency
        switch freqRaw.lowercased() {
        case "daily": freq = .daily
        case "weekly": freq = .weekly
        case "monthly": freq = .monthly
        case "yearly": freq = .yearly
        default: throw CLIError(message: "unknown --frequency '\(freqRaw)' (daily|weekly|monthly|yearly)")
        }
        let interval = try args.int("interval", default: 1)
        guard interval >= 1 else { throw CLIError(message: "--interval must be >= 1") }
        var end: EKRecurrenceEnd?
        var untilRaw: String?
        if let u = args.opt("until") {
            guard let until = dayFormatter.date(from: u) else {
                throw CLIError(message: "could not parse --until (use yyyy-MM-dd)")
            }
            end = EKRecurrenceEnd(end: until)
            untilRaw = u
        }
        let rule = EKRecurrenceRule(recurrenceWith: freq, interval: interval, end: end)
        event.recurrenceRules = [rule]
        recurrenceDesc = "\(freqRaw.lowercased())" + (interval > 1 ? " x\(interval)" : "") + (untilRaw != nil ? " until \(untilRaw!)" : "")
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
        "location": event.location ?? "",
        "recurrence": recurrenceDesc ?? "",
        "structuredLocation": resolvedTitle ?? "",
    ])
}

func cmdCancelEvent(_ args: Args) throws -> Never {
    let allowed = guardWritableCalendar(try args.str("calendar"))
    requireWriteAccess()
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
    emit(["status": status, "granted": status == "fullAccess", "allowedCalendar": allowedCalendarName(),
          "hint": status == "writeOnly"
              ? "Calendar access is 'Add Only': events can be created but not read, and the dedicated VERTUS calendar cannot be managed. Set Full Access in System Settings → Privacy & Security → Calendar."
              : ""])
}

// ── Main ──────────────────────────────────────────────────────────────────────
let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else {
    fail("usage: vertus-events <list-calendars|events|ensure-calendar|create-event|cancel-event> [--flag value ...]")
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