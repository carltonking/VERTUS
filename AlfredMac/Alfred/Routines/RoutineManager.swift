import Foundation

// MARK: - Routines
//
// Scheduled workflows the user can trigger from the phone (or from the bar).
// A routine is a named list of steps with a schedule; the manager persists
// them, fires them on schedule, executes the steps one by one, and broadcasts
// `routine.started` / `routine.progress` / `routine.completed` to phones over
// the socket.
//
// The wire shapes here are the shared contract with the iOS app — the phone's
// `RoutineStepPayload` / `RoutineSchedulePayload` / `RoutineSummary` mirror
// them exactly (see Alfred/Alfred/Models/Routine.swift).

/// One step in a routine. The wire shape is a flat object keyed by `kind`:
///
///   {"kind":"briefing","type":"daily_summary"}
///   {"kind":"hermes","prompt":"..."}
///   {"kind":"shell","command":"..."}
///   {"kind":"mail","action":"check_unread"}
///   {"kind":"reminder","title":"...","dueIn":3600}
///   {"kind":"browser","instruction":"...","url":"https://..."}   (url optional)
///   {"kind":"scrape","instruction":"...","url":"https://..."}    (url optional)
enum RoutineStep: Codable, Equatable {
    case briefing(type: String)
    case hermes(prompt: String)
    case shell(command: String)
    case mail(action: String)
    case reminder(title: String, dueIn: TimeInterval)
    /// Read-only web automation: open `url` (or search for `instruction` when
    /// no url is given) and report what the page says. Read-only by design —
    /// a routine never submits forms; that is the email skill's gated job.
    case browser(instruction: String, url: String?)
    /// Lightweight web fetch via the Crawlee bridge: open `url` (or search
    /// the web for `instruction` when no url is given) and report the text.
    /// Read-only GETs — no Chrome needed, results cached per settings.
    case scrape(instruction: String, url: String?)
    /// Career-ops work: "scan" searches the job boards against the owner's
    /// profile and reports the top scored listings; "follow_ups" lists
    /// applications whose follow-up window has passed.
    case career(action: String)
    /// Understand-Anything (the interactive knowledge graph): "analyze" runs
    /// the pipeline on the last-used code project, "docs" adds an architecture
    /// report from the graph's layers, "onboarding" walks the guided tour.
    case understand(action: String)
    /// NYU coursework: "check_deadlines" lists assignments due in the next
    /// week (plus overdue); "sync" forces a Canvas refresh first.
    case nyu(action: String)
    /// Study routines: "exam_prep" drills weak concepts for active exams,
    /// "problem_sets" reports in-progress sets, "reading_quiz" surfaces due
    /// readings, "lecture_review" lists today's notes, "weekly_review" writes
    /// the Sunday progress report. See StudyRoutineManager.
    case study(action: String)

    private enum Kind: String, Codable {
        case briefing, hermes, shell, mail, reminder, browser, scrape, career, understand, nyu, study
    }
    private enum Key: String, CodingKey {
        case kind, type, prompt, command, action, title, dueIn, instruction, url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .briefing: self = .briefing(type: try c.decode(String.self, forKey: .type))
        case .hermes: self = .hermes(prompt: try c.decode(String.self, forKey: .prompt))
        case .shell: self = .shell(command: try c.decode(String.self, forKey: .command))
        case .mail: self = .mail(action: try c.decode(String.self, forKey: .action))
        case .reminder:
            self = .reminder(
                title: try c.decode(String.self, forKey: .title),
                dueIn: try c.decode(TimeInterval.self, forKey: .dueIn))
        case .browser:
            self = .browser(
                instruction: try c.decode(String.self, forKey: .instruction),
                url: try c.decodeIfPresent(String.self, forKey: .url))
        case .scrape:
            self = .scrape(
                instruction: try c.decode(String.self, forKey: .instruction),
                url: try c.decodeIfPresent(String.self, forKey: .url))
        case .career:
            self = .career(action: try c.decode(String.self, forKey: .action))
        case .understand:
            self = .understand(action: try c.decode(String.self, forKey: .action))
        case .nyu:
            self = .nyu(action: try c.decode(String.self, forKey: .action))
        case .study:
            self = .study(action: try c.decode(String.self, forKey: .action))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .briefing(let type):
            try c.encode(Kind.briefing, forKey: .kind)
            try c.encode(type, forKey: .type)
        case .hermes(let prompt):
            try c.encode(Kind.hermes, forKey: .kind)
            try c.encode(prompt, forKey: .prompt)
        case .shell(let command):
            try c.encode(Kind.shell, forKey: .kind)
            try c.encode(command, forKey: .command)
        case .mail(let action):
            try c.encode(Kind.mail, forKey: .kind)
            try c.encode(action, forKey: .action)
        case .reminder(let title, let dueIn):
            try c.encode(Kind.reminder, forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(dueIn, forKey: .dueIn)
        case .browser(let instruction, let url):
            try c.encode(Kind.browser, forKey: .kind)
            try c.encode(instruction, forKey: .instruction)
            try c.encodeIfPresent(url, forKey: .url)
        case .scrape(let instruction, let url):
            try c.encode(Kind.scrape, forKey: .kind)
            try c.encode(instruction, forKey: .instruction)
            try c.encodeIfPresent(url, forKey: .url)
        case .career(let action):
            try c.encode(Kind.career, forKey: .kind)
            try c.encode(action, forKey: .action)
        case .understand(let action):
            try c.encode(Kind.understand, forKey: .kind)
            try c.encode(action, forKey: .action)
        case .nyu(let action):
            try c.encode(Kind.nyu, forKey: .kind)
            try c.encode(action, forKey: .action)
        case .study(let action):
            try c.encode(Kind.study, forKey: .kind)
            try c.encode(action, forKey: .action)
        }
    }

