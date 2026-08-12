//
//  AlfredUITests.swift
//  AlfredUITests
//
//  Created by Carlton King on 8/4/26.
//

import EventKit
import XCTest

final class AlfredUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// All six destinations sit in the bottom bar. SwiftUI's own TabView caps iPhone at five and
    /// hides the rest behind "More", which is why this bar is hand-rolled — if someone swaps it back
    /// for a stock TabView, two of these disappear and this fails.
    @MainActor
    func testAllSixTabsArePresent() throws {
        let app = XCUIApplication()
        app.launch()

        for tab in ["home", "chat", "messages", "email", "calendar", "settings"] {
            XCTAssertTrue(
                app.buttons["tab.\(tab)"].waitForExistence(timeout: 15),
                "Expected a \(tab) tab"
            )
        }

        XCTAssertFalse(app.buttons["More"].exists, "Nothing should be folded behind a More list")
    }

    /// The icons carry no visible titles, but VoiceOver reads names rather than SF Symbols — so the
    /// names have to survive as accessibility labels.
    @MainActor
    func testTabsStayNamedForVoiceOver() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["tab.home"].waitForExistence(timeout: 15))

        for (id, name) in [
            ("home", "Home"), ("chat", "Chat"), ("messages", "Messages"),
            ("email", "Email"), ("calendar", "Calendar"), ("settings", "Settings"),
        ] {
            XCTAssertEqual(app.buttons["tab.\(id)"].label, name, "\(id) lost its spoken name")
        }
    }

    /// Home greets the owner whether or not the app is connected.
    @MainActor
    func testHomeGreetsTheOwner() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome, Carlton"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testSettingsOpensFromTheBar() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome, Carlton"].waitForExistence(timeout: 15))

        app.buttons["tab.settings"].tap()
        XCTAssertTrue(app.staticTexts["Address"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["App token"].exists)
    }

    /// Alfred has exactly one theme now — monochrome. The old picker (three palettes) must not
    /// come back, so Settings must not offer a Theme section at all.
    @MainActor
    func testOnlyMonochromeThemeExists() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome, Carlton"].waitForExistence(timeout: 15))

        app.buttons["tab.settings"].tap()
        XCTAssertTrue(app.staticTexts["Address"].waitForExistence(timeout: 15))

        XCTAssertFalse(app.staticTexts["Theme"].exists, "Theme section must be gone")
        XCTAssertFalse(app.staticTexts["Solar Eclipse"].exists)
        XCTAssertFalse(app.staticTexts["Sage Forest"].exists)
        XCTAssertFalse(app.staticTexts["Monochromatic"].exists)
        XCTAssertFalse(app.buttons["theme.sage"].exists)
        XCTAssertFalse(app.buttons["theme.eclipse"].exists)
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

        app.buttons["tab.settings"].tap()

        let hostField = app.textFields["settings.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 15))
        hostField.tap()
        hostField.typeText(host)

        let tokenField = app.secureTextFields["settings.token"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 10))
        tokenField.tap()
        tokenField.typeText(token)

        app.buttons["tab.chat"].tap()
        XCTAssertTrue(
            app.staticTexts["Ask me anything"].waitForExistence(timeout: 15),
            "Chat should be usable once the app is connected"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chat — connected"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Calendar

    /// Calendar must explain itself before iOS asks. The system prompt can only ever be shown once,
    /// so a bare screen that triggers it on appear spends the single chance the app gets.
    ///
    /// Only reachable while the decision is still open. The runner's own authorization is no guide
    /// to the app's — TCC tracks them separately — so this reads the screen rather than the API, and
    /// skips if the decision has already been made. To get back to a fresh state:
    ///   xcrun simctl privacy booted reset calendar Carlton.Alfred
    @MainActor
    func testCalendarExplainsItselfBeforeAsking() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["tab.calendar"].waitForExistence(timeout: 15))
        app.buttons["tab.calendar"].tap()

        guard app.staticTexts["See what's coming up"].waitForExistence(timeout: 15) else {
            throw XCTSkip("Calendar access has already been decided on this device")
        }

        XCTAssertTrue(
            app.buttons["Connect Calendar"].exists,
            "The explanation screen must offer the button that triggers the system prompt"
        )
        XCTAssertFalse(
            app.staticTexts["Nothing in the next 30 days"].exists,
            "An undecided calendar must not claim the schedule is empty"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Calendar — before access"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// With access granted, real events reach the screen grouped under their day.
    ///
    /// Seeds the events itself, because a simulator's calendar is empty and an agenda only ever
    /// tested against no data proves nothing. Compiled out anywhere but the simulator, so running
    /// the suite on a real device can never write into someone's actual calendar.
    @MainActor
    func testCalendarShowsSeededEvents() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Seeding only ever runs on a simulator")
        #else
        try XCTSkipUnless(
            EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            "Test runner has no calendar access — grant it with simctl privacy"
        )

        try seedEvent(title: "Dentist", hoursFromNow: 26, location: "5th Ave")
        try seedEvent(title: "Standup", hoursFromNow: 2, location: nil)

        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["tab.calendar"].waitForExistence(timeout: 15))
        app.buttons["tab.calendar"].tap()

        XCTAssertTrue(
            app.staticTexts["Standup"].waitForExistence(timeout: 15),
            "A seeded event should appear in the agenda"
        )
        XCTAssertTrue(app.staticTexts["Dentist"].exists, "Tomorrow's event should appear too")
        XCTAssertTrue(app.staticTexts["Today"].exists, "Events should be grouped under a day heading")
        XCTAssertTrue(app.staticTexts["Tomorrow"].exists)

        // Worth asserting, but read the screenshot too: a large title over this ScrollView stopped
        // being painted while staying present *and* hittable here, so this catches the title being
        // dropped outright and nothing subtler.
        XCTAssertTrue(
            app.navigationBars["Calendar"].staticTexts["Calendar"].exists,
            "The agenda kept no navigation title"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Calendar — agenda"
        shot.lifetime = .keepAlways
        add(shot)
        #endif
    }

    private func seedEvent(title: String, hoursFromNow: Int, location: String?) throws {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.location = location
        event.startDate = Date().addingTimeInterval(TimeInterval(hoursFromNow) * 3600)
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
    }
}
