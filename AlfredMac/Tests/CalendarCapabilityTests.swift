import XCTest
@testable import Alfred

/// Unit tests for the pure string→Date parsing the calendar/reminder MCP tools
/// rely on. The EventKit side needs a live store + permission, so only the
/// deterministic parsing is tested here.
final class CalendarCapabilityTests: XCTestCase {

    private func local(_ format: String, _ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.date(from: value)
    }

    private func utc(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testISOParseWithExplicitTimeZone() throws {
        let parsed = try XCTUnwrap(CalendarCapability.parseISO("2026-09-05T15:00:00Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970, utc(y: 2026, mo: 9, d: 5, h: 15, mi: 0).timeIntervalSince1970, accuracy: 1)
    }

    func testISOParseWithFractionalSecondsAndZone() throws {
        let parsed = try XCTUnwrap(CalendarCapability.parseISO("2026-09-05T15:00:00.500Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970, utc(y: 2026, mo: 9, d: 5, h: 15, mi: 0).timeIntervalSince1970 + 0.5, accuracy: 0.001)
    }

    func testFloatingTimeIsLocal() {
        // No zone suffix means wall-clock in the user's time zone.
        XCTAssertEqual(CalendarCapability.parseISO("2026-09-05T09:30:00"),
                       local("yyyy-MM-dd'T'HH:mm:ss", "2026-09-05T09:30:00"))
        XCTAssertEqual(CalendarCapability.parseISO("2026-09-05 09:30"),
                       local("yyyy-MM-dd HH:mm", "2026-09-05 09:30"))
    }

    func testBareDateIsLocalMidnight() {
        XCTAssertEqual(CalendarCapability.parseISO("2026-09-05"),
                       local("yyyy-MM-dd", "2026-09-05"))
    }

    func testGarbageAndEmptyReject() {
        XCTAssertNil(CalendarCapability.parseISO(""))
        XCTAssertNil(CalendarCapability.parseISO("  "))
        XCTAssertNil(CalendarCapability.parseISO("tomorrow at 3"))
        XCTAssertNil(CalendarCapability.parseISO("not-a-date"))
    }
}