    /// A short human label for lists: "Briefing (news)", "Ask Alfred", "Run command"…
    var label: String {
        switch self {
        case .briefing(let type):
            return "Briefing — \(type.replacingOccurrences(of: "_", with: " "))"
        case .hermes: return "Ask Alfred"
        case .shell: return "Run command"
        case .mail(let action):
            return "Mail — \(action.replacingOccurrences(of: "_", with: " "))"
        case .reminder(let title, _):
            return "Reminder — \(title)"
        case .browser(let instruction, _):
            return "Browse — \(instruction.prefix(40))"
        case .scrape(let instruction, _):
            return "Scrape — \(instruction.prefix(40))"
        case .career(let action):
            switch action {
            case "follow_ups": return "Career — follow-ups"
            default: return "Career — scan jobs"
            }
        case .understand(let action):
            switch action {
            case "docs": return "Knowledge graph — visual docs"
            case "onboarding": return "Knowledge graph — onboarding tour"
            default: return "Knowledge graph — analyze project"
            }
        case .nyu(let action):
            switch action {
            case "sync": return "NYU — sync Canvas"
            default: return "NYU — check deadlines"
            }
        case .study(let action):
            switch action {
            case "exam_prep": return "Study — daily exam prep"
            case "problem_sets": return "Study — problem set check"
            case "reading_quiz": return "Study — reading quiz"
            case "lecture_review": return "Study — lecture notes review"
            default: return "Study — weekly review"
            }
        }
    }
}

/// When a routine fires. The wire shape:
///
///   {"type":"onDemand"}
///   {"type":"daily","hour":8,"minute":0}
///   {"type":"weekly","dayOfWeek":1,"hour":18,"minute":0}     (1 = Sunday)
///   {"type":"custom","cronExpression":"0 8 * * 1-5"}
enum RoutineSchedule: Codable, Equatable {
    case onDemand
    case daily(hour: Int, minute: Int)
    case weekly(dayOfWeek: Int, hour: Int, minute: Int)
    case custom(cronExpression: String)

    private enum Kind: String, Codable { case onDemand, daily, weekly, custom }
    private enum Key: String, CodingKey {
        case type, hour, minute, dayOfWeek, cronExpression
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .onDemand: self = .onDemand
        case .daily:
            self = .daily(hour: try c.decode(Int.self, forKey: .hour),
                          minute: try c.decode(Int.self, forKey: .minute))
        case .weekly:
            self = .weekly(dayOfWeek: try c.decode(Int.self, forKey: .dayOfWeek),
                           hour: try c.decode(Int.self, forKey: .hour),
                           minute: try c.decode(Int.self, forKey: .minute))
        case .custom:
            self = .custom(cronExpression: try c.decode(String.self, forKey: .cronExpression))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .onDemand:
            try c.encode(Kind.onDemand, forKey: .type)
        case .daily(let hour, let minute):
            try c.encode(Kind.daily, forKey: .type)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
        case .weekly(let dow, let hour, let minute):
            try c.encode(Kind.weekly, forKey: .type)
            try c.encode(dow, forKey: .dayOfWeek)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
        case .custom(let cron):
            try c.encode(Kind.custom, forKey: .type)
            try c.encode(cron, forKey: .cronExpression)
        }
    }

    var isScheduled: Bool {
        switch self {
        case .onDemand: return false
        case .daily, .weekly, .custom: return true
        }
    }

    /// The most recent occurrence at or before `now`, or nil for on-demand.
    /// This is what the scheduler fires on: a missed occurrence (Mac asleep,
    /// user away) stays "due" until the next tick runs it, and is never fired
    /// twice because the manager records the occurrence it executed.
    func previousOccurrence(onOrBefore now: Date) -> Date? {
        let cal = Calendar.current
        switch self {
        case .onDemand:
            return nil
        case .daily(let hour, let minute):
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard var date = cal.date(from: comps) else { return nil }
            if date > now { date = cal.date(byAdding: .day, value: -1, to: date) ?? date }
            return date
        case .weekly(let dow, let hour, let minute):
            var comps = cal.dateComponents([.year, .month, .day, .weekday], from: now)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard var date = cal.date(from: comps) else { return nil }
            var back = (comps.weekday ?? 1) - dow
            if back < 0 { back += 7 }
            date = cal.date(byAdding: .day, value: -back, to: date) ?? date
            if date > now { date = cal.date(byAdding: .day, value: -7, to: date) ?? date }
            return date
        case .custom(let cron):
            guard let simplified = Self.simplifyCron(cron) else { return nil }
            return simplified.previousOccurrence(onOrBefore: now)
        }
    }

    /// The next occurrence strictly after `now` (for display), or nil for
    /// on-demand / unparseable custom expressions.
    func nextOccurrence(after now: Date) -> Date? {
        let cal = Calendar.current
        switch self {
        case .onDemand:
            return nil
        case .daily(let hour, let minute):
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard var date = cal.date(from: comps) else { return nil }
            if date <= now { date = cal.date(byAdding: .day, value: 1, to: date) ?? date }
            return date
        case .weekly(let dow, let hour, let minute):
            var comps = cal.dateComponents([.year, .month, .day, .weekday], from: now)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let base = cal.date(from: comps) else { return nil }
            let today = comps.weekday ?? 1
            let forward = (dow - today + 7) % 7
            var date = cal.date(byAdding: .day, value: forward, to: base) ?? base
            if date <= now { date = cal.date(byAdding: .day, value: 7, to: date) ?? date }
            return date
        case .custom(let cron):
            guard let simplified = Self.simplifyCron(cron) else { return nil }
            return simplified.nextOccurrence(after: now)
        }
    }

    /// A human schedule line: "Daily at 8:00 AM", "Weekly on Sunday at 6:00 PM",
    /// "Custom: 0 8 * * 1-5", or "On demand".
    var displayText: String {
        let time = { (h: Int, m: Int) -> String in
            let date = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }
        switch self {
        case .onDemand: return "On demand"
        case .daily(let h, let m): return "Daily at \(time(h, m))"
        case .weekly(let dow, let h, let m):
            let name = Calendar.current.weekdaySymbols[(dow - 1 + 7) % 7]
            return "Weekly on \(name) at \(time(h, m))"
        case .custom(let cron): return "Custom: \(cron)"
        }
    }

    /// Reduce the cron forms users actually type to a daily/weekly schedule.
    /// Anything else (seconds, day-of-month, months) is unsupported and the
    /// routine simply never auto-fires — logged at creation, not silently.
    ///
    ///   "0 8 * * *"      → daily 08:00
    ///   "0 18 * * 0"     → weekly Sunday 18:00 (0 and 7 both mean Sunday)
    ///   "*/5 * * * *"    → nil (every-5-minutes isn't a routine)
    private static func simplifyCron(_ cron: String) -> RoutineSchedule? {
        let fields = cron.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }
        guard let minute = Int(fields[0]), let hour = Int(fields[1]) else { return nil }
        guard fields[2] == "*", fields[3] == "*" else { return nil }
        if fields[4] == "*" {
            guard (0...59).contains(minute), (0...23).contains(hour) else { return nil }
            return .daily(hour: hour, minute: minute)
        }
        guard let dow = Int(fields[4]), (0...7).contains(dow) else { return nil }
        guard (0...59).contains(minute), (0...23).contains(hour) else { return nil }
        // Cron's weekday (0 or 7 = Sunday, 1 = Monday…) differs from
        // Foundation's (1 = Sunday, 2 = Monday…). Convert before building;
        // both 0 and 7 mean Sunday (Foundation 1).
        let foundationDow = (dow == 0 || dow == 7) ? 1 : dow + 1
        return .weekly(dayOfWeek: foundationDow, hour: hour, minute: minute)
    }
}

