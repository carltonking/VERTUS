import AppKit
import Carbon
import OSLog

private let logger = Logger(subsystem: "com.alfred.app", category: "HotkeyListener")

final class HotkeyListener {
    private let callback: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var selfPtr: UnsafeMutableRawPointer?

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    // MARK: - Public API

    func start() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let ptr = Unmanaged.passRetained(self).toOpaque()
        selfPtr = ptr

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == HotkeyListener.signature,
                      hotKeyID.id == HotkeyListener.hotKeyID
                else { return noErr }

                let listener = Unmanaged<HotkeyListener>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    listener.callback()
                }
                return noErr
            },
            1,
            &eventType,
            ptr,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            cleanupRetainedSelf()
            logger.error("Failed to install hotkey event handler: \(handlerStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.hotKeyID
        )

        // Cmd+Shift+J. Carbon key code 38 is J.
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_J),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            stop()
            logger.error("Failed to register Cmd+Shift+J: \(registerStatus)")
            return
        }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
        cleanupRetainedSelf()
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private static let signature: OSType = 0x414C4652 // ALFR
    private static let hotKeyID: UInt32 = 1

    private func cleanupRetainedSelf() {
        if let selfPtr {
            Unmanaged<HotkeyListener>.fromOpaque(selfPtr).release()
            self.selfPtr = nil
        }
    }
}
