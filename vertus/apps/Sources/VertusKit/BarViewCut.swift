import Foundation

/// The QuickBar panel's "new session" is a VIEW reset, never a server-side
/// one: the hub keeps each agent's full transcript and run history, and the
/// panel transcript is a live mirror of the store's per-agent state. This
/// type owns the cut applied to that mirror.
///
/// Cut semantics (see QuickBarViewModel.newSession):
///   - everything on screen when the cut is made is hidden from the mirror;
///   - if a reply is mid-stream (isRunning with a trailing assistant entry),
///     that reply is NOT hidden — it is re-anchored so only the text that
///     streams AFTER the cut shows, and it keeps growing in place (the store
///     grows one entry per reply, same id, so a simple id-filter would lose
///     it entirely);
///   - nothing here touches the store or the hub — the mirror only.
///
/// Pure value logic, no AppKit: unit-tested in VertusKitTests.
public final class BarViewCut {
    /// Entry ids hidden by the current cut.
    private var hiddenIDs: Set<String> = []
    /// The re-anchored in-flight reply: its id and the text length at cut
    /// time. Only text beyond that prefix is shown as it streams.
    private var tailPrefix: (id: String, prefixLen: Int)?

    public init() {}

    /// No cut active — every entry is visible in full.
    public var isIdle: Bool { hiddenIDs.isEmpty && tailPrefix == nil }

    /// Apply a fresh cut against the current live transcript.
    public func cut(entries: [TranscriptEntry], isRunning: Bool) {
        hiddenIDs = []
        tailPrefix = nil
        if isRunning, let last = entries.last, last.role == "assistant" {
            tailPrefix = (last.id, last.text.count)
            hiddenIDs = Set(entries.filter { $0.id != last.id }.map(\.id))
        } else {
            hiddenIDs = Set(entries.map(\.id))
        }
    }

    /// Drop the cut (agent switch, panel restart) — full mirror again.
    public func reset() {
        hiddenIDs = []
        tailPrefix = nil
    }

    /// The text to display for `entry`, or nil when the cut hides it.
    /// For the re-anchored in-flight reply, text is truncated to the part
    /// that streamed after the cut ("" until the next delta arrives).
    public func visibleText(of entry: TranscriptEntry) -> String? {
        if hiddenIDs.contains(entry.id) { return nil }
        if let tail = tailPrefix, tail.id == entry.id {
            return String(entry.text.dropFirst(min(tail.prefixLen, entry.text.count)))
        }
        return entry.text
    }
}
