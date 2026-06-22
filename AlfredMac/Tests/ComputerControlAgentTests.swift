import XCTest
@testable import Alfred

final class ComputerControlAgentTests: XCTestCase {

    // MARK: - Intent detection

    func testExplicitControlOpenersExtractTask() {
        XCTAssertEqual(ComputerControlIntent.task(in: "control my mac and open Safari"), "open Safari")
        XCTAssertEqual(ComputerControlIntent.task(in: "use my mac to create a new note"), "create a new note")
        XCTAssertEqual(ComputerControlIntent.task(in: "Control the Mac: click the New button"), "click the New button")
    }

    func testMultiStepControlQueryIsDetected() {
        // Regression: this multi-"and" query was swallowed by the workflow planner and failed with
        // "No supported computer-control actions". It must be recognized as a control task so it
        // routes to the agent before the workflow planner.
        let task = ComputerControlIntent.task(in: "control my mac and open a new tab and go to github.com")
        XCTAssertEqual(task, "open a new tab and go to github.com")
    }

    func testNonControlQueriesAreNotHijacked() {
        XCTAssertNil(ComputerControlIntent.task(in: "what is the capital of France?"))
        XCTAssertNil(ComputerControlIntent.task(in: "summarize this article for me"))
        XCTAssertNil(ComputerControlIntent.task(in: "how do I control inflation?")) // 'control' but not an opener
    }

    func testFriendlyErrorForUnreachableProvider() {
        let connectionError = URLError(.cannotConnectToHost)
        let msg = LLMComputerControlPlanner.friendlyError(connectionError)
        XCTAssertTrue(msg.lowercased().contains("ollama"), "connection failures should hint at the local model: \(msg)")
    }

    // MARK: - Script validation guards (the safety net before confirmation)

    @MainActor
    func testValidScriptBuildsPlan() throws {
        let plan = try ComputerControlCapability().planFromActionScript("type \"hello\"\nhotkey cmd s\nwait 1")
        XCTAssertEqual(plan.actions.count, 3)
    }

    @MainActor
    func testSensitiveScriptRejected() {
        XCTAssertThrowsError(try ComputerControlCapability().planFromActionScript("type \"my password is hunter2\"")) { error in
            guard case ComputerControlCapability.ControlError.unsafeSensitiveText = error else {
                return XCTFail("expected unsafeSensitiveText, got \(error)")
            }
        }
    }

    @MainActor
    func testDestructiveScriptRejected() {
        XCTAssertThrowsError(try ComputerControlCapability().planFromActionScript("click 10 20\ntype \"please delete everything\"")) { error in
            guard case ComputerControlCapability.ControlError.potentiallyDestructive = error else {
                return XCTFail("expected potentiallyDestructive, got \(error)")
            }
        }
    }

    @MainActor
    func testMalformedKeyComboIsRecovered() throws {
        // Regression: llama3.1:8b emitted `press key "command" KEY "t"` for cmd+t. The parser must
        // strip the quotes + literal "key" and treat the two keys as a hotkey instead of failing.
        let plan = try ComputerControlCapability().planFromActionScript("press key \"command\" KEY \"t\"")
        XCTAssertEqual(plan.actions.count, 1)
        guard case .hotkey(let keys) = plan.actions[0] else {
            return XCTFail("expected a hotkey, got \(plan.actions[0])")
        }
        XCTAssertEqual(keys, ["command", "t"])
    }

    @MainActor
    func testSingleKeyStillPressed() throws {
        let plan = try ComputerControlCapability().planFromActionScript("press key return")
        guard case .pressKey(let key) = plan.actions[0] else {
            return XCTFail("expected a key press, got \(plan.actions[0])")
        }
        XCTAssertEqual(key, "return")
    }

    @MainActor
    func testActionCapEnforced() {
        let script = Array(repeating: "wait 1", count: 25).joined(separator: "\n")
        XCTAssertThrowsError(try ComputerControlCapability().planFromActionScript(script)) { error in
            guard case ComputerControlCapability.ControlError.tooManyActions = error else {
                return XCTFail("expected tooManyActions, got \(error)")
            }
        }
    }
}
