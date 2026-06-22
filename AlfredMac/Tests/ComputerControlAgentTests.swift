import XCTest
@testable import Alfred

final class ComputerControlAgentTests: XCTestCase {

    // MARK: - Intent detection

    func testExplicitControlOpenersExtractTask() {
        XCTAssertEqual(ComputerControlIntent.task(in: "control my mac and open Safari"), "open Safari")
        XCTAssertEqual(ComputerControlIntent.task(in: "use my mac to create a new note"), "create a new note")
        XCTAssertEqual(ComputerControlIntent.task(in: "Control the Mac: click the New button"), "click the New button")
    }

    func testNonControlQueriesAreNotHijacked() {
        XCTAssertNil(ComputerControlIntent.task(in: "what is the capital of France?"))
        XCTAssertNil(ComputerControlIntent.task(in: "summarize this article for me"))
        XCTAssertNil(ComputerControlIntent.task(in: "how do I control inflation?")) // 'control' but not an opener
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
    func testActionCapEnforced() {
        let script = Array(repeating: "wait 1", count: 25).joined(separator: "\n")
        XCTAssertThrowsError(try ComputerControlCapability().planFromActionScript(script)) { error in
            guard case ComputerControlCapability.ControlError.tooManyActions = error else {
                return XCTFail("expected tooManyActions, got \(error)")
            }
        }
    }
}
