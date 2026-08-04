import AppKit
import Combine
import SwiftUI

// Alfred is a client for Hermes Agent, not an assistant.
//
// It contributes exactly two things Hermes has no equivalent for:
//
//   1. A Spotlight-style bar at the notch (⌘⇧J), replacing Hermes' terminal TUI
//      and its localhost web dashboard.
//   2. Access to macOS — screen reading, the accessibility tree, and mouse and
//      keyboard control — handed to Hermes as MCP tools (AlfredToolServer).
//
// Everything else an assistant needs lives in Hermes, unmodified: the tool loop,
// the models, memory, persona (SOUL.md / USER.md), skills, cron and messaging.
// Alfred used to carry its own versions of all of that; they were deleted rather
// than left to rot beside the real ones.

// MARK: - Bar state

/// The bar's observable state. Deliberately small — Alfred holds no conversation
/// state of its own; Hermes owns the session.
@MainActor
final class BarState: ObservableObject {
    @Published var responseText: String = ""
    @Published var isProcessing: Bool = false
    @Published var presenceState: AssistantPresenceState = .hidden
    /// Bumped each time the bar is presented so the input field re-grabs focus
    /// (so you can type immediately on ⌘⇧J without clicking the field).
    @Published var focusToken: Int = 0
    /// Set while Hermes is waiting for the user to approve computer control.
    @Published var pendingConfirmation: PendingControlConfirmation?
}

// MARK: - Bridge view

/// PresenceRootView takes @Binding; this resolves them from the EnvironmentObject
/// so AppKit's NSHostingView doesn't have to manufacture bindings directly.
private struct BarContainer: View {
    @EnvironmentObject private var barState: BarState
    let onSubmit: (String) -> Void
    let onCollapse: () -> Void

    var body: some View {
        PresenceRootView(
            presenceState: Binding(
                get: { barState.presenceState },
                set: { barState.presenceState = $0 }
            ),
            barState: barState,
            onSubmit: onSubmit,
            onCollapse: onCollapse
        )
    }
}

// MARK: - App entry

@main
struct AlfredApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows: Alfred is menu-bar resident and the bar is an NSPanel the
        // delegate owns. Settings is required for a valid Scene graph.
        Settings { EmptyView() }
    }
}

