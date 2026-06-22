import XCTest
@testable import Alfred

/// Covers the pure click-reference parsing for the Semantic Object Map. The AX enumeration itself
/// needs a live UI, but the brittle text parsing (index vs label vs raw coordinate) is unit-tested
/// here, plus resolution against a fixed map.
final class AccessibilityObjectMapTests: XCTestCase {
    typealias Ref = AccessibilityObjectMap.ClickReference

    func testIndexReferences() {
        XCTAssertEqual(AccessibilityObjectMap.parseClickReference("click element 7"), .index(7))
        XCTAssertEqual(AccessibilityObjectMap.parseClickReference("click #3"), .index(3))
        XCTAssertEqual(AccessibilityObjectMap.parseClickReference("Click Element 12"), .index(12))
    }

    func testLabelReferences() {
        XCTAssertEqual(AccessibilityObjectMap.parseClickReference("click the Submit button"), .label("Submit"))
        XCTAssertEqual(AccessibilityObjectMap.parseClickReference(#"click "Sign In""#), .label("Sign In"))
        XCTAssertEqual(AccessibilityObjectMap.parseClickReference("click Settings"), .label("Settings"))
    }

    func testRawCoordinateClickIsNotAnElementReference() {
        // "click 100 200" must fall through to the coordinate parser, not be read as a label/index.
        XCTAssertNil(AccessibilityObjectMap.parseClickReference("click 100 200"))
    }

    func testNonClickLinesIgnored() {
        XCTAssertNil(AccessibilityObjectMap.parseClickReference("type \"hello\""))
        XCTAssertNil(AccessibilityObjectMap.parseClickReference("double click 10 20"))
        XCTAssertNil(AccessibilityObjectMap.parseClickReference("hotkey cmd c"))
    }

    func testResolveAgainstMap() {
        let map = [
            AccessibilityElement(index: 1, role: "AXButton", label: "Cancel", frame: CGRect(x: 0, y: 0, width: 80, height: 30)),
            AccessibilityElement(index: 2, role: "AXButton", label: "Submit", frame: CGRect(x: 100, y: 0, width: 80, height: 30)),
        ]
        XCTAssertEqual(AccessibilityObjectMap.resolve(.index(2), in: map)?.label, "Submit")
        XCTAssertEqual(AccessibilityObjectMap.resolve(.label("submit"), in: map)?.index, 2, "match is case-insensitive")
        XCTAssertNil(AccessibilityObjectMap.resolve(.index(9), in: map), "out-of-range index resolves to nil")
        XCTAssertNil(AccessibilityObjectMap.resolve(.label("Delete"), in: map))
    }

    func testRenderIsNumbered() {
        let map = [AccessibilityElement(index: 1, role: "AXButton", label: "OK", frame: .zero)]
        XCTAssertEqual(AccessibilityObjectMap.render(map), #"1: Button "OK""#)
    }
}
