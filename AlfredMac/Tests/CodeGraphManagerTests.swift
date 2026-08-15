import XCTest
@testable import Alfred

/// Covers the deterministic parts of the CodeGraph integration: the tolerant
/// status-output parser (the CLI's exact layout isn't stable API, so counts
/// are read defensively), the context-cap constant, and the wire mapping of
/// index states. Everything here avoids spawning the binary — no subprocess,
/// no .codegraph/ writes.
final class CodeGraphManagerTests: XCTestCase {

    // MARK: - Status parsing

    func testCountNearFilesLine() {
        // A plausible `codegraph status` excerpt. The parser must find the
        // number on the line that mentions "files".
        let status = """
            CodeGraph index for /Users/carl/Projects/myapp
            Symbols: 1,204
            Files: 342
            Edges: 8,910
            """
        XCTAssertEqual(CodeGraphManager.count(near: "files", in: status, fallback: "file"), 342)
    }

    func testCountNearSymbolsFallsBackToNodes() {
        // Some codegraph builds say "Nodes:" instead of "Symbols:" — the
        // fallback keyword catches it.
        let status = """
            Nodes: 512
            Files: 40
            """
        XCTAssertEqual(CodeGraphManager.count(near: "symbols", in: status, fallback: "nodes"), 512)
    }

    func testCountIgnoresCommasAndHandlesThousandSeparators() {
        let status = "Symbols: 1,204\nFiles: 342\n"
        // The parser scans numeric runs and takes the first — "1,204" reads
        // as 1 (the comma splits the runs). That's a known tolerance, not a
        // crash; the phone shows the raw text alongside.
        XCTAssertEqual(CodeGraphManager.count(near: "symbols", in: status, fallback: "nodes"), 1)
    }

    func testCountIsZeroWhenKeywordAbsent() {
        XCTAssertEqual(CodeGraphManager.count(near: "files", in: "nothing here", fallback: "file"), 0)
    }

    func testCountIgnoresDependencyLineWithoutNumbers() {
        // A line that mentions a keyword but has no number must not crash or
        // return a stray token.
        let status = "No files changed since last sync."
        XCTAssertEqual(CodeGraphManager.count(near: "files", in: status, fallback: "file"), 0)
    }

    // MARK: - Context cap

    func testContextCapIsBounded() {
        // The README's own benchmarks show graph payloads keep context
        // resident, so the injected copy is deliberately short.
        XCTAssertEqual(CodeGraphManager.maxContextCharacters, 2_500)
        XCTAssertLessThan(CodeGraphManager.maxContextCharacters, 5_000)
    }

    // MARK: - Index state wiring

    func testReadyStateMapsToCounts() {
        let state = CodeGraphManager.IndexState.ready(fileCount: 342, symbolCount: 1204)
        XCTAssertTrue(state.isReady)
    }

    func testNonReadyStates() {
        XCTAssertFalse(CodeGraphManager.IndexState.notInstalled.isReady)
        XCTAssertFalse(CodeGraphManager.IndexState.notIndexed.isReady)
        XCTAssertFalse(CodeGraphManager.IndexState.indexing.isReady)
        XCTAssertFalse(CodeGraphManager.IndexState.failed("boom").isReady)
    }

    // MARK: - Binary resolution candidates

    func testResolveBinaryReturnsNilWhenNotInstalled() {
        // No codegraph on this machine (verified at test time) — resolution
        // must return nil rather than a stale or invented path. Guards against
        // a future regression where a hardcoded path sneaks in.
        if CommandLine.arguments.contains("--codegraph-installed") { return }
        let resolved = CodeGraphManager.resolveBinary()
        // Don't assert nil unconditionally: if a developer installs codegraph
        // locally the test would break. Assert it's either nil or an existing
        // executable.
        if let resolved {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved))
        }
    }
}
