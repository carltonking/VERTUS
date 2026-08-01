import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ContextMonitor: ObservableObject {
    @Published private(set) var context: AppContext?
    @Published private(set) var suggestions: [ProactiveSuggestion] = []
    @Published private(set) var status: String = ""

    private var timer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var lastSignature = ""
    private var cachedBrowserSignature = ""
    private var pendingBrowserSignature = ""
    private var cachedBrowserContext: (url: String?, title: String?) = (nil, nil)
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.5) {
        self.interval = interval
    }

    func start() {
        guard timer == nil, appActivationObserver == nil else { return }
        refresh()

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(forceBrowserRead: true)
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        appActivationObserver = nil
    }

    func refresh(forceBrowserRead: Bool = false) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }

        let appName = app.localizedName ?? "Current app"
        let bundleIdentifier = app.bundleIdentifier
        let accessibilityGranted = AXIsProcessTrusted()
        let windowTitle = accessibilityGranted ? frontmostWindowTitle(for: app) : nil
        status = accessibilityGranted ? "" : "Accessibility is off: suggestions use limited app context."
        let browser = browserTabContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            forceRead: forceBrowserRead
        )

        let next = AppContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            browserURL: browser.url,
            browserTitle: browser.title
        )

        let signature = [
            next.appName,
            next.windowTitle ?? "",
            next.browserURL ?? "",
            next.browserTitle ?? "",
        ].joined(separator: "|")

        guard signature != lastSignature else { return }
        lastSignature = signature
        context = next
        suggestions = SuggestionEngine.suggestions(for: next)
    }

    private func frontmostWindowTitle(for app: NSRunningApplication) -> String? {
        // refresh() already gates this call on accessibilityGranted (AXIsProcessTrusted()); no re-check.
        guard let pid = app.processIdentifier as pid_t? else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef
        else { return nil }

        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }

        return titleRef as? String
    }

    private func browserTabContext(
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        forceRead: Bool
    ) -> (url: String?, title: String?) {
        let id = bundleIdentifier ?? ""
        let browserSignature = [id, appName, windowTitle ?? ""].joined(separator: "|")

        if !forceRead, browserSignature == cachedBrowserSignature {
            return cachedBrowserContext
        }

        guard let script = browserAppleScript(appName: appName, bundleIdentifier: id) else {
            cachedBrowserSignature = browserSignature
            cachedBrowserContext = (nil, nil)
            return (nil, nil)
        }

        if pendingBrowserSignature != browserSignature || forceRead {
            pendingBrowserSignature = browserSignature
            Task {
                let result = await Self.runAppleScript(script)
                await MainActor.run {
                    guard self.pendingBrowserSignature == browserSignature else { return }
                    self.pendingBrowserSignature = ""
                    self.cachedBrowserSignature = browserSignature
                    self.cachedBrowserContext = result
                    if result.url == nil, self.isBrowser(bundleIdentifier: id) {
                        self.status = "Browser automation is unavailable or denied: URL/title context is limited."
                    }
                    self.refresh()
                }
            }
        }

        return cachedBrowserContext
    }

    private func isBrowser(bundleIdentifier: String) -> Bool {
        [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
        ].contains(bundleIdentifier)
    }

    private func browserAppleScript(appName: String, bundleIdentifier: String) -> String? {
        if bundleIdentifier == "com.apple.Safari" {
            return """
                tell application "Safari"
                    if not (exists front document) then return ""
                    set tabURL to URL of front document
                    set tabName to name of front document
                    return tabURL & linefeed & tabName
                end tell
                """
        }

        if [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
        ].contains(bundleIdentifier) {
            return """
                tell application "\(appName)"
                    if not (exists front window) then return ""
                    set activeTab to active tab of front window
                    return URL of activeTab & linefeed & title of activeTab
                end tell
                """
        }

        return nil
    }

    private nonisolated static func runAppleScript(_ source: String) async -> (url: String?, title: String?) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return (nil, nil)
            }

            guard process.terminationStatus == 0 else {
                return (nil, nil)
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty
            else { return (nil, nil) }

            let lines = output.components(separatedBy: .newlines)
            let url = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (url?.isEmpty == false ? url : nil, title.isEmpty ? nil : title)
        }.value
    }
}
