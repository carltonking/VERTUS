import XCTest
@testable import Alfred

/// Covers the always-on adult-content block: the curated host list, the
/// long-tail host markers, the refusal messages, and the search-result
/// filtering. The block is deliberately not a setting, so every assertion
/// here pins the always-on behavior.
final class ContentBlockerTests: XCTestCase {

    // MARK: - Curated adult hosts

    func testCuratedAdultHostsBlocked() {
        let hosts = [
            // Tubes
            "pornhub.com", "www.pornhub.com", "m.xvideos.com", "xhamster.com",
            "xnxx.com", "redtube.com", "youporn.com",
            // Platforms
            "onlyfans.com", "fansly.com", "manyvids.com",
            // Cams
            "chaturbate.com", "stripchat.com", "livejasmin.com", "cams.com",
            // Studios
            "brazzers.com", "bangbros.com", "realitykings.com",
            // Magazines
            "playboy.com", "penthouse.com",
            // Erotica / hentai
            "literotica.com", "nhentai.net", "hentaihaven.com",
            // Adult dating
            "adultfriendfinder.com", "ashleymadison.com",
        ]
        for host in hosts {
            XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://\(host)/"), host)
            XCTAssertTrue(BrowserUseClient.isBlockedHost(host), host)
        }
    }

    func testSubdomainsOfAdultHostsBlocked() {
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://www.pornhub.com/view_video.php?viewkey=x"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://m.xvideos.com/video123"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://onlyfans.com/creator-name"))
    }

    // MARK: - Long-tail markers

    func testAdultMarkersCatchLongTailDomains() {
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://free-porn-clips.example.net"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://hentai-vids.example.com"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://xxxhub.example.org"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://fap-vault.example.com"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://escortlistings.example.com"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://camgirlchat.example.com"))
    }

    // MARK: - No false positives

    func testLegitimateSitesNotBlocked() {
        let urls = [
            "https://example.com",
            "https://www.nyu.edu",
            "https://en.wikipedia.org/wiki/Sex",
            "https://adultswim.com",            // "adult" alone is not a marker
            "https://sussex.com",               // "sex" alone is not a marker
            "https://cameras.example.com",      // "cam" alone is not a marker
            "https://github.com",
            "https://play.google.com",
        ]
        for url in urls {
            XCTAssertFalse(BrowserUseClient.isBlocked(url: url), url)
            XCTAssertFalse(BrowserUseClient.isAdultBlocked(url: url), url)
        }
    }

    // MARK: - Financial blocklist unchanged

    func testFinancialHostsStillBlocked() {
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://paypal.com/donate"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://checkout.chase.com/pay"))
        XCTAssertTrue(BrowserUseClient.isBlocked(url: "https://www.venmo.com"))
        XCTAssertFalse(BrowserUseClient.isAdultBlocked(url: "https://paypal.com/donate"))
    }

    // MARK: - Refusal messages

    func testRefusalMessageNamesAdultBlock() {
        XCTAssertTrue(BrowserUseClient.refusalMessage(for: "https://pornhub.com")
            .contains("adult-content"))
        XCTAssertTrue(BrowserUseClient.refusalMessage(for: "https://paypal.com")
            .contains("banks and payment providers"))
        XCTAssertFalse(BrowserUseClient.refusalMessage(for: "https://pornhub.com")
            .contains("banks"))
    }

    // MARK: - Search-result filtering

    func testFilterBlockedResultsDropsAdultAndKeepsClean() {
        let results: [[String: Any]] = [
            ["title": "clean article", "url": "https://example.com/article"],
            ["title": "adult result", "url": "https://www.pornhub.com/watch"],
            ["title": "long tail", "url": "https://free-porn-clips.example.net"],
            ["title": "financial", "url": "https://paypal.com/donate"],
            ["title": "no url", "note": "kept as-is"],
        ]
        let filtered = CrawleeClient.filterBlocked(results: results)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.contains { ($0["title"] as? String) == "clean article" })
        XCTAssertTrue(filtered.contains { ($0["note"] as? String) == "kept as-is" })
    }

    func testBlockedHostParsing() {
        XCTAssertFalse(BrowserUseClient.isBlockedHost("notpaypal.com"))
        XCTAssertFalse(BrowserUseClient.isBlockedHost("mypaypalclone.com"))
        XCTAssertTrue(BrowserUseClient.isBlockedHost("pornhub.com"))
        XCTAssertFalse(BrowserUseClient.isBlocked(url: "not a url"))
        XCTAssertFalse(BrowserUseClient.isBlocked(url: ""))
    }
}
