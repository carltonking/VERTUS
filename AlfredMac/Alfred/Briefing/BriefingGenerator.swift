import EventKit
import Foundation

// MARK: - Models
//
// The briefing contract both sides share. The Mac generates it; the iOS app
// receives it over the WebSocket as a `briefing.update` notification or the
// result of `briefing.get` / `briefing.get_now`. Field names are the wire
// format — the iOS `BriefingUpdate` mirrors them exactly.

/// One incremental change since the last briefing. `type` drives the iOS
/// iconography ("calendar_added", "calendar_cancelled", "email_received",
/// "reminder_set", "weather_updated"); `title` is the row the phone shows.
struct BriefingChange: Codable, Equatable {
    var type: String
    var title: String
    var details: String
    var timestamp: TimeInterval
}

/// A complete briefing: the conversational summary plus everything that
/// changed since the last one. `nextUpdateAt` is when the phone can expect
/// the following push; `focusedDay` is what the summary is about.
struct BriefingContent: Codable, Equatable {
    var summary: String
    var changes: [BriefingChange]
    var generatedAt: TimeInterval
    var nextUpdateAt: TimeInterval
    var focusedDay: String
}

/// A fingerprint of the gathered context, persisted so the next run can diff
/// against it. IDs drive the diff; the id→title maps exist so a change row on
/// the phone can name the event ("New calendar event: Standup") instead of
/// showing a raw identifier.
struct BriefingSnapshot: Codable, Equatable {
    var eventIDs: Set<String>
    /// eventIdentifier → title, for naming added events.
    var eventTitles: [String: String]
    var unreadMail: Int
    var importantSenders: [String]
    var reminderIDs: Set<String>
    /// calendarItemIdentifier → title, for naming new reminders.
    var reminderTitles: [String: String]
}

// MARK: - Generator

/// Generates Alfred's daily briefing on a schedule and hands each fresh copy
/// to `onGenerated` (the socket server subscribes to push it to phones).
///
/// Design:
///   * **Deterministic changes, conversational summary.** `detectChanges` is
///     pure Swift over snapshots — a cancelled meeting or a spike in unread
///     mail becomes a `BriefingChange` without trusting a model. Hermes only
///     writes the prose (the part a model is actually good at), so a flaky
///     model degrades to a template briefing instead of a broken one.
///   * **Never hijacks the user's session.** The Hermes turn is guarded on
///     `isTurnActive` and runs with `capture: false`, exactly like the mail
///     triager and the reflection pass.
///   * **Persistent baseline.** The last snapshot lives next to the briefing
///     in `~/.alfred/briefing.json`, so changes are detected across restarts.
final class BriefingGenerator {

    static let shared = BriefingGenerator()

    /// Fired with every freshly generated briefing (schedule or forced). The
    /// socket server sets this to broadcast `briefing.update` to phones.
    var onGenerated: ((BriefingContent) -> Void)?

    /// The agent session that writes the conversational summary. Handed over
    /// at launch by the app delegate, like MailWatcher's.
    weak var hermes: HermesSession?

    /// Optional weather source. Nothing in Alfred reads weather yet, so this
    /// stays nil and the weather section is skipped — the seam exists so a
    /// future provider plugs in without touching the generator.
    var weatherProvider: (() async -> String?)?

    private var timer: Timer?
    /// Hours (0-23) at which a briefing is generated, on the hour. Defaults to
    /// 5am–midnight. `setCustomSchedule` replaces this.
    private var schedule: Set<Int> = Set(5...23)
    private var lastGeneratedHour = -1
    private var isGenerating = false

    private(set) var current: BriefingContent?
    private var lastSnapshot: BriefingSnapshot?
    private let fileURL: URL
    private let scheduleKey = "alfred.briefing_schedule"

    private init() {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred") as NSString
        try? FileManager.default.createDirectory(atPath: dir as String, withIntermediateDirectories: true)
        fileURL = URL(fileURLWithPath: dir.appendingPathComponent("briefing.json"))
        if let stored = UserDefaults.standard.array(forKey: scheduleKey) as? [Int], !stored.isEmpty {
            schedule = Set(stored)
        }
        load()
    }

