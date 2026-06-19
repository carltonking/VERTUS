import SwiftUI
import AppKit
import Combine
import OSLog

private let logger = Logger(subsystem: "com.alfred.app", category: "AlfredApp")

// MARK: - Bar observable state
//
// BarState is a dedicated ObservableObject so AppDelegate can mutate
// responseText on the MainActor and SwiftUI will re-render BarView.
// Using a separate object avoids conforming AppDelegate to ObservableObject.

final class BarState: ObservableObject {
    @Published var responseText: String = ""
    @Published var isProcessing: Bool = false
    @Published var suggestions: [ProactiveSuggestion] = []
    @Published var contextLabel: String = ""
    @Published var contextStatus: String = ""
    @Published var presenceState: AssistantPresenceState = .hidden
}

// MARK: - Bridge view
//
// BarView takes @Binding. This container resolves it from the EnvironmentObject
// so AppKit (NSHostingView) doesn't need to manufacture a Binding directly.

private struct BarContainer: View {
    @EnvironmentObject private var barState: BarState
    @EnvironmentObject private var appState: AppState
    let onSubmit: (String) -> Void
    let onSuggestionTap: (ProactiveSuggestion) -> Void
    let onCollapse: () -> Void

    var body: some View {
        PresenceRootView(
            presenceState: $barState.presenceState,
            barState: barState,
            activeProject: projectName,
            contextLabel: barState.contextLabel,
            contextStatus: barState.contextStatus,
            onSubmit: onSubmit,
            onSuggestionTap: onSuggestionTap,
            onExpand: { barState.presenceState = .expanded },
            onCollapse: onCollapse
        )
    }

    private var projectName: String? {
        // Derive from suggestions or context label
        if !barState.contextLabel.isEmpty { return barState.contextLabel }
        return nil
    }
}

// MARK: - App entry

