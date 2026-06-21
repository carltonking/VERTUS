import Foundation
import AppKit

// MARK: - BrowserCapability
//
// Local, zero-auth read of what the user is browsing — current tab and open tabs in Safari or
// Chrome via AppleScript. "what am I reading", "what tabs do I have open", "what page am I on".
// Read-only. Needs Automation permission for the browser (prompted on first use). Routed before the
// LLM so the URL/title are exact.

enum BrowserCapability {

    static func handle(_ query: String) -> String? {
        let q = query.lowercased()
        guard isBrowserQuery(q) else { return nil }

        let wantsList = q.contains("tabs") || q.contains("all tab") || q.contains("open tab")
        // Honor an explicit browser mention; otherwise use whichever is frontmost/running.
        let browser: Browser
        if q.contains("chrome") { browser = .chrome }
        else if q.contains("safari") { browser = .safari }
        else { browser = frontmostBrowser() ?? .safari }

        return wantsList ? browser.listTabs() : browser.currentTab()
    }

    private static func isBrowserQuery(_ q: String) -> Bool {
        // Anchored phrases only — broad substrings like "this article"/"what website"/"what url"
        // were hijacking LLM requests ("summarize this article", "what website should I use").
        let triggers = ["what am i reading", "what tab am i", "current tab", "what tabs", "open tabs",
                        "what page am i on", "what site am i on", "what website am i on",
                        "what's the url", "whats the url", "what is the url", "what url am i on",
                        "the page i'm on", "the page im on", "what's this page", "whats this page",
                        "what is this article", "what's this article", "whats this article",
                        "read this article", "my open tabs", "what's open in my browser",
                        "list my tabs", "what am i browsing"]
        return triggers.contains { q.contains($0) }
    }

    private static func frontmostBrowser() -> Browser? {
        let running = NSWorkspace.shared.runningApplications
        let frontmost = running.first(where: { $0.isActive })?.bundleIdentifier
        if frontmost == "com.google.Chrome" { return .chrome }
        if frontmost == "com.apple.Safari" { return .safari }
        // Neither frontmost → pick whichever is running.
        let ids = Set(running.compactMap { $0.bundleIdentifier })
        if ids.contains("com.apple.Safari") { return .safari }
        if ids.contains("com.google.Chrome") { return .chrome }
        return nil
    }

    // MARK: - Per-browser AppleScript

    private enum Browser {
        case safari, chrome

        var appName: String { self == .safari ? "Safari" : "Google Chrome" }

        func currentTab() -> String {
            let tabRef = self == .safari ? "current tab of front window" : "active tab of front window"
            let script = """
            if application "\(appName)" is running then
                tell application "\(appName)"
                    if (count of windows) is 0 then return "No \(appName) windows open."
                    set t to \(tabRef)
                    return (name of t) & "\n" & (URL of t)
                end tell
            else
                return "\(appName) isn't open."
            end if
            """
            let out = runScript(script, fallback: "Couldn't read \(appName) — Alfred may need Automation permission for it.")
            let parts = out.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return out }
            return "You're on: \(parts[0])\n\(parts[1])"
        }

        func listTabs() -> String {
            let script = """
            if application "\(appName)" is running then
                tell application "\(appName)"
                    if (count of windows) is 0 then return "No \(appName) windows open."
                    set out to ""
                    set c to 0
                    repeat with t in tabs of front window
                        if c ≥ 15 then exit repeat
                        set out to out & "• " & (name of t) & " — " & (URL of t) & "\n"
                        set c to c + 1
                    end repeat
                    return out
                end tell
            else
                return "\(appName) isn't open."
            end if
            """
            let out = runScript(script, fallback: "Couldn't read \(appName) — Alfred may need Automation permission for it.")
            return out.isEmpty ? "No open tabs in \(appName)." : "Open in \(appName):\n\(out)"
        }
    }

    private static func runScript(_ source: String, fallback: String) -> String {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return fallback }
        let output = script.executeAndReturnError(&err)
        if err != nil { return fallback }
        return output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
    }
}
