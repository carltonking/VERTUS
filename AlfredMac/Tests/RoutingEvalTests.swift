import XCTest
@testable import Alfred

/// Eval harness: a fixed query set pinning QueryIntent's routing decisions.
///
/// QueryIntent is the deterministic layer that decides — before any LLM call —
/// whether a query hits web search, screen capture, calendar, app control, or
/// the shell. It breaks silently: a tweak to one keyword list can mis-route or
/// trigger an unwanted side effect with no compile error. This table is the
/// regression net. Add a row whenever a routing bug is found.
///
/// ponytail: pure data-driven assert over the deterministic router. No network,
/// no LLM, no fixtures. Live model behavior isn't unit-testable without mocking
/// every provider — out of scope until there's a real signal it's needed.
final class RoutingEvalTests: XCTestCase {

    private struct Case {
        let query: String
        var web = false
        var screen = false
        var calendar = false
        var appControl: String?
        var shell: String?
        let line: UInt

        init(_ query: String, web: Bool = false, screen: Bool = false,
             calendar: Bool = false, appControl: String? = nil,
             shell: String? = nil, line: UInt = #line) {
            self.query = query; self.web = web; self.screen = screen
            self.calendar = calendar; self.appControl = appControl
            self.shell = shell; self.line = line
        }
    }

    private let cases: [Case] = [
        // Plain knowledge questions must stay fully local — no routing flags.
        Case("What is a closure in Swift?"),
        Case("Explain how TLS handshakes work"),
        Case("write me a haiku about the sea"),

        // Web search: explicit asks + time-sensitive + link requests.
        Case("latest Swift release news", web: true),
        Case("what's the current price of bitcoin", web: true),
        Case("what's the weather in NYC", web: true),
        Case("who won the game last night", web: true),
        Case("give me links to swift tutorials", web: true),
        Case("search for the best mechanical keyboards", web: true),

        // Calendar intent wins over web even with a time word ("this week").
        Case("what meetings do I have this week", web: false, calendar: true),
        Case("show my reminders for today", calendar: true),
        Case("what's on my calendar", calendar: true),
        Case("upcoming events", calendar: true),

        // Screen context: only on explicit screen language.
        Case("look at my screen and explain this", screen: true),
        Case("what's on my screen", screen: true),
        Case("look at this code snippet", screen: false),
        Case("read this paragraph for me", screen: false),

        // App control: only when the query *starts* with an action verb.
        Case("open Calendar", appControl: "open Calendar"),
        Case("quit Spotify", appControl: "quit Spotify"),
        Case("Tell me how to open Calendar preferences", appControl: nil),
        Case("I should launch the rocket later", appControl: nil),

        // Shell: explicit prefix at start, or backtick span. Never mid-sentence.
        Case("run: ls -la", shell: "ls -la"),
        Case("run `pwd` for me", shell: "pwd"),
        Case("please explain run: ls -la", shell: nil),
        Case("how do I run a shell command", shell: nil),
    ]

    func testRoutingTable() {
        for c in cases {
            let intent = QueryIntent.analyze(c.query)
            XCTAssertEqual(intent.wantsWebSearch, c.web, "web: \(c.query)", line: c.line)
            XCTAssertEqual(intent.wantsScreenContext, c.screen, "screen: \(c.query)", line: c.line)
            XCTAssertEqual(intent.wantsCalendarContext, c.calendar, "calendar: \(c.query)", line: c.line)
            XCTAssertEqual(intent.appControlQuery, c.appControl, "appControl: \(c.query)", line: c.line)
            XCTAssertEqual(intent.shellCommand, c.shell, "shell: \(c.query)", line: c.line)
        }
    }

    /// Side-effect flag must be true iff app control or shell fired — gates the
    /// confirmation prompt, so a false negative = a silent action.
    func testHasSideEffectMatchesActions() {
        for c in cases {
            let intent = QueryIntent.analyze(c.query)
            let expected = c.appControl != nil || c.shell != nil
            XCTAssertEqual(intent.hasSideEffect, expected, "sideEffect: \(c.query)", line: c.line)
        }
    }
}
