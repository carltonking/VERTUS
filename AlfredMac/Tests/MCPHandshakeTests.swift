import XCTest
@testable import Alfred

/// Pins the MCP JSON-RPC wire frames. The original client sent a bare `tools/list`
/// with no handshake, which spec-compliant servers reject — these assert the
/// initialize -> notifications/initialized -> request frames are well-formed and
/// newline-delimited (the stdio transport requirement).
final class MCPHandshakeTests: XCTestCase {

    private func decode(_ data: Data) throws -> [String: Any] {
        XCTAssertEqual(data.last, 0x0A, "every frame must be newline-terminated")
        let obj = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        return try XCTUnwrap(obj)
    }

    func testInitializeFrame() throws {
        let json = try decode(MCPRequest.initialize().encodedLine())
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? Int, 1)
        XCTAssertEqual(json["method"] as? String, "initialize")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertNotNil(params["protocolVersion"] as? String)
        XCTAssertNotNil(params["capabilities"])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "Alfred")
    }

    func testInitializedNotificationHasNoId() throws {
        let json = try decode(MCPNotification.initialized().encodedLine())
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["method"] as? String, "notifications/initialized")
        XCTAssertNil(json["id"], "a notification must not carry an id")
    }

    func testRequestFrameUsesDistinctId() throws {
        // tools/list and tools/call are issued with id 2 so the reader can tell the real
        // response apart from the initialize response (id 1).
        let json = try decode(MCPRequest(id: 2, method: "tools/list", params: [:]).encodedLine())
        XCTAssertEqual(json["id"] as? Int, 2)
        XCTAssertEqual(json["method"] as? String, "tools/list")
        XCTAssertNotEqual(json["id"] as? Int, MCPRequest.initialize().id,
                          "request id must differ from the initialize id")
    }
}
