import XCTest
@testable import AlfredCore

final class ToolCallAccumulatorTests: XCTestCase {

    /// Hermes streams `function.arguments` split across SSE chunks — e.g.
    /// `{"function": {"arguments": "{\"path\":"` first, then the remainder.
    /// The accumulator must append fragments per `tool_call` index so the
    /// final arguments string is the complete JSON, not the last fragment.
    func testAccumulatesArgumentsAcrossChunksPerIndex() throws {
        var acc = ToolCallAccumulator()

        // First chunk: call header + the first fragment of the arguments JSON.
        let first = acc.accumulate(deltas: [
            [
                "index": 0,
                "id": "call_abc",
                "type": "function",
                "function": [
                    "name": "read_file",
                    "arguments": "{\"path\":",
                ],
            ]
        ])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].function.name, "read_file")
        XCTAssertEqual(first[0].function.arguments, "{\"path\":")

        // Second chunk: the rest of the arguments.
        let second = acc.accumulate(deltas: [
            [
                "index": 0,
                "function": ["arguments": " \"/Users/me/vault/note.md\"}"],
            ]
        ])
        XCTAssertEqual(second.count, 1)
        let accumulated = second[0].function.arguments
        XCTAssertEqual(accumulated, "{\"path\": \"/Users/me/vault/note.md\"}")

        // The accumulated arguments must be valid JSON with the right path.
        let data = try XCTUnwrap(accumulated.data(using: .utf8))
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "/Users/me/vault/note.md")
    }

    /// Multiple tool calls stream in parallel; indices must stay independent.
    func testAccumulatesSeparateIndicesIndependently() throws {
        var acc = ToolCallAccumulator()

        _ = acc.accumulate(deltas: [
            ["index": 0, "id": "call_a", "function": ["name": "read_file", "arguments": "{\"path\":"]],
            ["index": 1, "id": "call_b", "function": ["name": "read_file", "arguments": "{\"path\":"]],
        ])
        _ = acc.accumulate(deltas: [
            ["index": 1, "function": ["arguments": " \"/b.md\"}"]],
            ["index": 0, "function": ["arguments": " \"/a.md\"}"]],
        ])

        let completed = acc.completedCalls
        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(completed[0].function.arguments, "{\"path\": \"/a.md\"}")
        XCTAssertEqual(completed[1].function.arguments, "{\"path\": \"/b.md\"}")
    }

    /// A delta without an index is ignored, not fatal.
    func testDeltaWithoutIndexIsSkipped() {
        var acc = ToolCallAccumulator()
        let calls = acc.accumulate(deltas: [
            ["function": ["arguments": "orphan"]],
        ])
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(acc.completedCalls.isEmpty)
    }
}
