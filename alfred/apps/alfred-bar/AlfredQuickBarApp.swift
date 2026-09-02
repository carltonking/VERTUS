import AppKit
import Carbon.HIToolbox
import Combine
import QuartzCore
import ServiceManagement
import SwiftUI

// MARK: - Diagnostics

/// Debug trace to /tmp so hotkey/toggle behavior can be verified even for
/// launchd-spawned processes with no unified-log access.
func alfredTrace(_ message: String) {
    let line = "\(Date()) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: "/tmp/alfredbar_trace.log") {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        try? handle.close()
    } else {
        try? line.write(toFile: "/tmp/alfredbar_trace.log", atomically: true, encoding: .utf8)
    }
}

/// ALFRED Quick Bar — a notch prompt bar that hides inside the notch and
/// grows out of it when summoned. The panel is an exact replica of the
/// reference screenshot (316×127 pt body, 329 pt top edge, chamfered top
/// corners, 17 pt bottom radius), positioned flush with the very top of the
/// screen so it frames the notch. Toggle: ⇧⌘J or the menubar icon.
@main
struct AlfredQuickBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Global hotkey (Carbon; no Input Monitoring TCC permission needed)

/// Signature "ALBA".
private let hotKeySignature: OSType = 0x414C4241
/// ⇧⌘J — the only combo this app registers.
private let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
private var hotKeyRef: EventHotKeyRef?

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private var panel: KeyablePanel?
    private var host: NSHostingView<QuickBarRootView>?
    private var localMonitor: Any?
    private var statusItem: NSStatusItem?
    private var menubarIcon: NSImage?
    private var appLogo: NSImage?
    private var isHiding = false
    private var lastToggleAt = Date.distantPast
    private var heightObserver: AnyCancellable?
    private var currentWidgetHeight = NotchPanelMetrics.idleHeight()
    private let expansionState = ExpansionState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Bare executables (no app bundle / Info.plist) default to a
        // .prohibited activation policy, which makes the window server treat
        // this as a background-only app: the NSOpenPanel appears but is
        // dismissed the moment it tries to become key. Accessory = menu-bar
        // app that can still activate on demand (no dock icon).
        NSApp.setActivationPolicy(.accessory)
        alfredTrace("activation policy → \(NSApp.activationPolicy().rawValue)")
        loadIcons()
        buildPanel()
        registerHotkey()
        installMenubarIcon()
        registerLaunchAtLogin()

        if CommandLine.arguments.contains("--verify-nub") {
            renderPanel(progress: 0)
            return
        }
        if CommandLine.arguments.contains("--verify") {
            renderPanel(progress: 1, delay: 0.7)
            return
        }
        if CommandLine.arguments.contains("--verify-output")
            || CommandLine.arguments.contains("--verify-long") {
            // Seeded in the root view's onAppear; give the widget-height
            // animation time to finish before capturing.
            renderPanel(progress: 1, delay: 1.1)
            return
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPanel()
            }
        }
    }

    // MARK: - Icons

    private func loadIcons() {
        let dir: URL? = Bundle.main.resourceURL
            ?? Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        func load(_ name: String, size: CGFloat) -> NSImage? {
            guard let dir else { return nil }
            let fileURL = dir.appendingPathComponent(name)
            if let img = NSImage(contentsOf: fileURL) {
                img.size = NSSize(width: size, height: size)
                // Template so the system renders it black on light menu bars
                // and white on dark ones, matching the other menubar icons.
                img.isTemplate = true
                return img
            }
            return nil
        }
        menubarIcon = load("menubar-icon.png", size: 18)		// Template image — exactly like the menubar icon: the system paints
		// it using the current appearance (white on the black bar, black on
		// light surfaces), so it can never go "black on black".
		// LOGO_DARKMODE.png is the white hexagon with the triangle as a
		// transparent cutout; template rendering uses the alpha channel
		// only, so the bar background shows through the triangle.
		appLogo = load("LOGO_DARKMODE.png", size: 14)
    }

    // MARK: - Panel

    private func buildPanel() {
        let size = NSSize(
            width: NotchPanelMetrics.windowWidth,
            height: NotchPanelMetrics.idleHeight()
        )
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Status-bar level so the panel draws over the menu bar center
        // (the notch area) exactly like the reference app.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true

        let host = NSHostingView(rootView: QuickBarRootView(
            logo: appLogo,
            expansionState: expansionState
        ))
        host.wantsLayer = true

        self.host = host
        self.panel = panel
        // Frame must be set BEFORE the content view is assigned.
        let frame = restingFrame(on: NSScreen.main ?? NSScreen.screens[0])
        panel.setFrame(frame, display: false)
        panel.contentView = host

        // Keep the window's height in sync with the widget. Idle = prompt
        // bar only; once ALFRED is answering, the output pane grows in and
        // the window stretches downward (top edge stays flush with the top
        // of the screen). The frame follows the widget INSTANTLY — animating
        // it here as well would fight the SwiftUI size change and make the
        // bar jitter on screen.
        heightObserver = expansionState.$widgetHeight
            .removeDuplicates()
            .sink { [weak self] height in
                guard let self, let panel = self.panel else { return }
                self.currentWidgetHeight = height
                if panel.isVisible {
                    let frame = self.restingFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens.first ?? .init())
                    panel.setFrame(frame, display: true)
                }
            }
    }

    /// The window's top edge is flush with the top of the screen (y = 0),
    /// horizontally centered — the panel then sits exactly where the notch is.
    private func restingFrame(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let h = currentWidgetHeight
        return NSRect(
            x: f.midX - NotchPanelMetrics.windowWidth / 2,
            y: f.maxY - h,
            width: NotchPanelMetrics.windowWidth,
            height: h
        )
    }

    // MARK: - Show / hide transitions

    /// Grows the bar out of the notch: the panel shape animates from a small
    /// notch nub to the full measured panel, content is revealed by the mask
    /// as the shape grows downward.
    func showPanel() {
        guard let panel else { return }
        isHiding = false
        alfredTrace("showPanel")

        panel.setFrame(
            restingFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens.first ?? .init()),
            display: false
        )
        expansionState.progress = 0
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        alfredTrace("after activate: policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) key=\(panel.isKeyWindow) fieldFocusScheduled")

        withAnimation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.6)) {
            expansionState.progress = 1
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .alfredFocusInput, object: nil)
        }
    }

    /// Retracts the bar back into the notch (shape shrinks upward), then
    /// takes the window off screen.
    func hidePanel() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        alfredTrace("hidePanel")

        withAnimation(.easeIn(duration: 0.32)) {
            expansionState.progress = 0
        }
        NSAnimationContext.runAnimationGroup({ [weak self] ctx in
            ctx.duration = 0.32
            self?.panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isHiding else { return } // hide was reversed → keep shown
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1.0
            self.isHiding = false
        })
    }

    /// Show / hide on every press, even while an in-flight hide is animating
    /// (a press during a retract immediately reverses it).
    @objc func togglePanel() {
        guard let panel else { return }
        // Debounce: a single key press+release can fire the Carbon hotkey
        // twice (keyDown and keyUp both carry ⇧⌘J); ignore the second fire.
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.15 else { return }
        lastToggleAt = now
        alfredTrace("togglePanel (visible=\(panel.isVisible), hiding=\(isHiding))")
        if isHiding {
            isHiding = false
            showPanel()
            return
        }
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    // MARK: - Hotkeys

    private func registerHotkey() {
        installHotkeyHandler()
        // Carbon global hotkey — fires from any app WITHOUT needing the
        // Input Monitoring / Accessibility permission that NSEvent global
        // monitors silently lack for launchd-spawned processes.
        let modifiers = UInt32(cmdKey | shiftKey)
        let target = GetApplicationEventTarget()
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_J), modifiers, hotKeyID,
            target, 0, &hotKeyRef
        )
        alfredTrace("hotkey RegisterEventHotKey → \(status) (targetNil=\(target == nil), pid=\(getpid()))")
        // Local monitor: a backup in case the hotkey ever isn't consumed
        // system-wide; the Carbon handler is the primary path.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Escape retracts the bar.
            if event.keyCode == 53, self?.panel?.isVisible == true {
                self?.hidePanel()
                return nil
            }
            guard event.keyCode == kVK_ANSI_J,
                  event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control) else { return event }
            alfredTrace("local monitor fired (isKey=\(NSApp.keyWindow != nil))")
            self?.togglePanel()
            return nil
        }
    }

    /// Installs the event handler for our Carbon hotkey. The C callback
    /// dispatches onto the main thread and toggles the panel; it ignores the
    /// key while our app is frontmost (the local monitor owns that case).
    private func installHotkeyHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, _ in
            var got = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &got
            )
            guard err == noErr,
                  got.signature == hotKeyID.signature,
                  got.id == hotKeyID.id else { return noErr }
            DispatchQueue.main.async {
                alfredTrace("carbon hotkey fired (active=\(NSApp.isActive))")
                // NB: a registered carbon hotkey is consumed by the system
                // BEFORE it ever reaches the app, so the local monitor never
                // fires for it — always toggle here, no isActive guard.
                AppDelegate.shared?.togglePanel()
            }
            return noErr
        }
        let target = GetApplicationEventTarget()
        let installErr = InstallEventHandler(target, handler, 1, &eventSpec, nil, nil)
        alfredTrace("hotkey InstallEventHandler → \(installErr) (targetNil=\(target == nil), pid=\(getpid()))")
    }

    // MARK: - Menubar icon

    private func installMenubarIcon() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = menubarIcon
            button.toolTip = "ALFRED Quick Bar (⇧⌘J)"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Quick Bar (⇧⌘J)", action: #selector(togglePanel), keyEquivalent: "j")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ALFRED Bar", action: #selector(quitApp), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Launch at login

    private func registerLaunchAtLogin() {
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: - Offscreen verification renders

    private func verifyPath() -> String {
        let args = CommandLine.arguments
        if let i = args.firstIndex(where: { $0.hasPrefix("--verify") }), i + 1 < args.count {
            return args[i + 1]
        }
        return "/tmp/alfredbar_render.png"
    }

    /// Shows the real panel window at the given progress and captures the
    /// hosting view at 2× into a PNG (no screen-recording permission needed)
    /// so it can be compared pixel-for-pixel against the reference screenshot.
    private func renderPanel(progress: CGFloat, delay: TimeInterval = 0.7) {
        guard let panel, let host else { return }
        panel.setFrame(
            restingFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens.first ?? .init()),
            display: false
        )
        expansionState.progress = progress
        panel.alphaValue = 1
        panel.orderFront(nil)
        // Give the widget-height animation time to settle before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Capture at the CURRENT widget height so the rep matches the
            // view exactly (idle: bar only; active: bar + output pane).
            let h = self.currentWidgetHeight
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(NotchPanelMetrics.windowWidth * 2),
                pixelsHigh: Int(h * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            rep.size = NSSize(
                width: NotchPanelMetrics.windowWidth,
                height: h
            )
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: self.verifyPath()))
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Notifications

extension Notification.Name {
    static let alfredFocusInput = Notification.Name("alfredFocusInput")
    static let alfredAppendPrompt = Notification.Name("alfredAppendPrompt")
}