    // MARK: - Lifecycle

    /// Start the hourly schedule. Idempotent. The timer ticks every minute and
    /// fires only at the top of a scheduled hour, so sleep/wake and clock
    /// changes can't skip a briefing — the next minute tick catches it.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSLog("[briefing] scheduled — generates on the hour at \(schedule.sorted().map(String.init).joined(separator: ", "))")
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Replace the default hourly schedule, e.g. `[5, 12, 18]`. Persisted.
    func setCustomSchedule(times: [Int]) {
        let cleaned = Set(times.filter { (0...23).contains($0) })
        guard !cleaned.isEmpty else { return }
        schedule = cleaned
        UserDefaults.standard.set(Array(cleaned).sorted(), forKey: scheduleKey)
        NSLog("[briefing] custom schedule → \(cleaned.sorted().map(String.init).joined(separator: ", "))")
    }

    func getCurrentBriefing() -> BriefingContent? {
        current
    }

    // MARK: - Timer tick

    private func tick() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard schedule.contains(hour), hour != lastGeneratedHour, !isGenerating else { return }
        Task { _ = await generate() }
    }

    // MARK: - Generation

    /// Produce a briefing for `focusedDay` ("today", "tomorrow", "day after
    /// tomorrow"). Never throws — the caller always gets a briefing back, even
    /// when Hermes is busy, unconfigured, or wrong.
    func generate(focusedDay: String = "today") async -> BriefingContent {
        isGenerating = true
        defer { isGenerating = false }

        // Evening briefings look ahead: past 5pm, "today" becomes "tomorrow".
        // The rollover is decided once, here, so the calendar window, the
        // summary and the content's focusedDay all agree on the same day.
        let hour = Calendar.current.component(.hour, from: Date())
        let effectiveDay = focusedDay == "today" && hour >= 17 ? "tomorrow" : focusedDay

        let context = await gatherContext(focusedDay: effectiveDay)
        let changes = detectChanges(previous: lastSnapshot, current: context.snapshot)
        let summary = await writeSummary(for: context, focusedDay: effectiveDay, changes: changes)

        let now = Date().timeIntervalSince1970
        let content = BriefingContent(
            summary: summary,
            changes: changes,
            generatedAt: now,
            nextUpdateAt: nextUpdateTimeInterval(),
            focusedDay: effectiveDay)

        current = content
        lastSnapshot = context.snapshot
        persist()
        NSLog("[briefing] generated for \(focusedDay) — \(changes.count) change(s), summary \(summary.count) chars")
        onGenerated?(content)
        return content
    }

    // MARK: - Context gathering

    /// Everything the briefing can know, gathered defensively: each section is
    /// independent, and a failure in one (mail down, no calendar permission)
    /// drops that section instead of the whole briefing.
    private struct Context {
        var events: [(id: String, title: String, start: Date, end: Date, location: String?)]
        var reminders: [(id: String, title: String, due: Date?)]
        var unreadMail: Int
        var importantSenders: [String]
        var people: [(name: String, role: String?)]
        var habitLine: String?
        var weather: String?
        var snapshot: BriefingSnapshot
    }

    private func gatherContext(focusedDay: String) async -> Context {
        let cal = Calendar.current
        let now = Date()
        let (windowStart, windowEnd) = window(for: focusedDay, now: now, calendar: cal)

        // Calendar events in the window + reminders due up to a week out.
        var events: [(id: String, title: String, start: Date, end: Date, location: String?)] = []
        var reminders: [(id: String, title: String, due: Date?)] = []
        if let store = try? await authorizedEventStore() {
            let fetched = store.events(matching: store.predicateForEvents(
                withStart: windowStart, end: windowEnd, calendars: nil))
            events = fetched
                .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                .prefix(12)
                .map {
                    (CalendarCapability.identifier($0),
                     CalendarCapability.title($0),
                     $0.startDate ?? now,
                     $0.endDate ?? now,
                     $0.location)
                }
            let weekEnd = cal.date(byAdding: .day, value: 7, to: now) ?? now
            if let all = try? await fetchReminders(in: store, upTo: weekEnd) {
                reminders = all.prefix(12).map {
                    ($0.calendarItemIdentifier,
                     CalendarCapability.title($0),
                     $0.dueDateComponents?.date)
                }
            }
        }

        // Mail: unread count, and unread senders who are known people.
        var unreadMail = 0
        var unreadSenders: [String] = []
        if let envelopes = try? EmailCapability.shared.latestEnvelopes(
            account: "icloud", mailbox: "Inbox", limit: 50) {
            unreadMail = envelopes.filter(\.isUnread).count
            unreadSenders = envelopes
                .filter(\.isUnread)
                .compactMap { $0.fromName?.isEmpty == false ? $0.fromName : $0.fromEmail }
        }
        let knownNames = UnifiedMemoryLayer.shared.getPeopleIKnow(limit: 10).map(\.name)
        let importantSenders = unreadSenders.filter { sender in
            knownNames.contains { $0.range(of: sender, options: .caseInsensitive) != nil
                || sender.range(of: $0, options: .caseInsensitive) != nil }
        }

        // People worth naming in the summary. The unified graph's person
        // entities carry their best-known detail (role-ish context) in
        // `detail`.
        let people = UnifiedMemoryLayer.shared.getPeopleIKnow(limit: 5).map {
            (name: $0.name, role: $0.detail)
        }

        // Habit: what usually happens around this hour.
        var habitLine: String?
        if let prediction = HabitPredictionService.shared.predictNextApp() {
            let name = BehaviorProfile.friendlyName(for: prediction.bundleID)
            habitLine = "Usually around this time you're in \(name)."
        }

        // Weather, when a provider exists.
        var weather: String?
        if let weatherProvider {
            weather = await weatherProvider()
        }

        return Context(
            events: events,
            reminders: reminders,
            unreadMail: unreadMail,
            importantSenders: importantSenders,
            people: people,
            habitLine: habitLine,
            weather: weather,
            snapshot: BriefingSnapshot(
                eventIDs: Set(events.map(\.id)),
                eventTitles: Dictionary(events.map { ($0.id, $0.title) },
                                        uniquingKeysWith: { first, _ in first }),
                unreadMail: unreadMail,
                importantSenders: importantSenders,
                reminderIDs: Set(reminders.map(\.id)),
                reminderTitles: Dictionary(reminders.map { ($0.id, $0.title) },
                                           uniquingKeysWith: { first, _ in first })))
    }

    /// The calendar window the briefing covers, from the focused day's label.
    private func window(for focusedDay: String, now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        let dayOffset: Int
        switch focusedDay.lowercased() {
        case "tomorrow": dayOffset = 1
        case "day after tomorrow": dayOffset = 2
        default: dayOffset = 0
        }
        var start = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) ?? startOfToday
        if dayOffset == 0 { start = now }   // today: from now, not midnight
        let end = calendar.date(byAdding: .day, value: dayOffset + 1, to: startOfToday) ?? startOfToday
        return (start, end)
    }

    // MARK: - Change detection

    /// Diff the last snapshot against the current one. Pure and deterministic
    /// — the same two snapshots always produce the same changes.
    ///
    /// Validation: three events (9–10, 13–14, 15–16) on day one; one cancelled
    /// and one added by day two → exactly one `calendar_cancelled` and one
    /// `calendar_added`, nothing else.
    func detectChanges(previous: BriefingSnapshot?, current: BriefingSnapshot) -> [BriefingChange] {
        guard let previous else { return [] }   // first briefing: everything is the baseline
        let now = Date().timeIntervalSince1970
        var changes: [BriefingChange] = []

        let added = current.eventIDs.subtracting(previous.eventIDs)
        let cancelled = previous.eventIDs.subtracting(current.eventIDs)
        for id in added.sorted() {
            // Name the event in `details` — the phone's detail sheet shows it.
            changes.append(BriefingChange(
                type: "calendar_added", title: "New calendar event",
                details: current.eventTitles[id] ?? id, timestamp: now))
        }
        for id in cancelled.sorted() {
            // The title comes from the *previous* snapshot — the event is gone
            // from the current one, so that's the last place its name exists.
            changes.append(BriefingChange(
                type: "calendar_cancelled", title: "A calendar event was removed",
                details: previous.eventTitles[id] ?? id, timestamp: now))
        }

        let newImportant = current.importantSenders.filter { !previous.importantSenders.contains($0) }
        for sender in newImportant {
            changes.append(BriefingChange(
                type: "email_received", title: "Important email from \(sender)", details: sender,
                timestamp: now))
        }

        let newReminders = current.reminderIDs.subtracting(previous.reminderIDs)
        for id in newReminders.sorted() {
            changes.append(BriefingChange(
                type: "reminder_set", title: "A reminder was added",
                details: current.reminderTitles[id] ?? id, timestamp: now))
        }

        // Mail volume swings are only worth a change when they're large.
        if current.unreadMail >= previous.unreadMail + 5 {
            changes.append(BriefingChange(
                type: "email_received",
                title: "\(current.unreadMail) unread messages",
                details: "Up from \(previous.unreadMail) at the last briefing.",
                timestamp: now))
        }

        return changes.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Summary

    /// The conversational prose. Hermes writes it when it's free and answers;
    /// a deterministic template covers every other case so the phone always
    /// has something to show. `focusedDay` is already the rolled-over day.
    private func writeSummary(for context: Context, focusedDay: String, changes: [BriefingChange]) async -> String {
        if let hermes, await !hermes.isTurnActive {
            if let summary = await askHermes(hermes, context: context, focusedDay: focusedDay, changes: changes),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return summary
            }
        }
        return templateSummary(context: context, focusedDay: focusedDay)
    }

    /// One JSON-contract turn against the shared session. Mirrors the mail
    /// triager: tool-free, `capture: false`, strict JSON, tolerates prose
    /// fences by hunting the first balanced object.
    private func askHermes(_ hermes: HermesSession, context: Context, focusedDay: String, changes: [BriefingChange]) async -> String? {
        let contextBlock = contextBlock(for: context, focusedDay: focusedDay, changes: changes)
        let prompt = """
        You are Alfred's daily briefing generator. Write a natural, conversational \
        greeting and summary of the person's day. Speak in the second person \
        ("You have…", "Don't forget…"). Be concise but warm. Mention the notable \
        calendar events, reminders, unread mail, people, and habits below. Always \
        end with one encouraging send-off sentence.

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"summary": "your full briefing as one string"}

        \(contextBlock)
        """
        var transcript = ""
        for await event in await hermes.prompt(prompt, capture: false) {
            switch event {
            case .text(let chunk):
                transcript += chunk
            case .failed(let message):
                NSLog("[briefing] Hermes turn failed: %@", message)
                return nil
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                break
            }
        }
        let json = Self.extractJSONObject(from: transcript)
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = obj["summary"] as? String,
              !summary.isEmpty else {
            NSLog("[briefing] summary JSON unparsable — falling back to template")
            return nil
        }
        return summary
    }

    /// The prompt's context block: everything the summary can draw from, plus
    /// what changed since the last briefing so the model can acknowledge it.
    private func contextBlock(for context: Context, focusedDay: String, changes: [BriefingChange]) -> String {
        var lines: [String] = ["Focus day: \(focusedDay)."]

        if let weather = context.weather {
            lines.append("Weather: \(weather).")
        }
        if context.events.isEmpty {
            lines.append("Calendar: nothing on the schedule.")
        } else {
            lines.append("Calendar:")
            for event in context.events {
                let when = event.start.formatted(date: .omitted, time: .shortened)
                var line = "  - \(event.title) at \(when)"
                if let location = event.location, !location.isEmpty { line += ", \(location)" }
                lines.append(line)
            }
        }
        if !context.reminders.isEmpty {
            lines.append("Reminders:")
            for reminder in context.reminders {
                let when = reminder.due.map { $0.formatted(date: .omitted, time: .shortened) } ?? "no due date"
                lines.append("  - \(reminder.title) (\(when))")
            }
        }
        if context.unreadMail > 0 {
            lines.append("Mail: \(context.unreadMail) unread.")
        }
        if !context.importantSenders.isEmpty {
            lines.append("Important senders: \(context.importantSenders.joined(separator: ", ")).")
        }
        if !context.people.isEmpty {
            let peopleLine = context.people.map { person in
                person.role.map { "\(person.name) (\($0))" } ?? person.name
            }.joined(separator: ", ")
            lines.append("People you work with: \(peopleLine).")
        }
        if let habitLine = context.habitLine {
            lines.append("Habit: \(habitLine)")
        }
        if !changes.isEmpty {
            lines.append("Changed since the last briefing: \(changes.map(\.title).joined(separator: "; ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// Deterministic fallback: warm, plain, and always correct.
    private func templateSummary(context: Context, focusedDay: String) -> String {
        var sentences: [String] = []

        if context.events.isEmpty {
            sentences.append("Nothing on the calendar for \(focusedDay).")
        } else {
            let head = context.events.prefix(3)
            let first = head.map {
                let when = $0.start.formatted(date: .omitted, time: .shortened)
                return "\($0.title) at \(when)"
            }.joined(separator: ", ")
            sentences.append("For \(focusedDay): \(first).")
            if context.events.count > 3 {
                sentences.append("And \(context.events.count - 3) more event(s).")
            }
        }

        if !context.reminders.isEmpty {
            let due = context.reminders.prefix(2).map(\.title).joined(separator: " and ")
            sentences.append("Don't forget \(due).")
        }

        if context.unreadMail > 0 {
            if context.importantSenders.isEmpty {
                sentences.append("You have \(context.unreadMail) unread messages.")
            } else {
                sentences.append("You have \(context.unreadMail) unread messages, including one from \(context.importantSenders.joined(separator: " and ")).")
            }
        }

        if let habitLine = context.habitLine {
            sentences.append(habitLine)
        }

        sentences.append("Enjoy your day.")
        return sentences.joined(separator: " ")
    }

    // MARK: - Persistence

    private func persist() {
        struct Stored: Codable {
            var content: BriefingContent
            var snapshot: BriefingSnapshot
        }
        guard let content = current, let snapshot = lastSnapshot,
              let data = try? JSONEncoder().encode(Stored(content: content, snapshot: snapshot))
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        struct Stored: Codable {
            var content: BriefingContent
            var snapshot: BriefingSnapshot
        }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        current = stored.content
        lastSnapshot = stored.snapshot
    }

    // MARK: - Schedule helpers

    /// The next scheduled hour boundary as a unix timestamp — what the phone
    /// shows as "next update at".
    private func nextUpdateTimeInterval() -> TimeInterval {
        let cal = Calendar.current
        let now = Date()
        let hours = schedule.sorted()
        let currentHour = cal.component(.hour, from: now)
        guard let nextHour = hours.first(where: { $0 > currentHour })
            ?? hours.first else { return now.timeIntervalSince1970 }
        return cal.date(bySettingHour: nextHour, minute: 0, second: 0, of: now)?
            .timeIntervalSince1970 ?? now.timeIntervalSince1970
    }

    // MARK: - EventKit plumbing

    /// Fresh store with Calendar read access — the same dance
    /// `CalendarProactiveService` performs.
    private func authorizedEventStore() async throws -> EKEventStore {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return store
        case .notDetermined:
            _ = try? await store.requestFullAccessToEvents()
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized:
                return store
            default:
                throw CapabilityError.denied("Calendar access denied.")
            }
        default:
            throw CapabilityError.denied("Calendar access denied.")
        }
    }

    private func fetchReminders(in store: EKEventStore, upTo end: Date) async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let filtered = (reminders ?? [])
                    .filter { !$0.isCompleted }
                    .filter { reminder in
                        guard let due = reminder.dueDateComponents?.date else { return false }
                        return due <= end
                    }
                continuation.resume(returning: filtered)
            }
        }
    }

    // MARK: - JSON extraction

    /// Pull the first balanced {...} object out of a model reply, tolerating
    /// prose and markdown fences (same helper the reflection pass uses).
    private static func extractJSONObject(from raw: String) -> String {
        let chars = Array(raw)
        var depth = 0
        var inString = false
        var escaped = false
        var start = -1
        for (i, ch) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{":
                if start < 0 { start = i }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, start >= 0 {
                    return String(chars[start...i])
                }
            default:
                break
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