// MARK: - Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Direct handle to the running delegate. With `@NSApplicationDelegateAdaptor`
    /// SwiftUI installs its own object as `NSApp.delegate` and forwards lifecycle
    /// calls here, so `NSApp.delegate as? AppDelegate` is nil. Anything outside the
    /// SwiftUI graph (the MCP tool server, the confirmation broker) reaches the
    /// delegate through this.
    static weak var shared: AppDelegate?

    let barState = BarState()

    /// The agent. One long-lived `hermes acp` subprocess; see HermesSession.
    let hermes = HermesSession()

    private var barWindow: BarWindow?
    private var hotkeyListener: HotkeyListener?
    private var statusItem: NSStatusItem?
    private var escapeMonitor: Any?
    /// The turn currently streaming, so a new query supersedes it.
    private var hermesTask: Task<Void, Never>?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Menu-bar resident: no Dock icon, no window in the app switcher.
        NSApp.setActivationPolicy(.accessory)

        setupBarWindow()
        setupStatusItem()
        startHotkeyListener()
        installEscapeMonitor()

        // Hand Hermes the Mac. Started early because the shim it spawns retries
        // its connection for only a few seconds.
        AlfredToolServer.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        AlfredToolServer.shared.stop()
        Task { await hermes.shutdown() }
    }

    // MARK: Bar window

    private func setupBarWindow() {
        let window = BarWindow()
        let rootView = BarContainer(
            onSubmit: { [weak self] text in self?.handleQuery(text) },
            onCollapse: { [weak self] in self?.handleCollapse() }
        )
        .environmentObject(barState)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        // Vibrant notch look.
        let effectView = NSVisualEffectView(frame: hostingView.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])

        window.contentView = effectView
        barWindow = window

        // Resize as content changes. Confirmations are included because their
        // buttons render off the bottom of the panel otherwise, leaving the user
        // unable to answer a prompt that is blocking an agent turn.
        barState.$responseText
            .combineLatest(barState.$isProcessing, barState.$pendingConfirmation)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.resizeBar() }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func resizeBar() {
        guard let window = barWindow else { return }
        switch barState.presenceState {
        case .hidden, .collapsed, .listening:
            break
        case .expanded, .thinking, .responding:
            window.resizeNotch(toHeight: barHeight())
        }
    }

    private func barHeight() -> CGFloat {
        var total = ExpandedPresenceView.inputRowHeight + 4  // 4pt VStack top padding

        if barState.pendingConfirmation != nil {
            total += 1  // divider
            total += ExpandedPresenceView.confirmationScrollHeight
            total += ExpandedPresenceView.confirmationChromeHeight
        } else if barState.isProcessing || !barState.responseText.isEmpty {
            total += 1  // divider
            total += barState.responseText.isEmpty
                ? ExpandedPresenceView.loadingRowHeight
                : ExpandedPresenceView.responseHeight(for: barState.responseText)
        }
        return total
    }

    // MARK: Presenting

    private func showBar() {
        NSApp.activate(ignoringOtherApps: true)
        barWindow?.orderFrontRegardless()
        barState.presenceState = .expanded
        barWindow?.expand(toHeight: barHeight())
        barState.focusToken += 1
    }

    private func hideBar() {
        barState.presenceState = .hidden
        barWindow?.orderOut(nil)
    }

    private func toggleBar() {
        switch barState.presenceState {
        case .hidden, .collapsed:
            showBar()
        case .expanded, .thinking, .responding, .listening:
            hideBar()
        }
    }

    @objc private func showBarFromMenu() { showBar() }

    /// Esc, or a click outside the bar.
    private func handleCollapse() {
        // Esc while a control confirmation is up means "no". Collapsing without
        // answering would leave the agent suspended until it timed out, and would
        // make dismissal look like consent.
        if barState.pendingConfirmation != nil {
            ControlConfirmationBroker.shared.resolve(false, source: "escape-key")
            barState.responseText = "Cancelled."
            barState.presenceState = .expanded
            return
        }

        // Interrupt a running turn, so dismissing the bar also stops the agent
        // rather than leaving it working unseen.
        if barState.isProcessing {
            hermesTask?.cancel()
            Task { await hermes.cancel() }
            barState.isProcessing = false
        }
        hideBar()
    }

    // MARK: Hotkey

    private func startHotkeyListener() {
        guard hotkeyListener == nil else { return }
        let listener = HotkeyListener { [weak self] in self?.toggleBar() }
        hotkeyListener = listener
        listener.start()
    }

    /// Global Esc, so computer control can be stopped while another app is focused.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }   // Esc
            Task { @MainActor in
                guard let self else { return }
                if self.barState.pendingConfirmation != nil {
                    ControlConfirmationBroker.shared.resolve(false, source: "global-escape")
                }
            }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Alfred")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Alfred  ⌘⇧J",
                                action: #selector(showBarFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Computer Control",
                                action: #selector(toggleComputerControl), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Alfred",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action == #selector(showBarFromMenu)
            || menuItem.action == #selector(toggleComputerControl) {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        refreshComputerControlItem()
    }

    /// The gate that decides whether Hermes may click and type on this Mac. Ships
    /// off; see AlfredToolServer.runComputerControl.
    @objc private func toggleComputerControl() {
        let enabled = !UserDefaults.standard.bool(forKey: "computerControlEnabled")
        UserDefaults.standard.set(enabled, forKey: "computerControlEnabled")
        refreshComputerControlItem()
    }

    private func refreshComputerControlItem() {
        guard let menu = statusItem?.menu else { return }
        let enabled = UserDefaults.standard.bool(forKey: "computerControlEnabled")
        menu.items
            .first { $0.action == #selector(toggleComputerControl) }?
            .state = enabled ? .on : .off
    }

    // MARK: Querying

    /// Stream one Hermes turn into the bar.
    ///
    /// Alfred does no routing, no intent detection and no tool selection — Hermes
    /// decides what a request means. Adding a capability means exposing a tool in
    /// AlfredToolServer, not extending a branch here.
    func handleQuery(_ text: String) {
        barState.responseText = ""
        barState.isProcessing = true
        barState.presenceState = .thinking

        hermesTask?.cancel()
        hermesTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var streamed = ""            // assistant text only, excludes tool placeholders
            var showingToolStatus = false
            var failure: String?

            for await event in await self.hermes.prompt(text) {
                switch event {
                case .text(let chunk):
                    if self.barState.presenceState == .thinking {
                        self.barState.presenceState = .responding
                    }
                    // First real token clears any tool placeholder still on screen.
                    if showingToolStatus {
                        self.barState.responseText = ""
                        showingToolStatus = false
                    }
                    streamed += chunk
                    self.barState.responseText += chunk

                case .thought:
                    break  // reasoning stays hidden

                case .toolStarted(_, let title, _):
                    // Only while there is no answer yet — a tool firing mid-sentence
                    // must not clobber text the user is already reading.
                    if streamed.isEmpty {
                        showingToolStatus = true
                        self.barState.responseText = "\(title)…"
                    }

                case .toolProgress, .usage, .finished:
                    break

                case .failed(let message):
                    failure = message
                }
            }

            if let failure {
                self.barState.responseText = failure
            } else if self.barState.responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A model can return an empty completion; never leave the bar dead.
                self.barState.responseText = "I don't have an answer for that."
            }

            self.barState.isProcessing = false
            self.barState.presenceState = .expanded
        }
    }

    // MARK: Computer-control confirmation

    /// Bring the bar up carrying a confirmation. Presented here rather than as a
    /// system modal — see ControlConfirmationBroker for why.
    func presentControlConfirmation(_ request: PendingControlConfirmation) {
        barState.pendingConfirmation = request
        // Cancel streaming state so the confirmation isn't competing with a spinner.
        barState.isProcessing = false
        showBar()
    }

    func dismissControlConfirmation() {
        barState.pendingConfirmation = nil
    }
}
