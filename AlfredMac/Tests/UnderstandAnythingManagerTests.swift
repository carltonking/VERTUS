import XCTest
@testable import Alfred

/// Covers the deterministic parts of the Understand-Anything integration: the
/// tolerant knowledge-graph.json decoding, and the local queries (search,
/// impact, explain, architecture, trace, subgraphs) that back the phone's
/// visual sheet and the understand_* MCP tools. Everything runs against a
/// fixture graph in a temp project directory — no subprocess, no plugin
/// installed, no network.
@MainActor
final class UnderstandAnythingManagerTests: XCTestCase {

    /// The fixture: a tiny TS project with an auth module, an API layer, a DB
    /// layer and a test file — the shapes the real pipeline emits.
    private static let fixtureJSON = """
    {
      "version": "1.0.0",
      "project": {
        "name": "fixture-app",
        "languages": ["typescript"],
        "frameworks": [],
        "description": "A tiny fixture project for the tests.",
        "analyzedAt": "2026-08-01T00:00:00.000Z"
      },
      "nodes": [
        {"id": "file:src/main.ts", "type": "file", "name": "main.ts", "filePath": "src/main.ts", "summary": "The app entry point.", "tags": ["entry"]},
        {"id": "file:src/api.ts", "type": "file", "name": "api.ts", "filePath": "src/api.ts", "summary": "HTTP layer.", "tags": ["api"]},
        {"id": "file:src/auth.ts", "type": "file", "name": "auth.ts", "filePath": "src/auth.ts", "summary": "Authentication logic.", "tags": ["auth", "security"]},
        {"id": "file:src/db.ts", "type": "file", "name": "db.ts", "filePath": "src/db.ts", "summary": "Database access.", "tags": ["db"]},
        {"id": "file:test/auth.test.ts", "type": "file", "name": "auth.test.ts", "filePath": "test/auth.test.ts", "summary": "Tests for the auth module.", "tags": ["test"]},
        {"id": "function:src/auth.ts:login", "type": "function", "name": "login", "filePath": "src/auth.ts", "summary": "Logs a user in.", "tags": ["auth"]},
        {"id": "function:src/auth.ts:authenticate", "type": "function", "name": "authenticate", "filePath": "src/auth.ts", "summary": "Validates credentials.", "tags": ["auth"]},
        {"id": "function:src/api.ts:handleRequest", "type": "function", "name": "handleRequest", "filePath": "src/api.ts", "summary": "Routes an HTTP request.", "tags": ["api"]},
        {"id": "function:src/db.ts:saveUser", "type": "function", "name": "saveUser", "filePath": "src/db.ts", "summary": "Persists a user row.", "tags": ["db"]},
        {"id": "class:src/auth.ts:AuthService", "type": "class", "name": "AuthService", "filePath": "src/auth.ts", "summary": "Holds the auth methods.", "tags": ["auth"]},
        {"id": "class:src/db.ts:DbClient", "type": "class", "name": "DbClient", "filePath": "src/db.ts", "summary": "Wraps the database connection.", "tags": ["db"]}
      ],
      "edges": [
        {"source": "file:src/main.ts", "target": "file:src/api.ts", "type": "imports", "weight": 0.7},
        {"source": "file:src/api.ts", "target": "file:src/auth.ts", "type": "imports", "weight": 0.7},
        {"source": "file:src/api.ts", "target": "file:src/db.ts", "type": "imports", "weight": 0.7},
        {"source": "function:src/api.ts:handleRequest", "target": "class:src/auth.ts:AuthService", "type": "calls", "weight": 0.8},
        {"source": "function:src/api.ts:handleRequest", "target": "function:src/db.ts:saveUser", "type": "calls", "weight": 0.8},
        {"source": "class:src/auth.ts:AuthService", "target": "function:src/auth.ts:login", "type": "contains", "weight": 1.0},
        {"source": "class:src/auth.ts:AuthService", "target": "function:src/auth.ts:authenticate", "type": "contains", "weight": 1.0},
        {"source": "file:src/auth.ts", "target": "class:src/auth.ts:AuthService", "type": "contains", "weight": 1.0},
        {"source": "file:src/db.ts", "target": "class:src/db.ts:DbClient", "type": "contains", "weight": 1.0},
        {"source": "function:src/db.ts:saveUser", "target": "class:src/db.ts:DbClient", "type": "calls", "weight": 0.8},
        {"source": "file:test/auth.test.ts", "target": "file:src/auth.ts", "type": "imports", "weight": 0.7},
        {"source": "class:src/auth.ts:AuthService", "target": "file:test/auth.test.ts", "type": "tested_by", "weight": 0.5},
        {"source": "file:src/main.ts", "target": "function:src/api.ts:handleRequest", "type": "calls", "weight": 0.8}
      ],
      "layers": [
        {"id": "layer:api", "name": "API", "description": "HTTP layer", "nodeIds": ["file:src/api.ts"]},
        {"id": "layer:data", "name": "Data", "description": "Storage", "nodeIds": ["file:src/db.ts"]},
        {"id": "layer:ui", "name": "UI", "description": "Entry", "nodeIds": ["file:src/main.ts"]}
      ]
    }
    """

