//
//  AlfredUpdate.swift
//  Alfred
//
//  What the Mac pushes down the WebSocket. The socket carries JSON-RPC 2.0 frames
//  (the same wire shape Hermes ACP speaks over stdio); every *notification* the
//  phone cares about is decoded into one of these before it reaches a view, so the
//  UI never sees protocol noise — the same deal HermesEvent plays on the Mac side.
//

import Foundation

/// One thing that changed since the previous briefing. `type` drives iconography
/// ("calendar_added", "calendar_cancelled", "email_received", "reminder_set",
/// "weather_updated"); `title` is the row the Home tab shows.
struct BriefingChange: Codable, Equatable, Identifiable {
    var type: String
    var title: String
    var details: String
    var timestamp: TimeInterval

    /// Stable identity for lists and the detail sheet.
    var id: String { "\(type)-\(Int(timestamp))-\(title)" }
}

/// A fresh daily briefing pushed from the Mac — conversational summary prose,
/// everything that changed since the last one, and when the next one is due.
/// The Home tab re-renders from this without asking.
struct BriefingUpdate: Codable, Equatable {
    var summary: String
    var changes: [BriefingChange] = []
    var generatedAt: TimeInterval = 0
    var nextUpdateAt: TimeInterval = 0
    var focusedDay: String = "today"
    /// The self-optimization card, when the Mac has learned anything to report.
    var improvement: ImprovementCardPayload?

    /// Decode a briefing from a JSON-RPC `result` or `params` dictionary, as
    /// sent by the Mac's BriefingSocketServer. Tolerates the legacy wire shape
    /// where `changes` was a flat `[String]` of titles.
    static func fromJSON(_ params: [String: Any]) -> BriefingUpdate? {
        let summary = params["summary"] as? String ?? ""
        let changes: [BriefingChange]
        if let raw = params["changes"] as? [[String: Any]] {
            changes = raw.compactMap { dict in
                guard let title = dict["title"] as? String else { return nil }
                return BriefingChange(
                    type: dict["type"] as? String ?? "info",
                    title: title,
                    details: dict["details"] as? String ?? "",
                    timestamp: dict["timestamp"] as? TimeInterval ?? 0)
            }
        } else if let titles = params["changes"] as? [String] {
            changes = titles.map {
                BriefingChange(type: "info", title: $0, details: "", timestamp: 0)
            }
        } else {
            changes = []
        }
        guard !summary.isEmpty || !changes.isEmpty else { return nil }
        let improvement = (params["improvement"] as? [String: Any]).flatMap(ImprovementCardPayload.fromJSON)
        return BriefingUpdate(
            summary: summary,
            changes: changes,
            generatedAt: params["generatedAt"] as? TimeInterval ?? 0,
            nextUpdateAt: params["nextUpdateAt"] as? TimeInterval ?? 0,
            focusedDay: params["focusedDay"] as? String ?? "today",
            improvement: improvement)
    }
}

/// One event the phone received from Alfred over the socket.
enum AlfredUpdate: Equatable {
    case briefingUpdate(BriefingUpdate)
    /// Incremental assistant text. `isStreaming` is true for in-flight chunks and
    /// false for the final complete reply, so the UI can show a cursor.
    case chatMessage(text: String, isStreaming: Bool)
    /// A routine began running on the Mac (scheduled or Run Now).
    case routineStarted(routineID: String, name: String)
    /// A routine advanced a step — drives the "Running: step 1/5…" banner.
    case routineProgress(routineID: String, name: String, step: Int, total: Int, label: String)
    /// A routine finished, with its outcome.
    case routineCompleted(routineID: String, name: String, success: Bool, duration: TimeInterval, output: String)
    /// Routine metadata changed on the Mac outside a lifecycle event (the
    /// taste polish rewriting a created routine's name/description) — the
    /// Routines tab refreshes its list.
    case routinesChanged
    /// A chunk of code-session output streamed from the Mac's coding agent.
    case codeChunk(sessionID: String, text: String)
    /// A code session changed state (generating/paused/completed/error).
    case codeSessionStatus(sessionID: String, status: String)
    /// A test run finished on the Mac.
    case codeTestResult(sessionID: String, success: Bool, output: String, duration: TimeInterval, command: String)
    /// The Mac refreshed a session's git state.
    case codeGitStatus(sessionID: String, branch: String, uncommitted: Int)
    /// A mail sync pass finished on the Mac (background or pull-to-refresh) —
    /// `synced` messages landed, and the unified unread count is now `unread`.
    case mailSyncComplete(synced: Int, unread: Int, failedAccounts: [String])
    /// The Mac's total unread count changed — new mail arrived, or mail was
    /// read/archived somewhere. Drives the tab badge without a re-fetch.
    case mailUnreadChanged(unread: Int)
    /// A full folder sweep finished on the Mac — fresh folder stats, important
    /// finds, and any "important mail in Junk" rescue candidates.
    case mailScanComplete(MailScanSummaryPayload)
    /// The application tracker changed on the Mac (applied, status updated,
    /// deleted) — the Jobs tab refreshes its counts without asking.
    case careerApplicationsChanged(CareerSummaryPayload)
    case codeUpdate(code: String, language: String)
    case pushNotification(title: String, body: String)
    case error(message: String)
}

