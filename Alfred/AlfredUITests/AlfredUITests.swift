//
//  AlfredUITests.swift
//  AlfredUITests
//
//  Created by Carlton King on 8/4/26.
//

import XCTest

final class AlfredUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The five places Alfred lives. iPhone folds a sixth tab into a "More" list, so if someone
    /// adds one this fails rather than quietly demoting two destinations behind an extra tap.
    @MainActor
    func testFiveTabsArePresent() throws {
        let app = XCUIApplication()
        app.launch()

        for tab in ["Home", "Chat", "Messages", "Email", "Calendar"] {
            XCTAssertTrue(
                app.tabBars.buttons[tab].waitForExistence(timeout: 15),
                "Expected a \(tab) tab"
            )
        }

        XCTAssertFalse(app.tabBars.buttons["More"].exists, "A sixth tab would hide two destinations")
    }

    /// Home greets the owner whether or not the app is connected.
    @MainActor
    func testHomeGreetsTheOwner() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome, Carlton"].waitForExistence(timeout: 15))
    }

    /// Settings is reachable from Home even though it gave up its tab slot.
    @MainActor
    func testSettingsIsReachableFromHome() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome, Carlton"].waitForExistence(timeout: 15))

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Theme"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["App token"].exists)
    }

    /// All three themes are offered and selectable.
    @MainActor
    func testThemesCanBeChosen() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome, Carlton"].waitForExistence(timeout: 15))

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Theme"].waitForExistence(timeout: 15))

        for theme in ["Solar Eclipse", "Sage Forest", "Monochromatic"] {
            XCTAssertTrue(app.staticTexts[theme].exists, "Expected the \(theme) theme")
        }

        // Switching must not throw the view hierarchy away.
        app.buttons["theme.sage"].tap()
        XCTAssertTrue(app.staticTexts["Sage Forest"].waitForExistence(timeout: 5))
        app.buttons["theme.eclipse"].tap()
        XCTAssertTrue(app.staticTexts["Solar Eclipse"].waitForExistence(timeout: 5))
    }

    /// Configure the app the way a person would, then confirm Chat becomes usable.
    ///
    /// Credentials come from the environment, never the repository — pass them when running:
    ///   xcodebuild test ... ALFRED_HOST=… ALFRED_TOKEN=…
    /// Skips rather than fails when unset, so the suite stays green for anyone without them.
    @MainActor
    func testConfiguringUnlocksChat() throws {
        let env = ProcessInfo.processInfo.environment
        let host = env["ALFRED_HOST"] ?? ""
        let token = env["ALFRED_TOKEN"] ?? ""
        try XCTSkipIf(host.isEmpty || token.isEmpty, "ALFRED_HOST / ALFRED_TOKEN not provided")

        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome, Carlton"].waitForExistence(timeout: 15))

        app.buttons["Settings"].firstMatch.tap()

        let hostField = app.textFields["settings.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 15))
        hostField.tap()
        hostField.typeText(host)

        let tokenField = app.secureTextFields["settings.token"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 10))
        tokenField.tap()
        tokenField.typeText(token)

        app.swipeDown(velocity: .fast)  // dismiss the settings sheet

        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(
            app.staticTexts["Ask me anything"].waitForExistence(timeout: 15),
            "Chat should be usable once the app is connected"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat — connected"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
