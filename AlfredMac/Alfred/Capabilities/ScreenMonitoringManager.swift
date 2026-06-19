import AppKit
import ApplicationServices
import Foundation

struct MonitoredScreenContext {
    let capturedAt: Date
    let jpegData: Data
}

@MainActor
final class ScreenMonitoringManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status = "Screen monitoring is off."

    private let screen = ScreenCapability()
    private let interval: TimeInterval
    private var monitorTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var latestContext: MonitoredScreenContext?

    init(interval: TimeInterval = 45) {
        self.interval = interval
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Screen monitoring active. Captures stay in memory only."

        monitorTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        clearContext()
        isActive = false
        status = "Screen monitoring is off."
    }

    func latestSummary() -> String {
        guard let latestContext else { return "No screen context is currently cached." }
        let formatter = ISO8601DateFormatter()
        return "Latest screen context captured at \(formatter.string(from: latestContext.capturedAt)); \(ByteCountFormatter.string(fromByteCount: Int64(latestContext.jpegData.count), countStyle: .file)) held in memory."
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await captureOnce()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func captureOnce() async {
        if focusedFieldLooksSensitive() {
            clearContext()
            status = "Screen monitoring active; skipped capture while a sensitive field appears focused."
            return
        }

        do {
            let data = try await screen.captureScreen()
            latestContext = MonitoredScreenContext(capturedAt: Date(), jpegData: data)
            scheduleShortLivedClear()
            status = "Screen monitoring active. Latest capture is held in memory only."
        } catch {
            clearContext()
            isActive = false
            monitorTask?.cancel()
            monitorTask = nil
            status = "Screen monitoring stopped: \(error.localizedDescription)"
            await CapabilityEventLogger.shared.record("screen monitoring", "stopped", detail: error.localizedDescription)
        }
    }

    private func scheduleShortLivedClear() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            await MainActor.run {
                self?.latestContext = nil
                if self?.isActive == true {
                    self?.status = "Screen monitoring active. No recent capture is cached."
                }
            }
        }
    }

    private func clearContext() {
        clearTask?.cancel()
        clearTask = nil
        latestContext = nil
    }

    private func focusedFieldLooksSensitive() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemElement = AXUIElementCreateSystemWide()
        var focusedElementRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success, let focusedElementRef else {
            return false
        }

        let focusedElement = focusedElementRef as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute as CFString, from: focusedElement).lowercased()
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: focusedElement).lowercased()
        let description = stringAttribute(kAXDescriptionAttribute as CFString, from: focusedElement).lowercased()
        let title = stringAttribute(kAXTitleAttribute as CFString, from: focusedElement).lowercased()
        let combined = "\(role) \(subrole) \(description) \(title)"

        return combined.contains("secure")
            || combined.contains("password")
            || combined.contains("passcode")
            || combined.contains("credit card")
            || combined.contains("payment")
            || combined.contains("secret")
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else {
            return ""
        }
        return valueRef as? String ?? ""
    }
}
