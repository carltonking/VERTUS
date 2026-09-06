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

/// The panel's top-left slot (the old VERTUS logo button, whose job was
/// attach-file). Exactly TWO states, driven by "a turn is running AND no
/// text has arrived for the current view yet":
///   - `.plus`: at rest, and while output is streaming (text on screen).
///   - `.working`: the agent is working and nothing is on screen yet — the
///     logo spinner + "Working" label replace the plus until the first
///     text delta lands.
///
/// Queued turns (the selected agent is busy with an earlier prompt and this
/// view's prompt is behind it): the slot shows `.working` while nothing for
/// THIS view has arrived — but only until the holding run's next delta, at
/// which point the holding run is again the current run and its streaming
/// text is on screen (`.plus`; the queue depth is separately visible in the
/// fleet strip, "N queued").
public enum TopSlotPolicy {
    public enum State: Equatable {
        case plus
        case working
    }

    /// - Parameters:
    ///   - isStreaming: the selected agent has a running turn.
    ///   - turnHasText: the current view has received at least one text
    ///     delta from the running turn (first delta flips it to `.plus`).
    public static func state(isStreaming: Bool, turnHasText: Bool) -> State {
        (isStreaming && !turnHasText) ? .working : .plus
    }

    /// Whether the CURRENT run has produced visible text, derived from the
    /// transcript's last entry — scoped to the run in flight so a run
    /// started by another surface (routine, bot message, external prompt)
    /// never inherits "has text" from an older conversation. Accumulated
    /// flags went stale the moment the panel was opened while a turn was
    /// already running with prior text on screen.
    ///
    /// - Parameters:
    ///   - lastEntryRunID: the transcript's last entry's run id (nil when
    ///     the transcript is empty).
    ///   - currentRunID: the in-flight run (the store's lastRunID).
    ///   - lastEntryIsReply: the last entry is an assistant/vertus entry
    ///     (a user entry never counts as produced output).
    ///   - lastEntryText: the last entry's visible text.
    public static func currentRunHasVisibleText(lastEntryRunID: String?,
                                                currentRunID: String?,
                                                lastEntryIsReply: Bool,
                                                lastEntryText: String) -> Bool {
        guard lastEntryIsReply, let currentRunID, let lastEntryRunID,
              lastEntryRunID == currentRunID, !lastEntryText.isEmpty else { return false }
        return true
    }
}