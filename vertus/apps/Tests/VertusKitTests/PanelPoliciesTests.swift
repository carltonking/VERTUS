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

    // MARK: In-window Working indicator (turn-scoped "has text")

    func testCurrentRunWithVisibleReplyHasText() {
        XCTAssertTrue(WorkingIndicatorPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: "hi"))
    }

    func testOldConversationEntryDoesNotCount() {
        // Prior conversation on screen, current run (started elsewhere, e.g.
        // a routine) has not produced text yet — must read as NO text so
        // the in-window Working indicator shows.
        XCTAssertFalse(WorkingIndicatorPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-a", currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: "old reply"))
    }

    func testUserEntryNeverCountsAsOutput() {
        // Last entry is the user's own prompt — a reply has not started.
        XCTAssertFalse(WorkingIndicatorPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: "run-b",
            lastEntryIsReply: false, lastEntryText: "my prompt"))
    }

    func testEmptyOrMissingEntriesDoNotCount() {
        XCTAssertFalse(WorkingIndicatorPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: ""))
        XCTAssertFalse(WorkingIndicatorPolicy.currentRunHasVisibleText(
            lastEntryRunID: nil, currentRunID: "run-b",
            lastEntryIsReply: true, lastEntryText: "hi"))
        XCTAssertFalse(WorkingIndicatorPolicy.currentRunHasVisibleText(
            lastEntryRunID: "run-b", currentRunID: nil,
            lastEntryIsReply: true, lastEntryText: "hi"))
    }
}