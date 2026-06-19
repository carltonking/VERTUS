import Carbon
import OSLog

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotkeys: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var registeredHotkeys: [EventHotKeyRef] = []

    private let logger = Logger(subsystem: "com.alfred.input", category: "hotkey")

    private init() {}

    @discardableResult
    func registerHotkey(keyCode: UInt32, modifiers: UInt32, identifier: UInt32, action: @escaping () -> Void) -> Bool {
        var hotkeyID = EventHotKeyID(signature: 0x414C4652, id: identifier)
        var hotkeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard status == noErr, let ref = hotkeyRef else {
            logger.error("Failed to register hotkey \(identifier): \(status)")
            return false
        }

        hotkeys[identifier] = action
        registeredHotkeys.append(ref)
        logger.debug("Registered hotkey \(identifier)")
        return true
    }

    func installDefaultHotkeys() {
        installEventHandler()
        logger.info("Default hotkeys installed")
    }

    private func handleHotkeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return noErr }

        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )

        guard status == noErr else { return status }

        if let action = hotkeys[hotkeyID.id] {
            DispatchQueue.main.async {
                action()
            }
        }

        return noErr
    }

    func installEventHandler() {
        let handler: EventHandlerUPP = { _, event, _ in
            GlobalHotkeyManager.shared.handleHotkeyEvent(event)
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        if status != noErr {
            logger.error("Failed to install hotkey event handler: \(status)")
        }
    }

    func unregisterAll() {
        for ref in registeredHotkeys {
            UnregisterEventHotKey(ref)
        }
        registeredHotkeys.removeAll()
        hotkeys.removeAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }

        logger.info("All hotkeys unregistered")
    }
}
