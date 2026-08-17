import AppKit
import Combine
import SwiftUI
import UserNotifications
import AlfredCore
import AlfredMacApp

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
    /// Set when the user opened an email alert from the notification centre.
    /// While present, the next bar submission is treated as the reply to that
    /// email: rewritten in the user's style and sent, rather than a new query.
    @Published var pendingEmailReply: PendingEmailReply?
}

/// The email a mail-alert notification was about. When the user submits the bar
/// with this set, the submitted text is the *reply draft*, and Alfred sends it.
struct PendingEmailReply {
    /// himalaya message id — so the reply flow can re-read the message and send
    /// with the right In-Reply-To header.
    let messageID: String
    /// Display name of the sender, for the bar's "reply to" prompt.
    let senderName: String
    /// Subject of the original, for the prompt.
    let subject: String
}

// MARK: - Bridge view

/// PresenceRootView takes @Binding; this resolves them from the EnvironmentObject
/// so AppKit's NSHostingView doesn't have to manufacture bindings directly.
private struct BarContainer: View {
    @EnvironmentObject private var barState: BarState
    let onSubmit: (String, FileAttachment?) -> Void
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

    @State private var settings = AppSettings()
    @State private var chat = ChatStore()

    var body: some Scene {
        // One Alfred: the windowed surface (side panel, tabs) hosts the
        // macOSRootView from the AlfredMacApp library, and the delegate keeps
        // the menu-bar icon + ⌘⇧J notch bar. Settings is required for a valid
        // Scene graph.
        WindowGroup("Alfred") {
            macOSRootView()
                .environment(settings)
                .environment(chat)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 980, height: 720)
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
    /// The provider key ring (see ProviderKeyRing.swift).
    let providerKeys = ProviderKeyRing.shared

    /// The agent. One long-lived `hermes acp` subprocess; see HermesSession.
    let hermes = HermesSession()

    /// The coding agent: the forked opencode in ACP mode (see HermesSession).
    /// Spawned lazily on the first code-routed query; credentials, posture
    /// config and journal destination are injected fresh on every spawn, so a
    /// provider-ring rotation is picked up on the next process start.
    let codingAgent = HermesSession(engine: .opencode)

    /// The self-improving RLM coding agent (prime-agent, a pi fork) in ACP
    /// mode. Spawned lazily on the first prime-routed query; its provider and
    /// model are pinned from the ring on every spawn (see HermesSession).
    let primeAgent = HermesSession(engine: .primeAgent)

    private var barWindow: BarWindow?
    private var hotkeyListener: HotkeyListener?
    private var statusItem: NSStatusItem?
    /// The popover hanging off the menu-bar icon, and its state.
    private var settingsPopover: NSPopover?
    private var settingsPopoverClosedAt: Date?
    private var escapeMonitor: Any?
    /// The turn currently streaming, so a new query supersedes it.
    private var hermesTask: Task<Void, Never>?
    /// Respawns the agent session if it died while idle, so "Alfred is always
    /// on" stays true between queries. See startHermesKeepAlive().
    private var hermesKeepAlive: Timer?
    /// Answers messages from the iOS app. Nil until configured.
    private var relay: RelayWorker?
    /// Watches the inbox for important mail and posts notifications.
    private let mailWatcher = MailWatcher.shared

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[boot] applicationDidFinishLaunching begin / pid \(ProcessInfo.processInfo.processIdentifier)")
        Self.shared = self

        // A foreground app: window + Dock icon + menu bar. The window hosts
        // the windowed surface (macOSRootView); the menu bar keeps the status
        // item and the ⌘⇧J notch bar.
        NSApp.setActivationPolicy(.regular)

        setupBarWindow()
        setupStatusItem()
        startHotkeyListener()
        installEscapeMonitor()

        // Hand Hermes the Mac. Started early because the shim it spawns retries
        // its connection for only a few seconds.
        AlfredToolServer.shared.start()

        // Token compression (Headroom): register its MCP server so every Hermes
        // session can shrink large tool outputs before they eat context window
        // space, and keep the local client warm for Alfred's own prompts (mail
        // copilot bodies, briefing context). No-op when the binary isn't
        // installed; the app works identically either way.
        HeadroomMCPClient.shared.ensureRegisteredIfEnabled()

        // Browser automation (browser-use): probe the venv binary once at
        // launch so the Settings status line and the routine/email skill gates
        // know the truth. The MCP server for Hermes is already registered in
        // agent-servers.json (agent-bridge/setup.sh provisions it); nothing to
        // start here — browser tasks need Chrome running and the harness daemon
        // auto-starts on first use.
        BrowserUseClient.shared.refreshBinary()

        // Web scraping (Crawlee): probe the bridge's node + CLI once at launch
        // so the Settings status line and the routine scrape step know the
        // truth. The MCP server for Hermes is already registered in
        // agent-servers.json (agent-bridge/setup.sh provisions it); nothing to
        // start here — HTTP scraping is plain requests with no browser.
        CrawleeClient.shared.refreshBinary()

        // Career-ops: the job-hunt command center. Hermes writes the rubric
        // judgments and tailored CVs; the tracker pushes changes to phones
        // over the same socket the briefing and routines use (nothing to
        // "start" — scans and follow-ups are on-demand or routine-driven).
        CareerOpsManager.shared.hermes = hermes
        CareerOpsManager.shared.onApplicationsChanged = {
            BriefingSocketServer.shared.broadcastCareer(
                "career.applications_changed",
                params: BriefingSocketServer.summaryWire(CareerOpsManager.shared.summary()))
        }

        // NYU coursework: Canvas sync → SQLite store → briefing lines, deadline
        // reminders and calendar events. The sync timer and the hourly
        // reminder re-schedule live here; every completed sync pushes
        // `nyu.sync_complete` to phones so the Courses tab refreshes on its own.
        NYUIntegrationManager.shared.onSyncCompleted = { result in
            BriefingSocketServer.shared.broadcastNYU(
                "nyu.sync_complete",
                params: NYUIntegrationManager.syncResultWire(result))
        }
        NYUIntegrationManager.shared.start()

        // Personal memory: index the Obsidian vault, and distill the day's
        // material into vault concepts on a quiet schedule. Best-effort and
        // never throw.
        MemoryStore.shared.refresh()
        PersonalMemoryStore.shared.refresh()
        MemoryReflectionService.shared.start()


        // Persistent screen memory: capture + OCR + store every 45s, pruned
        // to 7 days. Requires Screen Recording permission; ticks fail
        // gracefully (and quietly) until it's granted.
        ScreenMonitoringManager.shared.start()

        // Fine-tuning loop: hourly check for enough accepted exchanges to
        // warrant retraining the local model. Runs off the main thread;
        // heavy work happens in a detached Task.
        FineTuneManager.shared.start()

        // Self-optimization loop (DSPy): collects 1–5 ratings of Alfred's
        // outputs and compiles them into learned prompt rules weekly. Local
        // only — nothing leaves the Mac. The scheduler tick checks
        // `isCompileDue`, so starting it here is cheap and idle otherwise.
        DSPyOptimizer.shared.start()

        // Unified memory: one-time harvest of the fragmented legacy systems
        // (GRDB-era tables, personal-memory.json, finetuning captures, the
        // agentmemory graph) into the single SQLite layer, plus the vault
        // mirror refresh. Idempotent and best-effort.
        Task.detached { await MigrationManager.shared.runIfNeeded() }

        // Notifications: the mail watcher delivers them, and taps here decide to
        // open the bar. The delegate must be installed before the watcher schedules.
        // Alerts are always on — there is no toggle to turn the watcher off.
        UNUserNotificationCenter.current().delegate = self
        mailWatcher.hermes = hermes
        mailWatcher.start()

        // Mail copilot: the same session powers classification, summaries,
        // task extraction, draft replies and natural-language search for the
        // phone's mail tab. Runs behind MailWatcher's own turns, never across
        // a conversation (MailAIService checks isTurnActive first).
        MailAIService.shared.hermes = hermes

        AgentCompletionWatcher.shared.start()

        // MemPalace: the persistent memory layer. Hermes drives preference
        // inference (through the reflection pass and on-demand turns); the
        // 6h timer runs the decay + prune consolidation.
        MemPalaceManager.shared.hermes = hermes
        MemPalaceManager.shared.start()

        // Daily briefing: generate on the hour, serve it to phones over the
        // socket, and push each fresh copy out the moment it lands.
        BriefingGenerator.shared.hermes = hermes
        BriefingGenerator.shared.onGenerated = { content in
            BriefingSocketServer.shared.broadcast(content)
        }
        BriefingSocketServer.shared.start()
        BriefingGenerator.shared.start()

        // Routines: scheduled workflows runnable from the phone. The manager
        // fires on schedule and pushes started/progress/completed events over
        // the same socket the briefing uses.
        RoutineManager.shared.hermes = hermes
        RoutineManager.shared.onRoutineStarted = { routine in
            BriefingSocketServer.shared.broadcastRoutine(
                "routine.started", params: BriefingSocketServer.routineStartedParams(routine))
        }
        RoutineManager.shared.onRoutineProgress = { routine, step, total, label in
            BriefingSocketServer.shared.broadcastRoutine(
                "routine.progress",
                params: BriefingSocketServer.routineProgressParams(routine, step: step, total: total, label: label))
        }
        RoutineManager.shared.onRoutineCompleted = { routine, result in
            BriefingSocketServer.shared.broadcastRoutine(
                "routine.completed",
                params: BriefingSocketServer.routineCompletedParams(routine, result: result))
        }
        RoutineManager.shared.onRoutinesChanged = {
            BriefingSocketServer.shared.broadcastRoutinesChanged()
        }
        RoutineManager.shared.start()

        // Taste (anti-slop text): the same session rewrites generic drafts,
        // routine names and summaries with specificity and the owner's voice.
        // The deterministic boringness gate keeps model turns rare.
        TasteSkillManager.shared.hermes = hermes

        // Personal Tutor: the same session explains concepts the way this
        // user learns, guides homework Socratically, and learns teaching
        // methods that work from feedback. Bounded turns behind a turn gate,
        // like taste — it can never hijack the conversation.
        PersonalTutorSkill.shared.hermes = hermes

        // Study Routines: exam prep, problem sets, readings, lecture notes and
        // the weekly review — scheduled via the routine library and adapting
        // to the tutor's live mastery + learning style. The notification
        // ticker nags on due readings and the Sunday review.
        StudyRoutineManager.shared.hermes = hermes
        StudyRoutineManager.shared.start()

        // Essay writing: full essays in the owner's voice with citations. The
        // skill runs its turns on its own dedicated Hermes session (spawned
        // lazily on first use), so the write_essay MCP tool can produce an
        // essay while the user's main session is mid-turn.

        // Remote coding sessions (AlfredCode): the manager streams agent
        // output to phones over the same socket the briefing and routines use.
        AlfredCodeManager.shared.onCodeChunk = { sessionID, text in
            BriefingSocketServer.shared.broadcastCode(
                "code.chunk", params: ["session_id": sessionID.uuidString, "text": text])
        }
        AlfredCodeManager.shared.onSessionStatus = { sessionID, status in
            BriefingSocketServer.shared.broadcastCode(
                "code.status", params: ["session_id": sessionID.uuidString, "status": status.rawValue])
        }
        AlfredCodeManager.shared.onTestResult = { sessionID, result in
            var params = BriefingSocketServer.testResultDictionary(result)
            params["session_id"] = sessionID.uuidString
            BriefingSocketServer.shared.broadcastCode("code.test_result", params: params)
        }
        // CodeGraph indexing progress → the Code tab's "Analyzing project…"
        // spinner, pushed as code.graph_status notifications.
        CodeGraphManager.shared.onStateChange = { projectPath, state in
            var payload: [String: Any] = ["project_path": projectPath]
            let wire = BriefingSocketServer.graphStateWireForBroadcast(state)
            for (key, value) in wire { payload[key] = value }
            BriefingSocketServer.shared.broadcastCode("code.graph_status", params: payload)
        }
        // Understand-Anything: same idea for the interactive knowledge graph —
        // when a background analysis finishes (or fails) the Code tab's
        // Knowledge Graph sheet recovers through code.understand_status.
        UnderstandAnythingManager.shared.onStateChange = { projectPath, state in
            var payload: [String: Any] = ["project_path": projectPath]
            let wire = BriefingSocketServer.understandStateWireForBroadcast(state)
            for (key, value) in wire { payload[key] = value }
            BriefingSocketServer.shared.broadcastCode("code.understand_status", params: payload)
        }

        AlfredCodeManager.shared.onGitStatus = { sessionID, status in
            var params = BriefingSocketServer.gitStatusDictionary(status)
            params["session_id"] = sessionID.uuidString
            BriefingSocketServer.shared.broadcastCode("code.git_status", params: params)
        }

        // Unified mail (MailManager): the Mac is the mail hub for the phone. It
        // syncs every Himalaya account (iCloud today) into a local SQLite cache
        // on a 5-minute timer and pushes sync-complete / unread-count events
        // over the same socket the briefing and routines use.
        MailManager.shared.onSyncCompleted = { result in
            BriefingSocketServer.shared.broadcastMail(
                "mail.sync_complete", params: BriefingSocketServer.mailSyncCompleteParams(result))
        }
        MailManager.shared.onUnreadCountChanged = { unread in
            BriefingSocketServer.shared.broadcastMail(
                "mail.unread_count_changed", params: BriefingSocketServer.mailUnreadParams(unread))
        }
        MailManager.shared.start()

        // Folder sweep (MailScanService): the configurable timer that checks
        // every folder — Inbox, Junk, Archive, Sent, custom — for mail that
        // matters, classifies it, and pushes the scan summary to phones
        // (`mail.scan_complete`). Notifications for "important email in Junk"
        // are the sweep's own (MailWatcher keeps new-inbox triage).
        MailScanService.shared.onScanCompleted = { summary in
            BriefingSocketServer.shared.broadcastMail(
                "mail.scan_complete",
                params: BriefingSocketServer.mailScanSummaryWire(summary))
        }
        MailScanService.shared.start()

        startRelayIfConfigured()

        // Always use cloud mode (NOUS portal models). Mirror the stored
        // provider keys into hermes' fallback chain so a quota-limited
        // primary provider auto-falls through to a free tier.
        if !providerKeys.keys.isEmpty {
            Task.detached { ProviderKeyRing.shared.syncHermesFallbackChain() }
        }

        // Keep the agent alive. A prompt respawns a dead session lazily, but an
        // idle death (hermes can exit cleanly under upstream faults — the
        // "Hermes stopped unexpectedly (exit 0)" symptom) should heal before
        // anyone asks. The watch keys on hasAttemptedStart rather than
        // hasStartedOnce so a first spawn that stalled on the ACP handshake
        // (an MCP bridge fetching over the network) also gets retried — that
        // stalled first attempt is exactly the session that needs healing most.
        startHermesKeepAlive()
    }

