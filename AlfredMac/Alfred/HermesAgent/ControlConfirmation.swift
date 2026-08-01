import AppKit
import Foundation

/// A pending request for the user to approve computer control.
struct PendingControlConfirmation: Identifiable, Equatable {
    let id = UUID()
    /// The resolved action list — what will actually happen, not the model's script.
    let summary: String
}

/// Bridges a background MCP tool call to a confirmation drawn in the Alfred bar.
///
/// Replaces the `NSAlert` this used to use. That alert *displayed* but dismissed
/// itself after 2-4s and returned `alertFirstButtonReturn` with nobody touching
/// the machine — it auto-approved, making the gate worthless. The cause was never
/// identified, but the shape of the bug is clear enough: driving an AppKit modal
/// session from a background-initiated call, in an `.accessory` app whose own
/// event monitors are live, is not something we control end to end.
///
/// This design avoids modal sessions entirely. The tool call suspends on a
/// continuation while the main thread stays free to render the bar and handle
/// clicks, and nothing can resolve the continuation except an explicit user
/// action or the timeout.
///
/// Two properties matter more than the UI:
///   * **Fails closed.** Timeout, a second concurrent request, or a missing
///     AppDelegate all deny. There is no path that approves by default.
///   * **Resolves exactly once.** The continuation is cleared before it is
///     resumed, so a click racing the timeout cannot resume it twice (which
///     would trap).
@MainActor
final class ControlConfirmationBroker {

    static let shared = ControlConfirmationBroker()

    /// How long to wait before denying. Long enough to read a multi-step plan,
    /// short enough that an unattended Mac doesn't leave an agent turn hanging.
    static let timeout: TimeInterval = 90

    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    /// Ask the user to approve `summary`. Suspends until they answer or it times out.
    func confirm(summary: String) async -> Bool {
        guard let delegate = AppDelegate.shared else { return false }

        // One at a time. A second request while one is open is denied rather than
        // queued — queueing would let a later approval be attributed to an
        // earlier, different plan.
        guard continuation == nil else { return false }

        delegate.presentControlConfirmation(.init(summary: summary))

        let approved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            continuation = c
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resolve(false, source: "timeout")
            }
        }
        return approved
    }

    /// Called by the bar's Run / Don't Run buttons, and by the timeout.
    ///
    /// `source` is not consumed — it labels the call sites so that "who approved
    /// this?" is answerable by reading, and so a diagnostic can be reattached
    /// without re-deriving it. Distinguishing a user click from an unattended
    /// resolution is exactly what was needed to characterise the NSAlert bug.
    func resolve(_ approved: Bool, source: String = "unspecified") {
        _ = source
        timeoutTask?.cancel()
        timeoutTask = nil
        AppDelegate.shared?.dismissControlConfirmation()

        // Clear before resuming: a click landing at the same moment as the
        // timeout must not resume the same continuation twice.
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: approved)
    }

    /// True while a confirmation is on screen — lets Esc handling prefer denying
    /// the request over collapsing the bar.
    var isAwaitingDecision: Bool { continuation != nil }
}
