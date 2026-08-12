import Foundation

// MARK: - Tool requests

/// `file_organize` arguments. Snake_case from the wire maps onto camelCase
/// properties (the server decodes with `.convertFromSnakeCase`).
struct FileOrganizeRequest: Decodable {
    let action: String                    // move | copy | delete | create_folder | list_folder
    let sourcePath: String?               // required for move / copy / delete
    let destinationPath: String?          // required for move / copy; the target dir for create_folder / list_folder
    let recursive: Bool?                  // list_folder: walk subfolders. Default false.
    let confirmation: String?             // delete: the user's explicit approval, quoted verbatim
}

/// `calendar_plan` arguments. Times are ISO-8601 strings; they parse through
/// `CalendarCapability.parseISO`, the same matcher the other calendar tools use.
struct CalendarPlanRequest: Decodable {
    let action: String                    // find_free_slots | suggest_meeting | detect_conflicts | next_deadline
    let durationMinutes: Int?             // find_free_slots, suggest_meeting
    let startDate: String?                // find_free_slots (defaults to now)
    let endDate: String?                  // find_free_slots (defaults to now + 7 days)
    let attendees: [String]?              // suggest_meeting (informational — see the service)
}

/// `habit_predict` arguments.
struct HabitPredictRequest: Decodable {
    let action: String                    // next_app | next_action | habit_chain
    let currentApp: String?               // next_action: a bundle ID like com.apple.dt.Xcode
}

// MARK: - Tool result

/// The uniform return of every handler. `data` carries structured payloads
/// (slots, conflicts, predictions) for tests and future JSON output; `text` is
/// the human-readable rendering the MCP layer sends back to the model.
///
/// Not `Encodable` despite the original spec: the MCP layer returns text
/// content, so a plain struct + renderer is the honest shape — structured JSON
/// output can be added later without touching the handlers.
struct ToolResult {
    let success: Bool
    let message: String
    let data: [String: Any]?
    let auditEntry: String?

    init(success: Bool, message: String, data: [String: Any]? = nil, auditEntry: String? = nil) {
        self.success = success
        self.message = message
        self.data = data
        self.auditEntry = auditEntry
    }

    static func failure(_ message: String) -> ToolResult {
        ToolResult(success: false, message: message)
    }

