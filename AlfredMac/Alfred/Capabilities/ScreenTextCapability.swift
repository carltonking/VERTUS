import AppKit
import ApplicationServices

/// Reads the frontmost app's visible TEXT via the Accessibility API (AXUIElement) — structured
/// text, not pixels. Battery-cheap (one bounded tree walk), privacy-first (no screenshots, no OCR).
struct ScreenTextCapability {
    struct Capture {
        let appName: String
        let bundleId: String
        let windowTitle: String
        let text: String
    }

    /// Extracts text from the focused window of the frontmost app. Returns nil if Accessibility
    /// isn't trusted, there's no frontmost app, or no meaningful text was found.
    func captureFrontmost(maxChars: Int = 6000) -> Capture? {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = front.localizedName ?? "Unknown"
        let bundleId = front.bundleIdentifier ?? ""
        let appElement = AXUIElementCreateApplication(front.processIdentifier)

        let window = copyElement(appElement, kAXFocusedWindowAttribute)
            ?? copyElement(appElement, kAXMainWindowAttribute)
        let windowTitle = window.flatMap { string($0, kAXTitleAttribute) } ?? ""

        var collected = ""
        if let window {
            walk(window, into: &collected, budget: maxChars, depth: 0)
        }
        let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 2 else { return nil }
        return Capture(appName: appName, bundleId: bundleId, windowTitle: windowTitle,
                       text: String(text.prefix(maxChars)))
    }

    /// Bounded recursive walk collecting text-bearing attributes (value / title / description).
    private func walk(_ element: AXUIElement, into out: inout String, budget: Int, depth: Int) {
        if out.count >= budget || depth > 40 { return }
        if let v = string(element, kAXValueAttribute), !v.isEmpty { appendLine(v, to: &out) }
        else if let t = string(element, kAXTitleAttribute), !t.isEmpty { appendLine(t, to: &out) }
        else if let d = string(element, kAXDescriptionAttribute), !d.isEmpty { appendLine(d, to: &out) }

        guard out.count < budget else { return }
        var childrenRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if out.count >= budget { break }
                walk(child, into: &out, budget: budget, depth: depth + 1)
            }
        }
    }

    private func appendLine(_ s: String, to out: inout String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return }
        out += trimmed + "\n"
    }

    private func copyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        // AXUIElement is a CFType; force-cast is the documented bridge here.
        return (ref as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
