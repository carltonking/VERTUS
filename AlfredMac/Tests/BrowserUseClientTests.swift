import XCTest
@testable import Alfred

/// Covers the deterministic parts of the BrowserUseClient integration: blocked
/// host detection, the Python literal escaper, the stdout JSON payload parser,
/// and the generated scripts' content. Everything here avoids spawning the
/// binary — no subprocess, no Chrome, no daemon. MainActor because the
/// subscription skill (and the routine step) are main-actor services.
@MainActor
final class BrowserUseClientTests: XCTestCase {

    override func tearDown() {
        // Isolate the persisted defaults so one test's toggles never leak into
        // another (or into the real app state on a dev machine running tests).
        UserDefaults.standard.removeObject(forKey: "alfred.browserAutomationEnabled")
        UserDefaults.standard.removeObject(forKey: "alfred.browserRequireConfirmation")
        super.tearDown()
    }

    // MARK: - Settings defaults

    func testDefaultsAreSafe() {
        // The spec asked for safety by default: automation off, confirmation on.
        XCTAssertFalse(BrowserUseClient.shared.isEnabled)
        XCTAssertTrue(BrowserUseClient.shared.requireConfirmation)
    }

    func testEnabledRoundTrips() {
        BrowserUseClient.shared.isEnabled = true
        XCTAssertTrue(BrowserUseClient.shared.isEnabled)
        BrowserUseClient.shared.isEnabled = false
        XCTAssertFalse(BrowserUseClient.shared.isEnabled)
    }

    // MARK: - Blocked hosts

    func testExactBlockedHost() {
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://paypal.com/donate"))
    }

    func testSubdomainOfBlockedHost() {
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://www.paypal.com/signin"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://checkout.chase.com/pay"))
    }

    func testBlockedWithSchemeAndPathVariants() {
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "http://venmo.com"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://stripe.com/payments"))
    }

    func testSuffixMatchDoesNotFakeBlock() {
        // "notpaypal.com" must NOT match "paypal.com" (suffix + "." boundary).
        XCTAssertFalse(BrowserUseClient.isBlocked(url: "https://notpaypal.com"))
        XCTAssertFalse(BrowserUseClient.isBlocked(url: "https://mypaypalclone.com/x"))
    }

    func testOrdinarySitesAreNotBlocked() {
        XCTAssertFalse(BrowserUseClient.isBlocked(url: "https://example.com"))
        XCTAssertFalse(BrowserUseClient.isBlocked(url: "https://www.nyu.edu"))
    }

    func testMalformedURLIsNotBlocked() {
        XCTAssertFalse(BrowserUseClient.isBlocked(url: "not a url"))
        XCTAssertFalse(BrowserUseClient.isBlocked(url: ""))
    }

    // MARK: - Python literal escaper

    func testPythonStringPlain() {
        XCTAssertEqual(BrowserUseClient.pythonString("hello"), "\"hello\"")
    }

    func testPythonStringEscapesQuotesAndBackslashes() {
        let escaped = BrowserUseClient.pythonString("say \"hi\" \\ now")
        XCTAssertTrue(escaped.hasPrefix("\""))
        XCTAssertTrue(escaped.hasSuffix("\""))
        // Recover the original by round-tripping through JSON.
        let data = escaped.data(using: .utf8)!
        // The escaped literal is a JSON *string* fragment — allowFragments is
        // required (top-level scalars are not arrays/objects).
        let decoded = try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! String
        XCTAssertEqual(decoded, "say \"hi\" \\ now")
    }

    func testPythonStringEscapesNewlines() {
        let escaped = BrowserUseClient.pythonString("line one\nline two")
        XCTAssertFalse(escaped.contains("\n"), "raw newlines must be escaped, got: \(escaped.debugDescription)")
        let data = escaped.data(using: .utf8)!
        let decoded = try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! String
        XCTAssertEqual(decoded, "line one\nline two")
    }

    // MARK: - stdout JSON parser

    func testLastJSONLinePicksTheObjectNotTheNoise() {
        let output = """
        [harness] starting...
        {"found": true, "text": "hello"}
        """
        let payload = BrowserUseClient.lastJSONLine(in: output)
        XCTAssertEqual(payload?["found"] as? Bool, true)
        XCTAssertEqual(payload?["text"] as? String, "hello")
    }

    func testLastJSONLineHandlesEmptyOutput() {
        XCTAssertNil(BrowserUseClient.lastJSONLine(in: ""))
    }

    func testLastJSONLineIgnoresNonObjectLines() {
        XCTAssertNil(BrowserUseClient.lastJSONLine(in: "some plain text\n42\n"))
    }

    // MARK: - Generated scripts

    func testSubscriptionRejectsEmptyEmailBeforeAnyBrowserRun() async {
        // The email gate lives above the browser layer — an empty address must
        // fail with a clear message, never a script run. Automation must be on
        // for the email check to be the gate that trips (the enable check is
        // the outer guard).
        BrowserUseClient.shared.isEnabled = true
        let outcome = await EmailSubscriptionSkill.shared.subscribe(
            url: "https://example.com", email: "", confirmed: true)
        guard case .failed(let message) = outcome else {
            XCTFail("expected .failed for empty email, got \(outcome)")
            return
        }
        XCTAssertTrue(message.contains("email"), "message should mention the email problem: \(message)")
    }

