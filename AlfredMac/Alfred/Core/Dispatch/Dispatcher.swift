import Foundation

/// Blueprint v1 §4 command classes — the safety backbone. The dispatcher proposes one;
/// the policy/confirmation rules dispose. `unattendedSafe` is reserved for routines (M2).
enum CommandClass: String {
    case readOnly = "read-only"
    case lowRiskWrite = "low-risk write"
    case highRiskWrite = "high-risk write"
    case cloudSensitive = "cloud-sensitive"
    case unattendedSafe = "unattended-safe"
}

enum Route: String {
    case local
    case cloud
}

/// The dispatcher's proposal for a single command.
struct DispatchDecision {
    /// Query with any manual `local:`/`cloud:` prefix stripped.
    let query: String
    let actionType: ActionType
    let commandClass: CommandClass
    let route: Route
    let routeReason: String
    let confirmRequired: Bool
    let forcedByPrefix: Bool

    /// One-line transparency string shown under the AlfredBar result (Blueprint §3).
    func routingLine(model: String, egressSummary: String) -> String {
        let mark = route == .local
            ? "✓ Local"
            : "☁ \(model.isEmpty ? "Cloud" : model.capitalized)"
        var parts = [mark, commandClass.rawValue]
        parts.append(route == .cloud
            ? (egressSummary.isEmpty ? "sent" : egressSummary)
            : "nothing left device")
        parts.append(routeReason)
        return parts.joined(separator: " · ")
    }
}

/// Stage-1 dispatcher (Blueprint v1 §4), rules-based for M1.
///
/// Classifies an AlfredBar command into a command class + route (local/cloud) + tool, and
/// flags whether confirmation is required and whether content is cloud-sensitive. Fully
/// deterministic and on-device. A local model replaces the keyword rules in M6 — but the
/// *policy* (class → confirmation, sensitive → redact) stays here, independent of the
/// model, so a wrong classification can never leak data or skip a confirmation.
struct Dispatcher {

    private let redactor: Redactor

    init(redactor: Redactor = Redactor()) {
        self.redactor = redactor
    }

    func decide(query rawQuery: String, providerIsCloud: Bool) -> DispatchDecision {
        // 1. Manual override prefixes (Blueprint §11 escape hatch).
        var query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var forcedRoute: Route?
        if let stripped = strip(prefix: "cloud:", from: query) {
            query = stripped
            forcedRoute = .cloud
        } else if let stripped = strip(prefix: "local:", from: query) {
            query = stripped
            forcedRoute = .local
        }

        // 2. Classify the action via keyword rules.
        let actionType = classify(query)

        // 3. Deterministic content checks, independent of the action type.
        let sensitive = redactor.redact(query).didRedact
        let destructive = isDestructive(query)

        // 4. Map to the blueprint's five command classes.
        let commandClass = Self.commandClass(for: actionType, sensitive: sensitive, destructive: destructive)

        // 5. Confirmation. User preference (2026-06-16): only DESTRUCTIVE actions
        //    (delete/remove/erase/trash/wipe/rm -rf/drop table/format) prompt for confirmation.
        //    Send-message and shell/system commands now run without a confirmation dialog. The
        //    command *class* (mapped below) is unchanged — send/shell stay high-risk in the audit
        //    log; they simply no longer block on a prompt.
        let confirmRequired = destructive

        // 6. Route. The blueprint dispatcher decides local-vs-cloud; with a user-selected
        //    provider in M1, the active provider determines reachability and a manual
        //    prefix overrides it.
        let route: Route
        let routeReason: String
        if let forced = forcedRoute {
            route = forced
            routeReason = "manual \(forced.rawValue): prefix"
        } else if providerIsCloud {
            route = .cloud
            routeReason = commandClass == .readOnly ? "read-only, no local model active" : "general query"
        } else {
            route = .local
            routeReason = "handled on device"
        }

        return DispatchDecision(
            query: query,
            actionType: actionType,
            commandClass: commandClass,
            route: route,
            routeReason: routeReason,
            confirmRequired: confirmRequired,
            forcedByPrefix: forcedRoute != nil
        )
    }

    // MARK: - Rules

    private func classify(_ query: String) -> ActionType {
        let q = query.lowercased()
        func any(_ keywords: [String]) -> Bool { keywords.contains { q.contains($0) } }

        if any(["send email", "send message", "send a message", "email to", "reply to", "forward ", "send the email"]) {
            return .sendMessage
        }
        if any(["run command", "execute command", "terminal ", "bash ", "shell ", "run script", "run: "]) {
            return .systemCommand
        }
        if any(["open ", "launch ", "start app"]) {
            return .openApplication
        }
        if any(["schedule", "calendar", "appointment", "meeting on", "event on", "remind me"]) {
            return .scheduleCalendarEvent
        }
        if any(["create file", "write a file", "save as", "save this", "new file", "new document", "export", "make a file", "write this", "create a"]) {
            return .createFile
        }
        if any(["edit ", "modify ", "rewrite ", "append ", "change the file"]) {
            return .editFile
        }
        if any(["find ", "search ", "locate ", "where is ", "look for "]) {
            return .searchFiles
        }
        if any(["remember", "recall", "what did", "earlier you"]) {
            return .queryMemory
        }
        return .respondText
    }

    private func isDestructive(_ query: String) -> Bool {
        let q = query.lowercased()
        return ["delete", "remove ", "erase", "trash ", "wipe", "rm -rf", "drop table", "format "].contains { q.contains($0) }
    }

    static func commandClass(for actionType: ActionType, sensitive: Bool, destructive: Bool) -> CommandClass {
        if sensitive { return .cloudSensitive }
        if destructive { return .highRiskWrite }
        switch actionType {
        case .respondText, .searchFiles, .queryMemory:
            return .readOnly
        case .openApplication, .createFile, .editFile, .scheduleCalendarEvent:
            return .lowRiskWrite
        case .sendMessage, .systemCommand:
            return .highRiskWrite
        }
    }

    private func strip(prefix: String, from text: String) -> String? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
