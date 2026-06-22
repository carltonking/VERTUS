import AppKit
import ApplicationServices

/// One actionable on-screen element: a stable 1-based index, its AX role, a human label, and
/// its screen frame. This is the "Semantic Object Map" — the model picks an element by number
/// or label instead of guessing pixel coordinates.
struct AccessibilityElement: Equatable {
    let index: Int
    let role: String
    let label: String
    let frame: CGRect

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

enum AccessibilityObjectMap {
    /// How the user/model referred to an element in a "click" action.
    enum ClickReference: Equatable {
        case index(Int)
        case label(String)
    }

    /// Roles worth offering as click targets — interactive controls only, not static text.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXPopUpButton", "AXComboBox", "AXTabButton",
        "AXDisclosureTriangle", "AXToolbarButton", "AXSegmentedControl", "AXIncrementor",
    ]

    /// Enumerate actionable elements of a window, in tree order. Bounded for battery/latency.
    /// Returns [] if Accessibility is denied or there is no window.
    ///
    /// `targetBundleId` matters because Alfred's own floating bar is usually frontmost while the
    /// user is typing — pass the app they actually want to inspect/control (e.g. ContextMonitor's
    /// last non-Alfred app) instead of capturing Alfred's own UI. Defaults to the frontmost app.
    @MainActor
    static func capture(maxElements: Int = 60, maxDepth: Int = 45, targetBundleId: String? = nil) -> [AccessibilityElement] {
        guard AXIsProcessTrusted() else { return [] }

        let target: NSRunningApplication?
        if let targetBundleId, targetBundleId != Bundle.main.bundleIdentifier {
            target = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == targetBundleId }
        } else {
            target = NSWorkspace.shared.frontmostApplication
        }
        guard let target else { return [] }

        let app = AXUIElementCreateApplication(target.processIdentifier)
        guard let window = copyElement(app, kAXFocusedWindowAttribute) ?? copyElement(app, kAXMainWindowAttribute)
        else { return [] }

        var out: [AccessibilityElement] = []
        walk(window, into: &out, maxElements: maxElements, depth: 0, maxDepth: maxDepth)
        return out
    }

    /// Parse a "click" action line into an element reference, or nil if it isn't one (e.g. a raw
    /// coordinate "click 100 200", which the coordinate parser handles). Pure — no AX access — so
    /// the brittle text parsing is unit-testable without a live UI.
    static func parseClickReference(_ rawLine: String) -> ClickReference? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = line.lowercased()
        guard lowered.hasPrefix("click "), !lowered.hasPrefix("double") else { return nil }

        let rest = String(line.dropFirst("click ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(rest.startIndex..., in: rest)

        // "element 7" or "#7"
        if let m = elementRefPattern.firstMatch(in: rest, range: range),
           let g = Range(m.range(at: 1), in: rest), let n = Int(rest[g]) {
            return .index(n)
        }
        // Two numbers => a raw coordinate click, not an element reference.
        if numberPattern.numberOfMatches(in: rest, range: range) >= 2 { return nil }

        // Otherwise treat the remainder as a label to match.
        var label = rest.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if label.lowercased().hasPrefix("the ") { label = String(label.dropFirst(4)) }
        if label.lowercased().hasSuffix(" button") { label = String(label.dropLast(" button".count)) }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count >= 2 else { return nil }
        return .label(label)
    }

    /// Resolve a reference against a captured map. Throws a descriptive message if unresolved.
    static func resolve(_ ref: ClickReference, in map: [AccessibilityElement]) -> AccessibilityElement? {
        switch ref {
        case .index(let n):
            return map.first { $0.index == n }
        case .label(let label):
            let needle = label.lowercased()
            // Prefer an exact label, fall back to a substring match.
            return map.first { $0.label.lowercased() == needle }
                ?? map.first { $0.label.lowercased().contains(needle) }
        }
    }

    /// Numbered list for injection into the computer-control prompt.
    static func render(_ map: [AccessibilityElement]) -> String {
        map.map { el in
            let role = el.role.replacingOccurrences(of: "AX", with: "")
            return "\(el.index): \(role) \"\(el.label)\""
        }.joined(separator: "\n")
    }

    // MARK: - AX walk

    private static let elementRefPattern = try! NSRegularExpression(pattern: #"(?i)(?:element\s*|#\s*)(\d+)"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)

    @MainActor
    private static func walk(_ element: AXUIElement, into out: inout [AccessibilityElement], maxElements: Int, depth: Int, maxDepth: Int) {
        if out.count >= maxElements || depth > maxDepth { return }

        if let role = string(element, kAXRoleAttribute), actionableRoles.contains(role),
           let frame = frame(of: element), frame.width > 1, frame.height > 1 {
            let raw = string(element, kAXTitleAttribute)
                ?? string(element, kAXDescriptionAttribute)
                ?? string(element, kAXValueAttribute)
                ?? ""
            let label = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            if !label.isEmpty {
                out.append(AccessibilityElement(index: out.count + 1, role: role, label: label, frame: frame))
            }
        }

        guard out.count < maxElements else { return }
        var childrenRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if out.count >= maxElements { break }
                walk(child, into: &out, maxElements: maxElements, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func copyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
