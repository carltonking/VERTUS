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

    // MARK: - isRecoverableTurnFailure — what must trigger rebuild + retry

    func testAgentExitIsRecoverableEvenWhenClean() {
        // A clean exit 0 is still an upstream fault (Ollama/provider drop) —
        // the "Hermes stopped unexpectedly (exit 0)" symptom. It must rebuild
        // and retry rather than fail the turn.
        XCTAssertTrue(HermesSession.isRecoverableTurnFailure(.agentExited(0)))
        XCTAssertTrue(HermesSession.isRecoverableTurnFailure(.agentExited(1)))
        XCTAssertTrue(HermesSession.isRecoverableTurnFailure(.agentExited(-15)))
    }

    func testTimeoutIsRecoverable() {
        XCTAssertTrue(HermesSession.isRecoverableTurnFailure(.turnTimedOut))
    }

    func testSessionLostProtocolErrorIsRecoverable() {
        XCTAssertTrue(HermesSession.isRecoverableTurnFailure(.protocolError("no active session")))
        XCTAssertTrue(HermesSession.isRecoverableTurnFailure(.protocolError("Session c8f21d2e is no longer active")))
    }

    func testStdinClosedIsRecoverable() {
        // The process died before the request was written — the write throws
        // "agent stdin closed". Same death, same recovery.
        XCTAssertTrue(HermesSession.isRecoverableTurnFailure(.protocolError("agent stdin closed")))
    }

    // MARK: - isRecoverableTurnFailure — what must surface as-is

    func testPromptLevelFailuresAreNotRecoverable() {
        XCTAssertFalse(HermesSession.isRecoverableTurnFailure(.protocolError("permission denied")))
        XCTAssertFalse(HermesSession.isRecoverableTurnFailure(.protocolError("tool execution failed")))
        XCTAssertFalse(HermesSession.isRecoverableTurnFailure(.protocolError("model not found")))
        XCTAssertFalse(HermesSession.isRecoverableTurnFailure(.notConfigured("pick a provider")))
        XCTAssertFalse(HermesSession.isRecoverableTurnFailure(.binaryNotFound))
        XCTAssertFalse(HermesSession.isRecoverableTurnFailure(.launchFailed("nope")))
    }

    // MARK: - recoveryLabel

    func testRecoveryLabelNamesTheFault() {
        XCTAssertTrue(HermesSession.recoveryLabel(.agentExited(0)).contains("exit"))
        XCTAssertTrue(HermesSession.recoveryLabel(.turnTimedOut).contains("turn watchdog: no response"))
        XCTAssertEqual(HermesSession.recoveryLabel(.protocolError("no active session")), "no active session")
    }

    // MARK: - handshakeTimedOut

    func testHandshakeTimeoutIsNotPromptRecoverable() {
        // A stalled startup is not fixed by retrying the prompt: the session
        // never existed, so rebuild-and-retry would just stall again. The
        // keepalive respawns the process instead.
        XCTAssertFalse(HermesSession.isRecoverableTurnFailure(.handshakeTimedOut))
    }

    func testHandshakeTimeoutMessageIsActionable() {
        let message = HermesError.handshakeTimedOut.localizedDescription
        XCTAssertTrue(message.contains("didn't finish starting"), message)
        XCTAssertTrue(message.contains("bridge"), message)
        XCTAssertTrue(message.contains("retry"), message)
    }
}
