import XCTest
@testable import Alfred

/// Verifies semantic retrieval via local Ollama (nomic-embed-text) surfaces meaning-related
/// memories even when they share NO keywords with the query — recall beyond FTS/BM25 lexical overlap.
final class MemorySemanticSearchTests: XCTestCase {

    private func makeStore() throws -> MemoryStore {
        let path = NSTemporaryDirectory() + "alfred-semtest-\(UUID().uuidString).sqlite"
        return try MemoryStore(path: path)
    }

    func testSemanticQueryRanksRelatedAboveUnrelated() throws {
        // Requires a local Ollama server with nomic-embed-text pulled. If it's unavailable the
        // feature degrades to lexical search, so skip rather than fail.
        try XCTSkipIf(MemoryStore.documentEmbedding(for: "ping") == nil,
                      "Ollama/nomic-embed-text unavailable — run `ollama pull nomic-embed-text`")

        let store = try makeStore()
        try store.save(content: "I bike to campus")
        try store.save(content: "I ride my bicycle to school")
        try store.save(content: "I had pizza for dinner last night")   // ordinary unrelated memory

        // "commute" shares no token with any memory — only embeddings connect it to the two cycling
        // memories. nomic's stronger signal cleanly separates them from the unrelated one.
        let hits = try store.search(query: "commute", limit: 3)
        let ranking = hits.map(\.content)

        let bikeIndex = ranking.firstIndex(of: "I bike to campus")
        let bicycleIndex = ranking.firstIndex(of: "I ride my bicycle to school")
        let unrelatedIndex = ranking.firstIndex(of: "I had pizza for dinner last night")

        XCTAssertNotNil(bikeIndex, "semantic recall should surface 'I bike to campus' for 'commute'")
        XCTAssertNotNil(bicycleIndex, "semantic recall should surface 'I ride my bicycle to school' for 'commute'")

        let worst = unrelatedIndex ?? Int.max
        XCTAssertLessThan(bikeIndex ?? .max, worst, "the biking memory should rank above the unrelated one")
        XCTAssertLessThan(bicycleIndex ?? .max, worst, "the bicycle memory should rank above the unrelated one")
    }
}
