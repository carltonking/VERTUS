import XCTest
@testable import Alfred

/// Pins down the "the session went away" classifier that drives the lost-session
/// recovery in HermesSession.runTurn: when a session/prompt round trip comes back
/// with one of these protocol errors, the session is rebuilt and the prompt is
/// retried once instead of the user seeing "no active session".
final class SessionRecoveryTests: XCTestCase {

    // MARK: - sessionLost — the messages that must trigger a rebuild

    func testMatchesTheExactObservedMessage() {
        XCTAssertTrue(HermesSession.sessionLost("no active session"))
    }

    func testMatchesCaseInsensitively() {
        XCTAssertTrue(HermesSession.sessionLost("No Active Session"))
        XCTAssertTrue(HermesSession.sessionLost("NO ACTIVE SESSION"))
    }

    func testMatchesHermesDetailsStyleVariants() {
        // Hermes can surface the same condition in data.details with a session id
        // and different phrasing — every variant must still trigger recovery.
        XCTAssertTrue(HermesSession.sessionLost("Session c8f21d2e is no longer active"))
        XCTAssertTrue(HermesSession.sessionLost("session does not exist"))
        XCTAssertTrue(HermesSession.sessionLost("session not found"))
        XCTAssertTrue(HermesSession.sessionLost("no such session"))
        XCTAssertTrue(HermesSession.sessionLost("invalid session"))
        XCTAssertTrue(HermesSession.sessionLost("the session is not active"))
        XCTAssertTrue(HermesSession.sessionLost("session inactive"))
    }

    // MARK: - sessionLost — messages that must NOT trigger a rebuild

    func testDoesNotMatchPromptLevelFailures() {
        XCTAssertFalse(HermesSession.sessionLost("permission denied"))
        XCTAssertFalse(HermesSession.sessionLost("tool execution failed"))
        XCTAssertFalse(HermesSession.sessionLost("model not found"))
        XCTAssertFalse(HermesSession.sessionLost("context window exhausted"))
    }

    func testDoesNotMatchInnocentUsesOfTheWords() {
        // A turn that merely *mentions* the words must not be misclassified.
        XCTAssertFalse(HermesSession.sessionLost("You have an active session."))
        XCTAssertFalse(HermesSession.sessionLost(""))
        XCTAssertFalse(HermesSession.sessionLost("session/prompt succeeded"))
    }
}
