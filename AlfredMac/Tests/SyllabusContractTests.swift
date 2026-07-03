import XCTest
@testable import Alfred

/// Parity with the cloud bot's api/_lib/keys.ts + study.ts. The expected hashes/strings below were
/// produced by the Node implementation — if these drift, the Mac and Telegram bots will create
/// DUPLICATE calendar events for the same syllabus item. Keep them byte-identical.
final class SyllabusContractTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(SyllabusKeys.normCode("CS 101"), "CS101")
        XCTAssertEqual(SyllabusKeys.normCode("cs-101"), "CS101")
        XCTAssertEqual(SyllabusKeys.normTitle("CS 101 Midterm 2", code: "CS 101"), "midterm 2")
        XCTAssertEqual(SyllabusKeys.normTitle("PS #3 (CS101)", code: "CS101"), "ps 3")
        XCTAssertEqual(SyllabusKeys.normTitle("Problem Set 3"), "problem set 3")
    }

    func testItemKeyParityWithCloud() {
        // Node: itemKey("CS 101","final","Final Exam","2026-12-15") === "a4d7bcaf9db8"
        XCTAssertEqual(SyllabusKeys.itemKey("CS 101", "final", "Final Exam", "2026-12-15"), "a4d7bcaf9db8")
        // Code normalization is invariant across "CS 101" / "cs101"
        XCTAssertEqual(
            SyllabusKeys.itemKey("cs101", "final", "Final Exam", "2026-12-15"),
            SyllabusKeys.itemKey("CS 101", "final", "Final Exam", "2026-12-15")
        )
        // Title echo of the code is stripped → same key with or without it
        XCTAssertEqual(
            SyllabusKeys.itemKey("CS 101", "final", "CS 101 Final Exam", "2026-12-15"),
            SyllabusKeys.itemKey("CS 101", "final", "Final Exam", "2026-12-15")
        )
        // Date is part of the key → distinct dates never collide
        XCTAssertNotEqual(
            SyllabusKeys.itemKey("CS 101", "reading", "Reading Response", "2026-09-01"),
            SyllabusKeys.itemKey("CS 101", "reading", "Reading Response", "2026-09-08")
        )
    }

    func testStudyKeyAndTokenParity() {
        // Node: studyKey("CS 101","a4d7bcaf9db8",14) === "04e2f0bcd6a4"
        XCTAssertEqual(SyllabusKeys.studyKey("CS 101", "a4d7bcaf9db8", 14), "04e2f0bcd6a4")

        let token = SyllabusKeys.schoolToken(key: "04e2f0bcd6a4", code: "CS 101", type: "study",
                                             batch: "CS101-2026", linkedExamKey: "a4d7bcaf9db8")
        XCTAssertEqual(token, "[alfred|v1|k=04e2f0bcd6a4|c=CS101|t=study|b=CS101-2026|x=a4d7bcaf9db8]")

        XCTAssertEqual(SyllabusKeys.schoolURL("CS 101", "exam", "abc123def456"),
                       "alfred://school/CS101/exam/abc123def456")
    }

    func testTokenStripsEscapableChars() {
        // Weight/topics with commas/semicolons must be sanitized so the token has no ICS-escapable chars.
        let token = SyllabusKeys.schoolToken(key: "k00000000000", code: "CS 101", type: "exam",
                                             batch: "CS101-2026", weight: "20%, extra", topics: ["graphs, trees", "DP"])
        let inner = String(token.dropFirst("[alfred|v1|".count).dropLast())
        XCTAssertFalse(inner.contains(","))
        XCTAssertFalse(inner.contains(";"))
        XCTAssertFalse(inner.contains("\\"))
        XCTAssertTrue(token.contains("tp=graphs trees~DP"))
    }

    func testStudyPlannerBackwardAndInFuture() {
        let exam = SyllabusItem(type: .final, title: "Final Exam", date: "2026-12-15",
                                start: nil, end: nil, allDay: true, weight: "40%",
                                topics: ["ch1", "ch2", "ch3", "ch4"], location: "Hall A", notes: nil)
        let now = isoParse("2026-11-01")!  // well before the exam
        let sessions = StudyPlanner.sessions(for: exam, code: "CS 101", batch: "CS101-2026", now: now)
        XCTAssertFalse(sessions.isEmpty)
        // final offsets [14,10,7,4,2,1] → Dec 1,5,8,11,13,14
        XCTAssertEqual(sessions.map { $0.date }, ["2026-12-01", "2026-12-05", "2026-12-08", "2026-12-11", "2026-12-13", "2026-12-14"])
        XCTAssertTrue(sessions.allSatisfy { $0.date < "2026-12-15" })
        XCTAssertTrue(sessions.allSatisfy { $0.url.hasPrefix("alfred://school/CS101/study/") })
    }
}
