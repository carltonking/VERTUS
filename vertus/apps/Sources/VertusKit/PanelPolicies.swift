import Foundation

/// Panel Escape-stop decision (Bug B9). Two presses while a turn is active:
/// the first stops the run, the second closes the panel. A press with
/// nothing running closes immediately. Pure logic so the panel's behavior
/// is unit-tested instead of click-verified.
public enum PanelEscapePolicy {
    public enum Action: Equatable {
        /// Stop the selected agent's active run (keep the panel open).
        case stopRun
        /// Close the panel (retract into the notch).
        case closePanel
    }

    /// - Parameters:
    ///   - isTurnActive: the selected agent has a running or blocked turn.
    ///   - stopPending: the previous Escape press already issued a stop (the
    ///     run may still be unwinding server-side, so `isTurnActive` can be
    ///     true while the stop is in flight — the second press must close).
    public static func nextAction(isTurnActive: Bool, stopPending: Bool) -> Action {
        if stopPending { return .closePanel }
        if isTurnActive { return .stopRun }
        return .closePanel
    }
}

/// QuickBar busy-strip rendering policy (Bugs B7/B10): which decorations a
/// strip entry shows. The busy dot was decorative — presence in the strip
/// already means busy — and was removed outright. The per-bot stop button
/// is the ONLY way to stop a background bot from the panel, so it stays for
/// every agent EXCEPT the selected one: the selected agent's run is stopped
/// with Escape (PanelEscapePolicy), so its stop button was redundant noise
/// next to the chat's "working" bubble.
public enum BusyStripPolicy {
    /// Whether the strip shows a stop button for this agent.
    public static func showsStopButton(agentID: String, selectedAgentID: String) -> Bool {
        agentID != selectedAgentID
    }
}