    /// The fixture with the layers array removed — what a deterministic-only
    /// run (no architecture agent) leaves behind.
    private static let fixtureWithoutLayers: String = {
        guard let data = fixtureJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return fixtureJSON }
        object["layers"] = nil
        object["tour"] = nil
        guard let stripped = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: stripped, encoding: .utf8)
        else { return fixtureJSON }
        return json
    }()

    /// Write the fixture into a fresh temp project and return its path.
    private func makeFixtureProject(json: String = UnderstandAnythingManagerTests.fixtureJSON) -> String {
        let dir = NSTemporaryDirectory()
            .appending("ua-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: (dir as NSString).appendingPathComponent(".ua"),
            withIntermediateDirectories: true)
        let file = ((dir as NSString).appendingPathComponent(".ua") as NSString)
            .appendingPathComponent("knowledge-graph.json")
        try? json.write(toFile: file, atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Status

    func testCommittedGraphReadsAsReadyWithoutPlugin() async {
        // A committed .ua/ graph is usable even when the plugin isn't installed
        // (the tool's docs-as-code pattern) — the read path must not gate on it.
        let project = makeFixtureProject()
        let state = await UnderstandAnythingManager.shared.ensureAnalyzed(projectPath: project)
        guard case .ready(let nodes, let edges, let layers) = state else {
            XCTFail("expected ready, got \(state)")
            return
        }
        XCTAssertEqual(nodes, 11)
        XCTAssertEqual(edges, 13)
        XCTAssertEqual(layers, 3)
    }

    func testNoGraphIsNotAnalyzed() async {
        let dir = NSTemporaryDirectory().appending("ua-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let state = await UnderstandAnythingManager.shared.ensureAnalyzed(projectPath: dir)
        XCTAssertEqual(state, .notAnalyzed)
    }

    // MARK: - Search

    func testSearchExactNameRanksFirst() async {
        let project = makeFixtureProject()
        let hits = await UnderstandAnythingManager.shared.search(query: "AuthService", projectPath: project)
        XCTAssertEqual(hits.first?.id, "class:src/auth.ts:AuthService")
    }

    func testSearchMatchesConceptsAcrossNamesAndPaths() async {
        let project = makeFixtureProject()
        let hits = await UnderstandAnythingManager.shared.search(query: "auth", projectPath: project)
        let ids = Set(hits.map(\.id))
        XCTAssertTrue(ids.contains("class:src/auth.ts:AuthService"))
        XCTAssertTrue(ids.contains("function:src/auth.ts:authenticate"))
        XCTAssertTrue(ids.contains("file:src/auth.ts"))
        // Non-auth nodes must not appear.
        XCTAssertFalse(ids.contains("file:src/db.ts"))
        XCTAssertFalse(ids.contains("function:src/db.ts:saveUser"))
    }

    func testSearchEmptyQueryReturnsNothing() async {
        let project = makeFixtureProject()
        let hits = await UnderstandAnythingManager.shared.search(query: "   ", projectPath: project)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Impact

    func testImpactFindsDirectAndTransitiveDependents() async {
        let project = makeFixtureProject()
        let hits = await UnderstandAnythingManager.shared.impact(
            of: "class:src/auth.ts:AuthService", projectPath: project)
        let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0) })

        // Direct: the API function that calls it, its containing file, and the
        // test that covers it (tested_by flips direction).
        XCTAssertEqual(byID["function:src/api.ts:handleRequest"]?.depth, 0)
        XCTAssertEqual(byID["file:src/auth.ts"]?.depth, 0)
        XCTAssertEqual(byID["file:test/auth.test.ts"]?.depth, 0)
        // Transitive: api.ts through the auth.ts import; main.ts through
        // handleRequest (main → handleRequest → AuthService = 2 hops).
        XCTAssertEqual(byID["file:src/api.ts"]?.depth, 1)
        XCTAssertEqual(byID["file:src/main.ts"]?.depth, 1)
    }

    func testImpactResolvesByNameNotJustID() async {
        let project = makeFixtureProject()
        let hits = await UnderstandAnythingManager.shared.impact(of: "DbClient", projectPath: project)
        XCTAssertTrue(hits.contains { $0.id == "function:src/db.ts:saveUser" })
    }

    func testImpactOfChangedFunctionIncludesItsContainer() async {
        // Changing authenticate breaks the class that contains it (it no longer
        // compiles) — the contains direction rule.
        let project = makeFixtureProject()
        let hits = await UnderstandAnythingManager.shared.impact(
            of: "function:src/auth.ts:authenticate", projectPath: project)
        XCTAssertTrue(hits.contains { $0.id == "class:src/auth.ts:AuthService" && $0.depth == 0 })
    }

    func testImpactUnknownTargetReturnsEmpty() async {
        let project = makeFixtureProject()
        let hits = await UnderstandAnythingManager.shared.impact(of: "doesNotExist", projectPath: project)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Explain

    func testExplainShowsNeighborsAndLayers() async {
        let project = makeFixtureProject()
        let explanation = await UnderstandAnythingManager.shared.explain(
            nodeID: "file:src/api.ts", projectPath: project)
        guard let explanation else {
            XCTFail("no explanation")
            return
        }
        XCTAssertEqual(explanation.node.displayName, "api.ts")
        // In: main.ts imports api.ts. Out: api.ts imports auth.ts and db.ts.
        let incoming = explanation.neighbors.filter { $0.direction == "in" }.map(\.node.id)
        let outgoing = explanation.neighbors.filter { $0.direction == "out" }.map(\.node.id)
        XCTAssertTrue(incoming.contains("file:src/main.ts"))
        XCTAssertTrue(outgoing.contains("file:src/auth.ts"))
        XCTAssertTrue(outgoing.contains("file:src/db.ts"))
        XCTAssertEqual(explanation.layers, ["API"])
    }

    func testExplainUnknownNodeReturnsNil() async {
        let project = makeFixtureProject()
        let explanation = await UnderstandAnythingManager.shared.explain(nodeID: "nope", projectPath: project)
        XCTAssertNil(explanation)
    }

    // MARK: - Architecture

    func testArchitectureUsesLayers() async {
        let project = makeFixtureProject()
        let layers = await UnderstandAnythingManager.shared.architecture(projectPath: project)
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(Set(layers.map(\.name)), ["API", "Data", "UI"])
        XCTAssertEqual(layers.first { $0.name == "API" }?.sampleNodes.first, "api.ts")
    }

    func testArchitectureFallsBackToDirectoriesWithoutLayers() async {
        // A deterministic-only graph has no layers array.
        let project = makeFixtureProject(json: Self.fixtureWithoutLayers)
        let layers = await UnderstandAnythingManager.shared.architecture(projectPath: project)
        XCTAssertTrue(layers.contains { $0.name == "src" })
        XCTAssertTrue(layers.contains { $0.name == "test" })
    }

    // MARK: - Trace

    func testTraceFindsForwardPath() async {
        let project = makeFixtureProject()
        let trace = await UnderstandAnythingManager.shared.trace(
            from: "file:src/main.ts", to: "file:src/db.ts", projectPath: project)
        XCTAssertEqual(trace?.nodeIDs, ["file:src/main.ts", "file:src/api.ts", "file:src/db.ts"])
        XCTAssertEqual(trace?.edgeTypes, ["imports", "imports"])
    }

    func testTraceBackwardWalksToRoot() async {
        let project = makeFixtureProject()
        // From saveUser back: handleRequest calls it, main.ts calls
        // handleRequest, main.ts has no callers → the root.
        let trace = await UnderstandAnythingManager.shared.trace(
            from: "function:src/db.ts:saveUser", to: nil, projectPath: project)
        XCTAssertEqual(trace?.nodeIDs.last, "file:src/main.ts")
        XCTAssertEqual(trace?.nodeIDs.first, "function:src/db.ts:saveUser")
        XCTAssertEqual(trace?.nodeIDs.count, 3)
    }

    func testTraceNoPathReturnsNil() async {
        let project = makeFixtureProject()
        // No forward path reaches the test file from main (imports stop at
        // api/db; nothing imports test/).
        let trace = await UnderstandAnythingManager.shared.trace(
            from: "file:src/main.ts", to: "file:test/auth.test.ts", projectPath: project)
        XCTAssertNil(trace)
    }

    // MARK: - Subgraphs

    func testNeighborhoodBoundsToDepthAndLimit() async {
        let project = makeFixtureProject()
        let subgraph = await UnderstandAnythingManager.shared.neighborhood(
            around: "class:src/auth.ts:AuthService", projectPath: project, depth: 1, limit: 60)
        guard let subgraph else {
            XCTFail("no subgraph")
            return
        }
        let ids = Set(subgraph.nodes.map(\.id))
        XCTAssertTrue(ids.contains("class:src/auth.ts:AuthService"))
        XCTAssertTrue(ids.contains("function:src/api.ts:handleRequest"))
        XCTAssertTrue(ids.contains("file:src/auth.ts"))
        XCTAssertTrue(ids.contains("file:test/auth.test.ts"))
        XCTAssertLessThanOrEqual(subgraph.nodes.count, 60)
    }

    func testGraphPreviewCapsNodesAndOnlyKeepsInternalEdges() async {
        let project = makeFixtureProject()
        let preview = await UnderstandAnythingManager.shared.graphPreview(projectPath: project, limit: 5)
        guard let preview else {
            XCTFail("no preview")
            return
        }
        XCTAssertEqual(preview.nodes.count, 5)
        let ids = Set(preview.nodes.map(\.id))
        XCTAssertTrue(preview.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
    }

    // MARK: - Tolerant decoding

    func testParsesGraphMissingLayersAndTour() async {
        let project = makeFixtureProject(json: Self.fixtureWithoutLayers)
        let graph = await UnderstandAnythingManager.shared.graph(projectPath: project)
        XCTAssertNotNil(graph)
        XCTAssertEqual(graph?.nodes.count, 11)
        XCTAssertEqual(graph?.layers ?? [], [])
    }

    func testMalformedGraphLoadsAsNil() async {
        let project = makeFixtureProject(json: "{ not json !!!")
        let graph = await UnderstandAnythingManager.shared.graph(projectPath: project)
        XCTAssertNil(graph)
    }
}