    /// The MCP text content. A failed call still returns readable text (not an
    /// error frame) so the model can read the reason and recover.
    var text: String {
        var lines = [message]
        if let auditEntry, !auditEntry.isEmpty {
            lines.append("Audit: \(auditEntry)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Handlers

/// Stateless dispatchers for the Phase-2 service layer. Each handler never
/// throws — every failure is folded into a `ToolResult` with a readable
/// message, and calendar queries degrade to empty arrays. The only side
/// effects are the ones the dispatched service itself performs.
enum ToolHandlers {

    // MARK: ISO 8601

    /// ISO8601DateFormatter is thread-safe for formatting (same guarantee
    /// CalendarCapability relies on for its cached formatters), so the handler
    /// shares one instance rather than allocating per slot.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Stable UTC timestamps for slot JSON, e.g. "2026-09-05T15:00:00Z".
    static func isoString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Decode MCP arguments into a request struct. Snake_case keys map onto
    /// camelCase properties; malformed JSON yields nil so the caller can
    /// answer with a missing-argument error instead of crashing.
    ///
    /// Stringified scalars ("true", "60") are normalized first — models
    /// occasionally send booleans and numbers as strings, and failing the whole
    /// request over one would surface a confusing "missing arguments" error.
    static func decode<T: Decodable>(_ type: T.Type, from arguments: [String: Any]) -> T? {
        let normalized: [String: Any] = arguments.mapValues { value in
            guard let string = value as? String else { return value }
            if string == "true" { return true }
            if string == "false" { return false }
            if let number = Int(string) { return number }
            if let number = Double(string) { return number }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - file_organize

    static func handleFileOrganize(_ req: FileOrganizeRequest) -> ToolResult {
        let capability = FileManagementCapability()
        let describe = FileManagementCapability.describe

        func path(_ raw: String?) -> URL? {
            raw.flatMap { $0.isEmpty ? nil : $0 }.map(URL.init(fileURLWithPath:))
        }

        switch req.action.lowercased() {

        case "move":
            guard let src = path(req.sourcePath), let dst = path(req.destinationPath) else {
                return .failure("move needs both source_path and destination_path.")
            }
            do {
                _ = try capability.moveFile(from: src, to: dst)
                return ToolResult(
                    success: true,
                    message: "Moved \(describe(src)) to \(describe(dst)).",
                    auditEntry: FileManagementCapability.auditMessage(
                        action: "moved", from: describe(src), to: describe(dst)))
            } catch {
                return .failure(error.localizedDescription)
            }

        case "copy":
            guard let src = path(req.sourcePath), let dst = path(req.destinationPath) else {
                return .failure("copy needs both source_path and destination_path.")
            }
            do {
                _ = try capability.copyFile(from: src, to: dst)
                return ToolResult(
                    success: true,
                    message: "Copied \(describe(src)) to \(describe(dst)).",
                    auditEntry: FileManagementCapability.auditMessage(
                        action: "copied", from: describe(src), to: describe(dst)))
            } catch {
                return .failure(error.localizedDescription)
            }

        case "delete":
            guard let src = path(req.sourcePath) else {
                return .failure("delete needs source_path.")
            }
            guard isExplicitConfirmation(req.confirmation) else {
                return ToolResult(
                    success: false,
                    message: "Deleting \(describe(src)) can't be undone. The user must explicitly confirm in their own words — pass their confirmation phrase in `confirmation` (e.g. \"confirm\") — before Alfred removes anything.")
            }
            do {
                _ = try capability.deleteFile(at: src, confirmed: true)
                return ToolResult(
                    success: true,
                    message: "Deleted \(describe(src)).",
                    auditEntry: FileManagementCapability.auditMessage(action: "deleted", from: describe(src), to: nil))
            } catch {
                return .failure(error.localizedDescription)
            }

        case "create_folder":
            guard let dst = path(req.destinationPath) else {
                return .failure("create_folder needs destination_path.")
            }
            do {
                _ = try capability.createFolder(at: dst)
                return ToolResult(
                    success: true,
                    message: "Created \(describe(dst)).",
                    auditEntry: FileManagementCapability.auditMessage(action: "created folder", from: nil, to: describe(dst)))
            } catch {
                return .failure(error.localizedDescription)
            }

        case "list_folder":
            guard let dst = path(req.destinationPath) else {
                return .failure("list_folder needs destination_path.")
            }
            do {
                let urls = try capability.listFolder(at: dst, recursive: req.recursive ?? false)
                let items = urls.map { describe($0) }
                return ToolResult(
                    success: true,
                    message: items.isEmpty ? "\(describe(dst)) is empty." : "\(items.count) entr\(items.count == 1 ? "y" : "ies") in \(describe(dst)):",
                    data: ["files": items])
            } catch {
                return .failure(error.localizedDescription)
            }

        default:
            return .failure("Unknown action '\(req.action)'. Use move, copy, delete, create_folder, or list_folder.")
        }
    }

    /// The delete gate: the model must quote the user's explicit approval.
    /// Keyword check per the tool's safety contract — a bare "delete" echoed
    /// back by the model is NOT enough; it needs a human confirmation phrase.
    ///
    /// Negation always wins: "do not confirm", "don't confirm", "cancel" must
    /// refuse even though they contain the word "confirm". The confirmation is
    /// not tied to a specific path — the model built the request from the user's
    /// own sentence (path + approval together), and in the app the bar broker in
    /// AlfredToolServer is the real human gate on top of this one.
    static func isExplicitConfirmation(_ confirmation: String?) -> Bool {
        guard let confirmation else { return false }
        let lower = confirmation.lowercased()
        let refused = lower.contains("not confirm")
            || lower.contains("don't confirm")
            || lower.contains("do not confirm")
            || lower.contains("cancel")
            || lower.contains("never")
            || lower.contains("don't delete")
            || lower.contains("do not delete")
        guard !refused else { return false }
        return lower.contains("confirm")
            || lower.contains("go ahead")
            || lower.contains("yes, delete")
            || lower.contains("yes delete")
            || lower == "yes"
    }

    // MARK: - calendar_plan

    /// `service` is injectable so tests can exercise the ISO rendering path
    /// without EventKit (which would hang a headless harness on a TCC prompt).
    /// The app path uses the real `CalendarProactiveService`.
    static func handleCalendarPlan(_ req: CalendarPlanRequest,
                                   service: any CalendarPlanning = CalendarProactiveService()) async -> ToolResult {
        let now = Date()

        switch req.action.lowercased() {

        case "find_free_slots":
            let duration = max(1, req.durationMinutes ?? 60)
            let start = req.startDate.flatMap(CalendarCapability.parseISO(_:)) ?? now
            let end = req.endDate.flatMap(CalendarCapability.parseISO(_:)) ?? now.addingTimeInterval(7 * 86_400)
            do {
                let slots = try await service.findFreeSlots(for: duration, between: start, and: end)
                let items = slots.map { slot -> [String: Any] in
                    [
                        "start": isoString(slot.start),
                        "end": isoString(slot.end),
                        "available_minutes": Int(slot.end.timeIntervalSince(slot.start) / 60),
                    ]
                }
                return ToolResult(
                    success: true,
                    message: "\(items.count) free slot\(items.count == 1 ? "" : "s") of ≥ \(duration) min:",
                    data: ["slots": items])
            } catch {
                // Calendar queries degrade gracefully: the model gets an empty
                // list plus the reason (usually missing Calendar permission).
                return ToolResult(
                    success: false,
                    message: error.localizedDescription,
                    data: ["slots": [] as [Any]])
            }

        case "suggest_meeting":
            let duration = max(1, req.durationMinutes ?? 60)
            do {
                if let start = try await service.suggestMeetingTime(
                    durationMinutes: duration, attendees: req.attendees ?? [], within: 7, workStart: 9, workEnd: 18) {
                    let end = start.addingTimeInterval(TimeInterval(duration * 60))
                    return ToolResult(
                        success: true,
                        message: "Suggested: \(isoString(start)) for \(duration) min.",
                        data: ["slots": [
                            ["start": isoString(start),
                             "end": isoString(end),
                             "available_minutes": duration] as [String: Any]
                        ]])
                }
                return ToolResult(
                    success: true,
                    message: "No free window in the next 7 days during work hours.",
                    data: ["slots": [] as [Any]])
            } catch {
                return ToolResult(
                    success: false,
                    message: error.localizedDescription,
                    data: ["slots": [] as [Any]])
            }

        case "detect_conflicts":
            do {
                let conflicts = try await service.detectConflicts(days: 7)
                let items = conflicts.map { ["first": $0.0, "second": $0.1] }
                return ToolResult(
                    success: true,
                    message: "\(items.count) overlapping event\(items.count == 1 ? "" : "s"):",
                    data: ["conflicts": items])
            } catch {
                return ToolResult(
                    success: false,
                    message: error.localizedDescription,
                    data: ["conflicts": [] as [Any]])
            }

        case "next_deadline":
            do {
                if let (event, days) = try await service.getNextDeadline() {
                    return ToolResult(
                        success: true,
                        message: "Next deadline: \(event) in \(days) day\(days == 1 ? "" : "s").",
                        data: ["next_deadline": ["event": event, "days_until": days]])
                }
                return ToolResult(
                    success: true,
                    message: "No upcoming timed events in the next year.",
                    data: ["next_deadline": [:] as [String: Any]])
            } catch {
                return ToolResult(
                    success: false,
                    message: error.localizedDescription,
                    data: ["next_deadline": [:] as [String: Any]])
            }

        default:
            return .failure("Unknown action '\(req.action)'. Use find_free_slots, suggest_meeting, detect_conflicts, or next_deadline.")
        }
    }

    // MARK: - habit_predict

    static func handleHabitPredict(_ req: HabitPredictRequest) -> ToolResult {
        let service = HabitPredictionService.shared
        let name = BehaviorProfile.friendlyName(for:)

        switch req.action.lowercased() {

        case "next_app":
            if let (bundle, confidence) = service.predictNextApp() {
                return ToolResult(
                    success: true,
                    message: name(bundle),
                    data: [
                        "prediction": "The user is most likely in \(name(bundle)) right now.",
                        "confidence": confidence,
                        "reasoning": "\(name(bundle)) dominates this hour on this weekday in the learned profile.",
                    ])
            }
            return ToolResult(
                success: true,
                message: "Not enough learned data yet to predict the current app.",
                data: [
                    "prediction": "",
                    "confidence": 0.0,
                    "reasoning": "The behavior profile has no signal for this hour yet — it builds from passive screen observations over time.",
                ])

        case "next_action":
            guard let currentApp = req.currentApp, !currentApp.isEmpty else {
                return ToolResult(
                    success: false,
                    message: "next_action needs current_app — a bundle ID like com.apple.dt.Xcode.",
                    data: ["confidence": 0.0])
            }
            if let transition = service.predictNextTransition(currentApp: currentApp) {
                return ToolResult(
                    success: true,
                    message: transition.prediction,
                    data: [
                        "prediction": transition.prediction,
                        "confidence": transition.confidence,
                        "reasoning": "\(name(currentApp)) is the usual app at this hour; \(name(transition.bundleID)) dominates the following hour.",
                    ])
            }
            return ToolResult(
                success: true,
                message: "No habitual transition from \(name(currentApp)) at this hour.",
                data: [
                    "prediction": "",
                    "confidence": 0.0,
                    "reasoning": "The user isn't typically in that app at this hour, or the following hour has no dominant app.",
                ])

        case "habit_chain":
            let chains = service.getHabitChain().map { chain in
                chain.map(name).joined(separator: " → ")
            }
            return ToolResult(
                success: true,
                message: chains.isEmpty ? "No habitual chains learned yet." : chains.joined(separator: "\n"),
                data: [
                    "chains": chains,
                    "confidence": 0.0,
                    "reasoning": "The daily rhythm of dominant apps, consecutive repeats collapsed.",
                ])

        default:
            return .failure("Unknown action '\(req.action)'. Use next_app, next_action, or habit_chain.")
        }
    }
}