/// The outcome of one step, for the phone's detail view.
struct RoutineStepResult: Codable, Equatable {
    var index: Int
    var label: String
    var success: Bool
    var output: String
}

/// The outcome of running a routine: overall success, the concatenated output,
/// and a per-step breakdown. Persisted on the routine as `lastResult` so the
/// phone can show history without a log of its own.
struct RoutineResult: Codable, Equatable {
    var success: Bool
    var output: String
    var duration: TimeInterval
    var stepsCompleted: Int
    var stepsTotal: Int
    var completedAt: TimeInterval
    var stepResults: [RoutineStepResult]
}

/// A persisted routine.
struct Routine: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var description: String
    var steps: [RoutineStep]
    var schedule: RoutineSchedule
    var enabled: Bool
    var createdAt: TimeInterval
    /// When the routine last *ran* (schedule or manual).
    var lastRun: TimeInterval?
    /// The schedule occurrence (unix seconds, minute-rounded) that was last
    /// executed by the scheduler — the dedup key that stops a missed morning
    /// run from firing every tick until the next one comes around.
    var lastScheduledAt: TimeInterval?
    /// When a *failed* scheduled run may be retried — one hour later, so a
    /// routine that fails at 08:00 isn't hammered every minute until it works.
    /// Nil while nothing is waiting on a retry.
    var nextRetryAt: TimeInterval?
    /// A one-off run requested for a specific moment (scheduleRoutine). Fires
    /// once regardless of schedule, then clears.
    var oneOffAt: TimeInterval?
    var lastResult: RoutineResult?

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        steps: [RoutineStep],
        schedule: RoutineSchedule,
        enabled: Bool = true,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        lastRun: TimeInterval? = nil,
        lastScheduledAt: TimeInterval? = nil,
        nextRetryAt: TimeInterval? = nil,
        oneOffAt: TimeInterval? = nil,
        lastResult: RoutineResult? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.schedule = schedule
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRun = lastRun
        self.lastScheduledAt = lastScheduledAt
        self.nextRetryAt = nextRetryAt
        self.oneOffAt = oneOffAt
        self.lastResult = lastResult
    }

    /// True when the scheduler should run this routine right now: enabled, and
    /// either a one-off moment has arrived, or a scheduled occurrence hasn't
    /// been executed yet (and any failed-run retry window has elapsed).
    /// A one-off fires even when the routine is paused — scheduling one is
    /// explicit intent that overrides the on/off toggle.
    func isDue(at now: Date = Date()) -> Bool {
        // One-off scheduled run: fires at its moment regardless of schedule
        // or the enabled toggle.
        if let oneOff = oneOffAt, now.timeIntervalSince1970 >= oneOff { return true }
        guard enabled else { return false }
        guard schedule.isScheduled else { return false }
        // A failed scheduled run waits out its retry window before firing again.
        if let retry = nextRetryAt, now.timeIntervalSince1970 < retry { return false }
        guard let prev = schedule.previousOccurrence(onOrBefore: now) else { return false }
        guard let last = lastScheduledAt else { return true }
        return prev.timeIntervalSince1970 > last
    }

    /// The moment the scheduler will fire next: a one-off, a pending retry, a
    /// missed occurrence (it runs on the next tick), then the next future one.
    /// Nil for on-demand. This is what the phone shows as "next run".
    func nextFireDate(from now: Date = Date()) -> Date? {
        // A queued one-off shows even for a paused routine (it will fire).
        if let oneOff = oneOffAt { return Date(timeIntervalSince1970: oneOff) }
        guard enabled else { return nil }
        if let retry = nextRetryAt, now.timeIntervalSince1970 < retry {
            return Date(timeIntervalSince1970: retry)
        }
        if isDue(at: now) { return schedule.previousOccurrence(onOrBefore: now) }
        return schedule.nextOccurrence(after: now)
    }
}

// MARK: - Template library