/// Maps a JSON-RPC notification (method + params) to an `AlfredUpdate`.
///
/// Pure and independent of the socket, so the mapping is testable without a
/// connection: feed it the exact dictionaries the Mac's server would send.
enum AlfredUpdateParser {
    static func parse(method: String, params: [String: Any]) -> AlfredUpdate? {
        switch method {
        case "briefing.update":
            guard let update = BriefingUpdate.fromJSON(params) else { return nil }
            return .briefingUpdate(update)

        case "session/update":
            // The ACP update envelope nests the real event under `params.update`.
            guard let update = params["update"] as? [String: Any] else { return nil }
            return parseSessionUpdate(update)

        case "routine.started":
            // New wire shape carries routine_id + routine_name; the legacy shape
            // used `name`.
            let startedName = params["routine_name"] as? String ?? params["name"] as? String ?? ""
            guard !startedName.isEmpty else { return nil }
            return .routineStarted(routineID: params["routine_id"] as? String ?? "", name: startedName)

        case "routine.progress":
            guard let progressName = params["routine_name"] as? String, !progressName.isEmpty else { return nil }
            return .routineProgress(
                routineID: params["routine_id"] as? String ?? "",
                name: progressName,
                step: params["step"] as? Int ?? 0,
                total: params["steps_total"] as? Int ?? 0,
                label: params["step_label"] as? String ?? "")

        case "routine.completed":
            let completedName = params["routine_name"] as? String ?? params["name"] as? String ?? ""
            guard !completedName.isEmpty else { return nil }
            return .routineCompleted(
                routineID: params["routine_id"] as? String ?? "",
                name: completedName,
                success: params["success"] as? Bool ?? false,
                duration: params["duration"] as? TimeInterval ?? 0,
                output: params["output"] as? String ?? params["result"] as? String ?? "")

        case "routines.changed":
            return .routinesChanged

        case "code.chunk":
            guard let text = params["text"] as? String else { return nil }
            return .codeChunk(sessionID: params["session_id"] as? String ?? "", text: text)

        case "code.status":
            guard let status = params["status"] as? String else { return nil }
            return .codeSessionStatus(sessionID: params["session_id"] as? String ?? "", status: status)

        case "code.test_result":
            guard let success = params["success"] as? Bool else { return nil }
            return .codeTestResult(
                sessionID: params["session_id"] as? String ?? "",
                success: success,
                output: params["output"] as? String ?? "",
                duration: params["duration"] as? TimeInterval ?? 0,
                command: params["command"] as? String ?? "")

        case "code.git_status":
            guard let branch = params["current_branch"] as? String else { return nil }
            return .codeGitStatus(
                sessionID: params["session_id"] as? String ?? "",
                branch: branch,
                uncommitted: params["uncommitted_changes"] as? Int ?? 0)

        case "code.update":
            guard let code = params["code"] as? String else { return nil }
            return .codeUpdate(code: code, language: params["language"] as? String ?? "")

        case "mail.sync_complete":
            return .mailSyncComplete(
                synced: params["synced"] as? Int ?? 0,
                unread: params["unread"] as? Int ?? 0,
                failedAccounts: params["failed_accounts"] as? [String] ?? [])

        case "mail.unread_count_changed":
            return .mailUnreadChanged(unread: params["unread"] as? Int ?? 0)

        case "mail.scan_complete":
            guard let scan = MailScanSummaryPayload.fromJSON(params) else { return nil }
            return .mailScanComplete(scan)

        case "career.applications_changed":
            guard let summary = CareerSummaryPayload.fromJSON(params) else { return nil }
            return .careerApplicationsChanged(summary)

        case "push.notification":
            guard let title = params["title"] as? String else { return nil }
            return .pushNotification(title: title, body: params["body"] as? String ?? "")

        case "error":
            return .error(message: params["message"] as? String ?? "Alfred's Mac reported an error.")

        default:
            // Unknown methods are dropped, not surfaced — the phone shouldn't
            // invent meaning for protocol noise.
            return nil
        }
    }

    /// The ACP `session/update` variants we can render on a phone. Content blocks
    /// are `{type, text}`; non-text blocks (image, audio) have no text and are
    /// skipped rather than rendered as an empty string.
    private static func parseSessionUpdate(_ update: [String: Any]) -> AlfredUpdate? {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            guard let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String,
                  !text.isEmpty else { return nil }
            return .chatMessage(text: text, isStreaming: true)

        case "agent_message_delta", "agent_message":
            guard let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String,
                  !text.isEmpty else { return nil }
            return .chatMessage(text: text, isStreaming: update["sessionUpdate"] as? String == "agent_message_delta")

        case "tool_call":
            // The call id is useful later (to pair with a tool result); the phone
            // only needs the human title today.
            guard update["toolCallId"] != nil else { return nil }
            let title = update["title"] as? String ?? "Working…"
            return .chatMessage(text: "🔧 \(title)", isStreaming: false)

        default:
            // plan / usage / permission requests — not surfaced on the phone yet.
            return nil
        }
    }
}
