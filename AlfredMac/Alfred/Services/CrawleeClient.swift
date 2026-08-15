//
//  CrawleeClient.swift
//  Alfred
//
//  Deterministic web scraping for Alfred's own orchestration paths, via the
//  local Crawlee bridge (agent-bridge/crawlee — our own thin wrapper around
//  the crawlee npm library).
//
//  Like browser-use, Crawlee has two faces in Alfred:
//
//   1. The agentic face — Hermes already gets it. The bridge's MCP server
//      (agent-bridge/crawlee-mcp-wrapper.sh, registered in
//      ~/.alfred/agent-servers.json) hands Hermes scrape_website /
//      scrape_multiple / scrape_with_js / scrape_search / scrape_paginated /
//      extract_articles, so the model can scrape on demand and reason about
//      what it finds. Nothing here duplicates that.
//
//   2. The deterministic face — what this file is. The bridge's one-shot CLI
//      (crawlee_cli.mjs) reads one JSON request on stdin and prints one JSON
//      result line on stdout — no model, no imagination, hard timeout. Alfred
//      uses that for scheduled work: a routine that scrapes a price, a page,
//      or search results.
//
//  Constraints verified against the installed bridge:
//
//   * stdout is the payload: exactly one JSON object line — the result, or
//     `{"error": "…"}` for a page-level failure. Infrastructure failures
//     (crawlee not installed, bad request) go to stderr with a nonzero exit.
//     The client treats an `error`-keyed payload as a failure, never an empty
//     win.
//   * HTTP mode needs nothing but the bridge's node_modules (npm install in
//     agent-bridge/crawlee). Chromium mode additionally needs Playwright
//     installed next to it; when it isn't, the bridge's error says so.
//   * Unlike browser-use, no Chrome needs to be running — HTTP scraping is
//     plain requests. This is the lightweight complement to the browser step.
//
//  Safety:
//   * `isEnabled` defaults ON — scraping is read-only GET requests to public
//     pages, the same risk class as the briefing's news fetch. (Browser
//     *automation* defaults off because it fills and submits forms; nothing
//     here submits anything.)
//   * Results are cached locally (~/.alfred/scrape_cache) so a routine that
//     checks a page every hour doesn't hammer the site — default TTL 1 day.
//   * Every request is logged to ~/.alfred/scrape_audit.log.
//
//  All network I/O is async and off the caller's actor; the one-shot process
//  is spawned detached with a hard timeout.

import CryptoKit
import Foundation

// MARK: - Results

/// The outcome of one one-shot scrape. `payload` is the JSON object the CLI
/// printed (a `{error}` object is a failure, not a payload); `rawOutput` is
/// kept for debugging when parsing fails.
struct CrawleeResult: Sendable {
    let succeeded: Bool
    let payload: [String: Any]?
    let rawOutput: String
    let message: String

    /// Convenience accessors for the typed operations' payload shapes.
    var text: String? { payload?["text"] as? String }
    var title: String? { payload?["title"] as? String }
}

// MARK: - Settings

/// Which engine the one-shot CLI uses. HTTP is fast and needs nothing but the
/// bridge; chromium renders JavaScript (Playwright) at the cost of a browser.
enum ScrapeMode: String, CaseIterable, Identifiable {
    case http
    case chromium

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .http: return "Fast (no JS)"
        case .chromium: return "Full browser"
        }
    }
}

