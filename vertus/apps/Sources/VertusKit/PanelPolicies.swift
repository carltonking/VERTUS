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

/// Whether the CURRENT run has produced visible text. This drives the
/// in-session-window "Working" indicator (logo spinner + label, shown in
/// the transcript area in the position the reply will occupy): the agent is
/// working and no text has arrived for the current view yet.
///
/// Derived from the transcript's last entry — scoped to the run in flight
/// so a run started by another surface (routine, bot message, external
/// prompt) never inherits "has text" from an older conversation. Accumulated
/// flags went stale the moment the panel was opened while a turn was
/// already running with prior text on screen.
///
/// Queued turns (the selected agent is busy with an earlier prompt and this
/// view's prompt is behind it): Working shows while nothing for THIS view
/// has arrived — until the holding run's next delta re-establishes it as
/// the current run and its streaming text is on screen (the queue depth is
/// separately visible in the fleet strip, "N queued").
public enum WorkingIndicatorPolicy {
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

/// The panel's transcript mirror: store entries minus the new-session cut,
/// minus empty non-user entries (an assistant entry with no visible text is
/// represented by the in-window Working indicator instead of an empty pill).
///
/// Extracted from QuickBarViewModel.syncSelected so the panel's mirror
/// construction is unit-testable — the pin for the class of bug where a
/// streamed reply silently fails to appear in the panel. ANY text delta
/// that reaches the store's transcript must survive this filter.
public struct PanelMirrorRow: Equatable {
    public let source: TranscriptEntry
    public let text: String

    public init(source: TranscriptEntry, text: String) {
        self.source = source
        self.text = text
    }
}

public enum PanelMirrorPolicy {
    /// Build the panel's visible mirror rows from the store transcript under
    /// the current new-session cut.
    public static func visible(entries: [TranscriptEntry], cut: BarViewCut) -> [PanelMirrorRow] {
        entries.compactMap { entry in
            guard let text = cut.visibleText(of: entry) else { return nil }
            guard !text.isEmpty || entry.role == "user" else { return nil }
            return PanelMirrorRow(source: entry, text: text)
        }
    }
}