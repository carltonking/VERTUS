import AppKit
import Carbon.HIToolbox
import Combine
import QuartzCore
import ServiceManagement
import SwiftUI
import UserNotifications
import VertusKit

// MARK: - Diagnostics

/// Debug trace to /tmp so hotkey/toggle behavior can be verified even for
/// launchd-spawned processes with no unified-log access.
func vertusTrace(_ message: String) {
    let line = "\(Date()) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: "/tmp/vertusbar_trace.log") {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        try? handle.close()
    } else {
        try? line.write(toFile: "/tmp/vertusbar_trace.log", atomically: true, encoding: .utf8)
    }
}

/// VERTUS — one app, one process: the full window (roster, chat, memory,
/// threads, screens, activity, bot editor) AND the notch QuickBar menubar
/// extra (⇧⌘J). One FleetStore, one fleet-stream connection, one health
/// poll, one memory index — the pre-merge VertusBar/VertusFleet pair ran
/// two processes and two of everything.
///
/// Activation policy: .regular (the default for a SwiftUI app). The QuickBar
/// panel keeps its window-level protections — .nonactivatingPanel,
/// .statusBar level, .canJoinAllSpaces/.fullScreenAuxiliary — so its
/// not-stealing behavior is identical under a regular app; see Checkpoint 0
/// of the merge prompt for the analysis.
@main
struct VertusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                // Replacing .newItem keeps ⌘N out (no second window concept).
                CommandGroup(replacing: .newItem) { }
                CommandMenu("VERTUS") {
                    Button("Open VERTUS Window") {
                        AppDelegate.shared?.openMainWindow()
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                }
            }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// AppKit constrains window frames so the top edge stays on screen —
    /// and for auto-resized windows it can push the whole panel DOWN below
    /// the menu bar (the bar visibly detaching from the top while typing).
    /// This panel must sit flush with the screen top at ALL times: return
    /// the requested frame untouched, never shifted downward.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

// MARK: - Global hotkey (Carbon; no Input Monitoring TCC permission needed)

