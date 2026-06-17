import AppKit
import ApplicationServices
import Foundation

/// Periodically captures the frontmost app's text (Accessibility), filters PII, skips excluded
/// apps + sensitive fields, and persists it to SQLite/FTS5 for later natural-language search.
/// Opt-in and battery-aware (structured text only — no continuous screenshots/OCR).
@MainActor
final class ScreenTextMonitor: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status = "Screen text capture is off."
    @Published private(set) var captureCount = 0

    private let store: MemoryStore
    private let capability = ScreenTextCapability()
    private let interval: TimeInterval
    private let excluded: Set<String>
    private var task: Task<Void, Never>?
    private var lastText = ""

    init(store: MemoryStore, interval: TimeInterval = 60, excluded: Set<String> = ScreenTextMonitor.defaultExcluded) {
        self.store = store
        self.interval = interval
        self.excluded = excluded
    }

    /// Apps never captured (matched as lowercase substrings of bundle id or app name).
    nonisolated static let defaultExcluded: Set<String> = [
        "1password", "keychain", "lastpass", "bitwarden", "dashlane",
        "bank", "wallet", "venmo", "paypal", "coinbase",
        "com.apple.keychainaccess"
    ]

    func start() {
        guard !isActive else { return }
        isActive = true
        // Capture reads text via the Accessibility API (AXIsProcessTrusted) — NOT Screen Recording.
        // If it isn't granted, capturing silently yields nothing, so prompt for it and say why.
        if AXIsProcessTrusted() {
            status = "Capturing screen text on-device every \(Int(interval))s."
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            status = "Needs Accessibility permission to capture — System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable Alfred."
        }
        // Loop runs regardless; once permission is granted mid-session, captures begin automatically.
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel(); task = nil
        isActive = false
        status = "Screen text capture is off."
    }

    private func loop() async {
        while !Task.isCancelled {
            captureOnce()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func captureOnce() {
        guard let cap = capability.captureFrontmost() else { return }
        let bid = cap.bundleId.lowercased()
        let name = cap.appName.lowercased()
        if excluded.contains(where: { bid.contains($0) || name.contains($0) }) { return }

        // Client-side PII filter using the same non-removable patterns as the cloud egress gate.
        let clean = Redactor().redact(cap.text).text
        // Skip near-identical consecutive captures (e.g. user idle on one window).
        guard clean != lastText else { return }
        lastText = clean

        store.insertScreenText(
            timestamp: Date().timeIntervalSince1970,
            appName: cap.appName, bundleId: cap.bundleId,
            windowTitle: cap.windowTitle, text: clean
        )
        captureCount += 1
    }
}