    /// Every 60s, if start() was ever attempted but no process is running,
    /// respawn it. Harmless while a turn is active (start() is idempotent and
    /// no-ops on a live process); the actual mid-turn death recovery lives in
    /// HermesSession.runTurn, which rebuilds and retries the prompt itself.
    private func startHermesKeepAlive() {
        guard hermesKeepAlive == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let session = self.hermes
                guard await session.hasAttemptedStart, !(await session.isProcessRunning()) else { return }
                NSLog("[hermes] keepalive: session process gone while idle — respawning")
                try? await session.start()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hermesKeepAlive = timer
        NSLog("[hermes] keepalive watch armed (60s)")
    }

    /// Answer messages from the iOS app, if a relay is configured.
    ///
    /// Off unless both values are set — an unconfigured install should not be
    /// making network calls, and there is nothing sensible to poll.
    private func startRelayIfConfigured() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "relayEndpoint"), let url = URL(string: raw),
              let token = defaults.string(forKey: "relayToken"), !token.isEmpty
        else {
            NSLog("[relay] not configured — set relayEndpoint and relayToken to answer from the phone")
            return
        }
        let worker = RelayWorker(endpoint: url, token: token, hermes: hermes)
        relay = worker
        Task { await worker.start() }
        NSLog("[relay] answering iOS app requests via %@", url.absoluteString)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        hermesKeepAlive?.invalidate()
        hermesKeepAlive = nil
        AgentCompletionWatcher.shared.stop()
        AlfredToolServer.shared.stop()
        if let relay { Task { await relay.stop() } }
        ScreenMonitoringManager.shared.stop()
        MemoryReflectionService.shared.stop()
        MemPalaceManager.shared.stop()
        HomeworkAssistantSkill.shared.stop()
        FineTuneManager.shared.stop()
        DSPyOptimizer.shared.stop()
        BriefingGenerator.shared.stop()
        RoutineManager.shared.stop()
        MailManager.shared.stop()
        // Tear down any live coding agents so a paused session isn't left
        // SIGSTOPped holding a process after the app quits.
        for session in AlfredCodeManager.shared.listSessions() {
            Task { await AlfredCodeManager.shared.stopSession(id: session.sessionId) }
        }
        BriefingSocketServer.shared.stop()
        Task { await hermes.shutdown() }
        // Tear down the multi-agent team's sessions too, so no specialized
        // Hermes process is left running after the app quits.
        Task { await MultiAgentOrchestrator.shared.shutdownAll() }
        // And the essay skill's dedicated agent, spawned on first write_essay.
        Task { await EssayWritingSkill.shared.shutdown() }
        // And the presentation skill's dedicated agent, spawned on first deck.
        Task { await PresentationGeneratorSkill.shared.shutdown() }
    }

    // MARK: Bar window

    private func setupBarWindow() {
        let window = BarWindow()
        let rootView = BarContainer(
            onSubmit: { [weak self] text, image in self?.handleQuery(text, image) },
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
        NSLog("[hotkey] toggleBar fired, current state \(barState.presenceState)")
        switch barState.presenceState {
        case .hidden, .collapsed:
            showBar()
        case .expanded, .thinking, .responding, .listening:
            hideBar()
        }
    }

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
        // rather than leaving it working unseen. A multi-agent run is stopped
        // the same way — cancelling the pipeline cancels the in-flight agents.
        if barState.isProcessing {
            hermesTask?.cancel()
            Task { await hermes.cancel() }
            MultiAgentOrchestrator.shared.cancelActiveRun()
            barState.isProcessing = false
        }
        hideBar()
    }

    // MARK: Hotkey

    private func startHotkeyListener() {
        NSLog("[hotkey] startHotkeyListener called")
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

    /// Clicking the menu-bar icon opens a small popover with two actions:
    /// relaunch and quit. Settings deliberately live nowhere in the menu bar —
    /// every capability is on by design and stays on.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "alfred-menubar", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        } else {
            item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Alfred")
        }
        item.button?.target = self
        item.button?.action = #selector(toggleSettingsPopover)
        statusItem = item
    }

    private func makeSettingsPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient   // click away to dismiss
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: popoverRootView())
        return popover
    }

    /// The popover's SwiftUI root. Rebuilt on every open (see
    /// toggleSettingsPopover) so @State re-seeds from persisted values — a
    /// transient popover keeps its hosting controller, and with it stale
    /// state, between shows otherwise.
    private func popoverRootView() -> SettingsPopoverView {
        SettingsPopoverView(
            onRelaunch: { [weak self] in self?.relaunchApp() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// Relaunch: quit this instance immediately, and let a detached shell
    /// (which survives our termination) reopen the same bundle a beat later —
    /// so the new instance never races the still-running one for the MCP
    /// socket or the agent session.
    private func relaunchApp() {
        settingsPopover?.performClose(nil)
        let bundlePath = Bundle.main.bundlePath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 2; open \"\(bundlePath)\" >/dev/null 2>&1"]
        try? proc.run()   // detached: persists after NSApp.terminate
        NSApp.terminate(nil)
    }

    @objc private func toggleSettingsPopover() {
        guard let button = statusItem?.button else { return }
        let popover = settingsPopover ?? makeSettingsPopover()
        settingsPopover = popover

        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Rebuild the root view so @State re-seeds from persisted values
        // (a transient popover keeps its hosting controller between shows,
        // taking stale @State with it).
        popover.contentViewController = NSHostingController(rootView: popoverRootView())
        // A transient popover is dismissed by the mouse-down on the status item
        // *before* this action runs, so without this the click that closed it
        // would immediately reopen it and the popover would look stuck open.
        if let closedAt = settingsPopoverClosedAt, Date().timeIntervalSince(closedAt) < 0.25 {
            return
        }
        NSApp.activate(ignoringOtherApps: true)   // so the text field can take keys
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: Querying

    /// Quota death — rotate the provider key ring and respawn the agent so the
    /// next try runs on a fresh key. Returns what the bar should show.
    private static func rotatedIfQuota(_ failure: String) -> String {
        let lower = failure.lowercased()
        let quotaMarkers = ["429", "rate limit", "quota", "usage limit", "billing",
                            "402", "no usage left", "insufficient_funds"]
        guard quotaMarkers.contains(where: { lower.contains($0) }),
              let delegate = AppDelegate.shared,
              delegate.providerKeys.keys.count > 1,
              let newKey = delegate.providerKeys.advance()
        else { return failure }

        let hermes = delegate.hermes
        Task { @MainActor in
            // Rotation swapped the active key: put hermes' *primary* provider
            // back in sync with it, then respawn so the next turn starts clean.
            Task.detached { ProviderKeyRing.shared.syncHermesFallbackChain() }
            await hermes.restart()
            NSLog("[keys] rotated to \(newKey.label) — agent respawning")
        }
        return "\(failure)\n\n\(newKey.label) hit its free-tier quota — Alfred rotated to the next key. Ask again."
    }

    /// Stream one Hermes turn into the bar.
    ///
    /// Alfred does no routing, no intent detection and no tool selection — Hermes
    /// decides what a request means. Adding a capability means exposing a tool in
    /// AlfredToolServer, not extending a branch here.
    // MARK: Querying

    /// A long-lived session means the agent's MCP channels can go stale (hermes
    /// quirk: first tool call after a spawn sometimes lands on a dead socket).
    /// If the failure is a transport error and this is the first attempt at
    /// this turn, respawn the agent and run the query again once.
    private func isMCPTransportFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("mcp call failed")
            || lower.contains("closedresource")
            || lower.contains("channel")
            || lower.contains("tool call failed")
    }

    /// One transport retry per app lifetime: if the agent's MCP channels
    /// collapse, first failure respawns the agent and replays the query once.
    private var retryMCPTurn = false

private func enforceRetry(_ text: String, _ attachment: FileAttachment?, agent: HermesSession) async {
        guard !retryMCPTurn else { return }
        retryMCPTurn = true
        NSLog("[hermes] MCP transport failed — respawning agent and retrying once")
        await agent.restart()
        // Clear-ish state in the bar so a bombed turn doesn't linger.
        await MainActor.run {
            barState.responseText = "(Alfred hit a channel reset — retrying…)"
            barState.presenceState = .thinking
        }
        // Re-run exactly the user's turn.
        await self.handleQueryAsync(text: text, attachment: attachment, agent: agent)
    }

    /// The direct:turn implementation used by the query entry and the retry
    /// path. `handleQuery` is the UI entry (it owns barState bookkeeping).
    private func handleQueryAsync(text: String, attachment: FileAttachment?, agent: HermesSession) async {
        var failure: String?
        // The turn consumes quota on whichever provider is active right now.
        if let provider = providerKeys.activeKey?.provider {
            UsageTracker.shared.record(provider: provider)
        }

        // The bar talks to the local Hermes server (AlfredMac/Server/server.py,
        // OpenAI-compatible /v1/chat/completions) directly over SSE through
        // HermesSession's ToolCallingProvider conformance — no hermes acp
        // subprocess, no Ollama config indirection. A per-turn session is cheap:
        // streamWithTools never touches the ACP process machinery. The tool set
        // is AlfredCore's: FileReadTool reads vault-contained files.
        let session = HermesSession(baseURL: ProcessInfo.processInfo.environment["ALFRED_HERMES_URL"] ?? "http://localhost:8080")
        let tools: [any LLMTool] = [FileReadTool()]
        do {
            _ = try await session.streamWithTools(
                prompt: text,
                tools: tools,
                onEvent: { event in
                    switch event {
                    case .contentDelta(let piece):
                        // Append to the bar's response area (ExpandedPresenceView,
                        // capped at ~5 lines then scrolls) on the main actor.
                        DispatchQueue.main.async {
                            if self.barState.presenceState == .thinking { self.barState.presenceState = .responding }
                            self.barState.responseText += piece
                        }
                    case .toolCallDelta(let call):
                        DispatchQueue.main.async {
                            self.barState.responseText += "\n[Tool: \(call.function.name)]\n"
                        }
                    case .done:
                        break
                    }
                }
            )
        } catch {
            failure = error.localizedDescription
            AlfredLog.provider.error("[provider] \(error.localizedDescription, privacy: .public)")
            // A hard quota/rate-limit answer caps that key at 0% on the
            // meter until the vendor window resets.
            let lower = (failure ?? "").lowercased()
            let markers = ["429", "rate limit", "quota", "usage limit",
                           "billing", "402", "no usage left", "insufficient_funds"]
            if markers.contains(where: { lower.contains($0) }) {
                UsageTracker.shared.recordQuotaHit(message: failure ?? "")
            }
        }

        if let failure {
            if isMCPTransportFailure(failure), !retryMCPTurn {
                await enforceRetry(text, attachment, agent: agent)
                return
            }
            barState.responseText = Self.rotatedIfQuota(failure)
        } else if barState.responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A model can return an empty completion; never leave the bar dead.
            barState.responseText = "I don't have an answer for that."
        }

        barState.isProcessing = false
        barState.presenceState = .expanded
    }

    /// Which agent answers a query. Code-heavy asks go to the coding agent
    /// (the forked opencode); self-improving/autonomous agent tasks go to
    /// prime-agent; everything else stays with Hermes.
    ///
    /// Explicit escape hatches: a prompt starting with `code:` (or `/code `)
    /// always routes to the coding agent, `prime:` (or `/prime `) routes to the
    /// self-improving agent, `hermes:` forces the general agent. Otherwise a
    /// conservative keyword match — a wrong guess is an inconvenience, not a
    /// loss, since all three agents can answer all kinds of questions.
    /// Pure (no state touched), so it is callable from anywhere — including tests.
    nonisolated static func engine(for text: String) -> AgentEngine {
        let lower = text.lowercased()
        if lower.hasPrefix("hermes:") || lower.hasPrefix("/hermes ") { return .hermes }
        if lower.hasPrefix("code:") || lower.hasPrefix("/code ") { return .opencode }
        if lower.hasPrefix("prime:") || lower.hasPrefix("/prime ") { return .primeAgent }
        // Prime markers: asks that explicitly invoke the self-improving RLM
        // loop. Deliberately narrow — most coding work stays with opencode.
        // "self-improv" (prefix) catches the natural phrasings — self-improve,
        // self-improving, self-improvement — while "self improve" catches the
        // unhyphenated space form.
        let primeMarkers = ["self-improv", "self improve", "rlm agent", "refine your skills"]
        if primeMarkers.contains(where: { lower.contains($0) }) { return .primeAgent }
        let codeMarkers = [
            "refactor", "unit test", "test suite", "test fails", "stack trace",
            "crash log", "compile error", "build error", "syntax error", "typeerror",
            "merge conflict", "pull request", "git push", "git commit", "git diff",
            "git status", "code review", "dependency", "package.json", "cargo.toml",
            "pyproject.toml", "requirements.txt", "swift build", "npm install",
            "pip install", "codebase", "fix the failing", "reproduce the bug",
            "func ", "def ", "```",
        ]
        return codeMarkers.contains(where: { lower.contains($0) }) ? .opencode : .hermes
    }

    func handleQuery(_ text: String, _ attachment: FileAttachment? = nil) {
        // Mail-alert mode: the submitted text is a reply draft, not a query.
        // Alfred rewrites it in the user's style and sends it through the
        // normal email_send tool (which still asks before anything goes out).
        if let pending = barState.pendingEmailReply {
            barState.pendingEmailReply = nil
            runReply(draft: text, pending: pending)
            return
        }

        // Multi-agent team: explicit requests (`multi:` / `/agents`) and marker
        // phrases (deep research, weekly planning, job search, code review)
        // run through the specialized-agent pipeline instead of one agent.
        // Checked before engine routing so those markers reach the team, not
        // the single general or coding agent. Off in Settings → the text falls
        // through to the normal path unchanged.
        if MultiAgentOrchestrator.shared.enabled, let task = MultiAgentOrchestrator.route(text) {
            handleMultiAgentQuery(task: task)
            return
        }

        barState.responseText = ""
        barState.isProcessing = true
        barState.presenceState = .thinking

        hermesTask?.cancel()
        let agent: HermesSession
        switch Self.engine(for: text) {
        case .opencode: agent = codingAgent
        case .primeAgent: agent = primeAgent
        case .hermes, .freebuff:
            // freebuff sessions belong to the phone's remote coding surface
            // (AlfredCodeManager); a query in the bar just gets the general
            // agent.
            agent = hermes
        }
        hermesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleQueryAsync(text: text, attachment: attachment, agent: agent)
        }
    }

    // MARK: Multi-agent queries

    /// Stream a multi-agent run into the bar: a header per agent, then the
    /// agent's text as it streams. The last agent's deliverable is the answer;
    /// the run's stage list is a bonus, not a leak — the user asked for the team.
    private func handleMultiAgentQuery(task: String) {
        barState.responseText = ""
        barState.isProcessing = true
        barState.presenceState = .thinking

        hermesTask?.cancel()
        hermesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // The run consumes quota on whichever provider is active, like a bar turn.
            if let provider = self.providerKeys.activeKey?.provider {
                UsageTracker.shared.record(provider: provider)
            }
            var failure: String?
            for await event in MultiAgentOrchestrator.shared.run(task: task) {
                switch event {
                case .stageStarted(let role, let index, let total):
                    if self.barState.presenceState == .thinking { self.barState.presenceState = .responding }
                    self.barState.responseText += "\n\n👥 \(role.displayName) agent (\(index)/\(total))\n"

                case .stageText(_, let chunk):
                    self.barState.responseText += chunk

                case .stageFinished:
                    self.barState.responseText += "\n"

                case .stageFailed(let role, let message):
                    self.barState.responseText += "\n⚠️ \(role.displayName) agent failed: \(message)\n"

                case .failed(let message):
                    failure = message

                case .finished(let stages, let duration):
                    self.barState.responseText += "\n\n— Multi-agent run: \(stages) agents · \(Int(duration))s —"
                }
            }
            if let failure {
                if self.barState.responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.barState.responseText = Self.rotatedIfQuota(failure)
                } else {
                    self.barState.responseText += "\n\n⚠️ \(failure)"
                }
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

    // MARK: Mail-alert replies

    /// Turn the user's bar submission into a reply to the alerted email, sent
    /// via the agent. The draft goes straight into a Hermes turn that re-reads
    /// the message, rewrites the draft in the user's professional style, and
    /// sends it with `email_send` (which still stops for human approval).
    private func runReply(draft: String, pending: PendingEmailReply) {
        barState.responseText = ""
        barState.isProcessing = true
        barState.presenceState = .thinking

        hermesTask?.cancel()
        let replyText = """
            Rewrite the user's draft below into a polished, professional email reply \
            in their voice and send it. First read the original email with \
            email_read (id \(pending.messageID)) so you reply to the right person \
            and keep the correct subject/thread. Then send with email_send.

            Reply to: \(pending.senderName)

            The user's draft:
            \(draft)
            """
        hermesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: String?
            // capture: false — the model is rewriting the user's draft here,
            // not answering a fresh user question; the draft and the rewrite
            // are the user's own words, not a valuable new exchange.
            for await event in await self.hermes.prompt(replyText, capture: false) {
                switch event {
                case .text(let chunk):
                    self.barState.responseText += chunk
                case .failed(let message):
                    failure = message
                case .thought, .toolStarted, .toolProgress, .usage, .finished:
                    break
                }
            }
            if let failure {
                self.barState.responseText = failure
            }
            self.barState.isProcessing = false
            self.barState.presenceState = .expanded
        }
    }

    /// Actually read and post the alerted email's full content into the bar.
    ///
    /// The notification tap can't stream; it just opens the bar with the message
    /// text so the user can type a reply, which runReply then sends.
    @MainActor
    func openEmailAlert(messageID: String, senderName: String, subject: String) {
        barState.pendingEmailReply = PendingEmailReply(
            messageID: messageID,
            senderName: senderName,
            subject: subject
        )
        showBar()

        // Fetch the body off the main thread — himalaya is a subprocess.
        Task.detached { [weak self] in
            let text = (try? EmailCapability.shared.readMessage(
                id: messageID, account: "icloud", mailbox: "Inbox"))
                ?? "Couldn't read that message."
            await MainActor.run {
                self?.barState.responseText = text.isEmpty ? "No body." : text
                self?.resizeBar()
            }
        }
    }
}

// MARK: - Notification delegate

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even while Alfred is frontmost: an important email is
        // the one time we want to interrupt.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let id = info["mailMessageID"] as? String ?? ""
        let sender = info["mailSender"] as? String ?? ""
        let subject = info["mailSubject"] as? String ?? ""

        if !id.isEmpty {
            openEmailAlert(messageID: id, senderName: sender, subject: subject)
        }
        completionHandler()
    }
}

// MARK: - Popover delegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        settingsPopoverClosedAt = Date()
    }
}
