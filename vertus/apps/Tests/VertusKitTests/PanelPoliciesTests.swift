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
}