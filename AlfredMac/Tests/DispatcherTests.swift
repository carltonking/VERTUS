import XCTest
@testable import Alfred

final class DispatcherTests: XCTestCase {
    private let dispatcher = Dispatcher()

    func testReadOnlyQuestionRunsWithoutConfirmation() {
        let d = dispatcher.decide(query: "what is a closure in Swift?", providerIsCloud: false)
        XCTAssertEqual(d.commandClass, .readOnly)
        XCTAssertFalse(d.confirmRequired)
    }

    func testDeleteIsHighRiskAndConfirms() {
        let d = dispatcher.decide(query: "delete the old report file", providerIsCloud: false)
        XCTAssertEqual(d.commandClass, .highRiskWrite)
        XCTAssertTrue(d.confirmRequired)
    }

    func testSendEmailIsHighRiskAndConfirms() {
        let d = dispatcher.decide(query: "send email to bob about the meeting", providerIsCloud: false)
        XCTAssertEqual(d.actionType, .sendMessage)
        XCTAssertEqual(d.commandClass, .highRiskWrite)
        XCTAssertTrue(d.confirmRequired)
    }

    func testCreateFileIsLowRiskNoConfirm() {
        let d = dispatcher.decide(query: "create a markdown file about Alfred", providerIsCloud: false)
        XCTAssertEqual(d.commandClass, .lowRiskWrite)
        XCTAssertFalse(d.confirmRequired)
    }

    func testSensitiveContentIsCloudSensitive() {
        let d = dispatcher.decide(query: "remember my password: hunter2", providerIsCloud: false)
        XCTAssertEqual(d.commandClass, .cloudSensitive)
    }

    func testLocalPrefixForcesLocalRouteAndStripsQuery() {
        let d = dispatcher.decide(query: "local: summarize this", providerIsCloud: true)
        XCTAssertEqual(d.route, .local)
        XCTAssertTrue(d.forcedByPrefix)
        XCTAssertEqual(d.query, "summarize this")
    }

    func testCloudPrefixForcesCloudRoute() {
        let d = dispatcher.decide(query: "cloud: write a poem", providerIsCloud: false)
        XCTAssertEqual(d.route, .cloud)
        XCTAssertTrue(d.forcedByPrefix)
    }

    func testCloudProviderRoutesReadOnlyToCloud() {
        let d = dispatcher.decide(query: "summarize this article", providerIsCloud: true)
        XCTAssertEqual(d.route, .cloud)
    }

    func testRoutingLineMarksLocalVsCloud() {
        let local = dispatcher.decide(query: "what time is it", providerIsCloud: false)
        XCTAssertTrue(local.routingLine(model: "local", egressSummary: "").contains("✓ Local"))

        let cloud = dispatcher.decide(query: "what time is it", providerIsCloud: true)
        XCTAssertTrue(cloud.routingLine(model: "gemini", egressSummary: "gemini: sent, no redactions").contains("☁"))
    }

    func testCommandClassMappingIsDeterministic() {
        XCTAssertEqual(Dispatcher.commandClass(for: .respondText, sensitive: false, destructive: false), .readOnly)
        XCTAssertEqual(Dispatcher.commandClass(for: .createFile, sensitive: false, destructive: false), .lowRiskWrite)
        XCTAssertEqual(Dispatcher.commandClass(for: .sendMessage, sensitive: false, destructive: false), .highRiskWrite)
        XCTAssertEqual(Dispatcher.commandClass(for: .respondText, sensitive: true, destructive: false), .cloudSensitive)
        XCTAssertEqual(Dispatcher.commandClass(for: .createFile, sensitive: false, destructive: true), .highRiskWrite)
    }
}
