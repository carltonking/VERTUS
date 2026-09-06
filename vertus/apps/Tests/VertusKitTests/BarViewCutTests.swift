import XCTest
@testable import VertusKit

/// The QuickBar panel's "new session" is a view reset over the shared store
/// mirror (the hub keeps full history). These pin the cut's contract:
///   - an idle cut hides everything on screen at cut time, forever, even
///     after later store events (the old button silently failed exactly
///     this way — the mirror re-populated on the next sync);
///   - an in-flight cut hides the old conversation but keeps the running
///     reply visible from the cut moment on, still growing in place;
///   - a reset (agent switch) restores the full mirror.
final class BarViewCutTests: XCTestCase {
    private func user(_ runID: String, _ text: String) -> TranscriptEntry {
        TranscriptEntry(runId: runID, role: "user", text: text)
    }

    private func assistant(_ runID: String, _ text: String) -> TranscriptEntry {
        TranscriptEntry(runId: runID, role: "assistant", text: text)
    }

    func testIdleCutHidesEverythingOnScreenAndNeverReappears() {
        let cut = BarViewCut()
        let u = user("r1", "question one")
        let a = assistant("r1", "answer one")
        let transcript = [u, a]

        cut.cut(entries: transcript, isRunning: false)

        XCTAssertNil(cut.visibleText(of: u))
        XCTAssertNil(cut.visibleText(of: a))
        XCTAssertFalse(cut.isIdle)

        // A later store event (the failure mode of the old button) must NOT
        // re-populate the mirror with pre-cut history.
        XCTAssertNil(cut.visibleText(of: u))
        XCTAssertNil(cut.visibleText(of: a))

        // A genuinely new run after the cut shows in full.
        let u2 = user("r2", "question two")
        let a2 = assistant("r2", "answer two")
        XCTAssertEqual(cut.visibleText(of: u2), "question two")
        XCTAssertEqual(cut.visibleText(of: a2), "answer two")
    }

    func testInFlightCutKeepsRunningReplyStreamingFromCutMoment() {
        let cut = BarViewCut()
        let u = user("r1", "question one")
        var a = assistant("r1", "Hello")   // the reply is mid-stream
        cut.cut(entries: [u, a], isRunning: true)

        // Old conversation hidden; the reply is re-anchored.
        XCTAssertNil(cut.visibleText(of: u))
        XCTAssertEqual(cut.visibleText(of: a), "")

        // The store grows the SAME entry in place (one entry per reply).
        a.text += " world, sir"
        XCTAssertEqual(cut.visibleText(of: a), " world, sir")

        // A user send after the cut appears (new run, not hidden).
        let u2 = user("r2", "next question")
        XCTAssertEqual(cut.visibleText(of: u2), "next question")
        let a2 = assistant("r2", "next answer")
        XCTAssertEqual(cut.visibleText(of: a2), "next answer")
    }

    func testRecutReanchorsToCurrentTail() {
        let cut = BarViewCut()
        var a = assistant("r1", "Hello world")
        cut.cut(entries: [a], isRunning: true)
        a.text += " and more"
        // Second cut while still streaming re-anchors at the new length.
        cut.cut(entries: [a], isRunning: true)
        XCTAssertEqual(cut.visibleText(of: a), "")
        a.text += " again"
        XCTAssertEqual(cut.visibleText(of: a), " again")
    }

    func testResetRestoresFullView() {
        let cut = BarViewCut()
        let u = user("r1", "question")
        let a = assistant("r1", "answer")
        cut.cut(entries: [u, a], isRunning: false)
        XCTAssertNil(cut.visibleText(of: a))

        cut.reset()
        XCTAssertTrue(cut.isIdle)
        XCTAssertEqual(cut.visibleText(of: u), "question")
        XCTAssertEqual(cut.visibleText(of: a), "answer")
    }

    func testUncutShowsEverything() {
        let cut = BarViewCut()
        XCTAssertTrue(cut.isIdle)
        XCTAssertEqual(cut.visibleText(of: assistant("r1", "hi")), "hi")
    }
}
