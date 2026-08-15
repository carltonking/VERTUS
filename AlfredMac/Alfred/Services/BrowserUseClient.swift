//
//  BrowserUseClient.swift
//  Alfred
//
//  Deterministic web automation for Alfred's own orchestration paths, via the
//  installed browser-use 3.x CLI (browser-use/browser-use, MIT).
//
//  There are two faces to browser-use in Alfred:
//
//   1. The agentic face — Hermes already has it. Alfred registers
//      `browser-use --mcp` in ~/.alfred/agent-servers.json (see
//      agent-bridge/browser-use-mcp-wrapper.sh), so every Hermes session
//      carries browser_navigate / browser_click / browser_type /
//      browser_extract_content / browser_screenshot / … and can *reason* about
//      a page. Nothing in this file duplicates that.
//
//   2. The deterministic face — what this file is. browser-use 3.x also runs
//      one-shot scripts: pipe Python to its stdin, helpers are pre-imported
//      (new_tab, goto_url, wait_for_load, page_info, fill_input, js, …),
//      `print()` goes to stdout (capped at 20k), and harness errors go to
//      stderr with a nonzero exit. Alfred uses that for scheduled work that
//      must not spend model quota or imagination: a routine checking a price,
//      the newsletter sign-up skill filling a form. Every operation is
//      read-mostly; anything that submits a form stops at a confirmation gate.
//
//  Constraints verified against the installed CLI (browser-harness 0.1.8):
//
//   * The one-shot mode needs Chrome running with the harness daemon up. When
//     they aren't, stderr carries a message like "chrome-not-running: … ask
//     the user to open Chrome, then retry" and the exit code is nonzero — the
//     client surfaces that verbatim instead of pretending to succeed.
//   * stdout is the payload. The harness caps it at 20,000 chars; scripts that
//     need more return the first N characters and say so.
//   * Scripts are plain Python. Standard-library imports (json, urllib) work.
//
//  Safety, matching the rest of Alfred's capability layer:
//
//   * Master switch `isEnabled` (default OFF — the spec asked for safety by
//     default; flipping it in Settings is the explicit opt-in).
//   * `requireConfirmation` (default ON): anything that *submits* a form
//     returns `.needsConfirmation` unless the caller passes `confirmed: true`
//     — and only Hermes with an explicit user ask, or the phone's
//     confirmation flow, ever does.
//   * A blocked-site list refuses to run at all: banks and payment providers
//     (automation never touches money-moving sites), plus a permanent,
//     toggle-free adult-content blocklist that is always on.
//   * Every action is written to ~/.alfred/browser_audit.log.

import Foundation

// MARK: - Results

/// The outcome of one scripted browser run. `payload` is whatever the script
/// printed (a JSON dict for the typed operations below); `rawOutput` is the
/// full stdout, kept for debugging when JSON parsing fails.
struct BrowserRunResult: Sendable {
    let succeeded: Bool
    /// The last JSON object line the script printed, when there was one.
    let payload: [String: Any]?
    /// Full stdout (may be truncated by the harness at 20k).
    let rawOutput: String
    /// The failure message — a harness error line, or the script's own error.
    let message: String
}

/// The outcome of a form-filling operation, which has a middle state the plain
/// run result doesn't: the form was *found* but Alfred stopped before
/// submitting because the user hasn't confirmed it yet.
enum BrowserSubmitOutcome: Sendable {
    /// The form was filled and submitted.
    case submitted(pageText: String)
    /// The email field was located but submission is gated on confirmation.
    case needsConfirmation(pageText: String)
    /// No email input could be found on the page.
    case noEmailField(pageText: String)
    /// The site is on the blocked list, or automation is disabled.
    case refused(String)
    /// The run failed (browser unavailable, timeout, harness error).
    case failed(String)
}

// MARK: - Client

final class BrowserUseClient {

    static let shared = BrowserUseClient()

    // MARK: Persisted settings

    private let enabledKey = "alfred.browserAutomationEnabled"
    private let confirmKey = "alfred.browserRequireConfirmation"

