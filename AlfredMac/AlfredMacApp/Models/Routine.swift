//
//  Routine.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Models/Routine.swift).
//

import Foundation

/// One step of a routine, as sent over the wire:
///
///   {"kind":"briefing","type":"daily_summary"}
///   {"kind":"hermes","prompt":"..."}
///   {"kind":"shell","command":"..."}
///   {"kind":"mail","action":"check_unread"}
///   {"kind":"reminder","title":"...","dueIn":3600}
///   {"kind":"browser","instruction":"...","url":"https://..."}   (url optional)
///   {"kind":"scrape","instruction":"...","url":"https://..."}    (url optional)
enum RoutineStepPayload: Codable, Hashable, Identifiable {
    case briefing(type: String)
    case hermes(prompt: String)
    case shell(command: String)
    case mail(action: String)
    case reminder(title: String, dueIn: TimeInterval)
    /// Read-only web automation: open `url` (or search for `instruction` when
    /// no url is given) and report what the page says.
    case browser(instruction: String, url: String?)
    /// Lightweight web fetch via the Mac's Crawlee bridge: open `url` (or
    /// search for `instruction` when no url is given) and report the text.
    case scrape(instruction: String, url: String?)
    /// Career-ops work on the Mac: "scan" finds and scores jobs against your
    /// profile; "follow_ups" lists applications that went quiet.
    case career(action: String)
    /// Understand-Anything (interactive knowledge graph): "analyze" builds the
    /// graph, "docs" adds an architecture report, "onboarding" walks the tour.
    case understand(action: String)
    /// NYU coursework: "check_deadlines" lists what's due in the next week
    /// plus anything overdue; "sync" forces a Canvas refresh first.
    case nyu(action: String)

    private enum Kind: String, Codable {
        case briefing, hermes, shell, mail, reminder, browser, scrape, career, understand, nyu
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
        }
    }

    var id: String {
        switch self {
        case .briefing(let type): return "briefing-\(type)"
        case .hermes(let prompt): return "hermes-\(prompt)"
        case .shell(let command): return "shell-\(command)"
        case .mail(let action): return "mail-\(action)"
        case .reminder(let title, let dueIn): return "reminder-\(title)-\(dueIn)"
        case .browser(let instruction, _): return "browser-\(instruction)"
        case .scrape(let instruction, _): return "scrape-\(instruction)"
        case .career(let action): return "career-\(action)"
        case .understand(let action): return "understand-\(action)"
        case .nyu(let action): return "nyu-\(action)"
        }
    }

    /// Short human label for lists and step editors.
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
        }
    }

    /// SF Symbol for the step type.
    var icon: String {
        switch self {
        case .briefing: return "sun.max"
        case .hermes: return "bubble.left.and.bubble.right"
        case .shell: return "terminal"
        case .mail: return "envelope"
        case .reminder: return "checklist"
        case .browser: return "globe"
        case .scrape: return "doc.text.magnifyingglass"
        case .career: return "briefcase"
        case .understand: return "point.3.connected.trianglepath.dotted"
        case .nyu: return "graduationcap.fill"
        }
    }
}

/// When a routine fires:
///
///   {"type":"onDemand"}
///   {"type":"daily","hour":8,"minute":0}
///   {"type":"weekly","dayOfWeek":1,"hour":18,"minute":0}   (1 = Sunday)
///   {"type":"custom","cronExpression":"0 8 * * 1-5"}
enum RoutineSchedulePayload: Codable, Hashable {
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

    /// Human schedule line for rows: "Daily at 8:00 AM", "On demand"…
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
}

/// One step's outcome from the last run — the detail sheet shows these.
struct RoutineStepResultPayload: Codable, Hashable {
    var index: Int
    var label: String
    var success: Bool
    var output: String
}

/// The outcome of the last run.
struct RoutineResultPayload: Codable, Hashable {
    var success: Bool
    var output: String
    var duration: TimeInterval
    var stepsCompleted: Int
    var stepsTotal: Int
    var completedAt: TimeInterval
    var stepResults: [RoutineStepResultPayload] = []
}

/// A routine as the Mac reports it in `routines.list` / `routines.create` /
/// `routines.update` results. `nextFireAt` is computed on the Mac at response
/// time (0 = on-demand or disabled).
struct RoutineSummary: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var description: String
    var steps: [RoutineStepPayload]
    var schedule: RoutineSchedulePayload
    var enabled: Bool
    var createdAt: TimeInterval
    var lastRun: TimeInterval
    var nextFireAt: TimeInterval
    var lastResult: RoutineResultPayload?

    /// Decode from the wire dictionaries (JSON-RPC result payloads).
    static func fromJSON(_ params: [String: Any]) -> RoutineSummary? {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let routine = try? JSONDecoder().decode(RoutineSummary.self, from: data)
        else { return nil }
        return routine
    }
}

/// The pre-defined routines offered as one-tap adds. Names must match the
/// Mac's `RoutineTemplates` exactly — the phone sends the name and the Mac
/// builds the routine.
enum RoutineTemplatesPayload {
    static let names: [String] = ["Morning Summary", "News Brief", "Evening Checklist", "Weekly Review", "Job Search Brief", "Application Follow-ups"]

    static func blurb(for name: String) -> String {
        switch name {
        case "Morning Summary": return "Today's schedule and mail, ready before you are."
        case "News Brief": return "A round-up of what's happening, first thing."
        case "Evening Checklist": return "How today went, and the three things tomorrow needs."
        case "Weekly Review": return "A week in review, with Notes open to capture it."
        case "Job Search Brief": return "A scan of new listings, scored against your profile."
        case "Application Follow-ups": return "The applications that went quiet — and who to chase."
        default: return ""
        }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "Morning Summary": return "sunrise"
        case "News Brief": return "newspaper"
        case "Evening Checklist": return "moon.stars"
        case "Weekly Review": return "calendar.badge.clock"
        case "Job Search Brief": return "briefcase"
        case "Application Follow-ups": return "paperplane"
        default: return "bolt"
        }
    }
}