@main
struct AlfredApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var updaterManager = UpdaterManager()

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterManager.checkForUpdates()
                }
                .disabled(!updaterManager.canCheckForUpdates)
            }
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let barState = BarState()

    private var barWindow: BarWindow?
    private weak var enableScreenMonitoringItem: NSMenuItem?
    private weak var disableScreenMonitoringItem: NSMenuItem?
    private weak var startFocusSessionItem: NSMenuItem?
    private weak var endFocusSessionItem: NSMenuItem?
    private weak var pauseFocusSessionItem: NSMenuItem?
    private weak var resumeFocusSessionItem: NSMenuItem?
    private weak var focusSensitivityItem: NSMenuItem?
    private var onboardingWindow: NSWindow?
    private var chatWindow: NSWindow?
    private var chatHostingController: NSHostingController<ChatWindowView>?
    private var chatViewModel: ChatViewModel?
    private var routineScheduler: RoutineScheduler?

    private var hotkeyListener: HotkeyListener?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var popover: NSPopover?
    private var contextMonitor: ContextMonitor?
    private let fileAccess = FileAccessCapability()
    private let selectedFileContext = SelectedFileContext()
    private let bookmarkStore = SecurityScopedBookmarkStore()
    private let computerControl = ComputerControlCapability()
    private let fileOperation = FileOperationCapability()
    private let messaging = MessagingCapability()
    private var pendingTextRecipient: MessagingCapability.Recipient?
    private let mailCompose = MailComposeCapability()
    private let screenMonitoring = ScreenMonitoringManager()
    private let focusSession = FocusSessionManager()
    private var escapeMonitor: Any?
    private var notchHoverMonitor: Any?
    private var hideOnLeaveTimer: Timer?
    private var shownByHover = false
    private(set) var llmRouter: LLMRouter?
    private(set) var memoryStore: MemoryStore?
    private var assistantCore: AssistantCore?
    private(set) var learningService: BehavioralLearningService?
    private(set) var projectAwareness: ProjectAwarenessService?
    private var adaptiveEngine: AdaptiveSuggestionEngine?
    private var personalContextService: PersonalContextService?
    private(set) var learningEventLog: LearningEventLog?
    private(set) var privacyManager: PrivacyManager?
    private(set) var relationshipMemoryService: RelationshipMemoryService?
    private(set) var memoryReflectionService: MemoryReflectionService?
    private(set) var proactiveSurfacingService: ProactiveMemorySurfacingService?
    private(set) var backupService: MemoryBackupService?
    private(set) var workflowDetectionService: WorkflowDetectionService?
    private(set) var writingStyleStore: WritingStyleStore?
    private(set) var adaptationEngine: ResponseAdaptationEngine?
    private(set) var appActivityMonitor: AppActivityMonitor?
    private(set) var workflowSuggestionService: WorkflowSuggestionService?
    private(set) var workflowExecutor: WorkflowExecutor?
    private(set) var memoryLinkService: MemoryLinkService?
    private var lastContextForLearning: AppContext?
    private var lastShownSuggestions: [ProactiveSuggestion] = []
    private var learningProfileTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        ensureAppDirectories()
        NotificationManager.shared.setup()

        do {
            memoryStore = try MemoryStore()
        } catch {
            // Without the store, Alfred degrades to a bare LLM with no memory, routines, or
            // capabilities. Surface it loudly instead of failing silently.
            logger.error("MemoryStore init failed: \(error.localizedDescription)")
            barState.contextStatus = "Memory store unavailable: \(error.localizedDescription)"
            let alert = NSAlert()
            alert.messageText = "Alfred: database problem"
            alert.informativeText = """
                Alfred couldn't open its database, so memory, routines, and most features are \
                disabled (the bar will only do basic chat).

                \(error.localizedDescription)

                To reset: quit Alfred, move ~/.alfred/db aside, then relaunch.
                """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        let router = LLMRouter(appState: appState)
        llmRouter = router

        GlobalHotkeyManager.shared.registerHotkey(
            keyCode: 8,
            modifiers: UInt32(768),
            identifier: 3,
            action: { [weak self] in
                self?.showChatWindow()
            }
        )

        if let store = memoryStore {
            let projectService = ProjectAwarenessService(memory: store)
            projectAwareness = projectService
            let adaptive = AdaptiveSuggestionEngine(memory: store)
            adaptiveEngine = adaptive
            let bls = BehavioralLearningService(memory: store)
            learningService = bls
            let eventLog = LearningEventLog()
            learningEventLog = eventLog
            privacyManager = PrivacyManager(mode: appState.privacyMode)
            let relationshipMem = RelationshipMemoryService()
            relationshipMemoryService = relationshipMem
            let reflectionService = MemoryReflectionService(relationshipMemory: relationshipMem)
            reflectionService.setMinimalMode(appState.privacyMode == .minimal)
            memoryReflectionService = reflectionService
            let contextCollector = ContextCollector(memoryStore: store)
            let wfDetection = WorkflowDetectionService(
                contextCollector: contextCollector,
                relationshipMemory: relationshipMem
            )
            workflowDetectionService = wfDetection

            let wfSuggestion = WorkflowSuggestionService(
                detectionService: wfDetection,
                contextCollector: contextCollector,
                relationshipMemory: relationshipMem
            )
            workflowSuggestionService = wfSuggestion

            let wfExecutor = WorkflowExecutor()
            workflowExecutor = wfExecutor

            let surfacingService = ProactiveMemorySurfacingService(
                relationshipMemory: relationshipMem,
                memoryReflections: reflectionService,
                contextCollector: contextCollector,
                workflowSuggestions: wfSuggestion
            )
            surfacingService.proactiveEnabled = appState.proactiveSuggestionsEnabled
            surfacingService.onBadgeUpdate = { [weak self] hasActive in
                self?.updateProactiveBadge(hasActive: hasActive)
            }
            proactiveSurfacingService = surfacingService
            let contextService = PersonalContextService(
                memory: store,
                learningService: bls,
                projectAwareness: projectService
            )
            personalContextService = contextService
            let wss = store.writingStyleStore
            writingStyleStore = wss
            let ts = store.timelineStore
            appActivityMonitor = AppActivityMonitor(store: ts)
            let relStore = store.relationshipStore
            let habitStore = store.habitStore
            let loopStore = store.learningLoopStore
            let adaptEngine = ResponseAdaptationEngine(
                writingStyle: wss,
                habits: habitStore,
                learningLoop: loopStore,
                rewardEngine: store.rewardEngine
            )
            adaptationEngine = adaptEngine
            // Blueprint v1 quarantine: the broad learning stack is built but NOT injected
            // unless FeatureScope.learningEnabled is on. Writing-style personalization (M8) is a
            // narrow exception gated by FeatureScope.personalizationEnabled — the compiler carries
            // ONLY the writing-style context when learning is off.
            let learningOn = FeatureScope.learningEnabled
            let personalizationOn = FeatureScope.personalizationEnabled
            let compiler = ContextCompiler(
                writingStyle: (learningOn || personalizationOn) ? wss : nil,
                habits: learningOn ? habitStore : nil,
                relationships: learningOn ? relStore : nil,
                timeline: learningOn ? ts : nil,
                adaptation: learningOn ? adaptEngine : nil,
                rewards: learningOn ? store.rewardEngine : nil
            )
            let actionEngine = ActionSelectionEngine(
                habits: learningOn ? habitStore : nil,
                rewards: learningOn ? store.rewardEngine : nil,
                adaptation: learningOn ? adaptEngine : nil
            )
            let dashService = store.taskDashboardService
            assistantCore = AssistantCore(
                router: router,
                memory: store,
                projectAwareness: learningOn ? projectService : nil,
                personalContextService: learningOn ? contextService : nil,
                relationshipMemoryService: learningOn ? relationshipMem : nil,
                memoryReflectionService: learningOn ? reflectionService : nil,
                writingStyle: learningOn ? wss : nil,
                relationshipStore: learningOn ? relStore : nil,
                habitStore: learningOn ? habitStore : nil,
                learningLoopStore: learningOn ? loopStore : nil,
                adaptationEngine: learningOn ? adaptEngine : nil,
                rewardEngine: learningOn ? store.rewardEngine : nil,
                contextCompiler: (learningOn || personalizationOn) ? compiler : nil,
                actionSelectionEngine: actionEngine,
                taskDashboardService: learningOn ? dashService : nil
            )
            let linkService = MemoryLinkService(relationshipMemory: relationshipMem)
            linkService.initialize()
            memoryLinkService = linkService

            relationshipMem.memoryLinkService = linkService
            reflectionService.memoryLinkService = linkService
            surfacingService.memoryLinkService = linkService

            let backupServ = MemoryBackupService(
                relationshipService: relationshipMem,
                reflectionService: reflectionService
            )
            backupServ.setWorkflowDetectionService(wfDetection)
            backupServ.setMemoryLinkService(linkService)
            backupService = backupServ
            backupServ.autoBackupEnabled = true
            backupServ.maxBackupCount = appState.backupMaxCount
            backupServ.encryptByDefault = appState.backupEncryptDefault
            backupServ.initialize()

            subscribeToWorkflowNotifications()
        }

        setupBarWindow()
        setupStatusItem()
        setupComputerControlCancelMonitor()
        resolveRememberedFileAccess()
        observeBarSizing()
        observeScreenMonitoring()
        observeFocusSession()
        observeOnboardingCompletion()
        observePrivacyMode()
        startContextMonitor()
        appActivityMonitor?.start()

        startLearningProfileTimer()

        if appState.isOnboardingComplete {
            startHotkeyListener()
            // Bar is hotkey-controlled only — no hover auto-show/hide. It never appears or
            // disappears on its own; it stays on screen until the user toggles it with ⌘⇧J.
        } else {
            showOnboarding()
        }

        SafetyAuditEngine.shared.assertNoAutonomousExecution()

        // Blueprint v1 §6: start the one sanctioned scheduler AFTER the audit (it lives in a
        // class the audit does not scan; only read-only routines run unattended).
        startRoutineScheduler()
    }

    private func startRoutineScheduler() {
        // Don't run routines (which can call cloud + post notifications) before onboarding +
        // permissions are granted. Started from observeOnboardingCompletion otherwise.
        guard appState.isOnboardingComplete else { return }
        guard let store = memoryStore, let core = assistantCore, let router = llmRouter else { return }
        let scheduler = RoutineScheduler(store: store, core: core, appState: appState, router: router)
        routineScheduler = scheduler
        scheduler.start()
    }


    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.unregisterAll()
        routineScheduler?.stop()
        unloadLaunchAgent()
    }

    /// Blueprint v1 §6/§11: a graceful Quit unloads the launchd keep-alive agent so the app
    /// isn't immediately relaunched. A crash (no graceful terminate) leaves the job loaded, so
    /// KeepAlive relaunches it; the next login reloads the agent via RunAtLoad either way.
    private func unloadLaunchAgent() {
        let plistPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/com.alfred.launcher.plist")
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", plistPath]
        do { try task.run() } catch { return }
        // Bound the wait so a stalled launchctl can't wedge Quit (we're mid-termination).
        let deadline = Date().addingTimeInterval(2.0)
        while task.isRunning && Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate() }
    }

    private func isLocalConnectionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        // LLMError wrapping a URLError
        if let llmError = error as? LLMError,
           case .networkError(let msg) = llmError,
           msg.contains("Could not connect") || msg.contains("Connection refused")
        {
            return true
        }
        return false
    }

    // MARK: - Directory setup

    private func ensureAppDirectories() {
        let dirs = [".alfred/db", ".alfred/wiki", ".alfred/logs"]
        let home = FileManager.default.homeDirectoryForCurrentUser
        for dir in dirs {
            let url = home.appending(path: dir, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func resolveRememberedFileAccess() {
        var statuses: [String] = []
        var rememberedFileURLs: [URL] = []
        var rememberedFolderURL: URL?

        do {
            if let fileResolution = try bookmarkStore.resolveFiles() {
                if fileResolution.isStale {
                    statuses.append("Remembered file access is stale. Choose the file again, then remember access.")
                } else if !fileResolution.urls.isEmpty {
                    rememberedFileURLs = fileResolution.urls
                    statuses.append(fileResolution.urls.count == 1
                        ? "Remembered file access loaded: \(fileResolution.urls[0].lastPathComponent)"
                        : "Remembered access loaded for \(fileResolution.urls.count) files.")
                }
            }
        } catch {
            statuses.append("Could not load remembered file access. Choose the file again.")
        }

        do {
            if let folderResolution = try bookmarkStore.resolveFolder() {
                if folderResolution.isStale {
                    statuses.append("Remembered folder access is stale. Choose the folder again, then remember access.")
                } else if let folderURL = folderResolution.urls.first {
                    rememberedFolderURL = folderURL
                    statuses.append("Remembered folder access loaded: \(folderURL.lastPathComponent)")
                }
            }
        } catch {
            statuses.append("Could not load remembered folder access. Choose the folder again.")
        }

        if !statuses.isEmpty {
            selectedFileContext.restoreRemembered(fileURLs: rememberedFileURLs, folderURL: rememberedFolderURL)
            barState.contextStatus = statuses.joined(separator: " ")
        }
    }

    // MARK: - Bar window

    private func setupBarWindow() {
        let window = BarWindow()
        let rootView = BarContainer(
            onSubmit: { [weak self] text in self?.handleQuery(text) },
            onSuggestionTap: { [weak self] suggestion in
                self?.handleSuggestionTap(suggestion)
            },
            onCollapse: { [weak self] in
                self?.handlePresenceCollapse()
            }
        )
        .environmentObject(appState)
        .environmentObject(barState)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        // Wrap in a visual-effect view for the vibrant notch look
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
    }

    private func showChatWindow() {
        if let window = chatWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let router = llmRouter else { return }
        let viewModel = ChatViewModel(llmRouter: router)
        chatViewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Alfred Chat"
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: ChatWindowView(viewModel: viewModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = hostingView

        chatWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupComputerControlCancelMonitor() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                self?.computerControl.cancel()
                self?.barState.contextStatus = "Computer control stop requested with Esc."
                // Collapse presence bar on Escape if visible
                if self?.barWindow?.isVisible == true {
                    self?.handlePresenceCollapse()
                }
            }
        }
    }

    private func observeBarSizing() {
        barState.$responseText
            .combineLatest(barState.$isProcessing, barState.$suggestions, barState.$presenceState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text, isProcessing, suggestions, presenceState in
                guard let self else { return }
                guard let window = self.barWindow else { return }

                switch presenceState {
                case .hidden, .collapsed:
                    break
                case .expanded, .thinking, .responding:
                    let height = self.expandedBarHeight(
                        text: text,
                        isProcessing: isProcessing,
                        suggestions: suggestions
                    )
                    window.resizeNotch(toHeight: height)
                case .listening:
                    window.resizeNotch(toHeight: 120)
                }
            }
            .store(in: &cancellables)
    }

    private func expandedBarHeight(text: String, isProcessing: Bool, suggestions: [ProactiveSuggestion]) -> CGFloat {
        var total = ExpandedPresenceView.inputRowHeight + 4 // 4 pt top padding from VStack

        let hasSuggestions = !suggestions.isEmpty
        let hasResponse = !text.isEmpty

        if hasSuggestions && !hasResponse && !isProcessing {
            total += ExpandedPresenceView.suggestionRowHeight
        }

        if isProcessing || hasResponse {
            total += 1 // divider
            if hasResponse {
                total += ExpandedPresenceView.responseHeight(for: text)
            } else {
                total += ExpandedPresenceView.loadingRowHeight
            }
        }

        return total
    }

    private func observeScreenMonitoring() {
        screenMonitoring.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if self.screenMonitoring.isActive || status.contains("Screen monitoring") {
                    self.barState.contextStatus = status
                }
            }
            .store(in: &cancellables)

        screenMonitoring.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.updateScreenMonitoringIndicator(isActive: isActive)
            }
            .store(in: &cancellables)

        if appState.screenMonitoringEnabled {
            screenMonitoring.start()
        }
    }

    private func observeFocusSession() {
        focusSession.sensitivity = FocusSensitivity(rawValue: appState.focusSensitivity) ?? .medium

        focusSession.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if self.focusSession.isActive || status.contains("Focus session") || status.contains("Focus nudge") {
                    self.barState.contextStatus = status
                }
            }
            .store(in: &cancellables)

        focusSession.$isActive
            .combineLatest(focusSession.$isPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateScreenMonitoringIndicator(isActive: self?.screenMonitoring.isActive == true)
            }
            .store(in: &cancellables)
    }

    private func observePrivacyMode() {
        appState.$privacyMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.privacyManager?.setMode(mode)
                self.memoryReflectionService?.setMinimalMode(mode == .minimal)
                self.proactiveSurfacingService?.setMinimalMode(mode == .minimal)
            }
            .store(in: &cancellables)
    }

    private func subscribeToWorkflowNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRunWorkflowNotification(_:)),
            name: .runWorkflowFromDashboard,
            object: nil
        )
    }

    @objc private func handleRunWorkflowNotification(_ notification: Notification) {
        guard let wfID = notification.userInfo?["workflowID"] as? String,
              let uuid = UUID(uuidString: wfID),
              let wf = workflowDetectionService?.workflow(by: uuid)
        else { return }
        workflowDetectionService?.recordUsage(id: uuid)
        workflowExecutor?.execute(wf)
        barState.contextStatus = "Running workflow: \(wf.title)"
    }

    private func updateScreenMonitoringIndicator(isActive: Bool) {
        let hasProactive = (proactiveSurfacingService?.getAvailableSuggestions().isEmpty == false)
        let icon = Self.makeMenuBarIcon()
        if hasProactive {
            icon.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 5, height: 5)).fill()
            icon.unlockFocus()
            icon.accessibilityDescription = "Alfred has proactive suggestions"
        }
        if focusSession.isActive {
            icon.lockFocus()
            (focusSession.isPaused ? NSColor.systemYellow : NSColor.systemOrange).setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 5, height: 5)).fill()
            icon.unlockFocus()
            icon.accessibilityDescription = focusSession.isPaused
                ? "Alfred, focus session paused"
                : "Alfred, focus session active"
        } else if isActive {
            icon.lockFocus()
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 5, height: 5)).fill()
            icon.unlockFocus()
            icon.accessibilityDescription = "Alfred, screen monitoring active"
        }
        enableScreenMonitoringItem?.state = isActive ? .on : .off
        disableScreenMonitoringItem?.isEnabled = isActive
        startFocusSessionItem?.isEnabled = !focusSession.isActive
        endFocusSessionItem?.isEnabled = focusSession.isActive
        pauseFocusSessionItem?.isEnabled = focusSession.isActive && !focusSession.isPaused
        resumeFocusSessionItem?.isEnabled = focusSession.isActive && focusSession.isPaused
        focusSensitivityItem?.title = "Focus Sensitivity: \(focusSession.sensitivity.displayName)"
    }

    private func startContextMonitor() {
        let monitor = ContextMonitor(interval: 1.5)
        contextMonitor = monitor

        monitor.$suggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawSuggestions in
                guard let self else { return }
                let context = self.lastContextForLearning
                let activeProject = self.projectAwareness?.currentProject()?.displayName
                let rates = self.learningService?.suggestionCategoriesByConfidence() ?? []
                let recent = [String]()
                let fallbackContext = AppContext(appName: "", bundleIdentifier: nil, windowTitle: nil, browserURL: nil, browserTitle: nil)

                let oldSugs = self.lastShownSuggestions
                self.lastShownSuggestions = rawSuggestions
                let newIds = Set(rawSuggestions.map { $0.id })
                for sugs in oldSugs where !newIds.contains(sugs.id) {
                    self.adaptiveEngine?.recordDismissed(category: self.adaptiveEngine?.category(for: sugs) ?? "default")
                }

                if let engine = self.adaptiveEngine {
                    let ranked = SuggestionEngine.rankedSuggestions(
                        for: context ?? fallbackContext,
                        adaptiveEngine: engine,
                        profileCategoryRates: rates,
                        recentActivity: recent,
                        activeProject: activeProject
                    )
                    self.barState.suggestions = ranked.map { $0.suggestion }
                    self.learningService?.recordSuggestionsShown(ranked.map { $0.suggestion }, context: context)
                } else {
                    self.barState.suggestions = rawSuggestions
                    self.learningService?.recordSuggestionsShown(rawSuggestions, context: context)
                }
            }
            .store(in: &cancellables)

        monitor.$context
            .receive(on: DispatchQueue.main)
            .sink { [weak self] context in
                guard let self, let context else {
                    self?.barState.contextLabel = ""
                    self?.lastContextForLearning = nil
                    return
                }
                self.lastContextForLearning = context
                self.projectAwareness?.ingestContext(context)
                let title = context.browserTitle ?? context.windowTitle
                if let title, !title.isEmpty {
                    self.barState.contextLabel = "\(context.appName) - \(title)"
                } else {
                    self.barState.contextLabel = context.appName
                }
                self.focusSession.observe(context: context)
            }
            .store(in: &cancellables)

        monitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.barState.contextStatus = status
            }
            .store(in: &cancellables)

        appState.$proactiveSuggestionsEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak monitor] enabled in
                guard let self, let monitor else { return }
                if enabled {
                    monitor.start()
                } else {
                    monitor.stop()
                    self.barState.suggestions = []
                    self.barState.contextLabel = ""
                    self.barState.contextStatus = "Proactive suggestions are off in Settings."
                }
                self.proactiveSurfacingService?.proactiveEnabled = enabled
            }
            .store(in: &cancellables)

        if appState.proactiveSuggestionsEnabled {
            monitor.start()
        } else {
            barState.contextStatus = "Proactive suggestions are off in Settings."
        }
    }

    // MARK: - Learning profile

    private func startLearningProfileTimer() {
        learningProfileTimer?.invalidate()
        learningProfileTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let learningService else { return }
                learningService.generateProfileUpdate()
                self.projectAwareness?.refreshProjects()

                // Feed active projects into relationship memory
                for project in (self.projectAwareness?.activeProjects() ?? []) {
                    self.relationshipMemoryService?.considerMention(
                        project.displayName,
                        category: .projects,
                        source: "project-awareness"
                    )
                }

                // Feed top learning interests
                for interest in learningService.topInterests(limit: 5) {
                    self.relationshipMemoryService?.considerMention(
                        interest,
                        category: .longTermInterests,
                        source: "behavioral-learning"
                    )
                }

                // Run memory reflection if cooldown has elapsed
                if self.memoryReflectionService?.shouldRunReflection() == true {
                    let count = self.memoryReflectionService?.runReflectionNow() ?? 0
                    if count > 0 {
                        self.barState.contextStatus = "Memory reflection generated \(count) insight(s)"
                    }
                }

                // Run habit detection from timeline data
                self.memoryStore?.habitStore.detectHabits()

                // Check for proactive suggestions
                if self.proactiveSurfacingService?.proactiveEnabled == true {
                    _ = self.proactiveSurfacingService?.forceCheck()
                }
            }
        }
    }

    // MARK: - Menu bar icon

    private static func makeMenuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "alfred-small-logo", withExtension: "png"),
           let sourceImage = NSImage(contentsOf: url) {
            sourceImage.size = NSSize(width: 18, height: 18)
            sourceImage.isTemplate = false
            sourceImage.accessibilityDescription = "Alfred"
            return sourceImage
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()

        let path = NSBezierPath()
        path.windingRule = .evenOdd

        // Outer triangle
        path.move(to: NSPoint(x: 9, y: 17))
        path.line(to: NSPoint(x: 17, y: 1))
        path.line(to: NSPoint(x: 1, y: 1))
        path.close()

        // Inner triangular counterform
        path.move(to: NSPoint(x: 9, y: 9.8))
        path.line(to: NSPoint(x: 5.4, y: 3.5))
        path.line(to: NSPoint(x: 12.6, y: 3.5))
        path.close()

        path.fill()

        image.isTemplate = true
        image.accessibilityDescription = "Alfred"
        return image
    }

    @objc private func showAlfredFromMenu() {
        contextMonitor?.refresh(forceBrowserRead: true)
        barState.presenceState = .expanded
        barWindow?.expand(toHeight: expandedBarHeight(
            text: barState.responseText,
            isProcessing: barState.isProcessing,
            suggestions: barState.suggestions
        ))
    }

    @objc private func showIntroFromMenu() {
        showOnboarding(initialStep: 0)
    }

    @objc private func showPermissionsFromMenu() {
        showOnboarding(initialStep: 4)
    }

    @objc private func runDiagnosticsFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await CapabilityEventLogger.shared.record("diagnostics", "requested")
            let summary = await diagnosticsSummary()
            showDiagnosticsPanel(summary)
            barState.contextStatus = "Diagnostics complete. Summary stayed local."
            await CapabilityEventLogger.shared.record("diagnostics", "completed")
        }
    }

    @objc private func copyDiagnosticsSummaryFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await CapabilityEventLogger.shared.record("diagnostics", "copy requested")
            let summary = await diagnosticsSummary()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
            barState.contextStatus = "Diagnostics summary copied. It contains status only, not file contents or paths."
            await CapabilityEventLogger.shared.record("diagnostics", "copied")
        }
    }

    private func diagnosticsSummary() async -> String {
        await CapabilityDiagnostics.makeSummary(
            appState: appState,
            selectedFiles: selectedFileContext.snapshot(),
            bookmarkStore: bookmarkStore,
            screenMonitoringActive: screenMonitoring.isActive,
            focusSessionActive: focusSession.isActive
        )
    }

    private func showDiagnosticsPanel(_ summary: String) {
        let alert = NSAlert()
        alert.messageText = "Alfred Diagnostics"
        alert.informativeText = "Local-only capability status. No contents, screenshots, secrets, or full paths are included."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Summary")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        textView.string = summary
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
            barState.contextStatus = "Diagnostics summary copied."
        }
    }

    @objc private func chooseFileFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await CapabilityEventLogger.shared.record("file access", "choose files requested")
            let urls = await fileAccess.chooseFiles()
            if urls.isEmpty {
                barState.contextStatus = "No file selected."
                await CapabilityEventLogger.shared.record("file access", "choose files cancelled")
                return
            }

            selectedFileContext.selectFiles(urls)
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            barState.contextStatus = urls.count == 1
                ? "Selected file: \(names)"
                : "Selected \(urls.count) files: \(names)"
            await CapabilityEventLogger.shared.record("file access", "files selected", detail: "\(urls.count) file(s)")
        }
    }

    @objc private func chooseFolderFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await CapabilityEventLogger.shared.record("file access", "choose folder requested")
            guard let url = await fileAccess.chooseFolder() else {
                barState.contextStatus = "No folder selected."
                await CapabilityEventLogger.shared.record("file access", "choose folder cancelled")
                return
            }

            selectedFileContext.selectFolder(url)
            barState.contextStatus = "Selected folder: \(url.lastPathComponent)"
            await CapabilityEventLogger.shared.record("file access", "folder selected", detail: url.lastPathComponent)
        }
    }

    @objc private func clearSelectedFilesFromMenu() {
        selectedFileContext.clear()
        barState.contextStatus = "Selected files cleared."
        Task { await CapabilityEventLogger.shared.record("file access", "selected context cleared") }
    }

    @objc private func rememberSelectedFileAccessFromMenu() {
        let urls = selectedFileContext.fileURLs
        guard !urls.isEmpty else {
            barState.contextStatus = "Choose one or more files before remembering file access."
            Task { await CapabilityEventLogger.shared.record("bookmarks", "remember files refused", detail: "no selected files") }
            return
        }

        do {
            try bookmarkStore.rememberFiles(urls)
            selectedFileContext.selectFiles(urls, remembered: true)
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            barState.contextStatus = urls.count == 1
                ? "Remembered file access: \(names)"
                : "Remembered access for \(urls.count) files."
            Task { await CapabilityEventLogger.shared.record("bookmarks", "remember files succeeded", detail: "\(urls.count) file(s)") }
        } catch {
            barState.contextStatus = "Could not remember file access: \(error.localizedDescription)"
            Task { await CapabilityEventLogger.shared.record("bookmarks", "remember files failed", detail: error.localizedDescription) }
        }
    }

    @objc private func rememberSelectedFolderAccessFromMenu() {
        guard let url = selectedFileContext.folderURL else {
            barState.contextStatus = "Choose a folder before remembering folder access."
            Task { await CapabilityEventLogger.shared.record("bookmarks", "remember folder refused", detail: "no selected folder") }
            return
        }

        do {
            try bookmarkStore.rememberFolder(url)
            selectedFileContext.selectFolder(url, remembered: true)
            barState.contextStatus = "Remembered folder access: \(url.lastPathComponent)"
            Task { await CapabilityEventLogger.shared.record("bookmarks", "remember folder succeeded", detail: url.lastPathComponent) }
        } catch {
            barState.contextStatus = "Could not remember folder access: \(error.localizedDescription)"
            Task { await CapabilityEventLogger.shared.record("bookmarks", "remember folder failed", detail: error.localizedDescription) }
        }
    }

    @objc private func forgetRememberedFileAccessFromMenu() {
        bookmarkStore.forgetFiles()
        if selectedFileContext.usesRememberedFileAccess {
            selectedFileContext.clear()
        }
        barState.contextStatus = "Forgot remembered file access."
        Task { await CapabilityEventLogger.shared.record("bookmarks", "forgot file access") }
    }

    @objc private func forgetRememberedFolderAccessFromMenu() {
        bookmarkStore.forgetFolder()
        if selectedFileContext.usesRememberedFolderAccess {
            selectedFileContext.clear()
        }
        barState.contextStatus = "Forgot remembered folder access."
        Task { await CapabilityEventLogger.shared.record("bookmarks", "forgot folder access") }
    }

    @objc func enableScreenMonitoringFromMenu() {
        appState.screenMonitoringEnabled = true
        screenMonitoring.start()
        barState.contextStatus = "Screen monitoring enabled. Captures stay in memory and are not sent to the model automatically."
        Task { await CapabilityEventLogger.shared.record("screen monitoring", "enabled") }
    }

    @objc func disableScreenMonitoringFromMenu() {
        appState.screenMonitoringEnabled = false
        screenMonitoring.stop()
        barState.contextStatus = "Screen monitoring disabled. In-memory screen context cleared."
        Task { await CapabilityEventLogger.shared.record("screen monitoring", "disabled") }
    }

    @objc private func startVoiceInputFromMenu() {
        guard VoiceInputCapability.isAuthorized else {
            barState.contextStatus = "Voice input not authorized. Grant speech recognition in System Settings."
            Task { await CapabilityEventLogger.shared.record("voice input", "not authorized") }
            return
        }
        guard let voiceInput = VoiceInputCapability() else {
            barState.contextStatus = "Voice input unavailable on this Mac."
            Task { await CapabilityEventLogger.shared.record("voice input", "unavailable") }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            barState.contextStatus = "Listening…"
            self.showBar()
            var fullTranscript = ""
            do {
                for try await partial in voiceInput.transcribe() {
                    fullTranscript = partial
                }
                barState.contextStatus = "Transcribed. Processing…"
                guard !fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    barState.contextStatus = "No speech detected."
                    return
                }
                handleQuery(fullTranscript)
            } catch {
                barState.contextStatus = "Voice input failed: \(error.localizedDescription)"
                Task { await CapabilityEventLogger.shared.record("voice input", "failed", detail: error.localizedDescription) }
            }
        }
    }

    @objc private func showTodaysEventsFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.showBar()
            barState.isProcessing = true
            barState.responseText = "Fetching your calendar…"
            let cal = CalendarRemindersCapability()
            do {
                let events = try await cal.readUpcomingEvents(limit: 10)
                let reminders = try await cal.readReminders(limit: 10)
                barState.responseText = "📅 Today & Upcoming\n\n\(events)\n\n\(reminders)"
            } catch {
                barState.responseText = "Could not fetch calendar: \(error.localizedDescription)"
                Task { await CapabilityEventLogger.shared.record("calendar", "failed", detail: error.localizedDescription) }
            }
            barState.isProcessing = false
        }
    }

    @objc private func startFocusSessionFromMenu() {
        guard let goal = promptForFocusGoal() else {
            barState.contextStatus = "Focus session not started."
            return
        }

        focusSession.start(goal: goal)
        screenMonitoring.start()
        contextMonitor?.start()
        barState.contextStatus = "Focus session started: \(goal)"
        updateScreenMonitoringIndicator(isActive: screenMonitoring.isActive)
        Task { await CapabilityEventLogger.shared.record("focus session", "started") }
    }

    @objc private func pauseFocusSessionFromMenu() {
        focusSession.pause()
        barState.contextStatus = "Focus session paused."
        updateScreenMonitoringIndicator(isActive: screenMonitoring.isActive)
        Task { await CapabilityEventLogger.shared.record("focus session", "paused") }
    }

    @objc private func resumeFocusSessionFromMenu() {
        focusSession.resume()
        screenMonitoring.start()
        contextMonitor?.start()
        barState.contextStatus = "Focus session resumed: \(focusSession.currentGoal)"
        updateScreenMonitoringIndicator(isActive: screenMonitoring.isActive)
        Task { await CapabilityEventLogger.shared.record("focus session", "resumed") }
    }

    @objc private func endFocusSessionFromMenu() {
        focusSession.end()
        if !appState.screenMonitoringEnabled {
            screenMonitoring.stop()
        }
        if !appState.proactiveSuggestionsEnabled {
            contextMonitor?.stop()
        }
        barState.contextStatus = "Focus session ended. Monitoring for this session stopped."
        updateScreenMonitoringIndicator(isActive: screenMonitoring.isActive)
        Task { await CapabilityEventLogger.shared.record("focus session", "ended") }
    }

    @objc private func cycleFocusSensitivityFromMenu() {
        let all = FocusSensitivity.allCases
        let current = focusSession.sensitivity
        let nextIndex = ((all.firstIndex(of: current) ?? 1) + 1) % all.count
        let next = all[nextIndex]
        focusSession.sensitivity = next
        appState.focusSensitivity = next.rawValue
        barState.contextStatus = "Focus sensitivity set to \(next.displayName)."
        updateScreenMonitoringIndicator(isActive: screenMonitoring.isActive)
    }

    private func promptForFocusGoal() -> String? {
        let alert = NSAlert()
        alert.messageText = "Start Focus Session"
        alert.informativeText = "What should Alfred help you stay focused on?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "e.g. work on Alfred file reading"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let goal = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? nil : goal
    }

    @objc private func stopComputerControlFromMenu() {
        computerControl.cancel()
        barState.contextStatus = "Computer control stop requested."
        Task { await CapabilityEventLogger.shared.record("computer control", "stopped by menu") }
    }

    @objc private func runWorkflowDetectionFromMenu() {
        let count = workflowDetectionService?.detectWorkflows().count ?? 0
        barState.contextStatus = count > 0
            ? "Detected \(count) new workflow pattern(s)"
            : "Workflow detection complete. No new patterns found."
    }

    @objc private func listWorkflowsFromMenu() {
        let workflows = workflowDetectionService?.allWorkflows ?? []
        if workflows.isEmpty {
            barState.contextStatus = "No workflows available. Run detection first."
            return
        }
        let lines = workflows.map { "• \($0.title) (\($0.steps.count) steps, used \($0.useCount)x)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Available Workflows"
        alert.informativeText = lines
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    @objc private func runMemoryReflectionFromMenu() {
        let count = memoryReflectionService?.runReflectionNow() ?? 0
        if count > 0 {
            barState.contextStatus = "Memory reflection generated \(count) new insight(s)"
        } else {
            barState.contextStatus = "No new insights found. May need more relationship memories."
        }
    }

    @objc private func showReflectionsFromMenu() {
        let reflections = memoryReflectionService?.getReflections() ?? []
        if reflections.isEmpty {
            barState.contextStatus = "No reflections available yet."
            return
        }

        let summary = memoryReflectionService?.generateReflectionSummary() ?? "No summary available."
        let alert = NSAlert()
        alert.messageText = "Memory Reflections"
        alert.informativeText = "Generated insights from your relationship memories.\n\n\(summary)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    private var personalizationWindow: NSWindow?

    @objc private func showPersonalizationDashboardFromMenu() {
        if let existing = personalizationWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Personalization Dashboard"
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 400)

        let projects = projectAwareness?.activeProjects() ?? []
        let interests = learningService?.topInterests() ?? []
        let preferredTypes = learningService?.preferredSuggestionTypes() ?? []
        let recentEvents = learningEventLog?.recent(days: 7) ?? []
        let context = personalContextService?.structuredContext()

        let rootView = PersonalizationDashboardView(
            activeProjects: projects,
            topInterests: interests,
            preferredTypes: preferredTypes,
            recentEvents: recentEvents,
            personalContext: context,
            onShowExplanation: { _ in }
        )
        .frame(width: 440, height: 520)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        personalizationWindow = window
    }

    @objc private func testNotificationFromMenu() {
        Task {
            await CapabilityEventLogger.shared.record("notifications", "test requested")
            do {
                let sent = try await NotificationManager.shared.send(
                    title: "Alfred",
                    body: "Notifications are ready. Nothing dramatic, thankfully.",
                    identifier: "alfred.test-notification"
                )
                if !sent {
                    await MainActor.run {
                        self.barState.contextStatus = "Notifications are disabled in System Settings."
                    }
                    await CapabilityEventLogger.shared.record("notifications", "refused", detail: "permission denied")
                } else {
                    await CapabilityEventLogger.shared.record("notifications", "test sent")
                }
            } catch {
                await MainActor.run {
                    self.barState.contextStatus = "Notification failed: \(error.localizedDescription)"
                }
                await CapabilityEventLogger.shared.record("notifications", "failed")
            }
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar status item

    /// The menu-bar control (Blueprint §1). Provides the only reliable way to quit a resident,
    /// Dock-less app — required before launchd KeepAlive can be safely re-enabled.
    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.makeMenuBarIcon()
            button.toolTip = "Alfred"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Right-click menu — a reliable escape hatch to Quit even if the popover misbehaves.
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Alfred", action: #selector(showBarFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Alfred", action: #selector(quitFromMenu), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusMenu = menu
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let isRight = NSApp.currentEvent.map {
            $0.type == .rightMouseUp || $0.modifierFlags.contains(.control)
        } ?? false
        if isRight, let item = statusItem, let menu = statusMenu {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil   // reset so the next left-click opens the popover
        } else {
            togglePopover()
        }
    }

    /// The menu-bar popover panel (weather-widget style) — Alfred's control surface.
    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
            return
        }
        guard let store = memoryStore else { return }
        let panel = AlfredPanelView(
            store: store,
            onRunNow: { [weak self] routine in self?.routineScheduler?.runNow(routine) },
            onQuit: { [weak self] in self?.quitFromMenu() }
        )
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 340, height: 460)
        pop.contentViewController = NSHostingController(rootView: panel)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showBarFromMenu() { showBar() }

    // MARK: - Hotkey

    private func startHotkeyListener() {
        guard hotkeyListener == nil else { return }
        let listener = HotkeyListener { [weak self] in self?.toggleBar() }
        hotkeyListener = listener
        listener.start()
    }

    private func showBar() {
        barState.presenceState = .expanded
        barWindow?.expand(toHeight: expandedBarHeight(
            text: barState.responseText,
            isProcessing: barState.isProcessing,
            suggestions: barState.suggestions
        ))
    }

    private func toggleBar() {
        guard let window = barWindow else { return }
        switch barState.presenceState {
        case .hidden:
            contextMonitor?.refresh(forceBrowserRead: true)
            barState.presenceState = .expanded
            window.expand(toHeight: expandedBarHeight(
                text: barState.responseText,
                isProcessing: barState.isProcessing,
                suggestions: barState.suggestions
            ))
        case .collapsed:
            barState.presenceState = .expanded
            window.expand(toHeight: expandedBarHeight(
                text: barState.responseText,
                isProcessing: barState.isProcessing,
                suggestions: barState.suggestions
            ))
        case .expanded, .thinking, .responding, .listening:
            hideBar()
        }
    }

    /// Fully remove the bar from screen (hotkey-only model). The last response is kept so the
    /// conversation resumes where it left off when the bar is brought back with the shortcut.
    private func hideBar() {
        shownByHover = false
        hideOnLeaveTimer?.invalidate()
        barState.isProcessing = false
        barState.presenceState = .hidden
        barWindow?.hideImmediately()
    }

    private func dismissBar() {
        shownByHover = false
        hideOnLeaveTimer?.invalidate()
        barState.presenceState = .collapsed
        barWindow?.collapse()
    }

    // MARK: - Notch hover

    private func startNotchHoverMonitor() {
        notchHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMouseMove() }
        }
    }

    private func handleMouseMove() {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(loc, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let hoverZone = loc.y >= screen.visibleFrame.maxY - 8
            && abs(loc.x - screen.visibleFrame.midX) < 150

        if hoverZone {
            hideOnLeaveTimer?.invalidate()

            switch barState.presenceState {
            case .hidden:
                barWindow?.showCollapsed()
                fallthrough
            case .collapsed:
                shownByHover = true
                barState.presenceState = .expanded
                barWindow?.expand(toHeight: expandedBarHeight(
                    text: barState.responseText,
                    isProcessing: barState.isProcessing,
                    suggestions: barState.suggestions
                ))
            default:
                break
            }
            return
        }

        guard shownByHover else { return }

        switch barState.presenceState {
        case .expanded, .collapsed:
            let barFrame = barWindow?.frame ?? .zero
            let tolerance = barFrame.insetBy(dx: -20, dy: -20)
            if NSMouseInRect(loc, tolerance, false) {
                hideOnLeaveTimer?.invalidate()
            } else {
                scheduleHoverHide()
            }
        default:
            break
        }
    }

    private func scheduleHoverHide() {
        guard hideOnLeaveTimer?.isValid != true else { return }
        hideOnLeaveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shownByHover else { return }
                guard self.barWindow?.isKeyWindow != true else { return }
                self.shownByHover = false
                self.collapseToStrip()
            }
        }
    }

    private func collapseToStrip() {
        barState.responseText = ""
        barState.isProcessing = false
        barState.presenceState = .collapsed
        barWindow?.collapse()
    }

    // MARK: - Presence actions

    private func handleSuggestionTap(_ suggestion: ProactiveSuggestion) {
        handleQuery(suggestion.prompt)
    }

    private func handlePresenceCollapse() {
        // Escape handler: fully dismiss (hotkey-only model — same as pressing the shortcut).
        hideBar()
    }

    // MARK: - Query handling

    /// Log a synchronous bar action (text/email/file op) to the `runs` audit, deriving status from
    /// its human-readable result. These return before the dispatcher's audit, so log them directly.
    private func auditBarAction(prompt: String, result: String, commandClass: String, dataSentToCloud: String? = nil) {
        let lower = result.lowercased()
        let status: String
        if lower.contains("cancelled") {
            status = "blocked"
        } else if lower.contains("couldn't") || lower.contains("could not") || lower.contains("failed")
                    || lower.hasPrefix("invalid") || lower.hasPrefix("no ") || lower.contains("not run") {
            status = "failed"
        } else {
            status = "success"
        }
        memoryStore?.recordAction(prompt: prompt, status: status, commandClass: commandClass,
                                  outputSummary: result, dataSentToCloud: dataSentToCloud)
    }

    func handleQuery(_ text: String) {
        barState.responseText = ""
        barState.isProcessing = true
        barState.presenceState = .thinking

        // Two-turn text flow: if Alfred just asked "what to send to X", this input IS the message.
        if let recipient = pendingTextRecipient {
            pendingTextRecipient = nil
            let message = text
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.barState.responseText = self.messaging.confirmAndSend(message: message, to: recipient)
                self.auditBarAction(prompt: "text \(recipient.display): \(message)",
                                    result: self.barState.responseText, commandClass: "high-risk write")
                self.barState.isProcessing = false
                self.barState.presenceState = .expanded
            }
            return
        }

        // M6 smart dispatcher: strip polite/filler wrappers ("can you", "please", "alfred,") so
        // every capability understands intent regardless of phrasing. `cmd` drives detection and
        // execution; the raw `text` is kept only for the audit log and the literal two-turn message.
        let cmd = QueryNormalizer.normalize(text)

        // Email via Mail.app — default opens a reviewable draft; "send" + a body auto-sends (gated).
        if let intent = MailComposeCapability.detect(in: cmd) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.barState.isProcessing = false
                    self.barState.presenceState = .expanded
                }
                guard let r = await self.mailCompose.resolveEmail(for: intent.recipient) else {
                    self.barState.responseText = MessagingCapability.contactsAccessDenied()
                        ? "Alfred doesn't have Contacts access. Grant it in System Settings → Privacy & Security → Contacts, or use a full email address."
                        : "Couldn't find an email for \"\(intent.recipient)\" — try a full email address."
                    return
                }
                self.barState.responseText = self.mailCompose.compose(
                    to: r.email, display: r.display, subject: intent.subject, body: intent.body, send: intent.send)
                self.auditBarAction(prompt: cmd, result: self.barState.responseText, commandClass: "high-risk write")
            }
            return
        }

        // "text <name> [saying <msg>]" — send an iMessage to a named contact.
        if let intent = MessagingCapability.detect(in: cmd) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Always stop "thinking", whatever path we take.
                defer {
                    self.barState.isProcessing = false
                    self.barState.presenceState = .expanded
                }
                guard let recipient = await self.messaging.resolveRecipient(for: intent.name) else {
                    self.barState.responseText = MessagingCapability.contactsAccessDenied()
                        ? "Alfred doesn't have Contacts access. Grant it in System Settings → Privacy & Security → Contacts, then try again."
                        : "Couldn't find \"\(intent.name)\" in Contacts — try a phone number or email."
                    return
                }
                if let message = intent.message {
                    self.barState.responseText = self.messaging.confirmAndSend(message: message, to: recipient)
                    self.auditBarAction(prompt: cmd, result: self.barState.responseText, commandClass: "high-risk write")
                } else {
                    self.pendingTextRecipient = recipient
                    self.barState.responseText = "What would you like to send to \(recipient.display)?"
                }
            }
            return
        }

        // Open the Routines manager (Blueprint §3) from the bar.
        let normalizedQuery = cmd.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["routines", "show routines", "manage routines", "open routines", "my routines", "panel"].contains(normalizedQuery) {
            barState.responseText = "Opening the Alfred panel from the menu bar…"
            barState.isProcessing = false
            barState.presenceState = .expanded
            togglePopover()
            return
        }

        // Open the Full Disk Access pane so Alfred can reach every folder without per-folder prompts.
        if ["full disk access", "grant full disk access", "grant full access", "file permissions",
            "grant permissions", "give alfred full access"].contains(normalizedQuery) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            barState.responseText = "Opening Full Disk Access. Click +, add Alfred (/Applications/Alfred.app), turn it on, then relaunch Alfred. That gives Alfred access to every folder on your Mac."
            barState.isProcessing = false
            barState.presenceState = .expanded
            return
        }

        // Writing-style personalization (M8): record the user's message on-device to build their
        // style profile — independent of the broad learning gate. This is a local SQLite write; it
        // never egresses. The derived style summary is injected into prompts via ContextCompiler.
        if FeatureScope.personalizationEnabled {
            writingStyleStore?.recordWritingSample(text: text, source: .chat)
        }

        // Blueprint v1 quarantine: behavioral-learning ingestion is off in v1 scope.
        if FeatureScope.learningEnabled {
        learningService?.recordQueryAccepted(text, context: lastContextForLearning)
        if let engine = adaptiveEngine {
            let cat = engine.category(for: ProactiveSuggestion(id: "", title: text, prompt: "", icon: ""))
            engine.recordAccepted(category: cat)
        }
        projectAwareness?.ingestQuery(text, context: lastContextForLearning)
        memoryStore?.relationshipStore.processText(text, source: .chat)

        // Feed query into relationship memory (preferences, workflows)
        let lowered = text.lowercased()
        if lowered.contains("prefer") || lowered.contains("like when") || lowered.contains("always") {
            relationshipMemoryService?.forceSave(text, category: .preferences, source: "query",
                                                  reasonSaved: "User stated a preference")
        }
        if lowered.contains("goal") || lowered.contains("aim to") || lowered.contains("want to") ||
           lowered.contains("trying to") || lowered.contains("plan to") {
            relationshipMemoryService?.forceSave(text, category: .goals, source: "query",
                                                  reasonSaved: "User stated a goal")
        }
        if lowered.contains("always have to") || lowered.contains("keep") || lowered.contains("recurring") {
            relationshipMemoryService?.considerMention(text, category: .recurringProblems, source: "query")
        }
        if lowered.contains("learning") || lowered.contains("getting better at") || lowered.contains("skill") {
            relationshipMemoryService?.considerMention(text, category: .skills, source: "query")
        }
        if lowered.contains("process") || lowered.contains("workflow") || lowered.contains("step") {
            relationshipMemoryService?.considerMention(text, category: .workflows, source: "query")
        }
        }

        let selectedFiles = selectedFileContext.snapshot()

        do {
            let planner = WorkflowPlanner(computerControl: computerControl)
            if let workflowPlan = try planner.makePlan(
                from: cmd,
                selectedFiles: selectedFiles,
                shellExecutionEnabled: appState.shellExecutionEnabled
            ) {
                Task { await CapabilityEventLogger.shared.record("workflow", "requested") }
                handleWorkflow(plan: workflowPlan, selectedFiles: selectedFiles)
                return
            }
        } catch {
            Task { await CapabilityEventLogger.shared.record("workflow", "refused", detail: error.localizedDescription) }
            barState.responseText = "Workflow not run: \(error.localizedDescription)"
            barState.isProcessing = false
            return
        }

        do {
            // Blueprint v1 scope: computer control is a gated Phase 2 capability.
            if FeatureScope.computerControlEnabled,
               let computerPlan = try computerControl.makePlan(from: text) {
                Task { await CapabilityEventLogger.shared.record("computer control", "requested") }
                handleComputerControl(plan: computerPlan, originalQuery: text)
                return
            }
        } catch {
            Task { await CapabilityEventLogger.shared.record("computer control", "refused") }
            barState.responseText = "Computer control not run: \(error.localizedDescription)"
            barState.isProcessing = false
            return
        }

        // File operations (organize/move/rename/delete) — interactive, explicit selection via
        // NSOpenPanel, confirmed, security-scoped. Never trusts paths typed into the prompt.
        if let op = FileOperationCapability.detect(in: cmd) {
            Task { await CapabilityEventLogger.shared.record("file operation", "requested") }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.fileOperation.handle(op, query: cmd)
                self.barState.responseText = result
                self.auditBarAction(prompt: cmd, result: result, commandClass: "file write")
                self.barState.isProcessing = false
                self.barState.presenceState = .expanded
            }
            return
        }

        // Blueprint v1 §4 two-stage brain: the dispatcher proposes (command class + route);
        // policy disposes (confirm high-risk). §8: audit every command.
        let decision = Dispatcher().decide(
            query: cmd,
            providerIsCloud: llmRouter?.isActiveProviderCloud ?? false
        )
        let runId = memoryStore?.startRun(source: "bar", prompt: text)
        let alreadyConfirmsElsewhere =
            QueryIntent.analyze(decision.query).shellCommand != nil
            || QueryIntent.analyze(decision.query).appControlQuery != nil
        if decision.confirmRequired && !alreadyConfirmsElsewhere {
            guard confirmHighRisk(decision) else {
                barState.responseText = "Cancelled — \(decision.commandClass.rawValue) needs confirmation."
                barState.isProcessing = false
                if let runId {
                    memoryStore?.completeRun(
                        id: runId, status: "blocked",
                        routeReason: decision.routeReason,
                        commandClass: decision.commandClass.rawValue,
                        errorText: "User declined confirmation"
                    )
                }
                return
            }
        }

        let ownerName = appState.ownerName
        let screenContextEnabled = appState.screenContextEnabled
        let shellExecutionEnabled = appState.shellExecutionEnabled
        let memoryExtractionEnabled = appState.memoryExtractionEnabled
        let conversationHistoryEnabled = appState.conversationHistoryEnabled
        let memoryRetentionDays = appState.memoryRetentionDays
        let core = assistantCore
        let router = llmRouter
        let memory = memoryStore

        // App control (open/launch/activate/hide/quit) is a low-risk write — run it without a
        // confirmation prompt (Blueprint §7: only high-risk writes — delete/send/shell — confirm).
        if QueryIntent.analyze(decision.query).appControlQuery != nil {
            Task { await CapabilityEventLogger.shared.record("app control", "requested") }
        }

        if let command = QueryIntent.analyze(decision.query).shellCommand {
            guard confirmShellCommand(command) else {
                barState.responseText = "Shell command cancelled."
                barState.isProcessing = false
                Task { await CapabilityEventLogger.shared.record("shell", "cancelled by user") }
                return
            }
            Task { await CapabilityEventLogger.shared.record("shell", "confirmed") }
        }

        Task {
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.barState.isProcessing = false
                    if self.barState.presenceState == .thinking || self.barState.presenceState == .responding {
                        self.barState.presenceState = .expanded
                    }
                }
            }

            do {
                if let core {
                    _ = try await core.process(
                        query: decision.query,
                        ownerName: ownerName,
                        screenContextEnabled: screenContextEnabled,
                        shellExecutionEnabled: shellExecutionEnabled,
                        memoryExtractionEnabled: memoryExtractionEnabled,
                        selectedFiles: selectedFiles,
                        conversationHistoryEnabled: conversationHistoryEnabled,
                        memoryRetentionDays: memoryRetentionDays
                    ) { [weak self] token in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if self.barState.presenceState == .thinking {
                                self.barState.presenceState = .responding
                            }
                            self.barState.responseText += token
                        }
                    }
                } else if let router {
                    // Fallback when MemoryStore failed to init
                    let now = ISO8601DateFormatter().string(from: Date())
                    _ = try await router.streamWithTools(
                        messages: [.user(text)],
                        system: AssistantPersona.systemIntro(ownerName: ownerName, currentDate: now),
                        tools: [LLMTool.openApplication.payload],
                        executeToolCall: AppControlCapability.executeToolCall
                    ) { [weak self] token in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if self.barState.presenceState == .thinking {
                                self.barState.presenceState = .responding
                            }
                            self.barState.responseText += token
                        }
                    }
                } else {
                    await MainActor.run { [weak self] in
                        self?.barState.responseText = "Alfred is not ready. Check your API key in Settings."
                    }
                }

                // Blueprint v1 §8: finalize the audit row + render the §3 routing line.
                if core != nil || router != nil {
                    let snapshot: (model: String, egress: String, full: String)? = await MainActor.run { [weak self] () -> (model: String, egress: String, full: String)? in
                        guard let self else { return nil }
                        let model = router?.activeProvider.id ?? ""
                        let egress = router?.lastEgressSummary ?? ""
                        // The model can return an empty completion (e.g. ambiguous input like
                        // "6!?"). Show an explicit message so the bar never looks dead.
                        if self.barState.responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.barState.responseText = "I'm sorry, but I don't have an answer for that."
                        }
                        // Transparency (model / route / redaction) is recorded in the runs
                        // audit row below; it is intentionally NOT shown in the bar.
                        return (model, egress, self.barState.responseText)
                    }
                    if let snapshot, let runId {
                        memory?.completeRun(
                            id: runId, status: "success",
                            modelUsed: snapshot.model,
                            routeReason: decision.routeReason,
                            commandClass: decision.commandClass.rawValue,
                            outputFull: snapshot.full,
                            outputSummary: String(snapshot.full.prefix(200)),
                            dataSentToCloud: snapshot.egress
                        )
                    }
                }
            } catch {
                if let runId {
                    let blocked = (error as? LLMRouter.EgressError) != nil
                    memory?.completeRun(
                        id: runId, status: blocked ? "blocked" : "failed",
                        modelUsed: router?.activeProvider.id,
                        routeReason: decision.routeReason,
                        commandClass: decision.commandClass.rawValue,
                        errorText: error.localizedDescription,
                        dataSentToCloud: router?.lastEgressSummary ?? ""
                    )
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let router = self.llmRouter
                    let providerId = router?.activeProvider.id ?? ""
                    if providerId == "local", self.isLocalConnectionError(error) {
                        self.barState.responseText = "Alfred's local model isn't ready yet.\n\nThe server is starting up in the background (it loads the model on first request and can take 10–30s). Try again in a moment.\n\nIf it never connects, run:\npython3 'Fine tuned model for alfred/local_alfred_server.py'"
                    } else {
                        self.barState.responseText = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func handleWorkflow(plan: WorkflowPlan, selectedFiles: SelectedFileSnapshot) {
        guard confirmWorkflow(plan: plan) else {
            barState.responseText = "Workflow cancelled."
            barState.isProcessing = false
            Task { await CapabilityEventLogger.shared.record("workflow", "cancelled by user") }
            memoryStore?.learningLoopStore.recordWorkflowCancelled()
            return
        }
        Task { await CapabilityEventLogger.shared.record("workflow", "started", detail: "\(plan.steps.count) step(s)") }

        let ownerName = appState.ownerName
        let screenContextEnabled = appState.screenContextEnabled
        let shellExecutionEnabled = appState.shellExecutionEnabled
        let memoryExtractionEnabled = appState.memoryExtractionEnabled
        let conversationHistoryEnabled = appState.conversationHistoryEnabled
        let memoryRetentionDays = appState.memoryRetentionDays
        let core = assistantCore

        barState.responseText = "Starting workflow...\n\(plan.summary)"

        Task {
            defer {
                Task { @MainActor [weak self] in
                    self?.barState.isProcessing = false
                }
            }

            guard let core else {
                await MainActor.run { [weak self] in
                    self?.barState.responseText = "Workflow not run: Alfred is not ready."
                }
                return
            }

            do {
                _ = try await core.processWorkflow(
                    plan: plan,
                    ownerName: ownerName,
                    screenContextEnabled: screenContextEnabled,
                    shellExecutionEnabled: shellExecutionEnabled,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    selectedFiles: selectedFiles,
                    conversationHistoryEnabled: conversationHistoryEnabled,
                    memoryRetentionDays: memoryRetentionDays
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.barState.contextStatus = progress
                    }
                } onToken: { [weak self] token in
                    Task { @MainActor [weak self] in
                        self?.barState.responseText = token
                    }
                }
                await CapabilityEventLogger.shared.record("workflow", "completed")
                let planCopy = plan
                await MainActor.run { [weak self] in
                    self?.recordWorkflowExecution(planCopy)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.barState.responseText = "Workflow error: \(error.localizedDescription)"
                }
                await CapabilityEventLogger.shared.record("workflow", "failed")
            }
        }
    }

    private func recordWorkflowExecution(_ plan: WorkflowPlan) {
        let stepCount = plan.steps.count
        memoryStore?.timelineStore.recordEvent(
            type: .workflowExecuted,
            applicationName: "Alfred",
            metadata: ["steps": "\(stepCount)", "summary": String(plan.summary.prefix(200))]
        )
        memoryStore?.learningLoopStore.recordWorkflowCompleted(
            metadata: ["steps": "\(stepCount)", "summary": String(plan.summary.prefix(100))]
        )
    }

    private func confirmWorkflow(plan: WorkflowPlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run this Alfred workflow?"
        alert.informativeText = """
        Proposed plan:

        \(plan.summary)

        Side-effect steps: \(plan.sideEffectCount). Alfred will still use native confirmation panels for file saves and existing permission checks for app, shell, or computer-control actions.
        """
        alert.alertStyle = plan.sideEffectCount > 1 ? .warning : .informational
        alert.addButton(withTitle: "Run Workflow")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmHighRisk(_ decision: DispatchDecision) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Confirm this \(decision.commandClass.rawValue)?"
        alert.informativeText = decision.query
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Proceed")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmShellCommand(_ command: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run this shell command?"
        alert.informativeText = """
        Alfred will execute this command with /bin/bash -c:

        \(command)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run Command")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func pruneConversationHistoryNow() {
        do {
            try memoryStore?.pruneConversationHistory(olderThanDays: appState.memoryRetentionDays)
            barState.contextStatus = "Conversation history pruned."
        } catch {
            barState.contextStatus = "Could not prune conversation history: \(error.localizedDescription)"
        }
    }

    func clearConversationHistoryFromSettings() {
        guard confirmDestructiveSettingsAction(
            title: "Clear conversation history?",
            message: "This deletes saved user and assistant messages from Alfred memory. Extracted memories remain."
        ) else { return }

        do {
            try memoryStore?.clearHistory()
            barState.contextStatus = "Conversation history cleared."
        } catch {
            barState.contextStatus = "Could not clear conversation history: \(error.localizedDescription)"
        }
    }

    func clearExtractedMemoriesFromSettings() {
        guard confirmDestructiveSettingsAction(
            title: "Clear extracted memories?",
            message: "This deletes saved long-term memory facts. Conversation history remains."
        ) else { return }

        do {
            try memoryStore?.clearMemories()
            barState.contextStatus = "Extracted memories cleared."
        } catch {
            barState.contextStatus = "Could not clear extracted memories: \(error.localizedDescription)"
        }
    }

    private func confirmDestructiveSettingsAction(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleComputerControl(plan: ComputerControlCapability.Plan, originalQuery: String) {
        guard computerControl.hasAccessibilityPermission else {
            computerControl.requestAccessibilityPermission()
            barState.responseText = "Accessibility permission is required for computer control. Grant access in System Settings, then try again."
            barState.isProcessing = false
            Task { await CapabilityEventLogger.shared.record("computer control", "refused", detail: "accessibility missing") }
            return
        }

        guard confirmComputerControl(plan: plan) else {
            barState.responseText = "Computer control cancelled."
            barState.isProcessing = false
            Task { await CapabilityEventLogger.shared.record("computer control", "cancelled by user") }
            return
        }

        Task { await CapabilityEventLogger.shared.record("computer control", "confirmed", detail: "\(plan.actions.count) action(s)") }
        barState.responseText = "Running computer control...\n\(plan.summary)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.barState.isProcessing = false }
            do {
                let message = try await self.computerControl.execute(plan) { [weak self] step in
                    self?.barState.contextStatus = "Computer control: \(step)"
                }
                self.barState.responseText = message
                self.barState.contextStatus = message
                await CapabilityEventLogger.shared.record("computer control", "completed")
            } catch {
                self.barState.responseText = "Computer control stopped: \(error.localizedDescription)"
                self.barState.contextStatus = "Computer control stopped."
                await CapabilityEventLogger.shared.record("computer control", "stopped")
            }
        }
    }

    private func confirmComputerControl(plan: ComputerControlCapability.Plan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow Alfred to control this Mac?"
        alert.informativeText = """
        Alfred will run these bounded actions now:

        \(plan.summary)

        Press Esc or use Stop Computer Control from the menu to cancel while actions are running.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run Actions")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Onboarding

    private func observeOnboardingCompletion() {
        appState.$isOnboardingComplete
            .dropFirst()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.startHotkeyListener()
                self?.startRoutineScheduler()
            }
            .store(in: &cancellables)
    }

    func showOnboarding(initialStep: Int = 0) {
        // Reuse existing window — always replace content so step is correct
        if let existing = onboardingWindow {
            existing.contentView = NSHostingView(
                rootView: OnboardingView(initialStep: initialStep)
                    .environmentObject(appState)
            )
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            existing.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Alfred Setup"
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OnboardingView(initialStep: initialStep)
                .environmentObject(appState)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    // MARK: - Proactive Memory Surfacing

    private weak var proactiveMenuItem: NSMenuItem?

    private func updateProactiveBadge(hasActive: Bool) {
    }

    @objc private func toggleProactiveSuggestionsFromMenu() {
        appState.proactiveSuggestionsEnabled.toggle()
        proactiveSurfacingService?.proactiveEnabled = appState.proactiveSuggestionsEnabled
        barState.contextStatus = appState.proactiveSuggestionsEnabled
            ? "Proactive suggestions enabled"
            : "Proactive suggestions disabled"
    }

    @objc private func showProactiveSuggestionsFromMenu() {
        let suggestions = proactiveSurfacingService?.forceCheck() ?? []
        if suggestions.isEmpty {
            barState.contextStatus = "No proactive suggestions available right now."
            return
        }
        let lines = suggestions.map { "• \($0.title): \($0.subtitle)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Proactive Suggestions"
        alert.informativeText = lines
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Dismiss All")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            for s in suggestions {
                proactiveSurfacingService?.dismissSuggestion(id: s.id)
            }
            barState.contextStatus = "Suggestions dismissed."
        }
    }

    // MARK: - Memory Dashboard

    @objc private func openMemoryDashboardFromMenu() {
        MemoryDashboardController.shared.showDashboard()
    }

    @objc private func exportAllMemoriesFromMenu() {
        guard let relationshipMemoryService else {
            barState.contextStatus = "Memory service unavailable."
            return
        }
        guard let json = relationshipMemoryService.exportToJSON(includeArchived: false) else {
            barState.contextStatus = "No memories to export."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Memories"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "alfred_memories_\(ISO8601DateFormatter().string(from: Date())).json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try json.write(to: url, atomically: true, encoding: String.Encoding.utf8)
            barState.contextStatus = "Memories exported to \(url.lastPathComponent)"
        } catch {
            barState.contextStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    @objc private func clearAllMemoriesFromMenu() {
        let alert = NSAlert()
        alert.messageText = "Delete all relationship memories?"
        alert.informativeText = "This cannot be undone. All relationship memories and reflections will be permanently deleted."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete All")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        relationshipMemoryService?.deleteAllMemories(includeArchived: true)
        memoryReflectionService?.resetAll()
        barState.contextStatus = "All memories cleared."
    }

    @objc private func exportTrainingDataFromMenu() {
        guard let store = memoryStore else {
            barState.contextStatus = "Memory store unavailable."
            return
        }
        let exporter = TrainingDatasetExporter(
            learningLoopStore: store.learningLoopStore,
            writingStyleStore: store.writingStyleStore!,
            rewardEngine: store.rewardEngine
        )
        do {
            let url = try exporter.exportToJSONL()
            let alert = NSAlert()
            alert.messageText = "Training Data Exported"
            alert.informativeText = "Exported to:\n\(url.path)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            barState.contextStatus = "Training data exported to \(url.lastPathComponent)"
        } catch {
            barState.contextStatus = "Training export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Backup

    @objc private func backupNowFromMenu() {
        guard let bs = backupService else {
            barState.contextStatus = "Backup service unavailable."
            return
        }
        let meta = bs.createBackup(encrypted: false)
        if meta != nil {
            barState.contextStatus = "Backup created: \(meta!.filename)"
        } else {
            barState.contextStatus = "Backup failed."
        }
    }

    @objc private func toggleAutoBackupFromMenu() {
        guard let bs = backupService else { return }
        bs.autoBackupEnabled.toggle()
        if bs.autoBackupEnabled {
            bs.startAutoBackup()
        } else {
            bs.stopAutoBackup()
        }
        barState.contextStatus = bs.autoBackupEnabled ? "Auto-backup enabled" : "Auto-backup disabled"
    }

    @objc func exportForSyncFromMenu() {
        guard let bs = backupService else {
            barState.contextStatus = "Backup service unavailable."
            return
        }
        guard let data = bs.exportForSync() else {
            barState.contextStatus = "Export failed."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export for Sync"
        panel.nameFieldStringValue = "alfred_sync_backup.\(bs.encryptByDefault ? "alfredbackup" : "json")"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            barState.contextStatus = "Sync export saved to \(url.lastPathComponent)"
        } catch {
            barState.contextStatus = "Export failed: \(error.localizedDescription)"
        }
}

}