    /// Master switch for Alfred's own deterministic browser automation
    /// (routines, the email subscription skill). Hermes' MCP tools are
    /// governed by Hermes' own permission system, not this switch. Defaults
    /// OFF — automation that touches real websites is opt-in.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Gate on form submission. Defaults ON: filling a form is harmless, but
    /// clicking submit acts in the real world, so it waits for explicit
    /// confirmation unless the caller proves the user asked for it.
    var requireConfirmation: Bool {
        get { UserDefaults.standard.object(forKey: confirmKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: confirmKey) }
    }

    // MARK: Binary discovery

    /// The venv `browser-use` binary. The MCP wrapper in agent-servers.json is
    /// authoritative for where the bridge lives (`<bridge>/.venvs/browser-use/
    /// bin/browser-use` sits next to it) — but the one-shot CLI must *not* be
    /// launched through the wrapper, which forces `--mcp`. Resolve the raw
    /// binary instead. Cached because probing is slow; `refreshBinary()`
    /// re-probes after an install.
    private(set) var binaryPath: String?
    private var didProbeBinary = false
    private var loggedUnavailable = false

    func refreshBinary() {
        binaryPath = Self.resolveBinary()
        didProbeBinary = true
    }

    var isAvailable: Bool {
        if !didProbeBinary { refreshBinary() }
        return binaryPath != nil
    }

    /// Find the venv `browser-use` binary, without ever launching the wrapper
    /// (the wrapper execs `--mcp`, which speaks MCP on stdio — wrong for the
    /// script mode this client uses).
    static func resolveBinary() -> String? {
        let home = NSHomeDirectory()

        // 1. Derive from the registered MCP server: the wrapper's directory
        //    holds the venv this wrapper points PATH at.
        let serversPath = "\(home)/.alfred/agent-servers.json"
        if let data = FileManager.default.contents(atPath: serversPath),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let servers = json["servers"] as? [[String: Any]],
           let wrapper = servers
                .first(where: { ($0["name"] as? String) == "browser-use" })?["args"] as? [String],
           let wrapperPath = wrapper.first(where: { $0.hasSuffix(".sh") || $0.contains("wrapper") }) {
            let bridge = (wrapperPath as NSString).deletingLastPathComponent
            let venvBin = "\(bridge)/.venvs/browser-use/bin/browser-use"
            if FileManager.default.isExecutableFile(atPath: venvBin) { return venvBin }
        }

        // 2. Login-shell probe (a GUI app inherits a minimal PATH; the shell
        //    sources the user's profile).
        guard let output = Self.runCapture(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v browser-use"],
            timeout: 5),
            let line = output.split(separator: "\n").first
        else { return nil }
        let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: Blocked sites

    /// Hosts Alfred's automation refuses to touch, whatever the instruction.
    /// Money-moving sites are never form-filling targets for a script — a
    /// mistake there costs real money, so the boundary is hard.
    static let blockedHosts: [String] = [
        "paypal.com", "venmo.com", "cash.app", "squareup.com", "stripe.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citibank.com",
        "capitalone.com", "usbank.com", "tdbank.com", "amex.com",
        "americanexpress.com", "discover.com", "schwab.com", "fidelity.com",
        "vanguard.com", "etrade.com", "robinhood.com", "coinbase.com",
        "gemini.com", "kraken.com",
    ]

    /// Adult-content hosts Alfred refuses to touch. This is deliberately NOT a
    /// setting and has no toggle — the block is hard-coded on so it can never
    /// be switched off. Covers the major tube sites, cam sites, studios,
    /// creator platforms, erotica, hentai and adult dating.
    static let adultBlockedHosts: [String] = [
        // Video / tube sites
        "pornhub.com", "xvideos.com", "xhamster.com", "xnxx.com", "redtube.com",
        "youporn.com", "tube8.com", "spankwire.com", "tnaflix.com", "eporner.com",
        "motherless.com", "vjav.com", "hclips.com", "porn.com", "pornhd.com",
        "beeg.com", "4tube.com", "sex.com", "youjizz.com", "keezmovies.com",
        "porn300.com", "vporn.com", "pornmd.com", "sunporno.com", "fapello.com",
        // Creator / subscription platforms
        "onlyfans.com", "fansly.com", "manyvids.com", "fancentro.com",
        "justfor.fans", "loyalfans.com", "clips4sale.com", "avnstars.com",
        // Cams
        "chaturbate.com", "stripchat.com", "camsoda.com", "livejasmin.com",
        "myfreecams.com", "streamate.com", "bongacams.com", "cam4.com",
        "camster.com", "jerkmate.com", "flirt4free.com", "cams.com",
        // Studios
        "brazzers.com", "bangbros.com", "realitykings.com", "naughtyamerica.com",
        "vixen.com", "blacked.com", "blackedraw.com", "evilangel.com", "milf.com",
        "babes.com", "twistys.com",
        // Magazines
        "playboy.com", "penthouse.com", "hustler.com", "playgirl.com",
        // Erotica / stories
        "literotica.com", "asstr.org", "sexstories.com", "lushstories.com",
        "eroticstories.com",
        // Hentai
        "nhentai.net", "hanime.tv", "hentaihaven.com", "hentai.tv", "hentaigasm.com",
        // Adult dating / classifieds
        "adultfriendfinder.com", "friendfinder.com", "ashleymadison.com",
        "seeking.com", "sexsearch.com", "naughtydate.com",
    ]

    /// Host-name markers that flag a domain as adult content even when the
    /// exact site isn't curated — the long tail of throwaway porn domains.
    /// High-precision substrings only, so a legitimate site like
    /// adultswim.com or sussex.com is never caught.
    static let adultHostMarkers: [String] = [
        "porn", "hentai", "xxx", "fap", "escort", "camgirl", "sexcam",
        "milf", "bdsm", "nude",
    ]

    /// True when a bare host (no scheme, no path) is on either blocklist, or
    /// matches an adult-content marker. Subdomains of a blocked host count.
    static func isBlockedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        let onList = { (list: [String]) in list.contains { h == $0 || h.hasSuffix("." + $0) } }
        if onList(blockedHosts) { return true }
        return onList(adultBlockedHosts) || adultHostMarkers.contains { h.contains($0) }
    }

