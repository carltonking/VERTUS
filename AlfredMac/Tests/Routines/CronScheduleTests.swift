import XCTest
@testable import Alfred

final class CronScheduleTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: c)!
    }

    // MARK: - Parsing

    func testValidExpressionsParse() {
        XCTAssertNotNil(CronSchedule("0 9 * * *"))
        XCTAssertNotNil(CronSchedule("*/30 * * * *"))
        XCTAssertNotNil(CronSchedule("0 8 * * 1"))
        XCTAssertNotNil(CronSchedule("0 0 1 1 *"))
        XCTAssertNotNil(CronSchedule("* * * * *"))
        XCTAssertNotNil(CronSchedule("15,45 9-17 * * 1-5"))
    }

    func testInvalidExpressionsRejected() {
        XCTAssertNil(CronSchedule("0 9 * *"))        // 4 fields
        XCTAssertNil(CronSchedule("0 9 * * * *"))    // 6 fields
        XCTAssertNil(CronSchedule("60 * * * *"))     // minute > 59
        XCTAssertNil(CronSchedule("0 24 * * *"))     // hour > 23
        XCTAssertNil(CronSchedule("0 9 32 * *"))     // dom > 31
        XCTAssertNil(CronSchedule("0 9 * 13 *"))     // month > 12
        XCTAssertNil(CronSchedule("0 9 * * 8"))      // dow > 7
        XCTAssertNil(CronSchedule("abc * * * *"))    // non-numeric
        XCTAssertNil(CronSchedule("*/0 * * * *"))    // zero step
    }

    // MARK: - Matching

    func testDailyAtNineMatchesOnlyThatMinute() {
        let cron = CronSchedule("0 9 * * *")!
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 9, 0), in: utc))
        XCTAssertFalse(cron.matches(date(2026, 6, 9, 9, 1), in: utc))
        XCTAssertFalse(cron.matches(date(2026, 6, 9, 10, 0), in: utc))
    }

    func testStepEveryFifteenMinutes() {
        let cron = CronSchedule("*/15 * * * *")!
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 10, 0), in: utc))
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 10, 15), in: utc))
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 10, 45), in: utc))
        XCTAssertFalse(cron.matches(date(2026, 6, 9, 10, 7), in: utc))
    }

    func testDayOfWeekMonday() {
        // 2026-06-08 is a Monday; 2026-06-09 is a Tuesday.
        let cron = CronSchedule("0 0 * * 1")!
        XCTAssertTrue(cron.matches(date(2026, 6, 8, 0, 0), in: utc))
        XCTAssertFalse(cron.matches(date(2026, 6, 9, 0, 0), in: utc))
    }

    func testSundayAcceptsZeroAndSeven() {
        // 2026-06-07 is a Sunday.
        XCTAssertTrue(CronSchedule("0 0 * * 0")!.matches(date(2026, 6, 7, 0, 0), in: utc))
        XCTAssertTrue(CronSchedule("0 0 * * 7")!.matches(date(2026, 6, 7, 0, 0), in: utc))
    }

    func testDomDowOrSemantics() {
        // "0 0 13 * 5": fires on the 13th OR any Friday (2026-06-12 is a Friday).
        let cron = CronSchedule("0 0 13 * 5")!
        XCTAssertTrue(cron.matches(date(2026, 6, 12, 0, 0), in: utc))  // Friday
        XCTAssertTrue(cron.matches(date(2026, 6, 13, 0, 0), in: utc))  // the 13th
        XCTAssertFalse(cron.matches(date(2026, 6, 10, 0, 0), in: utc)) // neither
    }

    func testListAndRange() {
        let cron = CronSchedule("15,45 9-17 * * 1-5")!
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 9, 15), in: utc))   // Tue 09:15
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 17, 45), in: utc))  // Tue 17:45
        XCTAssertFalse(cron.matches(date(2026, 6, 9, 8, 15), in: utc))  // hour out of range
        XCTAssertFalse(cron.matches(date(2026, 6, 9, 9, 30), in: utc))  // minute not listed
        XCTAssertFalse(cron.matches(date(2026, 6, 7, 9, 15), in: utc))  // Sunday
    }

    // MARK: - nextDate

    func testNextDateDaily() {
        let cron = CronSchedule("0 9 * * *")!
        let next = cron.nextDate(after: date(2026, 6, 8, 9, 30), in: utc)
        XCTAssertEqual(next, date(2026, 6, 9, 9, 0))
    }

    func testNextDateIsStrictlyAfter() {
        let cron = CronSchedule("0 9 * * *")!
        // Starting exactly at a matching minute returns the NEXT occurrence.
        let next = cron.nextDate(after: date(2026, 6, 8, 9, 0), in: utc)
        XCTAssertEqual(next, date(2026, 6, 9, 9, 0))
    }

    func testNextDateEveryThirtyMinutes() {
        let cron = CronSchedule("*/30 * * * *")!
        let next = cron.nextDate(after: date(2026, 6, 9, 10, 5), in: utc)
        XCTAssertEqual(next, date(2026, 6, 9, 10, 30))
    }

    func testStepFromSingleValueIsRange() {
        // "5/15" means 5,20,35,50 (every 15 starting at 5), not just {5}.
        let cron = CronSchedule("5/15 * * * *")!
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 10, 5), in: utc))
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 10, 20), in: utc))
        XCTAssertTrue(cron.matches(date(2026, 6, 9, 10, 50), in: utc))
        XCTAssertFalse(cron.matches(date(2026, 6, 9, 10, 7), in: utc))
    }

    func testNextDateLeapDaySpansYears() {
        // Pure Feb-29 schedule: next from 2026-06-09 is 2028-02-29 (>366 days away).
        let cron = CronSchedule("0 0 29 2 *")!
        let next = cron.nextDate(after: date(2026, 6, 9, 12, 0), in: utc)
        XCTAssertEqual(next, date(2028, 2, 29, 0, 0))
    }
}
