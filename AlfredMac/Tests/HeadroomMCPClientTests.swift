import XCTest
@testable import Alfred

/// Covers the deterministic parts of the Headroom token-compression client:
/// the level thresholds that decide *when* Alfred compresses, and the
/// decoding of headroom_compress results (including the case where Headroom
/// returns a JSON structure rather than a plain string). Everything here
/// avoids spawning the binary — no subprocess, no registration writes.
final class HeadroomMCPClientTests: XCTestCase {

    // MARK: - Compression level thresholds

    func testModerateLeavesShortContentAlone() {
        // Moderate floor: 1500 chars. A typical short email body is below it
        // and should pass through uncompressed — the round-trip costs more
        // than the savings are worth.
        let short = String(repeating: "x", count: 1400)
        XCTAssertLessThan(short.count, HeadroomCompressionLevel.moderate.minimumCompressibleLength)
        XCTAssertGreaterThan(
            String(repeating: "x", count: 2000).count,
            HeadroomCompressionLevel.moderate.minimumCompressibleLength)
    }

    func testAggressiveLowersTheFloor() {
        XCTAssertLessThan(HeadroomCompressionLevel.aggressive.minimumCompressibleLength,
                          HeadroomCompressionLevel.moderate.minimumCompressibleLength)
        XCTAssertEqual(HeadroomCompressionLevel.aggressive.minimumCompressibleLength, 400)
    }

    // MARK: - CompressResult decoding

    func testDecodesStringResult() {
        let dict: [String: Any] = [
            "compressed": "a tiny summary of the email",
            "hash": "abc123def456",
            "original_tokens": 1200,
            "compressed_tokens": 150,
            "tokens_saved": 1050,
            "savings_percent": 87.5,
            "transforms": ["smart-crusher"],
            "note": "Original stored with hash=abc123def456",
        ]
        let result = CompressResult(dict: dict)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.compressedString, "a tiny summary of the email")
        XCTAssertEqual(result?.hash, "abc123def456")
        XCTAssertEqual(result?.tokensSaved, 1050)
        XCTAssertEqual(result?.savingsPercent, 87.5)
    }

    func testDecodesStructuredResultAsJSONText() {
        // Headroom may hand back a parsed structure for array-heavy content;
        // compressedString must round-trip it so the model sees one text block.
        let dict: [String: Any] = [
            "compressed": ["items": [1, 2, 3], "errors": ["FATAL at line 4"]],
            "hash": "h1",
        ]
        let result = CompressResult(dict: dict)
        XCTAssertNotNil(result)
        let text = result?.compressedString ?? ""
        XCTAssertTrue(text.contains("FATAL at line 4"), text)
        XCTAssertTrue(text.contains("\"items\""), text)
    }

    func testDecodesMissingFieldsToZeroes() {
        let dict: [String: Any] = ["compressed": "x", "hash": "h"]
        let result = CompressResult(dict: dict)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tokensSaved, 0)
        XCTAssertEqual(result?.savingsPercent, 0)
    }

    func testNilWithoutHash() {
        // The hash is what makes content retrievable — a result without it is
        // not a usable compression result.
        XCTAssertNil(CompressResult(dict: ["compressed": "x"]))
    }
}
