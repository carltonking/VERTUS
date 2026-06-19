import Foundation
import AppKit
import ApplicationServices

/// Phase 7 — UI automation via the macOS Accessibility (AX) API.
/// Lets Alfred read the frontmost app's controls and click/type into them.
/// Requires Accessibility permission (System Settings ▸ Privacy & Security ▸
/// Accessibility). AX is inherently brittle — titles/layouts vary per app — so this
/// is scripted + human-in-loop, and every action still flows through the gateway.
enum UIControl {

    struct El { let role: String; let title: String }

    static func isTrusted() -> Bool { AXIsProcessTrusted() }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func role(_ el: AXUIElement) -> String {
        (attr(el, kAXRoleAttribute as String) as? String) ?? "?"
    }

    private static func title(_ el: AXUIElement) -> String {
        (attr(el, kAXTitleAttribute as String) as? String)
            ?? (attr(el, kAXDescriptionAttribute as String) as? String)
            ?? (attr(el, kAXValueAttribute as String) as? String) ?? ""
    }

    private static func frontApp() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// Walk the AX tree of the frontmost app, collecting interactive elements with titles.
    static func listElements(maxDepth: Int = 6, limit: Int = 60) -> [El] {
        guard let root = frontApp() else { return [] }
        var out: [El] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            if out.count >= limit || depth > maxDepth { return }
            let r = role(el), t = title(el)
            let interactive = r.contains("Button") || r.contains("TextField") || r.contains("TextArea")
                || r.contains("MenuItem") || r.contains("CheckBox") || r.contains("PopUpButton") || r.contains("Link")
            if interactive && !t.isEmpty { out.append(El(role: r, title: t)) }
            for c in children(el) { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    /// Find a pressable element by (case-insensitive) title and press it.
    static func click(title wanted: String) -> Bool {
        guard let root = frontApp() else { return false }
        var found: AXUIElement?
        func walk(_ el: AXUIElement, _ depth: Int) {
            if found != nil || depth > 8 { return }
            if title(el).lowercased() == wanted.lowercased() { found = el; return }
            for c in children(el) { walk(c, depth + 1) }
        }
        walk(root, 0)
        guard let el = found else { return false }
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// Type a string into whatever is focused, via synthesized keyboard input.
    static func type(_ text: String) -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return false }
        var utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
