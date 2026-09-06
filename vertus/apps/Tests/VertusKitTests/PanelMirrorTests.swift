import XCTest
@testable import VertusKit

/// The panel's transcript mirror, pinned. The regression this guards: a
/// streamed reply silently failing to appear in the panel's session window.
/// The mirror filter (PanelMirrorPolicy) is the exact code QuickBarViewModel
/// runs — any text delta that reaches the store's per-agent transcript must
/// produce a visible row here, and the first delta must be visible in full
/// (the in-window Working indicator is replaced in place by the reply).
final class PanelMirrorTests: XCTestCase {
    private let cut = BarViewCut()

    /// THE pin: a live text delta (with the model's typical leading-newline
    /// preamble) produces a visible transcript row in the panel's mirror.
    func testTextDeltaProducesVisibleMirrorRow() {
        let state = AgentLiveState(agentID: "primary")
        state.appendLocalUserEntry(runID: "run-1", text: "hi")
        state.appendDelta(runID: "run-1", text: "\n\nAs requested, sir — here it is.")

        let rows = PanelMirrorPolicy.visible(entries: state.transcript, cut: cut)

        XCTAssertEqual(rows.count, 2, "user entry + the streamed reply must both be visible")
        guard let reply = rows.last else { return }
        XCTAssertEqual(reply.source.role, "assistant")
        XCTAssertEqual(reply.text, "As requested, sir — here it is.",
                       "the delta survives the mirror (leading whitespace trimmed at entry-open)")
    }

    /// A growing reply: the same entry keeps its identity while text appends,
    /// so the mirror row shows the FULL accumulated text, not just one delta.
    func testGrowingReplyStaysOneVisibleRow() {
        let state = AgentLiveState(agentID: "primary")
        state.appendLocalUserEntry(runID: "run-1", text: "hi")
        state.appendDelta(runID: "run-1", text: "Hello")
        state.appendDelta(runID: "run-1", text: " world")
        state.appendDelta(runID: "run-1", text: "!")

        let rows = PanelMirrorPolicy.visible(entries: state.transcript, cut: cut)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.text, "Hello world!")
    }

    /// A user entry is always visible, even before any reply exists.
    func testUserEntryVisibleWhileReplyPending() {
        let state = AgentLiveState(agentID: "primary")
        state.appendLocalUserEntry(runID: "run-1", text: "hi")

        let rows = PanelMirrorPolicy.visible(entries: state.transcript, cut: cut)

        XCTAssertEqual(rows.map(\.source.role), ["user"])
        XCTAssertEqual(rows.first?.text, "hi")
    }

    /// An assistant entry with no visible text (post-cut re-anchor before the
    /// next delta) produces NO row — the in-window Working indicator covers
    /// that state, not an empty pill.
    func testEmptyAssistantEntryDropped() {
        let state = AgentLiveState(agentID: "primary")
        state.appendDelta(runID: "run-1", text: "   \n  ")  // whitespace-only first delta

        let rows = PanelMirrorPolicy.visible(entries: state.transcript, cut: cut)
        XCTAssertTrue(rows.isEmpty)
    }

    /// After a new-session cut, pre-cut entries are hidden but the re-anchored
    /// in-flight reply streams in — the post-cut tail only.
    func testCutHidesOldConversationButStreamsTail() {
        let state = AgentLiveState(agentID: "primary")
        state.appendLocalUserEntry(runID: "run-1", text: "old prompt")
        state.appendDelta(runID: "run-1", text: "old reply is long enough")

        let cut = BarViewCut()
        cut.cut(entries: state.transcript, isRunning: true)

        // Next delta arrives AFTER the cut — the reply keeps growing in place.
        state.appendDelta(runID: "run-1", text: " NEW TAIL")
        let rows = PanelMirrorPolicy.visible(entries: state.transcript, cut: cut)

        XCTAssertEqual(rows.count, 1, "only the re-anchored reply survives the cut")
        XCTAssertEqual(rows.first?.text, " NEW TAIL",
                       "only the text streamed after the cut is visible")
    }

    /// Folded history rows (m<id>) render exactly like live deltas.
    func testHistoryRowsVisible() {
        let state = AgentLiveState(agentID: "primary")
        let old = MessageRow(id: 1, runId: "run-0", agentId: "primary", role: "user", text: "past", createdAt: 1)
        let oldReply = MessageRow(id: 2, runId: "run-0", agentId: "primary", role: "assistant", text: "past reply", createdAt: 2)
        _ = state.mergeHistoryPage([oldReply, old])  // newest-first

        let rows = PanelMirrorPolicy.visible(entries: state.transcript, cut: cut)
        XCTAssertEqual(rows.map(\.text), ["past", "past reply"])
    }
}