    func testSubscriptionRejectsMalformedEmail() async {
        BrowserUseClient.shared.isEnabled = true
        let outcome = await EmailSubscriptionSkill.shared.subscribe(
            url: "https://example.com", email: "not-an-email", confirmed: true)
        guard case .failed(let message) = outcome else {
            XCTFail("expected .failed for malformed email, got \(outcome)")
            return
        }
        XCTAssertTrue(message.contains("email"), "message should mention the email problem: \(message)")
    }

    func testSubscriptionRefusedWhenAutomationOff() async {
        BrowserUseClient.shared.isEnabled = false
        let outcome = await EmailSubscriptionSkill.shared.subscribe(
            url: "https://example.com", email: "a@b.com", confirmed: true)
        guard case .failed(let message) = outcome else {
            XCTFail("expected .failed when automation is off, got \(outcome)")
            return
        }
        XCTAssertTrue(message.lowercased().contains("off"), "message should say automation is off: \(message)")
    }

    // MARK: - Generated scripts

    func testSearchScriptBuildsDuckDuckGoQuery() {
        // DuckDuckGo's JS-free HTML endpoint is the deterministic search path.
        let script = BrowserUseClient.searchScript(query: "macbook price", maxChars: 4000)
        XCTAssertTrue(script.contains("html.duckduckgo.com/html/"))
        XCTAssertTrue(script.contains("quote("))
        XCTAssertTrue(script.contains("wait_for_load()"))
        XCTAssertTrue(script.contains("json.dumps"))
        // The query lands JSON-escaped inside quote() — never raw.
        XCTAssertTrue(script.contains("quote(\"macbook price\")"))
    }

    func testExtractScriptEmbedsURLAndCap() {
        let script = BrowserUseClient.extractScript(url: "https://example.com/x", maxChars: 2500)
        XCTAssertTrue(script.contains("new_tab(\"https://example.com/x\")"))
        XCTAssertTrue(script.contains("text[:2500]"))
    }

    func testPageInfoScriptEmbedsURLAndCapsAtSixThousand() {
        let script = BrowserUseClient.pageInfoScript(url: "https://example.com")
        XCTAssertTrue(script.contains("page_info()"))
        XCTAssertTrue(script.contains("text[:6000]"))
        XCTAssertTrue(script.contains("\"url\""))
        XCTAssertTrue(script.contains("\"title\""))
    }

    func testFillScriptSubmitFlagControlsSubmission() {
        let withSubmit = BrowserUseClient.fillScript(
            url: "https://substack.com", email: "a@b.com", submit: true)
        let withoutSubmit = BrowserUseClient.fillScript(
            url: "https://substack.com", email: "a@b.com", submit: false)
        XCTAssertTrue(withSubmit.contains("SUBMIT = True"))
        XCTAssertTrue(withoutSubmit.contains("SUBMIT = False"))
        // The selector probe and the native-setter fill path exist in both.
        for script in [withSubmit, withoutSubmit] {
            XCTAssertTrue(script.contains("input[type=email]"))
            XCTAssertTrue(script.contains("Object.getOwnPropertyDescriptor"))
            XCTAssertTrue(script.contains("json.dumps(sel)"))
        }
    }

    func testFillScriptEscapesHostileValues() {
        // A quote/newline-laden email must land JSON-escaped, never raw — the
        // JSON string is also a valid Python literal, so the script stays one
        // well-formed program.
        let script = BrowserUseClient.fillScript(
            url: "https://example.com", email: "a\"b@c.com\n", submit: false)
        XCTAssertFalse(script.contains("a\"b@c.com\n"))
        // The escaped form round-trips: the script contains a JSON-quoted email.
        XCTAssertTrue(script.contains("email = \"a\\\"b@c.com\\n\""))
    }

    // MARK: - Confirmation gate logic

    func testSubmitRefusedWhenDisabled() async {
        BrowserUseClient.shared.isEnabled = false
        let outcome = await BrowserUseClient.shared.fillEmailAndSubmit(
            url: "https://example.com", email: "a@b.com", confirmed: true)
        guard case .refused = outcome else {
            XCTFail("expected .refused when disabled, got \(outcome)")
            return
        }
    }

    func testSubmitRefusedForBlockedHostEvenWhenEnabled() async {
        BrowserUseClient.shared.isEnabled = true
        let outcome = await BrowserUseClient.shared.fillEmailAndSubmit(
            url: "https://paypal.com", email: "a@b.com", confirmed: true)
        guard case .refused = outcome else {
            XCTFail("expected .refused for blocked host, got \(outcome)")
            return
        }
    }

    // MARK: - Binary resolution

    func testResolveBinaryIsNilOrExecutable() {
        // No browser-use on PATH in the test sandbox (verified at test time).
        // Guard against a regression where a hardcoded path sneaks in.
        let resolved = BrowserUseClient.resolveBinary()
        if let resolved {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved))
        }
    }
}
