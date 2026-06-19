import XCTest
@testable import Alfred

final class QueryNormalizerTests: XCTestCase {

    func testStripsLeadingPoliteness() {
        XCTAssertEqual(QueryNormalizer.normalize("Can you open Spotify"), "open Spotify")
        XCTAssertEqual(QueryNormalizer.normalize("could you please text mom saying hi"), "text mom saying hi")
        XCTAssertEqual(QueryNormalizer.normalize("please open Notes"), "open Notes")
        XCTAssertEqual(QueryNormalizer.normalize("I need you to delete report.pdf"), "delete report.pdf")
    }

    func testStripsAlfredAddress() {
        XCTAssertEqual(QueryNormalizer.normalize("Alfred, open Notes"), "open Notes")
        XCTAssertEqual(QueryNormalizer.normalize("hey alfred pull up my downloads"), "pull up my downloads")
    }

    func testStripsTrailingFiller() {
        XCTAssertEqual(QueryNormalizer.normalize("open spotify for me"), "open spotify")
        XCTAssertEqual(QueryNormalizer.normalize("delete report.pdf please"), "delete report.pdf")
        XCTAssertEqual(QueryNormalizer.normalize("organize my downloads, thanks"), "organize my downloads")
    }

    func testStripsStackedWrappers() {
        XCTAssertEqual(QueryNormalizer.normalize("hey alfred can you please open spotify for me"), "open spotify")
    }

    func testPreservesCaseAndParameters() {
        XCTAssertEqual(QueryNormalizer.normalize("text Carlton, hey there"), "text Carlton, hey there")
        XCTAssertEqual(QueryNormalizer.normalize("email Bob@Work.com about Q3"), "email Bob@Work.com about Q3")
    }

    func testLeavesPlainQueriesUntouched() {
        XCTAssertEqual(QueryNormalizer.normalize("what is 6!"), "what is 6!")
        XCTAssertEqual(QueryNormalizer.normalize("how can you tell if a number is prime"),
                       "how can you tell if a number is prime")
    }

    func testDoesNotStripPartialWordMatch() {
        // "alfredo" must not be treated as the "alfred" address.
        XCTAssertEqual(QueryNormalizer.normalize("alfredo sauce recipe"), "alfredo sauce recipe")
    }

    func testAllFillerFallsBackToOriginal() {
        XCTAssertEqual(QueryNormalizer.normalize("please"), "please")
    }
}
