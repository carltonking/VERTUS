import AppKit
import ApplicationServices
import Combine
import Foundation

/// Captures the frontmost app's text (Accessibility), filters PII, skips excluded apps +
/// sensitive fields, and persists it to SQLite/FTS5 for later natural-language search.
/// Opt-in and battery-aware (structured text only — no continuous screenshots/OCR).
///
/// Capture is event-driven: it fires on ContextMonitor's app/window/URL change signal
/// (debounced so rapid app-switching coalesces to one capture of the settled app), with a
/// long idle-fallback tick as a backstop. This catches transient UI a fixed timer misses
/// and avoids re-capturing an idle, unchanged window.
@MainActor
final class ScreenTextMonitor: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status = "Screen text capture is off."
    @Published private(set) var captureCount = 0

    private let store: MemoryStore
    private let capability = ScreenTextCapability()
    private let screen = ScreenCapability()
    private let ocr = VisionOCRCapability()
    private let idleFallback: TimeInterval
    private let excluded: Set<String>
    private let contextChanges: AnyPublisher<AppContext?, Never>?
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastText = ""

    init(
        store: MemoryStore,
        contextChanges: AnyPublisher<AppContext?, Never>? = nil,
        idleFallback: TimeInterval = 300,
        excluded: Set<String> = ScreenTextMonitor.defaultExcluded
    ) {
        self.store = store
        self.contextChanges = contextChanges
        self.idleFallback = idleFallback
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
            status = "Capturing screen text on-device when the active app or page changes."
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            status = "Needs Accessibility permission to capture — System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable Alfred."
        }

        // Event-driven: capture when the frontmost app/window/URL changes. Trailing debounce
        // coalesces rapid app-switching into a single capture of the app the user lands on;
        // captureOnce()'s exclusion + dedup guards keep redundant rows out.
        contextChanges?
            .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.captureOnce() }
            .store(in: &cancellables)

        // Backstop: a slow idle tick still captures content that changes without a context
        // change (e.g. scrolling a long document in the same window), and covers the case where
        // no context-change publisher was wired. Once permission is granted mid-session, captures
        // begin automatically.
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel(); task = nil
        cancellables.removeAll()
        isActive = false
        status = "Screen text capture is off."
    }

    private func loop() async {
        while !Task.isCancelled {
            captureOnce()
            try? await Task.sleep(nanoseconds: UInt64(idleFallback * 1_000_000_000))
        }
    }

    private func captureOnce() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let bid = (front.bundleIdentifier ?? "").lowercased()
        let name = (front.localizedName ?? "").lowercased()
        if excluded.contains(where: { bid.contains($0) || name.contains($0) }) { return }

        if let cap = capability.captureFrontmost() {
            insertIfNew(appName: cap.appName, bundleId: cap.bundleId, windowTitle: cap.windowTitle, text: cap.text)
        } else {
            // Accessibility yielded no text (canvas/PDF-in-browser/Electron/remote-desktop/image).
            // Fall back to on-device Vision OCR of a screenshot. Gated to the empty-a11y case so it
            // stays rare and cheap, and routed through the same exclusion + Redactor + dedup guards.
            ocrFallback(appName: front.localizedName ?? "Unknown", bundleId: front.bundleIdentifier ?? "")
        }
    }

    /// Redact, dedup, and persist. Shared by the Accessibility and OCR paths so OCR rows get the
    /// same PII filtering and consecutive-duplicate suppression.
    private func insertIfNew(appName: String, bundleId: String, windowTitle: String, text: String) {
        // Client-side PII filter using the same non-removable patterns as the cloud egress gate.
        let clean = Redactor().redact(text).text
        guard clean.count > 2, clean != lastText else { return }
        lastText = clean

        store.insertScreenText(
            timestamp: Date().timeIntervalSince1970,
            appName: appName, bundleId: bundleId,
            windowTitle: windowTitle, text: clean
        )
        captureCount += 1
    }

    private func ocrFallback(appName: String, bundleId: String) {
        Task { [weak self] in
            guard let self,
                  let jpeg = try? await self.screen.captureScreen() else { return }
            let text = await self.ocr.recognizeText(in: jpeg)
            guard !text.isEmpty else { return }
            self.insertIfNew(appName: appName, bundleId: bundleId, windowTitle: "", text: text)
        }
    }
}