    /// True when the URL's host is a blocked host — financial or adult.
    static func isBlocked(url: String) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        return isBlockedHost(host)
    }

    /// True when the URL's host is blocked specifically for adult content.
    static func isAdultBlocked(url: String) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        let h = host.lowercased()
        let onList = adultBlockedHosts.contains { h == $0 || h.hasSuffix("." + $0) }
        return onList || adultHostMarkers.contains { h.contains($0) }
    }

    /// The refusal line for a blocked URL — names the adult block when that's
    /// what tripped, so the message never says "banks" about a porn site.
    static func refusalMessage(for url: String) -> String {
        if isAdultBlocked(url: url) {
            return "That site is on Alfred's always-on adult-content blocklist — it is never accessed."
        }
        return "That site is on Alfred's blocked list (banks and payment providers are never automated)."
    }

    // MARK: Audit log

    /// Append one audit line to ~/.alfred/browser_audit.log. Never throws;
    /// a log write that fails is not worth surfacing.
    func logAudit(_ action: String, url: String, detail: String) {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("browser_audit.log")
        let line = "\(Self.timestamp()) \(action) url=\(url) \(detail)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
        NSLog("[browser] %@ url=%@ %@", action, url, detail)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Core runner

    /// Pipe one Python script to `browser-use` and return what it printed.
    ///
    /// stdout is the payload (the script's `print()` output, capped at 20k by
    /// the harness); stderr carries harness noise and errors. A nonzero exit
    /// means the script raised or the harness couldn't connect — the stderr
    /// tail is the actionable message ("open Chrome, then retry").
    func runScript(_ script: String, timeout: TimeInterval = 90) async -> BrowserRunResult {
        guard isAvailable, let binary = binaryPath else {
            logUnavailableOnce()
            return BrowserRunResult(succeeded: false, payload: nil, rawOutput: "",
                                    message: "Browser automation isn't installed.")
        }

        // Spawn off the caller's actor: the run can block up to `timeout`, and
        // callers (RoutineManager, the mail skill) live on the main actor.
        return await Task.detached(priority: .utility) { [script] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            do { try process.run() } catch {
                return BrowserRunResult(succeeded: false, payload: nil, rawOutput: "",
                                        message: error.localizedDescription)
            }

            // Feed the script, then close stdin so the harness knows the
            // script is complete (it reads stdin until EOF). The writes are
            // try? — the process can exit before we write (Chrome not running
            // returns exit 1 immediately), and an uncaught throw inside this
            // detached task would crash the app.
            try? inPipe.fileHandleForWriting.write(Data(script.utf8))
            try? inPipe.fileHandleForWriting.closeFile()

            // Drain both pipes on background threads. EOF on stdout is the
            // completion signal — waiting on termination can race the last
            // write, exactly the bug Headroom's runCapture was fixed for.
            let drained = DispatchSemaphore(value: 0)
            var output = "", errText = ""
            DispatchQueue.global().async {
                output = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                drained.signal()
            }
            DispatchQueue.global().async {
                errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }

            let completed = drained.wait(timeout: .now() + timeout)
            if completed != .success {
                process.terminate()
                return BrowserRunResult(succeeded: false, payload: nil, rawOutput: output,
                                        message: "Browser task timed out after \(Int(timeout))s.")
            }
            process.waitUntilExit()

            let exitCode = process.terminationStatus
            if exitCode != 0 {
                let reason = Self.diagnosticLine(from: errText)
                    ?? "browser-use exited with code \(exitCode)"
                return BrowserRunResult(succeeded: false, payload: nil, rawOutput: output,
                                        message: reason)
            }
            // The payload is the last JSON object line the script printed;
            // anything before it is harness chatter. A payload that carries an
            // "error" key is a *script-level* failure (the try/except printed
            // it and exited 0) — treat it as a failure, not success, so a
            // dead tab or JS exception never reads as an empty win.
            let payload = Self.lastJSONLine(in: output)
            let scriptError = payload?["error"] as? String
            return BrowserRunResult(succeeded: payload != nil && scriptError == nil,
                                    payload: payload,
                                    rawOutput: output,
                                    message: scriptError
                                        ?? (payload == nil ? "Script produced no JSON payload." : ""))
        }.value
    }

    /// Pick the actionable line out of a stderr dump — the "chrome-not-running"
    /// style message, not the traceback noise.
    private static func diagnosticLine(from stderr: String) -> String? {
        let lines = stderr.split(separator: "\n").map(String.init)
        return lines.last { $0.contains("chrome") || $0.contains("daemon") || $0.contains("Traceback") }
            ?? lines.last(where: { !$0.isEmpty })
    }

    /// The last line of stdout that parses as a JSON object, or nil.
    static func lastJSONLine(in output: String) -> [String: Any]? {
        let lines = output.split(separator: "\n").map(String.init)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            return obj
        }
        return nil
    }

    private func logUnavailableOnce() {
        guard !loggedUnavailable else { return }
        loggedUnavailable = true
        NSLog("[browser] browser-use not found — Alfred's browser automation is off. Install via agent-bridge/setup.sh (or `uv tool install browser-use`).")
    }

    // MARK: - Typed operations

    /// Open a URL and report the page's url/title and visible text. The
    /// deterministic "what's on this page" — no LLM, no tool calls.
    func pageInfo(url: String) async -> BrowserRunResult {
        await runScript(Self.pageInfoScript(url: url))
    }

    /// The Python script `pageInfo` runs. Static and internal so tests can
    /// exercise the exact script without spawning the binary.
    static func pageInfoScript(url: String) -> String {
        """
        import json
        try:
            new_tab(__URL__)
            wait_for_load()
            info = page_info()
            text = js("document.body ? document.body.innerText : ''") or ''
            print(json.dumps({
                "url": info.get("url", ""),
                "title": info.get("title", ""),
                "text": text[:6000],
            }))
        except Exception as e:
            print(json.dumps({"error": str(e)}))
        """
        .replacingOccurrences(of: "__URL__", with: pythonString(url))
    }

    /// Navigate to `url` and return up to `maxChars` of the page's text. The
    /// always-on blocklist is enforced here, at the network chokepoint, so a
    /// blocked (adult or financial) URL can never be opened no matter which
    /// caller asks.
    func extractText(url: String, maxChars: Int = 4000) async -> BrowserRunResult {
        if Self.isBlocked(url: url) {
            logAudit("blocked", url: url, detail: "refused: blocked host")
            return BrowserRunResult(succeeded: false, payload: nil, rawOutput: "",
                                    message: Self.refusalMessage(for: url))
        }
        return await runScript(Self.extractScript(url: url, maxChars: maxChars))
    }

    /// The Python script `extractText` runs.
    static func extractScript(url: String, maxChars: Int) -> String {
        """
        import json
        try:
            new_tab(__URL__)
            wait_for_load()
            text = js("document.body ? document.body.innerText : ''") or ''
            print(json.dumps({"text": text[:__MAX__]}))
        except Exception as e:
            print(json.dumps({"error": str(e)}))
        """
        .replacingOccurrences(of: "__URL__", with: pythonString(url))
        .replacingOccurrences(of: "__MAX__", with: String(maxChars))
    }

    /// Search the web (DuckDuckGo's JS-free HTML endpoint — no key, no
    /// consent wall) and return the result-page text.
    func search(query: String, maxChars: Int = 4000) async -> BrowserRunResult {
        await runScript(Self.searchScript(query: query, maxChars: maxChars))
    }

    /// The Python script `search` runs.
    static func searchScript(query: String, maxChars: Int) -> String {
        """
        import json
        from urllib.parse import quote
        try:
            new_tab("https://html.duckduckgo.com/html/?q=" + quote(__QUERY__))
            wait_for_load()
            text = js("document.body ? document.body.innerText : ''") or ''
            print(json.dumps({"text": text[:__MAX__]}))
        except Exception as e:
            print(json.dumps({"error": str(e)}))
        """
        .replacingOccurrences(of: "__QUERY__", with: pythonString(query))
        .replacingOccurrences(of: "__MAX__", with: String(maxChars))
    }

    /// Fill the page's email field and submit, gated on confirmation.
    ///
    /// Selectors are found by the page's own structure (input[type=email] and
    /// friends) rather than a hardcoded per-site map, so it works on any
    /// newsletter signup without a rule file. React-friendly: the value is set
    /// through the native setter and input/change events are dispatched.
    ///
    /// The confirmation gate: when `requireConfirmation` is on and `confirmed`
    /// is false, the script *fills but never clicks submit* and returns
    /// `.needsConfirmation` with the page text — the caller decides whether the
    /// user actually asked for this subscription.
    func fillEmailAndSubmit(url: String, email: String, confirmed: Bool) async -> BrowserSubmitOutcome {
        guard isEnabled else { return .refused("Browser automation is off in Settings.") }
        guard !Self.isBlocked(url: url) else {
            logAudit("blocked", url: url, detail: "refused: blocked host")
            return .refused(Self.refusalMessage(for: url))
        }
        guard confirmed || !requireConfirmation else {
            // Still look at the page so the caller can show what *would* have
            // been filled, but never click submit. A failed probe (page
            // didn't load) is a failure, not a pending confirmation.
            let probe = await runScript(Self.fillScript(url: url, email: email, submit: false))
            guard probe.succeeded else { return .failed(probe.message) }
            let text = Self.textFrom(probe) ?? ""
            logAudit("fill-awaiting-confirmation", url: url, detail: "email=\(email)")
            return .needsConfirmation(pageText: text)
        }

        let result = await runScript(Self.fillScript(url: url, email: email, submit: true))
        guard result.succeeded else { return .failed(result.message) }
        let text = Self.textFrom(result) ?? result.rawOutput
        // The script reports whether an email field existed at all; a page
        // without one is not a submission.
        if let found = result.payload?["found"] as? Bool, !found {
            logAudit("fill-no-field", url: url, detail: "email=\(email)")
            return .noEmailField(pageText: text)
        }
        logAudit("submitted", url: url, detail: "email=\(email)")
        return .submitted(pageText: text)
    }

    /// The script for fillEmailAndSubmit. `submit` false = fill and stop;
    /// true = fill and click the form's submit button. Static and internal so
    /// tests can exercise the exact script without spawning the binary.
    ///
    /// `sel` is a Python variable (the selector the JS probe found), so the
    /// fill JS is built at Python runtime with `json.dumps(sel)` — JSON strings
    /// are valid JS string literals, so no quoting bugs regardless of the
    /// selector's characters. The submit/no-submit difference is a Python
    /// boolean (`SUBMIT`), so the script is one well-formed program either
    /// way, not text assembled from fragments.
    ///
    /// Deliberately a Swift *raw* string (#"""…"""#): the Python script itself
    /// contains Python triple-quoted JS strings, which would otherwise collide
    /// with Swift's multiline delimiters. Values are injected by placeholder
    /// replacement, never by interpolation.
    static func fillScript(url: String, email: String, submit: Bool) -> String {
        #"""
        import json
        SUBMIT = __SUBMIT__
        try:
            new_tab(__URL__)
            wait_for_load()
            email = __EMAIL__
            sel = js("""(() => {
                const sels = ['input[type=email]', 'input[name=email]', 'input#email',
                              'input[autocomplete=email]', 'input[placeholder*="mail" i]'];
                for (const s of sels) { const el = document.querySelector(s); if (el) return s; }
                return null;
            })()""")
            if not sel:
                text = js("document.body ? document.body.innerText : ''") or ''
                print(json.dumps({"found": False, "text": text[:4000]}))
            else:
                fill_js = "(() => {" + \
                    "const el = document.querySelector(" + json.dumps(sel) + ");" + \
                    "const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;" + \
                    "setter.call(el, " + json.dumps(email) + ");" + \
                    "el.dispatchEvent(new Event('input', {bubbles: true}));" + \
                    "el.dispatchEvent(new Event('change', {bubbles: true}));" + \
                    "return el.value;" + \
                    "})()"
                filled = js(fill_js)
                clicked = 'held'
                if SUBMIT:
                    clicked = js("""(() => {
                        const emailEl = document.querySelector('input[type=email], input[name=email], input#email, input[autocomplete=email]');
                        const form = emailEl ? emailEl.closest('form') : null;
                        const btn = form ? form.querySelector('button[type=submit], input[type=submit], button') : document.querySelector('button[type=submit], input[type=submit]');
                        if (btn) { btn.click(); return 'yes'; }
                        return 'no-button';
                    })()""")
                    wait_for_load()
                text = js("document.body ? document.body.innerText : ''") or ''
                print(json.dumps({"found": True, "clicked": clicked, "filled": filled, "text": text[:4000]}))
        except Exception as e:
            print(json.dumps({"error": str(e)}))
        """#
        .replacingOccurrences(of: "__URL__", with: Self.pythonString(url))
        .replacingOccurrences(of: "__EMAIL__", with: Self.pythonString(email))
        .replacingOccurrences(of: "__SUBMIT__", with: submit ? "True" : "False")
    }

    /// Best-effort page text from a run result.
    private static func textFrom(_ result: BrowserRunResult) -> String? {
        guard let payload = result.payload else { return nil }
        if let text = payload["text"] as? String { return text }
        if let error = payload["error"] as? String { return error }
        return nil
    }

    /// JSON-encode a Swift string so it lands in the Python script as a valid
    /// string literal (JSON strings are valid Python string literals).
    /// `.withoutEscapingSlashes` keeps URLs readable — a `\/` escape is valid
    /// in both JSON and Python, but a URL that reads naturally is easier to
    /// audit in the generated script.
    static func pythonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: [value],
                options: [.withoutEscapingSlashes]),
              var s = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        s.removeFirst()
        s.removeLast()
        return s
    }

    // MARK: Process helper

    /// Capture a short-lived command's stdout, with a hard timeout. Mirrors
    /// Headroom's runCapture.
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
