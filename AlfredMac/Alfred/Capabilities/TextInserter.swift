import AppKit
import ApplicationServices

struct TextInserter {

    // MARK: - Public

    func insert(text: String) async {
        if await tryAXInsert(text: text) { return }
        if await tryPasteboardInsert(text: text) { return }
        await typeFallback(text: text)
    }

    // MARK: - Strategy 1: AXUIElement direct write

    @MainActor
    private func tryAXInsert(text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemElement = AXUIElementCreateSystemWide()
        var focusedElementRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        guard result == .success,
              let ref = focusedElementRef,
              CFGetTypeID(ref as AnyObject) == AXUIElementGetTypeID()
        else { return false }

        let focusedElement = ref as! AXUIElement

        // Read existing value, insert text at end (or replace selection)
        var valueRef: AnyObject?
        AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &valueRef)
        let existing = (valueRef as? String) ?? ""

        // Try to get selected range to insert at cursor position
        var rangeRef: AnyObject?
        var insertionPoint = existing.endIndex
        if AXUIElementCopyAttributeValue(
            focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeValue = rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, AXValueType.cfRange, &cfRange) {
                if let idx = existing.utf16.index(
                    existing.utf16.startIndex,
                    offsetBy: cfRange.location,
                    limitedBy: existing.utf16.endIndex
                ) {
                    insertionPoint = idx.samePosition(in: existing) ?? existing.endIndex
                }
            }
        }

        var newValue = existing
        newValue.insert(contentsOf: text, at: insertionPoint)

        let setResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            newValue as CFString
        )

        return setResult == .success
    }

    // MARK: - Strategy 2: NSPasteboard + Cmd+V

    @MainActor
    private func tryPasteboardInsert(text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (types: [NSPasteboard.PasteboardType], data: [NSPasteboard.PasteboardType: Data])? in
            let types = item.types
            let dataMap = Dictionary(uniqueKeysWithValues: types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
            return (types: types, data: dataMap)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKeyEvent(keyCode: 9, flags: .maskCommand)  // Cmd+V

        // Short wait then restore clipboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            if let items = savedItems {
                for item in items {
                    let pbItem = NSPasteboardItem()
                    for (type, data) in item.data {
                        pbItem.setData(data, forType: type)
                    }
                    pasteboard.writeObjects([pbItem])
                }
            }
        }

        return true
    }

    // MARK: - Strategy 3: CGEvent keystroke fallback

    private func typeFallback(text: String) async {
        for scalar in text.unicodeScalars {
            let char = scalar.value
            guard let source = CGEventSource(stateID: .combinedSessionState) else { continue }

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char)])
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char)])
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }

            // ~60 WPM pacing to avoid dropped events
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Helpers

    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
