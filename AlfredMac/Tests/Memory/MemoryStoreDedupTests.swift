import XCTest
@testable import Alfred

/// Covers the two memory-quality fixes: dedup-on-write and relevance-ranked retrieval.
final class MemoryStoreDedupTests: XCTestCase {

    private func makeStore() throws -> MemoryStore {
        let path = NSTemporaryDirectory() + "alfred-memtest-\(UUID().uuidString).sqlite"
        return try MemoryStore(path: path)
    }

    func testVerbatimFactIsNotDuplicated() throws {
        let store = try makeStore()
        try store.save(content: "User prefers concise answers", tags: ["auto"])
        try store.save(content: "User prefers concise answers", tags: ["auto"])
        try store.save(content: "  User prefers concise answers  ", tags: ["auto"]) // whitespace variant

        let hits = try store.search(query: "concise answers", limit: 20)
        XCTAssertEqual(hits.count, 1, "verbatim re-saves should collapse to one row")
    }

    func testContainedFactCollapsesAndKeepsLongerPhrasing() throws {
        let store = try makeStore()
        try store.save(content: "User drives a Tesla")
        try store.save(content: "User drives a Tesla Model 3 in red") // superset

        let hits = try store.search(query: "Tesla", limit: 20)
        XCTAssertEqual(hits.count, 1, "one-contains-the-other should collapse")
        XCTAssertEqual(hits.first?.content, "User drives a Tesla Model 3 in red",
                       "the longer, more-informative phrasing wins")
    }

    func testDistinctFactsAreKept() throws {
        let store = try makeStore()
        try store.save(content: "User lives in Brooklyn")
        try store.save(content: "User works as a quant researcher")

        XCTAssertEqual(try store.search(query: "Brooklyn", limit: 20).count, 1)
        XCTAssertEqual(try store.search(query: "quant", limit: 20).count, 1)
    }

    func testRetrievalRanksByRelevanceNotJustRecency() throws {
        let store = try makeStore()
        // Saved oldest-first; the most relevant match to the query is the FIRST one saved,
        // so a pure recency order would bury it. bm25 ranking must surface it on top.
        try store.save(content: "User's primary programming language is Swift")
        try store.save(content: "User went hiking in Swift Current last summer")
        try store.save(content: "User likes coffee")

        let hits = try store.search(query: "programming language Swift", limit: 5)
        XCTAssertGreaterThanOrEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.content, "User's primary programming language is Swift",
                       "best lexical match should rank first, not the most recently written row")
    }

    func testEmptyContentIsIgnored() throws {
        let store = try makeStore()
        try store.save(content: "   ")
        XCTAssertTrue(try store.search(query: "anything", limit: 20).isEmpty)
    }
}