/// Signature "ALBA".
private let hotKeySignature: OSType = 0x414C4241
/// ⇧⌘J — the only combo this app registers.
private let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
private var hotKeyRef: EventHotKeyRef?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    /// ONE store for the whole process: the main window and the QuickBar
    /// panel observe the same fleet stream, health poll, and memory index.
    let store: FleetStore

    private var panel: KeyablePanel?
    private var host: NSHostingView<QuickBarRootView>?
    private var localMonitor: Any?
    private var windowCloseMonitor: Any?
    private var statusItem: NSStatusItem?
    private var menubarIcon: NSImage?
    private var appLogo: NSImage?
    private var isHiding = false
    private var lastToggleAt = Date.distantPast
    private var heightObserver: AnyCancellable?
    private var currentWidgetHeight = NotchPanelMetrics.idleHeight()
    private let expansionState = ExpansionState()
    private var mainWindow: NSWindow?
    private var memoryWindow: NSWindow?
    private var notifier: CompletionNotifier?

    override init() {
        let config = ServerConfig.load()
        self.store = FleetStore(
            client: VertusHTTPClient(config: config),
            stream: FleetStream(config: config,
                                cursor: StreamCursor(processName: "vertus"))
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Regular app by default (the SwiftUI @main App policy); set it
        // explicitly so the intent survives refactors. The Dock icon and
        // ⌘Tab presence are the accepted cost of one app with a real window;
        // nothing about the panel's non-stealing behavior depends on policy.
        NSApp.setActivationPolicy(.regular)
        vertusTrace("activation policy → \(NSApp.activationPolicy().rawValue)")
        loadIcons()
        buildPanel()
        registerHotkey()
        installMenubarIcon()
        registerLaunchAtLogin()
        installNotifications()
        installPanelQuitMonitor()
        installWindowCloseMonitor()
        openMainWindow()

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
        // (No --show flag: showing the panel is ⇧⌘J's job, and a launch-time
        // auto-show made GUI verification loops hard to reason about. Render
        // verification uses --verify*, which captures and exits on its own.)
    }

    // MARK: - Icons

    private func loadIcons() {
        // Bundle resources when bundled; the legacy PNGs in vertus-bar/ as
        // the bare-executable fallback.
        var dirs: [URL] = []
        let bundleDir = Bundle.main.resourceURL ?? Bundle.main.bundleURL.deletingLastPathComponent()
        dirs.append(bundleDir.resolvingSymlinksInPath())
        dirs.append(bundleDir.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vertus-bar"))
        func load(_ name: String, size: CGFloat) -> NSImage? {
            for dir in dirs {
                let fileURL = dir.appendingPathComponent(name)
                if let img = NSImage(contentsOf: fileURL) {
                    img.size = NSSize(width: size, height: size)
                    img.isTemplate = true
                    return img
                }
            }
            return nil
        }
        menubarIcon = load("menubar-icon.png", size: 18)
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
            expansionState: expansionState,
            store: store
        ))
        host.wantsLayer = true
        // The hosting view must NEVER resize the window on its own: its
        // content-size tracking grows the window bottom-anchored (AppKit
        // keeps the window origin), which is exactly what pushed the bar
        // down off the top of the screen when the prompt strip grew. The
        // window frame is owned by the height observer + showPanel, which
        // always keep the top edge flush.
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }

        self.host = host
        self.panel = panel
        // Frame must be set BEFORE the content view is assigned.
        let frame = restingFrame(on: NSScreen.main ?? NSScreen.screens[0])
        panel.setFrame(frame, display: false)
        panel.contentView = host

        // Keep the window's height in sync with the widget. Idle = prompt
        // bar only; once VERTUS is answering, the output pane grows in and
        // the window stretches downward (top edge stays flush with the top
        // of the screen). The frame follows the widget INSTANTLY — animating
        // it here as well would fight the SwiftUI size change and make the
        // bar jitter on screen.
        heightObserver = expansionState.$widgetHeight
            .removeDuplicates()
            .sink { [weak self] height in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel else { return }
                    self.currentWidgetHeight = height
                    if panel.isVisible {
                        let frame = self.restingFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens.first ?? .init())
                        panel.setFrame(frame, display: true)
                    }
                }
            }
        // The SwiftUI content can resize while the panel is hidden (typing in
        // the prompt grew the strip, a background turn finished, …). AppKit
        // frames anchor at the bottom-left, so the next show would keep the
        // stale top edge and push the bar DOWN off the top of the screen.
        // Re-sync on every order-front instead: showPanel recomputes the
        // frame from the widget height, so the top edge is always flush.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                guard panel.occlusionState.contains(.visible) else { return }
                panel.setFrame(
                    self.restingFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens.first ?? .init()),
                    display: false
                )
            }
        }
        // Keep the top edge flush when displays change (resolution, plugged/
        // unplugged monitor): the frame must be recomputed for the new screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.currentWidgetHeight = self.expansionState.widgetHeight
                panel.setFrame(
                    self.restingFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens.first ?? .init()),
                    display: true
                )
            }
        }
    }

    /// The window's top edge is flush with the top of the screen (y = 0),
    /// horizontally centered — the panel then sits exactly where the notch is.
    /// The height always comes from `expansionState.widgetHeight` (the view's
    /// own published size), never from a cached value — if the SwiftUI content
    /// resized without a height-observer tick, this still pins the top edge
    /// correctly so the bar can never detach from the top of the screen.
    private func restingFrame(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let h = expansionState.widgetHeight
        return NSRect(
            x: f.midX - NotchPanelMetrics.windowWidth / 2,
            y: f.maxY - h,
            width: NotchPanelMetrics.windowWidth,
            height: h
        )
    }

    // MARK: - Main window (owned by the delegate, so "Open in Fleet" is an
    // in-process activation, never a second process)

    /// Open (or bring forward) the main VERTUS window. Closing it hides it —
    /// the menubar item and ⇧⌘J keep working; Quit from the menubar quits
    /// everything.
    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VERTUS"
        window.contentView = NSHostingView(
            rootView: FleetRootView().environmentObject(store)
        )
        window.setFrameAutosaveName("VERTUSMainWindow")
        window.center()
        window.delegate = self
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// The Memory view as its OWN window, not a sheet. Memory browsing is a
    /// place you spend time (read, edit, search, watch bots write) — a
    /// borderless sheet with no close control was a trap (Bug 2: the app had
    /// to be force-quit). A titled, resizable window gives it the platform
    /// conventions: traffic-light close, ⌘W via the Window menu, ⌘M, resize.
    func showMemoryWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = memoryWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Memory"
        window.contentView = NSHostingView(
            rootView: MemoryView().environmentObject(store)
        )
        window.setFrameAutosaveName("VERTUSMemoryWindow")
        window.isReleasedWhenClosed = false
        memoryWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Show / hide transitions

    /// Grows the bar out of the notch: the panel shape animates from a small
    /// notch nub to the full measured panel, content is revealed by the mask
    /// as the shape grows downward.
    func showPanel() {
        guard let panel else { return }
        isHiding = false
        vertusTrace("showPanel")

        panel.setFrame(
            restingFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens.first ?? .init()),
            display: false
        )
        expansionState.progress = 0
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        vertusTrace("after activate: policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) key=\(panel.isKeyWindow) fieldFocusScheduled")

        withAnimation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.6)) {
            MainActor.assumeIsolated { expansionState.progress = 1 }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            MainActor.assumeIsolated {
                ctx.duration = 0.2
                panel.animator().alphaValue = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .vertusFocusInput, object: nil)
        }
    }

    /// Retracts the bar back into the notch (shape shrinks upward), then
    /// takes the window off screen.
    func hidePanel() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        vertusTrace("hidePanel")

        withAnimation(.easeIn(duration: 0.32)) {
            MainActor.assumeIsolated { expansionState.progress = 0 }
        }
        NSAnimationContext.runAnimationGroup({ [weak self] ctx in
            MainActor.assumeIsolated {
                ctx.duration = 0.32
                self?.panel?.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return } // hide was reversed → keep shown
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1.0
                self.isHiding = false
            }
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
        vertusTrace("togglePanel (visible=\(panel.isVisible), hiding=\(isHiding))")
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
        vertusTrace("hotkey RegisterEventHotKey → \(status) (targetNil=\(target == nil), pid=\(getpid()))")
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
            vertusTrace("local monitor fired (isKey=\(NSApp.keyWindow != nil))")
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
                vertusTrace("carbon hotkey fired (active=\(NSApp.isActive))")
                // NB: a registered carbon hotkey is consumed by the system
                // BEFORE it ever reaches the app, so the local monitor never
                // fires for it — always toggle here, no isActive guard.
                AppDelegate.shared?.togglePanel()
            }
            return noErr
        }
        let target = GetApplicationEventTarget()
        let installErr = InstallEventHandler(target, handler, 1, &eventSpec, nil, nil)
        vertusTrace("hotkey InstallEventHandler → \(installErr) (targetNil=\(target == nil), pid=\(getpid()))")
    }

    // MARK: - Menubar icon

    private func installMenubarIcon() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = menubarIcon
            button.toolTip = "VERTUS (⇧⌘J)"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle VERTUS (⇧⌘J)", action: #selector(togglePanel), keyEquivalent: "j")
            .target = self
        menu.addItem(withTitle: "Open VERTUS Window", action: #selector(openMainWindow), keyEquivalent: "o")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit VERTUS", action: #selector(quitApp), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - ⌘Q while the panel is key

    /// The QuickBar panel is a .nonactivatingPanel (VertusApp.swift:77-78):
    /// using it never activates VERTUS, and key-equivalent dispatch (⌘Q)
    /// belongs to the ACTIVE app — so while another app is frontmost, the
    /// standard menu's "Quit VERTUS" (⌘Q) is unreachable and ⌘Q would quit
    /// the frontmost app instead. Key events to the key panel ARE delivered
    /// to this app (that is how typing into the bar works), so a local
    /// monitor can intercept ⌘Q exactly when the panel is key and terminate
    /// ourselves. When VERTUS is the active app the panel is never key with
    /// an external menu bar owning ⌘Q, so we pass the event through and the
    /// standard menu handles it — exactly one path fires in every state.
    private func installPanelQuitMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)
            let isQ = event.charactersIgnoringModifiers?.lowercased() == "q"
            guard hasCmd && !hasShift && isQ else { return event }
            guard let panel = self.panel, panel.isKeyWindow else { return event }
            vertusTrace("⌘Q intercepted while QuickBar panel is key — terminating")
            NSApp.terminate(nil)
            return nil
        }
    }

    // MARK: - ⌘W for manually-created windows

    /// SwiftUI's generated Window > Close (⌘W) command only acts on
    /// scene-managed windows; both our windows are created by the delegate
    /// (main + Memory), so the shortcut no-ops while the menu item's click
    /// works. Intercept ⌘W and performClose on the key window ourselves:
    /// the main window hides (windowShouldClose -> orderOut), the Memory
    /// window closes. The panel is not a closable window — ⌘W while the
    /// panel is key passes through (⇧⌘J is its close).
    private func installWindowCloseMonitor() {
        windowCloseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)
            let isW = event.charactersIgnoringModifiers?.lowercased() == "w"
            guard hasCmd && !hasShift && isW else { return event }
            guard let key = NSApp.keyWindow, key !== self.panel else { return event }
            vertusTrace("⌘W intercepted for key window \(key.title) — closing")
            key.performClose(nil)
            return nil
        }
    }

    // MARK: - Launch at login

    private func registerLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        // SMAppService.Status: notRegistered=0, enabled=1, requiresApproval=2,
        // notFound=3. Only .enabled means the login item actually exists;
        // .notFound (an app not in /Applications, or an ad-hoc-signed bundle
        // that never persisted) must retry registration, not skip it.
        if status == .enabled {
            vertusTrace("login item already enabled")
            return
        }
        vertusTrace("login item status \(status.rawValue) — registering")
        do {
            try SMAppService.mainApp.register()
            vertusTrace("login item registered via SMAppService")
        } catch {
            // Ad-hoc signed bundles can be refused by SMAppService on some
            // macOS builds (it fails silently with a domain error). Fall
            // back to a launchd plist that launches the BUNDLE binary (not a
            // raw swiftc product), so the notification entitlement context is
            // preserved — the whole reason Checkpoint 2 demands a bundle.
            vertusTrace("SMAppService.register failed: \(error) — falling back to launchd plist")
            installLegacyLoginPlist()
        }
    }

    private func installLegacyLoginPlist() {
        let binary = Bundle.main.executablePath ?? ""
        guard !binary.isEmpty else {
            vertusTrace("login item fallback: no executable path to install")
            return
        }
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.vertus.app.plist"
        let plist: [String: Any] = [
            "Label": "com.vertus.app",
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath))
            vertusTrace("login item fallback plist written: \(plistPath)")
        } catch {
            vertusTrace("login item fallback plist write failed: \(error)")
        }
    }

    // MARK: - Notifications (bundle-only, as before the merge)

    private func installNotifications() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                // Degrade silently: the in-app unread badge still works.
            }
        }
        let notifier = CompletionNotifier(store: store)
        self.notifier = notifier
        if CommandLine.arguments.contains("--smoke-probe") {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                print("SMOKE authorization=\(settings.authorizationStatus.rawValue)")
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                for n in delivered {
                    print("SMOKE delivered: \(n.request.content.title) | \(n.request.content.body.prefix(80))")
                }
                exit(0)
            }
        }
    }

    // MARK: - Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the main window must not quit the app: the menubar item
        // and ⇧⌘J stay. Quit from the menubar quits everything.
        false
    }

    // MARK: - Offscreen verification renders

    private func verifyPath() -> String {
        let args = CommandLine.arguments
        if let i = args.firstIndex(where: { $0.hasPrefix("--verify") }), i + 1 < args.count {
            return args[i + 1]
        }
        return "/tmp/vertusbar_render.png"
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
}

// MARK: - Window delegate: closing the main window hides it (object stays)

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let vertusFocusInput = Notification.Name("vertusFocusInput")
    static let vertusAppendPrompt = Notification.Name("vertusAppendPrompt")
}