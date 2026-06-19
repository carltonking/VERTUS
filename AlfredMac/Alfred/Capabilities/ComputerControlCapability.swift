import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ComputerControlCapability {
    private static let maxActions = 20
    private var isCancelled = false

    struct Plan {
        let actions: [Action]

        var summary: String {
            actions.enumerated()
                .map { index, action in "\(index + 1). \(action.summary)" }
                .joined(separator: "\n")
        }
    }

    enum Action {
        case moveMouse(x: CGFloat, y: CGFloat)
        case click(x: CGFloat, y: CGFloat)
        case doubleClick(x: CGFloat, y: CGFloat)
        case pressKey(String)
        case hotkey([String])
        case typeText(String)
        case wait(TimeInterval)

        var summary: String {
            switch self {
            case .moveMouse(let x, let y):
                return "Move mouse to (\(Int(x)), \(Int(y)))"
            case .click(let x, let y):
                return "Click at (\(Int(x)), \(Int(y)))"
            case .doubleClick(let x, let y):
                return "Double click at (\(Int(x)), \(Int(y)))"
            case .pressKey(let key):
                return "Press key: \(key)"
            case .hotkey(let keys):
                return "Press hotkey: \(keys.joined(separator: "+"))"
            case .typeText(let text):
                return "Type text: \(text.count) characters"
            case .wait(let seconds):
                return "Wait \(String(format: "%.1f", seconds)) seconds"
            }
        }
    }

    enum ControlError: LocalizedError {
        case notRequested
        case accessibilityMissing
        case noActions
        case tooManyActions
        case unsafeSensitiveText
        case potentiallyDestructive
        case invalidAction(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notRequested:
                return nil
            case .accessibilityMissing:
                return "Accessibility permission is required for computer control. Open Alfred Permissions and grant Accessibility access."
            case .noActions:
                return "No supported computer-control actions were found. Use actions like click 100 200, double click 100 200, hotkey command tab, type \"text\", wait 1."
            case .tooManyActions:
                return "Computer-control requests are capped at 20 actions. Please ask for a smaller set."
            case .unsafeSensitiveText:
                return "I won't type passwords, payment details, or sensitive secrets."
            case .potentiallyDestructive:
                return "That looks potentially destructive. Please break it into a smaller request and confirm the destructive step separately."
            case .invalidAction(let line):
                return "I couldn't parse this computer-control action: \(line)"
            case .cancelled:
                return "Computer control cancelled."
            }
        }
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func makePlan(from query: String) throws -> Plan? {
        let lowered = query.lowercased()
        let triggers = [
            "control my mac",
            "control the mac",
            "control this mac",
            "control computer",
            "control the computer",
            "use my mac",
            "click ",
            "double click",
            "move mouse",
            "press key",
            "hotkey",
            "type text",
        ]
        guard triggers.contains(where: { lowered.contains($0) }) else {
            return nil
        }

        if containsSensitiveEntryRequest(lowered) {
            throw ControlError.unsafeSensitiveText
        }
        if containsDestructiveRequest(lowered) {
            throw ControlError.potentiallyDestructive
        }

        let actionText = normalizedActionText(from: query)
        let lines = actionText
            .components(separatedBy: CharacterSet(charactersIn: "\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var actions: [Action] = []
        for line in lines {
            guard let action = parseAction(line) else {
                if line.lowercased().contains("control") || line.lowercased().contains("please") {
                    continue
                }
                throw ControlError.invalidAction(line)
            }
            actions.append(action)
        }

        guard !actions.isEmpty else { throw ControlError.noActions }
        guard actions.count <= Self.maxActions else { throw ControlError.tooManyActions }
        return Plan(actions: actions)
    }

    func cancel() {
        isCancelled = true
    }

    func execute(_ plan: Plan, onStep: ((String) -> Void)? = nil) async throws -> String {
        guard hasAccessibilityPermission else {
            throw ControlError.accessibilityMissing
        }

        isCancelled = false
        var completed: [String] = []

        for action in plan.actions {
            if isCancelled { throw ControlError.cancelled }
            onStep?(action.summary)
            try await execute(action)
            completed.append(action.summary)
        }

        return "Computer control complete. Ran \(completed.count) action\(completed.count == 1 ? "" : "s")."
    }

    private func execute(_ action: Action) async throws {
        switch action {
        case .moveMouse(let x, let y):
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        case .click(let x, let y):
            postMouse(at: CGPoint(x: x, y: y), clickCount: 1)
        case .doubleClick(let x, let y):
            postMouse(at: CGPoint(x: x, y: y), clickCount: 2)
        case .pressKey(let key):
            guard let keyCode = Self.keyCode(for: key) else {
                throw ControlError.invalidAction("press key \(key)")
            }
            postKey(keyCode: keyCode, flags: [])
        case .hotkey(let keys):
            let parsed = try parseHotkey(keys)
            postKey(keyCode: parsed.keyCode, flags: parsed.flags)
        case .typeText(let text):
            try await type(text)
        case .wait(let seconds):
            let capped = min(max(seconds, 0.1), 10)
            try await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000))
        }
    }

    private func normalizedActionText(from query: String) -> String {
        let separators = ["actions:", "action:", "then:"]
        for separator in separators {
            if let range = query.range(of: separator, options: [.caseInsensitive]) {
                return String(query[range.upperBound...])
            }
        }
        return query
    }

    private func parseAction(_ rawLine: String) -> Action? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = line.lowercased()

        if lowered.hasPrefix("move mouse") || lowered.hasPrefix("move") {
            return coordinates(from: line).map { .moveMouse(x: $0.x, y: $0.y) }
        }
        if lowered.hasPrefix("double click") {
            return coordinates(from: line).map { .doubleClick(x: $0.x, y: $0.y) }
        }
        if lowered.hasPrefix("click") {
            return coordinates(from: line).map { .click(x: $0.x, y: $0.y) }
        }
        if lowered.hasPrefix("press key") {
            let key = line.replacingOccurrences(of: #"(?i)^press key\s+"#, with: "", options: .regularExpression)
            return key.isEmpty ? nil : .pressKey(key)
        }
        if lowered.hasPrefix("hotkey") {
            let keys = line
                .replacingOccurrences(of: #"(?i)^hotkey\s+"#, with: "", options: .regularExpression)
                .split { $0 == "+" || $0 == " " || $0 == "," }
                .map(String.init)
                .filter { !$0.isEmpty }
            return keys.isEmpty ? nil : .hotkey(keys)
        }
        if lowered.hasPrefix("type text") || lowered.hasPrefix("type ") {
            let text = quotedText(in: line)
                ?? line.replacingOccurrences(of: #"(?i)^type(?: text)?\s+"#, with: "", options: .regularExpression)
            guard !containsSensitiveEntryRequest(text.lowercased()) else { return nil }
            return text.isEmpty ? nil : .typeText(text)
        }
        if lowered.hasPrefix("wait") {
            let seconds = Double(line.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()) ?? 1
            return .wait(seconds)
        }

        return nil
    }

    private func coordinates(from text: String) -> (x: CGFloat, y: CGFloat)? {
        guard let regex = try? NSRegularExpression(pattern: #"(-?\d+(?:\.\d+)?)"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard matches.count >= 2,
              let xRange = Range(matches[0].range(at: 1), in: text),
              let yRange = Range(matches[1].range(at: 1), in: text),
              let x = Double(text[xRange]),
              let y = Double(text[yRange])
        else { return nil }
        return (CGFloat(x), CGFloat(y))
    }

    private func quotedText(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]*)"|'([^']*)'"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        for index in 1...2 {
            if let textRange = Range(match.range(at: index), in: text) {
                return String(text[textRange])
            }
        }
        return nil
    }

    private func parseHotkey(_ keys: [String]) throws -> (keyCode: CGKeyCode, flags: CGEventFlags) {
        var flags: CGEventFlags = []
        var keyName: String?

        for key in keys.map({ $0.lowercased() }) {
            switch key {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "option", "alt":
                flags.insert(.maskAlternate)
            case "control", "ctrl":
                flags.insert(.maskControl)
            default:
                keyName = key
            }
        }

        guard let keyName, let keyCode = Self.keyCode(for: keyName) else {
            throw ControlError.invalidAction("hotkey \(keys.joined(separator: "+"))")
        }

        return (keyCode, flags)
    }

    private func postMouse(at point: CGPoint, clickCount: Int) {
        CGWarpMouseCursorPosition(point)
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        for click in 1...clickCount {
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) async throws {
        for scalar in text.unicodeScalars {
            if isCancelled { throw ControlError.cancelled }
            guard let source = CGEventSource(stateID: .combinedSessionState) else { continue }
            var value = UniChar(scalar.value)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func containsSensitiveEntryRequest(_ text: String) -> Bool {
        ["password", "passcode", "secret", "api key", "token", "credit card", "payment", "ssn", "social security"].contains {
            text.contains($0)
        }
    }

    private func containsDestructiveRequest(_ text: String) -> Bool {
        ["delete", "remove", "erase", "trash", "wipe", "format", "purchase", "buy now", "send money", "transfer money"].contains {
            text.contains($0)
        }
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        let key = key.lowercased()
        let table: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
            "`": 50, "escape": 53, "esc": 53, "delete": 51, "backspace": 51,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        return table[key]
    }
}