/// How long a cached scrape stays fresh before the next request re-fetches.
enum ScrapeCacheDuration: String, CaseIterable, Identifiable {
    case never, day, week, month

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .never: return "Never cache"
        case .day: return "1 day"
        case .week: return "1 week"
        case .month: return "1 month"
        }
    }

    /// Seconds a cached entry survives; 0 = don't cache at all.
    var ttl: TimeInterval {
        switch self {
        case .never: return 0
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

// MARK: - Client

final class CrawleeClient {

    static let shared = CrawleeClient()

    // MARK: Persisted settings

    private let enabledKey = "alfred.scrapingEnabled"
    private let modeKey = "alfred.scrapingMode"
    private let cacheKey = "alfred.scrapingCacheDuration"
    private let retriesKey = "alfred.scrapingRetries"
    private let timeoutKey = "alfred.scrapingTimeout"

    /// Master switch for Alfred's own deterministic scraping (routines).
    /// Defaults ON: scraping is read-only GET requests — the same risk class
    /// as the briefing's news fetch — unlike browser automation, which fills
    /// and submits forms and therefore defaults off. Hermes' MCP tools are
    /// governed by Hermes' permission system, not this switch.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Engine for new scrapes: http (default) or chromium. `ScrapeMode` is
    /// stored by rawValue.
    var mode: ScrapeMode {
        get { UserDefaults.standard.string(forKey: modeKey).flatMap(ScrapeMode.init(rawValue:)) ?? .http }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// How long a scrape result stays cached before a routine re-fetches.
    var cacheDuration: ScrapeCacheDuration {
        get { UserDefaults.standard.string(forKey: cacheKey).flatMap(ScrapeCacheDuration.init(rawValue:)) ?? .day }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cacheKey) }
    }

    /// Crawlee's per-request retry count (1 = conservative, 3 = aggressive).
    var retries: Int {
        get { UserDefaults.standard.object(forKey: retriesKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(max(0, min(newValue, 5)), forKey: retriesKey) }
    }

    /// Hard timeout per request, in seconds.
    var timeout: TimeInterval {
        get { UserDefaults.standard.object(forKey: timeoutKey) as? TimeInterval ?? 30 }
        set { UserDefaults.standard.set(max(5, min(newValue, 120)), forKey: timeoutKey) }
    }

    // MARK: Bridge discovery

    /// The node binary and the bridge's CLI script, resolved once and cached.
    /// `refreshBinary()` re-probes after an install.
    private(set) var bridge: (node: String, cli: String)?
    private var didProbeBridge = false
    private var loggedUnavailable = false

    func refreshBinary() {
        bridge = Self.resolveBridge()
        didProbeBridge = true
    }

    var isAvailable: Bool {
        if !didProbeBridge { refreshBinary() }
        return bridge != nil
    }

    /// Find `node` and the bridge's crawlee_cli.mjs. The registered MCP
    /// wrapper's directory (agent-bridge/) is authoritative for where the
    /// bridge lives; node is resolved through the login shell because a GUI
    /// app inherits a minimal PATH.
    static func resolveBridge() -> (node: String, cli: String)? {
        let home = NSHomeDirectory()

        // 1. Bridge dir from the registered crawlee server's wrapper path.
        var bridgeDir: String?
        let serversPath = "\(home)/.alfred/agent-servers.json"
        if let data = FileManager.default.contents(atPath: serversPath),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let servers = json["servers"] as? [[String: Any]],
           let wrapper = servers
                .first(where: { ($0["name"] as? String) == "crawlee" })?["args"] as? [String],
           let wrapperPath = wrapper.first(where: { $0.hasSuffix(".sh") || $0.contains("wrapper") }) {
            bridgeDir = (wrapperPath as NSString).deletingLastPathComponent
        }
        // Fallback: the standard repo location next to this project.
        if bridgeDir == nil {
            bridgeDir = NSHomeDirectory() + "/01 - PROJECTS/ALFRED/agent-bridge"
        }
        guard let dir = bridgeDir else { return nil }
        let cli = dir + "/crawlee/crawlee_cli.mjs"
        guard FileManager.default.fileExists(atPath: cli) else { return nil }

        // 2. Node via the login shell.
        guard let output = Self.runCapture(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v node"],
            timeout: 5),
            let line = output.split(separator: "\n").first
        else { return nil }
        let node = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard node.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: node) else { return nil }
        return (node, cli)
    }

    // MARK: Audit log

    /// Append one line to ~/.alfred/scrape_audit.log. Never throws.
    func logAudit(_ action: String, url: String, detail: String) {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("scrape_audit.log")
        let line = "\(Self.timestamp()) \(action) url=\(url) \(detail)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
        NSLog("[crawlee] %@ url=%@ %@", action, url, detail)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Core runner

    /// Run one JSON request through the bridge's one-shot CLI and return its
    /// result. stdout is the payload (one JSON line); a nonzero exit or an
    /// `error`-keyed payload is a failure with the message surfaced.
    func runRequest(_ request: [String: Any], timeout: TimeInterval? = nil) async -> CrawleeResult {
        guard isAvailable, let bridge else {
            logUnavailableOnce()
            return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                 message: "Scraping isn't installed. Run agent-bridge/setup.sh to install the crawlee bridge.")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8)
        else {
            return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                 message: "Couldn't encode the scrape request.")
        }
        let effectiveTimeout = timeout ?? self.timeout

        return await Task.detached(priority: .utility) { [node = bridge.node, cli = bridge.cli, json] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [cli]
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            do { try process.run() } catch {
                return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                     message: error.localizedDescription)
            }

            // Feed the request, then close stdin (EOF is the completion
            // signal). try? — the process can exit before we write, and an
            // uncaught throw inside this detached task would crash the app.
            try? inPipe.fileHandleForWriting.write(Data(json.utf8))
            try? inPipe.fileHandleForWriting.closeFile()

            // Drain both pipes on background threads; EOF on stdout is
            // completion. Waiting on termination can race the last write.
            let drained = DispatchSemaphore(value: 0)
            var output = "", errText = ""
            DispatchQueue.global().async {
                output = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                drained.signal()
            }
            DispatchQueue.global().async {
                errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }

            let completed = drained.wait(timeout: .now() + effectiveTimeout)
            if completed != .success {
                process.terminate()
                return CrawleeResult(succeeded: false, payload: nil, rawOutput: output,
                                     message: "Scrape timed out after \(Int(effectiveTimeout))s.")
            }
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let reason = Self.diagnosticLine(from: errText)
                    ?? "crawlee bridge exited with code \(process.terminationStatus)"
                return CrawleeResult(succeeded: false, payload: nil, rawOutput: output,
                                     message: reason)
            }
            let payload = Self.lastJSONLine(in: output)
            let scriptError = payload?["error"] as? String
            return CrawleeResult(succeeded: payload != nil && scriptError == nil,
                                 payload: payload,
                                 rawOutput: output,
                                 message: scriptError
                                     ?? (payload == nil ? "Bridge produced no JSON payload." : ""))
        }.value
    }

    /// Pick the actionable line out of a stderr dump.
    private static func diagnosticLine(from stderr: String) -> String? {
        let lines = stderr.split(separator: "\n").map(String.init)
        return lines.last { $0.contains("crawlee-cli") || $0.contains("Error") }
            ?? lines.last(where: { !$0.isEmpty })
    }

    /// The last line of stdout that parses as a JSON object, or nil.
    static func lastJSONLine(in output: String) -> [String: Any]? {
        let lines = output.split(separator: "\n").map(String.init)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            return obj
        }
        return nil
    }

    private func logUnavailableOnce() {
        guard !loggedUnavailable else { return }
        loggedUnavailable = true
        NSLog("[crawlee] bridge not found — Alfred's scraping is off. Install via agent-bridge/setup.sh.")
    }

    // MARK: - Blocked content

    /// The always-on blocklist (adult content + financial), shared with the
    /// browser client. A blocked URL is refused before any request runs and
    /// before any cache is read, so it can never be fetched or served stale.
    private func refusedIfBlocked(url: String) -> CrawleeResult? {
        guard BrowserUseClient.isBlocked(url: url) else { return nil }
        logAudit("blocked", url: url, detail: "refused: blocked host")
        return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                             message: BrowserUseClient.refusalMessage(for: url))
    }

    /// Drop search/article results that point at a blocked (adult or
    /// financial) host. Pure so it unit-tests without the bridge.
    static func filterBlocked(results: [[String: Any]]) -> [[String: Any]] {
        results.filter { item in
            guard let url = item["url"] as? String else { return true }
            return !BrowserUseClient.isBlocked(url: url)
        }
    }

    /// A result copy with any blocked entries removed from a `results` list.
    private static func filtering(_ result: CrawleeResult) -> CrawleeResult {
        guard result.succeeded, let payload = result.payload,
              let results = payload["results"] as? [[String: Any]] else {
            return result
        }
        let filtered = filterBlocked(results: results)
        guard filtered.count != results.count else { return result }
        var cleaned = payload
        cleaned["results"] = filtered
        return CrawleeResult(succeeded: true, payload: cleaned,
                             rawOutput: result.rawOutput, message: result.message)
    }

    // MARK: - Typed operations

    /// Scrape `url` and return its title + readable text. Cached per
    /// `cacheDuration`; pass `forceRefresh: true` to bypass the cache.
    func scrape(url: String, forceRefresh: Bool = false) async -> CrawleeResult {
        guard isEnabled else {
            return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                 message: "Scraping is off in Settings.")
        }
        if let refused = refusedIfBlocked(url: url) { return refused }
        if !forceRefresh, let cached = cached(op: "scrape", url: url) { return cached }

        logAudit("scrape", url: url, detail: "mode=\(mode.rawValue) retries=\(retries)")
        let request: [String: Any] = [
            "op": "scrape",
            "url": url,
            "mode": mode.rawValue,
            "maxChars": 20_000,
            "retries": retries,
            "timeoutSecs": Int(timeout),
        ]
        let result = await runRequest(request)
        if result.succeeded { store(cache: result, op: "scrape", url: url) }
        return result
    }

    /// Scrape `url` in chromium mode regardless of the default mode — the
    /// explicit "this page needs JavaScript" call.
    func scrapeWithJS(url: String, forceRefresh: Bool = false) async -> CrawleeResult {
        guard isEnabled else {
            return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                 message: "Scraping is off in Settings.")
        }
        if let refused = refusedIfBlocked(url: url) { return refused }
        if !forceRefresh, let cached = cached(op: "scrape_js", url: url) { return cached }

        logAudit("scrape_js", url: url, detail: "mode=chromium")
        let request: [String: Any] = [
            "op": "scrape",
            "url": url,
            "mode": "chromium",
            "maxChars": 20_000,
            "retries": retries,
            "timeoutSecs": Int(timeout),
        ]
        let result = await runRequest(request)
        if result.succeeded { store(cache: result, op: "scrape_js", url: url) }
        return result
    }

    /// Extract article links from a listing page.
    func articles(url: String, forceRefresh: Bool = false) async -> CrawleeResult {
        guard isEnabled else {
            return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                 message: "Scraping is off in Settings.")
        }
        if let refused = refusedIfBlocked(url: url) { return refused }
        if !forceRefresh, let cached = cached(op: "articles", url: url) { return cached }

        logAudit("articles", url: url, detail: "mode=\(mode.rawValue)")
        let request: [String: Any] = [
            "op": "articles",
            "url": url,
            "mode": mode.rawValue,
            "maxResults": 20,
            "retries": retries,
            "timeoutSecs": Int(timeout),
        ]
        let result = await runRequest(request)
        if result.succeeded { store(cache: result, op: "articles", url: url) }
        return Self.filtering(result)
    }

    /// Search the web (DuckDuckGo HTML) for `query`, optionally narrowed to
    /// `site`. Not cached — search results go stale in minutes, unlike a page.
    func search(query: String, site: String? = nil) async -> CrawleeResult {
        guard isEnabled else {
            return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                 message: "Scraping is off in Settings.")
        }
        // A site-narrowed search aimed at a blocked host is refused outright.
        if let site, !site.isEmpty, BrowserUseClient.isBlockedHost(site) {
            logAudit("blocked", url: site, detail: "refused: blocked search site")
            return CrawleeResult(succeeded: false, payload: nil, rawOutput: "",
                                 message: BrowserUseClient.refusalMessage(for: "https://" + site))
        }
        logAudit("search", url: "", detail: "query=\(query) site=\(site ?? "")")
        var request: [String: Any] = [
            "op": "search",
            "query": query,
            "maxResults": 10,
            "timeoutSecs": 15,
        ]
        if let site, !site.isEmpty { request["site"] = site }
        // Results are filtered so Alfred never surfaces a link to a blocked
        // (adult or financial) host.
        return Self.filtering(await runRequest(request))
    }

    // MARK: - Cache

    /// Per-key cache files in ~/.alfred/scrape_cache/<sha256>.json. Each holds
    /// `{cachedAt, result}` so a routine checking a page hourly reuses the
    /// last fetch within the TTL instead of hammering the site.
    private func cached(op: String, url: String) -> CrawleeResult? {
        let ttl = cacheDuration.ttl
        guard ttl > 0, let file = Self.cacheFileURL(op: op, url: url) else { return nil }
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cachedAt = json["cachedAt"] as? TimeInterval
        else { return nil }
        guard Date().timeIntervalSince1970 - cachedAt < ttl else { return nil }
        guard let result = json["result"] as? [String: Any],
              (result["error"] as? String) == nil
        else { return nil }
        return CrawleeResult(succeeded: true, payload: result, rawOutput: "", message: "")
    }

    private func store(cache result: CrawleeResult, op: String, url: String) {
        guard cacheDuration.ttl > 0, let file = Self.cacheFileURL(op: op, url: url),
              let payload = result.payload,
              let data = try? JSONSerialization.data(withJSONObject: [
                "cachedAt": Date().timeIntervalSince1970,
                "result": payload,
              ])
        else { return }
        try? data.write(to: file, options: .atomic)
        Self.pruneStaleCacheFiles()
    }

    /// Delete cache files older than 30 days so a TTL change or a cache
    /// disable never leaves them accumulating forever. Best-effort, called on
    /// each cache write.
    static func pruneStaleCacheFiles(maxAge: TimeInterval = 30 * 86_400) {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred/scrape_cache")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > maxAge
            else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// The cache file for a (op, url) pair. Nil when the URL is unusable.
    static func cacheFileURL(op: String, url: String) -> URL? {
        guard let data = "\(op)|\(url)".data(using: .utf8) else { return nil }
        let digest = Insecure.SHA1.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred/scrape_cache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: (dir as NSString).appendingPathComponent("\(hex).json"))
    }

    /// The request dictionary the CLI will see for a scrape — static so tests
    /// exercise the exact payload without spawning node.
    static func scrapeRequest(url: String, mode: String, maxChars: Int,
                              retries: Int, timeoutSecs: Int) -> [String: Any] {
        [
            "op": "scrape",
            "url": url,
            "mode": mode,
            "maxChars": maxChars,
            "retries": retries,
            "timeoutSecs": timeoutSecs,
        ]
    }

    // MARK: Process helper

    /// Capture a short-lived command's stdout, with a hard timeout.
    private static func runCapture(executable: String, arguments: [String],
                                   timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let drained = DispatchSemaphore(value: 0)
        var output = ""
        DispatchQueue.global().async {
            output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            drained.signal()
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard drained.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return output
    }
}
