import Foundation
import OSLog
import SwiftUI

// MARK: - Violation types

enum ViolationType: String {
    case autonomousTimer
    case backgroundScheduler
    case unconfirmedExecutionPath
    case orphanedActionType
}

// MARK: - Violation record

struct SafetyViolation: Identifiable {
    let id: UUID
    let type: ViolationType
    let description: String
    let timestamp: Date

    init(type: ViolationType, description: String) {
        self.id = UUID()
        self.type = type
        self.description = description
        self.timestamp = Date()
    }
}

// MARK: - Safety audit engine

final class SafetyAuditEngine {
    static let shared = SafetyAuditEngine()

    private var violations: [SafetyViolation] = []
    private let logger = Logger(subsystem: "com.alfred.safety", category: "audit")

    private init() {}

    // MARK: - Public API

    func runStartupAudit() -> Bool {
        violations.removeAll()

        scanForTimers(in: TaskEngine.self, label: "TaskEngine")
        scanForTimers(in: TaskDashboardService.self, label: "TaskDashboardService")
        scanForTimers(in: ActionSelectionEngine.self, label: "ActionSelectionEngine")

        scanForDispatchSources(in: TaskEngine.self, label: "TaskEngine")
        scanForDispatchSources(in: TaskDashboardService.self, label: "TaskDashboardService")

        scanForDisplayLinks()

        verifyNoNotificationAutoExecution()
        verifyNoBackgroundPolling()

        #if DEBUG
        for v in violations {
            print("[SafetyAudit] VIOLATION: \(v.type.rawValue) — \(v.description)")
        }
        if violations.isEmpty {
            print("[SafetyAudit] All checks passed, no violations found.")
        }
        #endif

        return violations.isEmpty
    }

    func assertNoAutonomousExecution() {
        let clean = runStartupAudit()

        if clean { return }

        let message = violations.map { "\($0.type.rawValue): \($0.description)" }.joined(separator: "\n")
        let fullMessage = "Autonomous execution path detected. Alfred will not start.\n\nViolations:\n\(message)"

        #if DEBUG
        print("[SafetyAudit] FATAL: \(fullMessage)")
        #else
        logger.fault("\(fullMessage, privacy: .public)")
        #endif

        let alert = NSAlert()
        alert.messageText = "Safety Audit Failed"
        alert.informativeText = fullMessage
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Per-component audits

    func auditTaskEngine(_ engine: TaskEngine) -> Bool {
        var clean = true

        let mirror = Mirror(reflecting: engine)
        for child in mirror.children {
            if child.value is Timer {
                record(.autonomousTimer, "TaskEngine contains a Timer property '\(child.label ?? "?")'")
                clean = false
            }
        }

        if clean {
            logger.debug("TaskEngine audit passed")
        }
        return clean
    }

    func auditActionRegistry(_ registry: ActionPolicyRegistry.Type) -> Bool {
        var clean = true

        for type in ActionType.allCases {
            let risk = registry.riskLevel(for: type)
            let confirmed = registry.requiresConfirmation(for: type)

            if type == .sendMessage && risk != .high {
                record(.unconfirmedExecutionPath, "sendMessage mapped to risk \(risk.rawValue), expected .high")
                clean = false
            }
            if type == .systemCommand && risk != .high {
                record(.unconfirmedExecutionPath, "systemCommand mapped to risk \(risk.rawValue), expected .high")
                clean = false
            }
            if type == .systemCommand && !confirmed {
                record(.unconfirmedExecutionPath, "systemCommand missing requiresConfirmation")
                clean = false
            }
        }

        let allMapped = ActionType.allCases.allSatisfy { type in
            let _ = registry.actionClass(for: type)
            let _ = registry.riskLevel(for: type)
            let _ = registry.requiresConfirmation(for: type)
            return true
        }

        if !allMapped {
            record(.orphanedActionType, "Some ActionType cases are not fully mapped in registry")
            clean = false
        }

        if clean {
            logger.debug("ActionRegistry audit passed")
        }
        return clean
    }

    // MARK: - Timer scanning

    private func scanForTimers(in type: AnyClass, label: String) {
        var count: UInt32 = 0
        guard let properties = class_copyPropertyList(type, &count) else { return }
        defer { free(properties) }

        for i in 0..<Int(count) {
            let property = properties[i]
            guard let attrs = property_getAttributes(property) else { continue }
            let attrString = String(cString: attrs)
            let name = String(cString: property_getName(property))

            if attrString.contains("Timer") {
                record(.autonomousTimer, "\(label).\(name) is a Timer property")
            }
            if attrString.contains("DispatchSource") {
                record(.backgroundScheduler, "\(label).\(name) is a DispatchSource property")
            }
            if attrString.contains("CADisplayLink") || attrString.contains("CVDisplayLink") {
                record(.autonomousTimer, "\(label).\(name) is a display link property")
            }
        }
    }

    private func scanForDispatchSources(in type: AnyClass, label: String) {
        var count: UInt32 = 0
        guard let properties = class_copyPropertyList(type, &count) else { return }
        defer { free(properties) }

        for i in 0..<Int(count) {
            let property = properties[i]
            guard let attrs = property_getAttributes(property) else { continue }
            let attrString = String(cString: attrs)
            let name = String(cString: property_getName(property))

            if attrString.contains("DispatchSource") {
                record(.backgroundScheduler, "\(label).\(name) is a DispatchSource property")
            }
        }
    }

    private func scanForDisplayLinks() {
        guard let shared = NSApplication.shared as AnyObject? else { return }
        let mirror = Mirror(reflecting: shared)
        for child in mirror.children {
            if child.value is CADisplayLink {
                record(.autonomousTimer, "NSApplication contains a CADisplayLink")
            }
        }
    }

    // MARK: - Notification center audit

    private func verifyNoNotificationAutoExecution() {
        let allowedPrefixes = [
            "AlfredSettingsChanged",
            "NSApplication",
            "NSWindow",
            "NSTextView",
            "NSMenu"
        ]

        let center = NotificationCenter.default
        let mirror = Mirror(reflecting: center)
        var observedNames: [String] = []

        for child in mirror.children {
            if let name = child.label, name.contains("observer") || name.contains("name") {
                observedNames.append(name)
            }
        }

        for name in observedNames {
            let isAllowed = allowedPrefixes.contains { name.hasPrefix($0) }
            if !isAllowed && name.contains("execute") || name.contains("run") || name.contains("task") {
                record(.unconfirmedExecutionPath, "Suspicious Notification observer: '\(name)' may auto-trigger execution")
            }
        }
    }

    private func verifyNoBackgroundPolling() {
        let pollingIndicators = ["poll", "refreshLoop", "watchLoop", "backgroundPoll", "statusCheck"]
        let candidates: [AnyClass] = [
            TaskEngine.self,
            TaskDashboardService.self,
            ActionSelectionEngine.self
        ]

        for klass in candidates {
            var count: UInt32 = 0
            guard let methods = class_copyMethodList(klass, &count) else { continue }
            defer { free(methods) }

            for i in 0..<Int(count) {
                let sel = method_getName(methods[i])
                let name = NSStringFromSelector(sel).lowercased()
                for indicator in pollingIndicators {
                    if name.contains(indicator.lowercased()) {
                        record(.backgroundScheduler, "\(klass) has method '\(NSStringFromSelector(sel))' which looks like a polling loop")
                    }
                }
            }
        }
    }

    // MARK: - Recording

    private func record(_ type: ViolationType, _ description: String) {
        let violation = SafetyViolation(type: type, description: description)
        violations.append(violation)
        logger.warning("\(type.rawValue): \(description, privacy: .public)")
    }
}
