// MARK: - Action class

enum ActionClass: CaseIterable {
    case readOnly
    case localMutation
    case externalCommunication
    case systemExecution
}

// MARK: - Action type registry

enum ActionType: String, CaseIterable {
    case respondText = "respond_text"
    case openApplication = "open_application"
    case searchFiles = "search_files"
    case createFile = "create_file"
    case editFile = "edit_file"
    case scheduleCalendarEvent = "schedule_calendar_event"
    case sendMessage = "send_message"
    case queryMemory = "query_memory"
    case systemCommand = "system_command"
}

// MARK: - Policy registry

struct ActionPolicyRegistry {

    /// Maps an ActionType to its class, risk level, and confirmation requirement.
    static func actionClass(for actionType: ActionType) -> ActionClass {
        switch actionType {
        case .searchFiles, .queryMemory, .respondText:
            return .readOnly
        case .openApplication, .createFile, .editFile:
            return .localMutation
        case .scheduleCalendarEvent, .sendMessage:
            return .externalCommunication
        case .systemCommand:
            return .systemExecution
        }
    }

    static func riskLevel(for actionType: ActionType) -> ActionRiskLevel {
        switch actionClass(for: actionType) {
        case .readOnly:
            return .low
        case .localMutation:
            switch actionType {
            case .openApplication:
                return .low
            case .createFile, .editFile:
                return .medium
            default:
                return .medium
            }
        case .externalCommunication:
            return .high
        case .systemExecution:
            return .high
        }
    }

    static func requiresConfirmation(for actionType: ActionType) -> Bool {
        switch actionClass(for: actionType) {
        case .readOnly:
            return false
        case .localMutation:
            switch actionType {
            case .openApplication:
                return false
            case .createFile, .editFile:
                return true
            default:
                return true
            }
        case .externalCommunication:
            return true
        case .systemExecution:
            return true
        }
    }

    // MARK: - String-based helpers (bridge from codebase string conventions)

    static func actionClass(for actionType: String) -> ActionClass {
        guard let type = ActionType(rawValue: actionType) else { return .systemExecution }
        return actionClass(for: type)
    }

    static func riskLevel(for actionType: String) -> ActionRiskLevel {
        guard let type = ActionType(rawValue: actionType) else { return .high }
        return riskLevel(for: type)
    }

    static func requiresConfirmation(for actionType: String) -> Bool {
        guard let type = ActionType(rawValue: actionType) else { return true }
        return requiresConfirmation(for: type)
    }

    /// Asserts policy coverage — the exhaustive switch in actionClass(for:)
    /// already guarantees all ActionType cases are mapped at compile time.
    /// This method exists as an explicit signal that coverage validation matters.
    static func validatePolicyCoverage() {
        for type in ActionType.allCases {
            _ = actionClass(for: type)
            _ = riskLevel(for: type)
            _ = requiresConfirmation(for: type)
        }
    }
}