/// The pre-defined routines offered on the phone as one-tap adds. Seeded into
/// the store on first launch so a fresh install starts with something useful.
enum RoutineTemplates {
    struct Template {
        let name: String
        let description: String
        let steps: [RoutineStep]
        let schedule: RoutineSchedule
    }

    static let all: [Template] = [
        Template(
            name: "Morning Summary",
            description: "Today's schedule and mail, ready before you are.",
            steps: [.briefing(type: "daily_summary"), .briefing(type: "calendar")],
            schedule: .daily(hour: 8, minute: 0)),
        Template(
            name: "News Brief",
            description: "A round-up of what's happening, first thing.",
            steps: [.briefing(type: "news")],
            schedule: .daily(hour: 7, minute: 30)),
        Template(
            name: "Evening Checklist",
            description: "How today went, and the three things tomorrow needs.",
            steps: [
                .briefing(type: "daily_summary"),
                .hermes(prompt: "What should I focus on tomorrow? Give me a short checklist of the three most important items."),
            ],
            schedule: .daily(hour: 19, minute: 0)),
        Template(
            name: "Weekly Review",
            description: "A week in review, with Notes open to capture it.",
            steps: [
                .hermes(prompt: "Summarize my week: what I got done, what stalled, and the one thing to prioritise next week."),
                .shell(command: "open -a Notes"),
            ],
            schedule: .weekly(dayOfWeek: 1, hour: 18, minute: 0)),
        Template(
            name: "Job Search Brief",
            description: "A scan of new listings, scored against your profile.",
            steps: [.career(action: "scan")],
            schedule: .weekly(dayOfWeek: 2, hour: 8, minute: 0)),
        Template(
            name: "Application Follow-ups",
            description: "The applications that went quiet — and who to chase.",
            steps: [.career(action: "follow_ups")],
            schedule: .daily(hour: 9, minute: 0)),
        Template(
            name: "Check for Upcoming Deadlines",
            description: "The assignments due this week, and anything already overdue — from Canvas.",
            steps: [.nyu(action: "check_deadlines")],
            schedule: .daily(hour: 8, minute: 0)),
        Template(
            name: "Generate Visual Docs",
            description: "An up-to-date architecture report and interactive graph for your latest project.",
            steps: [.understand(action: "docs")],
            schedule: .onDemand),
        Template(
            name: "Onboarding Tour",
            description: "A guided walk through the codebase — layers first, then key files — for a new teammate.",
            steps: [.understand(action: "onboarding")],
            schedule: .onDemand),
    ] + StudyRoutineTemplates.all
}

// MARK: - Manager

/// Owns the routine library and the schedule. Persists to
/// `~/.alfred/routines.json`, checks every minute for due routines, executes
/// them step by step, and broadcasts lifecycle events to the socket server
/// (`onRoutineStarted` / `onRoutineProgress` / `onRoutineCompleted`).
///
/// Safety, matching the mail triager and the briefing generator:
///   * A scheduled run never starts while Hermes is mid-turn — the tick skips
///     and the routine stays due, so the next minute's tick picks it up.
///   * Hermes steps run with `capture: false` (background work, not a user ask).
@MainActor
final class RoutineManager {

    static let shared = RoutineManager()

    /// Fired when a routine begins / advances / finishes. The socket server sets
    /// these to broadcast `routine.started` / `routine.progress` /
    /// `routine.completed` to phones.
    var onRoutineStarted: ((Routine) -> Void)?
    var onRoutineProgress: ((Routine, Int, Int, String) -> Void)?   // (routine, step, total, label)
    var onRoutineCompleted: ((Routine, RoutineResult) -> Void)?
    /// Fired whenever a routine's metadata changes outside a lifecycle event
    /// (the taste polish rewriting a created routine's name/description) so
    /// phones can refresh without polling.
    var onRoutinesChanged: (() -> Void)?

    /// The agent that answers `hermes` steps. Handed over at launch, like the
    /// briefing generator's.
    weak var hermes: HermesSession?

    private var routines: [Routine] = []
    private var timer: Timer?
    private var isRunning = false
    /// Routine ids currently executing — the scheduler never double-fires one.
    private var runningIDs: Set<UUID> = []

    private let fileURL: URL
    private let hasSeededKey = "alfred.routines_seeded_v1"

    private init() {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred") as NSString
        try? FileManager.default.createDirectory(atPath: dir as String, withIntermediateDirectories: true)
        fileURL = URL(fileURLWithPath: dir.appendingPathComponent("routines.json"))
        load()
    }

    // MARK: - Lifecycle

    /// Start the one-minute scheduler. Idempotent.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSLog("[routines] scheduler started — \(routines.count) routine(s)")
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - CRUD

    func listRoutines() -> [Routine] { routines }

    func routine(id: UUID) -> Routine? {
        routines.first { $0.id == id }
    }

    /// Create a routine. For a schedule whose occurrence has already passed
    /// today, `lastScheduledAt` is seeded to that occurrence so a brand-new
    /// routine doesn't fire immediately — it waits for the next one.
    func createRoutine(
        name: String,
        description: String,
        steps: [RoutineStep],
        schedule: RoutineSchedule,
        enabled: Bool = true,
        skipPolish: Bool = false
    ) -> Routine {
        var routine = Routine(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: steps,
            schedule: schedule,
            enabled: enabled)
        if schedule.isScheduled, let prev = schedule.previousOccurrence(onOrBefore: Date()) {
            routine.lastScheduledAt = Self.minuteRounded(prev.timeIntervalSince1970)
        }
        routines.append(routine)
        save()
        NSLog("[routines] created '\(routine.name)' (\(routine.id.uuidString))")
        // Template names ("Morning Summary", "Weekly Review") are curated by
        // hand — never rewrite a name the user explicitly chose by tapping a
        // template. Custom names and descriptions are the polish's target.
        if !skipPolish {
            polishRoutineMetadata(routine)
        }
        return routine
    }

