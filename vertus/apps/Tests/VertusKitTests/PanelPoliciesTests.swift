import XCTest
@testable import VertusKit

/// Bug B9 (Escape stop-then-close) and B7/B10 (busy-strip stop buttons) as
/// pure logic — provable without clicking the real panel.
final class PanelPoliciesTests: XCTestCase {
    // MARK: Escape (B9)

    func testEscapeClosesWhenNothingRunning() {
        XCTAssertEqual(PanelEscapePolicy.nextAction(isTurnActive: false, stopPending: false),
                       .closePanel)
    }

    func testEscapeStopsWhenTurnActive() {
        XCTAssertEqual(PanelEscapePolicy.nextAction(isTurnActive: true, stopPending: false),
                       .stopRun)
    }

    func testSecondPressClosesWhileStopStillInFlight() {
        // The stop is async: the run may still show as running on the second
        // press — it must close anyway (two presses = stop, then close).
        XCTAssertEqual(PanelEscapePolicy.nextAction(isTurnActive: true, stopPending: true),
                       .closePanel)
    }

    func testSecondPressAfterNaturalEndCloses() {
        XCTAssertEqual(PanelEscapePolicy.nextAction(isTurnActive: false, stopPending: true),
                       .closePanel)
    }

    // MARK: Busy strip (B7/B10)

    func testStripShowsStopOnlyForNonSelectedAgents() {
        XCTAssertFalse(BusyStripPolicy.showsStopButton(agentID: "primary",
                                                       selectedAgentID: "primary"),
                       "selected agent's run is stopped with Escape — its stop button is redundant")
        XCTAssertTrue(BusyStripPolicy.showsStopButton(agentID: "scout",
                                                      selectedAgentID: "primary"),
                      "a background bot's stop button is the ONLY way to stop it from the panel")
    }

    // MARK: Top-left slot (plus / Working)

    func testIdleShowsPlus() {
        XCTAssertEqual(TopSlotPolicy.state(isStreaming: false, turnHasText: true), .plus)
        XCTAssertEqual(TopSlotPolicy.state(isStreaming: false, turnHasText: false), .plus)
    }

    func testStreamingWithTextShowsPlus() {
        // Output is streaming — the plus must be back (per spec: at rest
        // AND while output is streaming).
        XCTAssertEqual(TopSlotPolicy.state(isStreaming: true, turnHasText: true), .plus)
    }

    func testWorkingBeforeFirstDelta() {
        XCTAssertEqual(TopSlotPolicy.state(isStreaming: true, turnHasText: false), .working)
    }

    func testFirstDeltaFlipsToPlus() {
        // The exact transition the user asked to prove: the moment the first
        // text delta arrives, Working disappears and the plus returns.
        XCTAssertEqual(TopSlotPolicy.state(isStreaming: true, turnHasText: false), .working)
        XCTAssertEqual(TopSlotPolicy.state(isStreaming: true, turnHasText: true), .plus)
    }

    func testQueuedBehindEarlierTurnShowsWorking() {
        // The selected agent is busy with an earlier prompt; this view's
        // prompt is queued and nothing for it has arrived. The agent IS
        // working and the queue depth is separately visible in the fleet
        // strip ("N queued"), so the slot shows Working, not plus.
        XCTAssertEqual(TopSlotPolicy.state(isStreaming: true, turnHasText: false), .working)
    }

    // MARK: Turn-scoped "has text" (a run from another surface must not
    // inherit has-text from an older conversation)

    func testCurrentRunWithVisibleReplyHasText() {
        XCTAssertTrue(TopSlotPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: "hi"))
    }

    func testOldConversationEntryDoesNotCount() {
        // Prior conversation on screen, current run (started elsewhere, e.g.
        // a routine) has not produced text yet — must read as NO text so
        // the slot shows Working instead of the plus.
        XCTAssertFalse(TopSlotPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-a", currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: "old reply"))
    }

    func testUserEntryNeverCountsAsOutput() {
        // Last entry is the user's own prompt — a reply has not started.
        XCTAssertFalse(TopSlotPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: "run-b",
            lastEntryIsReply: false, lastEntryText: "my prompt"))
    }

    func testEmptyOrMissingEntriesDoNotCount() {
        XCTAssertFalse(TopSlotPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: ""))
        XCTAssertFalse(TopSlotPolicy.currentRunHasVisibleText(
            lastEntryRunID: nil, currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: "hi"))
        XCTAssertFalse(TopSlotPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: nil,
            lastEntryIsReply: true, lastEntryText: "hi"))
    }
}