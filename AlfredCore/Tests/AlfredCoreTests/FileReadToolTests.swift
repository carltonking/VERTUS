import XCTest
@testable import AlfredCore

final class FileReadToolTests: XCTestCase {

    private var tempDir: URL!
    private var vaultDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileReadToolTests-\(UUID().uuidString)")
        vaultDir = tempDir.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testReadsFileInsideVault() async throws {
        let note = vaultDir.appendingPathComponent("note.md")
        try "hello vault".write(to: note, atomically: true, encoding: .utf8)

        let tool = FileReadTool(vaultPath: vaultDir.path)
        let args = #"{"path": "\#(note.path)"}"#
        let content = try await tool.execute(arguments: args)
        XCTAssertEqual(content, "hello vault")
    }

    func testRefusesFileOutsideVault() async throws {
        let outside = tempDir.appendingPathComponent("secret.txt")
        try "top secret".write(to: outside, atomically: true, encoding: .utf8)

        let tool = FileReadTool(vaultPath: vaultDir.path)
        let args = #"{"path": "\#(outside.path)"}"#
        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected a throw for an outside-vault path")
        } catch let error as LLMError {
            XCTAssertTrue(error.localizedDescription.contains("outside the allowed vault"))
        }
    }

    func testRefusesPathTraversalEscapingVault() async throws {
        let outside = tempDir.appendingPathComponent("secret.txt")
        try "top secret".write(to: outside, atomically: true, encoding: .utf8)

        let tool = FileReadTool(vaultPath: vaultDir.path)
        // `../` from inside the vault must not escape the root.
        let traversal = (vaultDir.path as NSString).appendingPathComponent("../secret.txt")
        let args = #"{"path": "\#(traversal)"}"#
        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected a throw for a traversal path")
        } catch let error as LLMError {
            XCTAssertTrue(error.localizedDescription.contains("outside the allowed vault"))
        }
    }

    func testRefusesOverLargeFile() async throws {
        let big = vaultDir.appendingPathComponent("big.md")
        try String(repeating: "x", count: FileReadTool.maxReadBytes + 1)
            .write(to: big, atomically: true, encoding: .utf8)

        let tool = FileReadTool(vaultPath: vaultDir.path)
        let args = #"{"path": "\#(big.path)"}"#
        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected a throw for an oversized file")
        } catch let error as LLMError {
            XCTAssertTrue(error.localizedDescription.contains("1MB limit"))
        }
    }

    func testRejectsMissingPathArgument() async throws {
        let tool = FileReadTool(vaultPath: vaultDir.path)
        do {
            _ = try await tool.execute(arguments: "{}")
            XCTFail("expected a throw for a missing path")
        } catch let error as LLMError {
            XCTAssertTrue(error.localizedDescription.contains("'path'"))
        }
    }
}
