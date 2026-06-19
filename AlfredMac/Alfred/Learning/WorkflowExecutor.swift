import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.alfred.app", category: "WorkflowExecutor")

enum WorkflowExecutionStatus {
    case notStarted
    case running(stepIndex: Int, stepTitle: String)
    case completed
    case failed(stepIndex: Int, reason: String)
    case cancelled
}

@MainActor
final class WorkflowExecutor {
    var onStatusChange: ((WorkflowExecutionStatus) -> Void)?
    var onQueryRequest: ((String) -> Void)?

    private(set) var status: WorkflowExecutionStatus = .notStarted
    private var isCancelled = false

    func execute(_ workflow: Workflow) {
        status = .running(stepIndex: 0, stepTitle: workflow.steps.first?.title ?? "")
        isCancelled = false
        onStatusChange?(status)

        Task {
            for (index, step) in workflow.steps.enumerated() {
                guard !isCancelled else {
                    status = .cancelled
                    onStatusChange?(status)
                    return
                }

                status = .running(stepIndex: index, stepTitle: step.title)
                onStatusChange?(status)

                switch step.type {
                case .query:
                    onQueryRequest?(step.title)

                case .notify:
                    notifyUser(title: workflow.title, body: step.title)

                case .wait:
                    try? await Task.sleep(nanoseconds: 2_000_000_000)

                case .confirm:
                    guard await confirmStep(step.title) else {
                        status = .cancelled
                        onStatusChange?(status)
                        return
                    }

                case .execute:
                    notifyUser(title: "Executing", body: step.title)
                }
            }

            guard !isCancelled else {
                status = .cancelled
                onStatusChange?(status)
                return
            }

            status = .completed
            onStatusChange?(status)
            notifyUser(title: "Workflow Complete", body: "Finished: \(workflow.title)")
        }
    }

    func cancel() {
        isCancelled = true
    }

    private func notifyUser(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func confirmStep(_ title: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Workflow Confirmation"
                alert.informativeText = title
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Continue")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