    /// Taste-polish a freshly created routine's name and description in the
    /// background. Fire-and-forget: creation is never blocked on a model turn,
    /// and a rewrite only lands when the text is genuinely generic (the
    /// deterministic gate). The routine is updated in place and phones are
    /// told via onRoutinesChanged.
    private func polishRoutineMetadata(_ routine: Routine) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The polish turn takes seconds. If the owner edited the routine in
            // that window, never clobber the newer values — the polish was
            // derived from the originals.
            guard let current = self.routines.first(where: { $0.id == routine.id }),
                  current.name == routine.name,
                  current.description == routine.description
            else { return }
            let taste = TasteSkillManager.shared
            let polishedName = await taste.polishIfNeeded(routine.name, scope: .routines)
            let polishedDescription = await taste.polishIfNeeded(routine.description, scope: .routines)
            guard polishedName != routine.name || polishedDescription != routine.description else {
                return
            }
            self.updateRoutine(id: routine.id, name: polishedName, description: polishedDescription)
            self.onRoutinesChanged?()
        }
    }

    /// Update any subset of a routine's fields; nil leaves each untouched.
    @discardableResult
    func updateRoutine(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        steps: [RoutineStep]? = nil,
        schedule: RoutineSchedule? = nil,
        enabled: Bool? = nil
    ) -> Routine? {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return nil }
        var routine = routines[index]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            routine.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let description { routine.description = description.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let steps, !steps.isEmpty { routine.steps = steps }
        if let schedule {
            routine.schedule = schedule
            // A schedule change resets the fired-occurrence marker so the next
            // applicable occurrence is treated as new.
            routine.lastScheduledAt = schedule.previousOccurrence(onOrBefore: Date()).map { Self.minuteRounded($0.timeIntervalSince1970) }
        }
        if let enabled { routine.enabled = enabled }
        routines[index] = routine
        save()
        return routine
    }

    @discardableResult
    func deleteRoutine(id: UUID) -> Bool {
        let before = routines.count
        routines.removeAll { $0.id == id }
        runningIDs.remove(id)
        if routines.count != before {
            save()
            return true
        }
        return false
    }

    /// Add a template by name — the phone's one-tap quick-add.
    @discardableResult
    func addTemplate(named name: String) -> Routine? {
        guard let template = RoutineTemplates.all.first(where: { $0.name == name }) else { return nil }
        return createRoutine(
            name: template.name,
            description: template.description,
            steps: template.steps,
            schedule: template.schedule)
    }

    // MARK: - Execution

    /// Where a run came from — the scheduler or the phone's "Run Now". Only
    /// scheduler runs get automatic retry on failure.
    enum RunSource {
        case scheduled
        case manual
    }

    /// Run a routine now (scheduled tick or the phone's "Run Now"). Never
    /// throws; every outcome is a `RoutineResult`.
    func runRoutine(id: UUID, source: RunSource = .manual) async -> RoutineResult {
        guard let index = routines.firstIndex(where: { $0.id == id }) else {
            return RoutineResult(
                success: false, output: "No routine with that id.", duration: 0,
                stepsCompleted: 0, stepsTotal: 0, completedAt: Date().timeIntervalSince1970, stepResults: [])
        }
        // The phone's manual run can land while the scheduler is mid-fire on the
        // same routine; a second concurrent run is never useful.
        guard !runningIDs.contains(id) else {
            return RoutineResult(
                success: false, output: "Already running.", duration: 0,
                stepsCompleted: 0, stepsTotal: routines[index].steps.count,
                completedAt: Date().timeIntervalSince1970, stepResults: [])
        }

        runningIDs.insert(id)
        defer {
            runningIDs.remove(id)
            isRunning = false
        }
        isRunning = true

        let routine = routines[index]
        onRoutineStarted?(routine)
        let started = Date().timeIntervalSince1970
        let stepResults = await execute(routine)
        let duration = Date().timeIntervalSince1970 - started

        let total = routine.steps.count
        let completed = stepResults.filter(\.success).count
        let output = stepResults.map { step in
            let mark = step.success ? "✓" : "✗"
            return "\(mark) \(step.label)\n\(step.output)"
        }.joined(separator: "\n")
        let result = RoutineResult(
            success: total > 0 && completed == total,
            output: output.isEmpty ? "No steps." : output,
            duration: duration,
            stepsCompleted: completed,
            stepsTotal: total,
            completedAt: started + duration,
            stepResults: stepResults)

        if let index = routines.firstIndex(where: { $0.id == id }) {
            routines[index].lastRun = started + duration
            routines[index].lastResult = result

            let now = Date()
            // A one-off run is consumed by firing, whatever its outcome.
            if let oneOff = routine.oneOffAt, now.timeIntervalSince1970 >= oneOff {
                routines[index].oneOffAt = nil
            }
            // A fire records *which occurrence* ran so the next tick doesn't
            // re-fire it. A failed *scheduled* run keeps the occurrence due but
            // backs off an hour instead of hammering every minute.
            if routine.schedule.isScheduled,
               let prev = routine.schedule.previousOccurrence(onOrBefore: now) {
                if result.success || source == .manual {
                    // Success, or the user ran it by hand (that satisfies the
                    // occurrence): mark it executed, clear any pending retry.
                    routines[index].lastScheduledAt = Self.minuteRounded(prev.timeIntervalSince1970)
                    routines[index].nextRetryAt = nil
                } else {
                    routines[index].nextRetryAt = now.addingTimeInterval(3600).timeIntervalSince1970
                }
            }
            save()
        }
        NSLog("[routines] '\(routine.name)' finished — \(completed)/\(total) steps, \(String(format: "%.1f", duration))s")
        onRoutineCompleted?(routine, result)
        return result
    }

    /// Queue a routine to run once at `date`, independent of its schedule.
    @discardableResult
    func scheduleRoutine(id: UUID, for date: Date) -> Routine? {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return nil }
        routines[index].oneOffAt = date.timeIntervalSince1970
        save()
        NSLog("[routines] '\(routines[index].name)' scheduled once for \(date)")
        return routines[index]
    }

    /// Run the steps one by one, never stopping the routine on a failure —
    /// each step's outcome is recorded and the next one runs. Steps that touch
    /// Hermes respect the session guard and use `capture: false`.
    private func execute(_ routine: Routine) async -> [RoutineStepResult] {
        var results: [RoutineStepResult] = []
        for (index, step) in routine.steps.enumerated() {
            onRoutineProgress?(routine, index + 1, routine.steps.count, step.label)
            let outcome: (success: Bool, output: String)
            switch step {
            case .briefing(let type):
                outcome = await runBriefing(type: type)
            case .hermes(let prompt):
                outcome = await runHermes(prompt)
            case .shell(let command):
                outcome = await runShell(command)
            case .mail(let action):
                outcome = runMail(action: action)
            case .reminder(let title, let dueIn):
                outcome = await runReminder(title: title, dueIn: dueIn)
            case .browser(let instruction, let url):
                outcome = await runBrowser(instruction: instruction, url: url)
            case .scrape(let instruction, let url):
                outcome = await runScrape(instruction: instruction, url: url)
            case .career(let action):
                outcome = await runCareer(action: action)
            case .understand(let action):
                outcome = await runUnderstand(action: action)
            case .nyu(let action):
                outcome = await runNYU(action: action)
            case .study(let action):
                outcome = await runStudy(action: action)
            }
            results.append(RoutineStepResult(
                index: index,
                label: step.label,
                success: outcome.success,
                output: outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return results
    }

    // MARK: Step implementations

    private func runBriefing(type: String) async -> (success: Bool, output: String) {
        // Every briefing kind funnels through the same generator today — the
        // phone's card and the push notification are the delivery channel. A
        // "news" type degrades honestly to the regular summary.
        let content = await BriefingGenerator.shared.generate(focusedDay: "today")
        guard !content.summary.isEmpty else { return (false, "Briefing came back empty.") }
        return (true, content.summary)
    }

    private func runHermes(_ prompt: String) async -> (success: Bool, output: String) {
        // Multi-agent routine steps run on their own team (per-role sessions),
        // so they neither wait on nor block the shared bar session — the team
        // does the whole pipeline and the final deliverable is the step output.
        if MultiAgentOrchestrator.shared.enabled, let task = MultiAgentOrchestrator.route(prompt) {
            let output = await MultiAgentOrchestrator.shared.runCollectingText(task: task)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let success = !trimmed.isEmpty && !trimmed.hasPrefix("Multi-agent run failed")
            return (success, trimmed.isEmpty ? "The agent team returned an empty answer." : trimmed)
        }

        guard let hermes else { return (false, "No agent session — Alfred isn't running Hermes.") }
        // Wait up to ~10s for a free session before giving up on this step; the
        // scheduler already avoids starting while a turn is active, so this only
        // bites when the user starts typing just as a routine fires.
        var waited = 0
        while await hermes.isTurnActive, waited < 10 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 2
        }
        guard await !hermes.isTurnActive else {
            return (false, "Hermes is busy with a live turn — skipped.")
        }

        var transcript = ""
        for await event in await hermes.prompt(prompt, capture: false) {
            switch event {
            case .text(let chunk): transcript += chunk
            case .failed(let message): return (false, message)
            case .thought, .toolStarted, .toolProgress, .usage, .finished: break
            }
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (false, "Hermes returned an empty answer.") : (true, trimmed)
    }

    /// Run a shell command via /bin/bash -c with a hard timeout; the routine
    /// must never hang on a wedged child process.
    private func runShell(_ command: String) async -> (success: Bool, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: (proc.terminationStatus == 0, output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (false, error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Read-only mail actions. Sending stays with the agent's `email_send`
    /// tool — a routine should never fire a message without the user watching.
    private func runMail(action: String) -> (success: Bool, output: String) {
        let envelopes = (try? EmailCapability.shared.latestEnvelopes(
            account: "icloud", mailbox: "Inbox", limit: 50)) ?? []
        let unread = envelopes.filter(\.isUnread)
        switch action {
        case "check_unread":
            return (true, "\(unread.count) unread message\(unread.count == 1 ? "" : "s") in Inbox.")
        case "send_summary":
            guard !unread.isEmpty else { return (true, "No unread mail.") }
            let lines = unread.prefix(10).map { env -> String in
                let from = env.fromName?.isEmpty == false ? env.fromName! : env.fromEmail
                return "• \(from)"
            }
            return (true, "\(unread.count) unread. Newest:\n" + lines.joined(separator: "\n"))
        default:
            return (false, "Unknown mail action '\(action)'.")
        }
    }

    /// Read-only web automation via BrowserUseClient: open `url` and report
    /// what the page says, or — when no url is given — search the web for the
    /// instruction and report the top results. This is the routine-shaped
    /// "check the price / look that up / see what the news says" step.
    ///
    /// Never submits anything (read-only by design) and honors the master
    /// switch: with browser automation off the step fails with an honest
    /// message instead of silently doing nothing. Needs Chrome running with
    /// the browser-use daemon up — when it isn't, the harness's own error
    /// ("open Chrome, then retry") is surfaced.
    private func runBrowser(instruction: String, url: String?) async -> (success: Bool, output: String) {
        let client = BrowserUseClient.shared
        guard client.isEnabled else {
            return (false, "Browser automation is off in Settings — no step ran.")
        }

        if let url, !url.isEmpty {
            guard !BrowserUseClient.isBlocked(url: url) else {
                client.logAudit("routine-blocked", url: url, detail: "refused: blocked host")
                return (false, BrowserUseClient.refusalMessage(for: url))
            }
            client.logAudit("routine-page", url: url, detail: "instruction=\(instruction)")
            let result = await client.extractText(url: url, maxChars: 2000)
            guard result.succeeded else { return (false, result.message) }
            let text = result.payload?["text"] as? String ?? ""
            return (true, Self.trimmedPageText(text))
        }

        client.logAudit("routine-search", url: "", detail: "instruction=\(instruction)")
        let result = await client.search(query: instruction, maxChars: 2000)
        guard result.succeeded else { return (false, result.message) }
        let text = result.payload?["text"] as? String ?? ""
        return (true, Self.trimmedPageText(text))
    }

    /// A page's worth of scraped text down to the lines that matter for a
    /// routine result line.
    private static func trimmedPageText(_ text: String) -> String {
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.prefix(10).joined(separator: "\n").prefix(1500))
    }

    /// Lightweight web fetch via CrawleeClient: open `url` and report what
    /// the page says, or — when no url is given — search the web for the
    /// instruction and report the top results. Read-only by design (GET
    /// requests only, never a form), honors the master switch, and needs no
    /// Chrome — the complement to the browser step when a page is simple
    /// enough that a full browser would be wasted.
    private func runScrape(instruction: String, url: String?) async -> (success: Bool, output: String) {
        let client = CrawleeClient.shared
        guard client.isEnabled else {
            return (false, "Scraping is off in Settings — no step ran.")
        }

        if let url, !url.isEmpty {
            client.logAudit("routine-scrape", url: url, detail: "instruction=\(instruction)")
            let result = await client.scrape(url: url)
            guard result.succeeded else { return (false, result.message) }
            let title = result.title.map { "\($0)\n" } ?? ""
            return (true, title + Self.trimmedPageText(result.text ?? ""))
        }

        client.logAudit("routine-search", url: "", detail: "instruction=\(instruction)")
        let result = await client.search(query: instruction)
        guard result.succeeded else { return (false, result.message) }
        guard let results = result.payload?["results"] as? [[String: Any]], !results.isEmpty else {
            return (false, "No search results.")
        }
        let lines = results.prefix(5).map { item -> String in
            let title = item["title"] as? String ?? ""
            let url = item["url"] as? String ?? ""
            return "• \(title) — \(url)"
        }
        return (true, lines.joined(separator: "\n"))
    }

    /// Career-ops work via CareerOpsManager: "scan" searches the job boards
    /// against the owner's profile and reports the top scored listings;
    /// "follow_ups" lists applications whose follow-up window has passed.
    /// Read-only — nothing here submits an application.
    private func runCareer(action: String) async -> (success: Bool, output: String) {
        let manager = CareerOpsManager.shared
        switch action {
        case "scan":
            let postings = await manager.searchJobs(limit: 8)
            guard !postings.isEmpty else {
                return (false, "No listings found. Check your job preferences in Settings (role types, locations) and try again.")
            }
            let ranked = await manager.scoreAndRank(postings)
            let lines = ranked.map { item -> String in
                let mark = item.score.shouldApply ? "★" : "·"
                return "\(mark) \(item.posting.title) — \(item.posting.company) (\(String(format: "%.1f", item.score.score)))"
            }
            return (true, "Top \(lines.count) jobs by fit:\n" + lines.joined(separator: "\n"))
        case "follow_ups":
            let due = manager.followUpsDue()
            guard !due.isEmpty else {
                return (true, "No follow-ups due — every application is either recent or answered.")
            }
            let lines = due.map { app -> String in
                let days = Int(max(1, (Date().timeIntervalSince1970 - app.appliedAt) / 86_400))
                return "• \(app.title) at \(app.company) — \(days)d ago, no reply yet"
            }
            return (true, "\(due.count) follow-up(s) due:\n" + lines.joined(separator: "\n"))
        default:
            return (false, "Unknown career action '\(action)'.")
        }
    }

    /// Understand-Anything work: analyze the last-used code project and report
    /// from its knowledge graph. "analyze" runs (or refreshes) the pipeline;
    /// "docs" adds an architecture report from the graph's layers; "onboarding"
    /// walks the guided tour. Needs a project to act on — routines carry no
    /// path, so the step uses the project most recently used in the Code tab.
    private func runUnderstand(action: String) async -> (success: Bool, output: String) {
        guard let projectPath = AlfredCodeManager.shared.lastKnownProjectPath() else {
            return (false, "No project to analyze — pick a project folder in the Code tab first.")
        }
        let manager = UnderstandAnythingManager.shared
        guard manager.isEnabled else {
            return (false, "Understand-Anything is off in Settings — no step ran.")
        }
        guard manager.isInstalled else {
            return (false, "Understand-Anything isn't installed on the Mac. Install it with: curl -fsSL https://raw.githubusercontent.com/Egonex-AI/Understand-Anything/main/install.sh | bash")
        }

        // Make sure there's a graph; analyze is idempotent when one exists.
        var state = await manager.ensureAnalyzed(projectPath: projectPath)
        if !state.isReady {
            state = await manager.analyze(projectPath: projectPath)
        }
        guard case .ready(let nodes, let edges, let layers) = state else {
            return (false, "The knowledge graph isn't ready (\(stateDescription(state))).")
        }

        let header = "\(projectPath) — \(nodes) nodes, \(edges) edges, \(layers) layer\(layers == 1 ? "" : "s")"
        switch action {
        case "docs":
            let summaries = await manager.architecture(projectPath: projectPath)
            guard !summaries.isEmpty else { return (false, header + "\nNo architecture to report.") }
            let lines = summaries.map { layer -> String in
                var line = "\n■ \(layer.name) — \(layer.nodeCount) node\(layer.nodeCount == 1 ? "" : "s")"
                if let description = layer.description, !description.isEmpty {
                    line += "\n  \(description)"
                }
                if !layer.sampleNodes.isEmpty {
                    line += "\n  e.g. \(layer.sampleNodes.prefix(4).joined(separator: ", "))"
                }
                return line
            }
            return (true, header + lines.joined(separator: "\n"))
        case "onboarding":
            guard let graph = await manager.graph(projectPath: projectPath),
                  let tour = graph.tour, !tour.isEmpty else {
                return (true, header + "\nNo guided tour in this graph (the pipeline builds one with the full /understand run).")
            }
            let steps = tour.sorted { $0.order < $1.order }.prefix(8).map { step -> String in
                var line = "\n\(step.order). \(step.title)"
                if let description = step.description, !description.isEmpty {
                    line += "\n  \(description)"
                }
                if !step.nodeIds.isEmpty {
                    let names = step.nodeIds.prefix(4).compactMap { id in
                        graph.nodes.first(where: { $0.id == id })?.displayName
                    }
                    if !names.isEmpty { line += "\n  → \(names.joined(separator: ", "))" }
                }
                return line
            }
            return (true, header + steps.joined(separator: "\n"))
        default:
            return (true, header + "\nThe graph is ready to explore — open it from the Code tab's Knowledge Graph sheet.")
        }
    }

    private func stateDescription(_ state: UnderstandAnythingManager.GraphState) -> String {
        switch state {
        case .notInstalled: return "plugin not installed"
        case .notAnalyzed: return "not analyzed"
        case .analyzing: return "still analyzing"
        case .ready: return "ready"
        case .failed(let message): return message
        }
    }

    /// NYU coursework via NYUIntegrationManager: "check_deadlines" reports
    /// what's due in the next week plus anything overdue; "sync" forces a
    /// Canvas refresh first and reports its outcome. Needs the integration
    /// configured — the step says so plainly when it isn't.
    private func runNYU(action: String) async -> (success: Bool, output: String) {        let manager = NYUIntegrationManager.shared
        guard manager.isConfigured else {
            return (false, "The NYU integration isn't configured — add a Canvas token in Settings (NYU) and turn it on, then run again.")
        }
        switch action {
        case "sync":
            let result = await manager.syncNow()
            return (result.success, result.message)
        case "check_deadlines":
            let upcoming = manager.dueWithin(days: 7)
            let overdue = manager.overdue()
            guard !upcoming.isEmpty || !overdue.isEmpty else {
                return (true, "Nothing due in the next 7 days, and nothing overdue. Enjoy the breathing room — sync when you want a fresh look.")
            }
            var lines: [String] = []
            if !upcoming.isEmpty {
                lines.append("\(upcoming.count) assignment\(upcoming.count == 1 ? "" : "s") due in the next 7 days:")
                lines.append(contentsOf: upcoming.prefix(10).map { row -> String in
                    let when = row.dueAt.map {
                        Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted)
                    } ?? "no due date"
                    return "• \(row.name) — \(row.courseName) (due \(when))"
                })
            }
            if !overdue.isEmpty {
                lines.append("\(overdue.count) overdue — submit or mark them:")
                lines.append(contentsOf: overdue.prefix(5).map { row in
                    "• \(row.name) — \(row.courseName) (overdue \(row.daysUntil.map { "\(abs($0))d" } ?? ""))"
                })
            }
            return (true, lines.joined(separator: "\n"))
        default:
            return (false, "Unknown nyu action '\(action)'.")
        }
    }

    /// Study-routine work via StudyRoutineManager: exam prep, problem sets,
    /// reading quizzes, lecture review and the weekly report. The manager
    /// adapts each step to the tutor's live mastery + learning style.
    private func runStudy(action: String) async -> (success: Bool, output: String) {
        await StudyRoutineManager.shared.runStep(action: action)
    }

    /// Set a reminder due `dueIn` seconds from now, in the user's real Reminders
    /// store via the existing capability.
    private func runReminder(title: String, dueIn: TimeInterval) async -> (success: Bool, output: String) {
        let capability = CalendarCapability()
        do {
            let due = Date().addingTimeInterval(dueIn)
            let reply = try await capability.createReminder(.init(title: title, due: due))
            return (true, reply)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Scheduler

    /// Every minute: run whatever is due. Skips entirely while Hermes is
    /// mid-turn — the routines stay due, so the next tick catches them.
    private func tick() {
        guard !isRunning else { return }
        let now = Date()
        let due = routines.filter { !runningIDs.contains($0.id) && $0.isDue(at: now) }
        guard !due.isEmpty else { return }

        Task {
            for routine in due {
                _ = await runRoutine(id: routine.id, source: .scheduled)
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(routines) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([Routine].self, from: data) {
            routines = stored
            return
        }
        // First launch: seed the template library. Guarded by a defaults flag so
        // deleting every routine doesn't resurrect the templates on relaunch.
        if !UserDefaults.standard.bool(forKey: hasSeededKey) {
            for template in RoutineTemplates.all {
                var routine = Routine(
                    name: template.name,
                    description: template.description,
                    steps: template.steps,
                    schedule: template.schedule)
                if let prev = template.schedule.previousOccurrence(onOrBefore: Date()) {
                    routine.lastScheduledAt = Self.minuteRounded(prev.timeIntervalSince1970)
                }
                routines.append(routine)
            }
            UserDefaults.standard.set(true, forKey: hasSeededKey)
            save()
            NSLog("[routines] seeded \(routines.count) template routine(s)")
        }
    }

    /// Round to the minute so a schedule occurrence matches regardless of
    /// sub-second drift between tick and fire.
    private static func minuteRounded(_ t: TimeInterval) -> TimeInterval {
        (t / 60).rounded() * 60
    }
}
