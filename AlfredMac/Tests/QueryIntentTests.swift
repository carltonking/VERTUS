import XCTest
@testable import Alfred

final class QueryIntentTests: XCTestCase {
    func testGeneralQuestionDoesNotTriggerWebSearch() {
        let intent = QueryIntent.analyze("What is a closure in Swift?")
        XCTAssertFalse(intent.wantsWebSearch)
        XCTAssertNil(intent.shellCommand)
        XCTAssertNil(intent.appControlQuery)
    }

    func testExplicitLatestTriggersWebSearch() {
        let intent = QueryIntent.analyze("latest Swift release news")
        XCTAssertTrue(intent.wantsWebSearch)
    }

    func testCurrentInfoTriggersWebSearch() {
        XCTAssertTrue(QueryIntent.analyze("what's the weather in NYC").wantsWebSearch)
        XCTAssertTrue(QueryIntent.analyze("current price of bitcoin").wantsWebSearch)
        XCTAssertTrue(QueryIntent.analyze("who won the game last night").wantsWebSearch)
    }

    func testLinkRequestTriggersWebSearch() {
        XCTAssertTrue(QueryIntent.analyze("give me links to swift tutorials").wantsWebSearch)
        XCTAssertTrue(QueryIntent.analyze("find me a website for learning piano").wantsWebSearch)
    }

    func testExplicitShellCommandOnlyAtStart() {
        XCTAssertEqual(QueryIntent.analyze("run: ls -la").shellCommand, "ls -la")
        XCTAssertNil(QueryIntent.analyze("please explain run: ls -la").shellCommand)
    }

    func testBacktickShellCommandDetected() {
        XCTAssertEqual(QueryIntent.analyze("run `pwd` for me").shellCommand, "pwd")
    }

    func testAppControlRequiresPrefix() {
        XCTAssertEqual(QueryIntent.analyze("open Calendar").appControlQuery, "open Calendar")
        XCTAssertNil(QueryIntent.analyze("Tell me how to open Calendar preferences").appControlQuery)
    }

    func testScreenContextRequiresExplicitScreenLanguage() {
        XCTAssertTrue(QueryIntent.analyze("look at my screen and explain this").wantsScreenContext)
        XCTAssertFalse(QueryIntent.analyze("look at this code snippet").wantsScreenContext)
    }
}
