import AppKit
import SwiftUI

/// What the menu-bar popover shows.
///
/// Settings are deliberately bare now: every capability is on by design and
/// stays on. Alfred can use the screen, the terminal, and the mail watcher
/// without toggles — the only choices are showing the bar, the API key
/// ring, and quitting.
@MainActor
final class SettingsModel: ObservableObject {
    let keys = ProviderKeyRing.shared

    @Published var newKey = ""
    @Published var newKeyLabel = ""
    @Published var newKeyProvider: LLMProvider = .gemini

    /// Cloud or local — the only model choice there is. Switching persists the
    /// choice, writes Hermes' config, and restarts the session so the next turn
    /// runs on the newly selected model world.
    @Published var modelMode: ModelMode {
        didSet {
            guard modelMode != oldValue else { return }
            UserDefaults.standard.set(modelMode.rawValue, forKey: ProviderKeyRing.modelModeKey)
            ProviderKeyRing.shared.applyModelMode(modelMode)
            Task { @MainActor in
                await AppDelegate.shared?.hermes.restart()
            }
        }
    }

    init() {
        modelMode = ProviderKeyRing.persistedModelMode()
        tokenCompressionEnabled = HeadroomMCPClient.shared.isEnabled
        compressionLevel = HeadroomMCPClient.shared.compressionLevel
        codeGraphEnabled = CodeGraphManager.shared.isEnabled
        codeGraphIndexOnLoad = CodeGraphManager.shared.indexOnLoad
        understandEnabled = UnderstandAnythingManager.shared.isEnabled
        understandIndexOnLoad = UnderstandAnythingManager.shared.indexOnLoad
        let nyuSettings = NYUIntegrationManager.shared.settings
        nyuEnabled = nyuSettings.enabled
        nyuCanvasToken = nyuSettings.canvasToken
        nyuTargetGPA = nyuSettings.targetGPA
        nyuRemind24h = nyuSettings.remind24h
        nyuRemind1h = nyuSettings.remind1h
        nyuCalendarSync = nyuSettings.calendarSyncEnabled
        nyuSyncFrequency = nyuSettings.syncFrequencyHours
        browserAutomationEnabled = BrowserUseClient.shared.isEnabled
        browserRequireConfirmation = BrowserUseClient.shared.requireConfirmation
        scrapingEnabled = CrawleeClient.shared.isEnabled
        scrapeMode = CrawleeClient.shared.mode
        scrapeCacheDuration = CrawleeClient.shared.cacheDuration
        tasteEnabled = TasteSkillManager.shared.isEnabled
        tasteAggressiveness = TasteSkillManager.shared.aggressiveness
        tasteVoice = TasteSkillManager.shared.voice
        tasteScopes = TasteSkillManager.shared.scopes
        multiAgentEnabled = MultiAgentOrchestrator.shared.enabled
        multiAgentParallelization = MultiAgentOrchestrator.shared.parallelization
        multiAgentTimeout = MultiAgentOrchestrator.shared.timeout
        presentationDefaultSlides = PresentationGeneratorSkill.shared.defaultSlides
        presentationStyle = PresentationGeneratorSkill.shared.styleID
        presentationIncludeNotes = PresentationGeneratorSkill.shared.includeNotes
        presentationExportFormat = PresentationGeneratorSkill.shared.exportFormat
        memoryEnabled = MemPalaceManager.shared.settings.enabled
        memoryLearningMode = MemPalaceManager.shared.settings.learningMode
        memoryDecayRate = MemPalaceManager.shared.settings.decayRate
        memoryConfidenceThreshold = MemPalaceManager.shared.settings.confidenceThreshold
        memoryExcludedCategories = MemPalaceManager.shared.settings.excludedCategories
        let homework = HomeworkAssistantSkill.shared.settings
        homeworkEnabled = homework.enabled
        homeworkDefaultMode = homework.defaultMode
        homeworkCodeStyle = homework.codeStyle
        homeworkShowSteps = homework.showSteps
        homeworkDifficulty = homework.difficulty
        homeworkFormat = homework.format
    }

    /// Browser automation (browser-use): Alfred's own deterministic web
    /// automation — routines that check a page, the newsletter sign-up skill.
    /// Off by default (automation touching real websites is opt-in); Hermes'
    /// own browser MCP tools are governed by Hermes' permission system and are
    /// not this switch. Persisted through BrowserUseClient.
    @Published var browserAutomationEnabled: Bool {
        didSet {
            guard browserAutomationEnabled != oldValue else { return }
            BrowserUseClient.shared.isEnabled = browserAutomationEnabled
        }
    }

    /// Gate on form submission: on = Alfred fills forms but never clicks
    /// submit without explicit confirmation. Persisted through BrowserUseClient.
    @Published var browserRequireConfirmation: Bool {
        didSet {
            guard browserRequireConfirmation != oldValue else { return }
            BrowserUseClient.shared.requireConfirmation = browserRequireConfirmation
        }
    }

    /// One-line status for the browser section: installed + Chrome caveat, or
    /// the setup hint.
    var browserStatus: String {
        if BrowserUseClient.shared.isAvailable {
            return BrowserUseClient.shared.isEnabled
                ? "Ready — Chrome must be running for tasks"
                : "Installed — off"
        }
        return "Not installed — run agent-bridge/setup.sh"
    }

    /// Web scraping (Crawlee): Alfred's lightweight, read-only page fetches —
    /// routine steps that scrape a page or search results. On by default
    /// (plain GET requests, unlike browser automation which fills forms).
    /// Persisted through CrawleeClient.
    @Published var scrapingEnabled: Bool {
        didSet {
            guard scrapingEnabled != oldValue else { return }
            CrawleeClient.shared.isEnabled = scrapingEnabled
        }
    }

    /// Engine for new scrapes: http (fast, no JS) or chromium (renders JS).
    /// Persisted through CrawleeClient.
    @Published var scrapeMode: ScrapeMode {
        didSet {
            guard scrapeMode != oldValue else { return }
            CrawleeClient.shared.mode = scrapeMode
        }
    }

    /// How long a scrape result stays cached before a routine re-fetches.
    /// Persisted through CrawleeClient.
    @Published var scrapeCacheDuration: ScrapeCacheDuration {
        didSet {
            guard scrapeCacheDuration != oldValue else { return }
            CrawleeClient.shared.cacheDuration = scrapeCacheDuration
        }
    }

    /// One-line status for the scraping section: installed or the setup hint.
    var scrapingStatus: String {
        if CrawleeClient.shared.isAvailable {
            return CrawleeClient.shared.isEnabled
                ? "Ready — \(scrapeMode.displayName.lowercased())"
                : "Installed — off"
        }
        return "Not installed — run agent-bridge/setup.sh"
    }

    /// Taste (anti-slop text): rewrite generic AI output with specificity and
    /// the owner's voice. On by default; the deterministic boringness check
    /// decides what's worth a model turn, so specific writing is never touched.
    /// Persisted through TasteSkillManager.
    @Published var tasteEnabled: Bool {
        didSet {
            guard tasteEnabled != oldValue else { return }
            TasteSkillManager.shared.isEnabled = tasteEnabled
        }
    }

    /// How hard the rewrite pushes: conservative (worst offenders only) →
    /// aggressive (anything with a whiff of boilerplate). Persisted through
    /// TasteSkillManager.
    @Published var tasteAggressiveness: TasteAggressiveness {
        didSet {
            guard tasteAggressiveness != oldValue else { return }
            TasteSkillManager.shared.aggressiveness = tasteAggressiveness
        }
    }

    /// Whose voice the rewrite lands in. Persisted through TasteSkillManager.
    @Published var tasteVoice: TasteVoice {
        didSet {
            guard tasteVoice != oldValue else { return }
            TasteSkillManager.shared.voice = tasteVoice
        }
    }

    /// What a polish pass may touch. Persisted through TasteSkillManager.
    @Published var tasteScopes: [TasteScope] {
        didSet {
            guard tasteScopes != oldValue else { return }
            TasteSkillManager.shared.scopes = tasteScopes
        }
    }

    /// One-line status for the taste section.
    var tasteStatus: String {
        guard TasteSkillManager.shared.isEnabled else { return "Off" }
        return "On — \(TasteSkillManager.shared.aggressiveness.displayName.lowercased())"
    }

    /// A binding into the scope set for one scope's toggle.
    func binding(for scope: TasteScope) -> Binding<Bool> {
        Binding(
            get: { self.tasteScopes.contains(scope) },
            set: { included in
                var updated = self.tasteScopes
                if included {
                    if !updated.contains(scope) { updated.append(scope) }
                } else {
                    updated.removeAll { $0 == scope }
                }
                self.tasteScopes = updated
            })
    }

    /// Multi-agent team: whether requests spawn specialized agents, and how
    /// they run. Persisted through MultiAgentOrchestrator, which also owns the
    /// routing decision for each query.
    @Published var multiAgentEnabled: Bool {
        didSet {
            guard multiAgentEnabled != oldValue else { return }
            MultiAgentOrchestrator.shared.enabled = multiAgentEnabled
        }
    }

    @Published var multiAgentParallelization: MultiAgentParallelization {
        didSet {
            guard multiAgentParallelization != oldValue else { return }
            MultiAgentOrchestrator.shared.parallelization = multiAgentParallelization
        }
    }

    @Published var multiAgentTimeout: AgentTimeout {
        didSet {
            guard multiAgentTimeout != oldValue else { return }
            MultiAgentOrchestrator.shared.timeout = multiAgentTimeout
        }
    }

    /// One-line status for the multi-agent section.
    var multiAgentStatus: String {
        guard MultiAgentOrchestrator.shared.enabled else { return "Off" }
        return "On — \(MultiAgentOrchestrator.shared.parallelization.displayName.lowercased())"
    }

    /// Presentations: default deck length, design style, speaker notes and
    /// export format. Persisted through PresentationGeneratorSkill, which also
    /// learns the user's style from deck history (StyleMatcher).
    @Published var presentationDefaultSlides: Int {
        didSet {
            guard presentationDefaultSlides != oldValue else { return }
            PresentationGeneratorSkill.shared.defaultSlides = presentationDefaultSlides
        }
    }

    @Published var presentationStyle: String {
        didSet {
            guard presentationStyle != oldValue else { return }
            PresentationGeneratorSkill.shared.styleID = presentationStyle
        }
    }

    @Published var presentationIncludeNotes: Bool {
        didSet {
            guard presentationIncludeNotes != oldValue else { return }
            PresentationGeneratorSkill.shared.includeNotes = presentationIncludeNotes
        }
    }

    @Published var presentationExportFormat: PresentationExportFormat {
        didSet {
            guard presentationExportFormat != oldValue else { return }
            PresentationGeneratorSkill.shared.exportFormat = presentationExportFormat
        }
    }

    /// One-line status for the presentations section.
    var presentationStatus: String {
        let decks = PresentationGeneratorSkill.shared.records().count
        return decks == 1 ? "1 deck made" : "\(decks) decks made"
    }

    /// MemPalace (persistent memory): whether the layer is on, how eagerly it
    /// learns, how fast memories decay, the confidence bar for use, and which
    /// categories are privacy-excluded. Persisted through MemPalaceManager.
    @Published var memoryEnabled: Bool {
        didSet {
            guard memoryEnabled != oldValue else { return }
            MemPalaceManager.shared.updateSettings { $0.enabled = memoryEnabled }
        }
    }

    @Published var memoryLearningMode: MemoryLearningMode {
        didSet {
            guard memoryLearningMode != oldValue else { return }
            MemPalaceManager.shared.updateSettings { $0.learningMode = memoryLearningMode }
        }
    }

    @Published var memoryDecayRate: MemoryDecayRate {
        didSet {
            guard memoryDecayRate != oldValue else { return }
            MemPalaceManager.shared.updateSettings { $0.decayRate = memoryDecayRate }
        }
    }

    @Published var memoryConfidenceThreshold: Double {
        didSet {
            guard memoryConfidenceThreshold != oldValue else { return }
            MemPalaceManager.shared.updateSettings { $0.confidenceThreshold = memoryConfidenceThreshold }
        }
    }

    @Published var memoryExcludedCategories: [MemoryCategory] {
        didSet {
            guard memoryExcludedCategories != oldValue else { return }
            MemPalaceManager.shared.updateSettings { $0.excludedCategories = memoryExcludedCategories }
        }
    }

    /// One-line status for the memory section.
    var memoryStatus: String {
        guard MemPalaceManager.shared.settings.enabled else { return "Off" }
        return "On — \(MemPalaceManager.shared.settings.learningMode.displayName.lowercased())"
    }

    /// A binding into the excluded-category set for one category's toggle.
    func memoryBinding(for category: MemoryCategory) -> Binding<Bool> {
        Binding(
            get: { self.memoryExcludedCategories.contains(category) },
            set: { excluded in
                var updated = self.memoryExcludedCategories
                if excluded {
                    if !updated.contains(category) { updated.append(category) }
                } else {
                    updated.removeAll { $0 == category }
                }
                self.memoryExcludedCategories = updated
            })
    }

    /// Homework Assistant: whether the solver is on, which mode wins by
    /// default (teach vs submit), how code is written, how much working to
    /// show, how hard, and the output format. Persisted through
    /// HomeworkAssistantSkill.
    @Published var homeworkEnabled: Bool {
        didSet {
            guard homeworkEnabled != oldValue else { return }
            HomeworkAssistantSkill.shared.isEnabled = homeworkEnabled
        }
    }

    @Published var homeworkDefaultMode: HomeworkMode {
        didSet {
            guard homeworkDefaultMode != oldValue else { return }
            HomeworkAssistantSkill.shared.defaultMode = homeworkDefaultMode
        }
    }

    @Published var homeworkCodeStyle: HomeworkCodeStyle {
        didSet {
            guard homeworkCodeStyle != oldValue else { return }
            HomeworkAssistantSkill.shared.codeStyle = homeworkCodeStyle
        }
    }

    @Published var homeworkShowSteps: HomeworkShowSteps {
        didSet {
            guard homeworkShowSteps != oldValue else { return }
            HomeworkAssistantSkill.shared.showSteps = homeworkShowSteps
        }
    }

    @Published var homeworkDifficulty: HomeworkDifficulty {
        didSet {
            guard homeworkDifficulty != oldValue else { return }
            HomeworkAssistantSkill.shared.difficulty = homeworkDifficulty
        }
    }

    @Published var homeworkFormat: HomeworkFormat {
        didSet {
            guard homeworkFormat != oldValue else { return }
            HomeworkAssistantSkill.shared.format = homeworkFormat
        }
    }

    /// One-line status for the homework section.
    var homeworkStatus: String {
        guard HomeworkAssistantSkill.shared.isEnabled else { return "Off" }
        return "On — \(HomeworkAssistantSkill.shared.defaultMode.displayName.lowercased())"
    }

    /// Code graph (CodeGraph): index projects so coding agents answer from a
    /// prebuilt graph instead of crawling files. Persisted through
    /// CodeGraphManager, which also decides whether sessions get the MCP tools.
    @Published var codeGraphEnabled: Bool {
        didSet {
            guard codeGraphEnabled != oldValue else { return }
            CodeGraphManager.shared.setEnabled(codeGraphEnabled)
        }
    }

    @Published var codeGraphIndexOnLoad: Bool {
        didSet {
            guard codeGraphIndexOnLoad != oldValue else { return }
            CodeGraphManager.shared.setIndexOnLoad(codeGraphIndexOnLoad)
        }
    }

    /// One-line status for the code-graph section: installed or the install
    /// command.
    var codeGraphStatus: String {
        if CodeGraphManager.shared.isAvailable {
            return "Graph ready — sessions answer from it."
        }
        return "Not installed — run: curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh"
    }

    /// Understand-Anything (interactive knowledge graph): analyze projects so
    /// the phone can search, trace and click through the codebase visually.
    /// Persisted through UnderstandAnythingManager. The analysis itself runs
    /// the agent pipeline, so analyze-on-load is off by default (token cost).
    @Published var understandEnabled: Bool {
        didSet {
            guard understandEnabled != oldValue else { return }
            UnderstandAnythingManager.shared.setEnabled(understandEnabled)
        }
    }

    @Published var understandIndexOnLoad: Bool {
        didSet {
            guard understandIndexOnLoad != oldValue else { return }
            UnderstandAnythingManager.shared.setIndexOnLoad(understandIndexOnLoad)
        }
    }

    /// One-line status for the understand-anything section: installed or the
    /// install command.
    var understandStatus: String {
        if UnderstandAnythingManager.shared.isInstalled {
            return UnderstandAnythingManager.shared.isAvailable
                ? "Graphs ready — open from the Code tab"
                : "Plugin installed — Node.js missing"
        }
        return "Not installed — run: curl -fsSL https://raw.githubusercontent.com/Egonex-AI/Understand-Anything/main/install.sh | bash"
    }

    // MARK: - NYU coursework

    /// NYU (Canvas): the token, the toggles and the target GPA. Persisted
    /// through NYUIntegrationManager; the token is held in UserDefaults like
    /// the other settings (Keychain storage is a stated follow-up).
    @Published var nyuEnabled: Bool {
        didSet {
            guard nyuEnabled != oldValue else { return }
            NYUIntegrationManager.shared.updateSettings { $0.enabled = nyuEnabled }
        }
    }

    @Published var nyuCanvasToken: String {
        didSet {
            guard nyuCanvasToken != oldValue else { return }
            NYUIntegrationManager.shared.updateSettings { $0.canvasToken = nyuCanvasToken }
        }
    }

    @Published var nyuTargetGPA: Double {
        didSet {
            guard nyuTargetGPA != oldValue else { return }
            NYUIntegrationManager.shared.updateSettings { $0.targetGPA = nyuTargetGPA }
        }
    }

    @Published var nyuRemind24h: Bool {
        didSet {
            guard nyuRemind24h != oldValue else { return }
            NYUIntegrationManager.shared.updateSettings { $0.remind24h = nyuRemind24h }
        }
    }

    @Published var nyuRemind1h: Bool {
        didSet {
            guard nyuRemind1h != oldValue else { return }
            NYUIntegrationManager.shared.updateSettings { $0.remind1h = nyuRemind1h }
        }
    }

    @Published var nyuCalendarSync: Bool {
        didSet {
            guard nyuCalendarSync != oldValue else { return }
            NYUIntegrationManager.shared.updateSettings { $0.calendarSyncEnabled = nyuCalendarSync }
        }
    }

    @Published var nyuSyncFrequency: Int {
        didSet {
            guard nyuSyncFrequency != oldValue else { return }
            NYUIntegrationManager.shared.updateSettings { $0.syncFrequencyHours = nyuSyncFrequency }
        }
    }

    /// One-line status for the NYU section: configured + last sync, or what's
    /// missing.
    var nyuStatus: String {
        let manager = NYUIntegrationManager.shared
        guard manager.isConfigured else {
            return manager.settings.enabled ? "On — token missing" : "Off"
        }
        let last = manager.listAssignments().count
        return "On — \(last) assignment\(last == 1 ? "" : "s") tracked"
    }

    /// Token compression (Headroom). On by default; the knob controls how
    /// eagerly Alfred shrinks content before it reaches the model. Persisted
    /// through HeadroomMCPClient, which also keeps the MCP registration in
    /// sync with the switch.
    @Published var tokenCompressionEnabled: Bool {
        didSet {
            guard tokenCompressionEnabled != oldValue else { return }
            HeadroomMCPClient.shared.setEnabled(tokenCompressionEnabled)
        }
    }

    @Published var compressionLevel: HeadroomCompressionLevel {
        didSet {
            guard compressionLevel != oldValue else { return }
            HeadroomMCPClient.shared.compressionLevel = compressionLevel
        }
    }

    /// One-line status for the compression section: installed with a level, or
    /// missing with the install command.
    var compressionStatus: String {
        if HeadroomMCPClient.shared.isAvailable {
            return "Compressing \(compressionLevel.displayName.lowercased()) — \(HeadroomMCPClient.shared.isEnabled ? "on" : "off")"
        }
        return "Headroom not installed — install with: uv tool install --python 3.13 \"headroom-ai[all]\""
    }

    var activeLabel: String {
        guard let key = keys.activeKey else { return "none — using Hermes defaults" }
        return "\(key.provider.displayName): \(key.label)"
    }

    /// One-line summary shown at the right of the MODEL header.
    var modeSummary: String {
        switch modelMode {
        case .cloud:
            return keys.activeKey.map { "\($0.provider.displayName): \($0.label)" }
                ?? "Hermes defaults"
        case .local:
            return LocalModels.brain
        }
    }

    /// The explanatory line under the toggle.
    var modeDetail: String {
        switch modelMode {
        case .cloud:
            return "Uses the API keys below, with automatic fallback across them."
        case .local:
            return "Runs entirely on this Mac through Ollama. alfred-brain decides within each turn which tools and local models to use — no cloud calls, no keys needed."
        }
    }
}

struct SettingsPopoverView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var usage = UsageTracker.shared

    let onShowBar: () -> Void
    let onRelaunch: () -> Void
    let onQuit: () -> Void

    /// Whether the API key rows and the "Add" form are shown. The key ring
    /// collapses to just the "API KEYS" header so the popover stays compact
    /// once everything is configured.
    @State private var isKeysExpanded = false

    /// Lets the "API KEYS" header show it is clickable without restyling the row.
    @State private var isKeysHovering = false

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            Text("Alfred is always on: computer control, terminal access, and "
                 + "mail alerts are enabled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            compressionSection

            Divider()

            codeGraphSection

            Divider()

            understandSection

            Divider()

            nyuSection

            Divider()

            browserSection

            Divider()

            scrapingSection

            Divider()

            multiAgentSection

            Divider()

            presentationSection

            Divider()

            tasteSection

            Divider()

            memorySection

            Divider()

            homeworkSection

            Divider()

            modelSection

            Divider()

            keysSection

            Divider()

            HStack {
                Button("Show Alfred", action: onShowBar)
                Text("⌘⇧J")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Relaunch", action: onRelaunch)
                Button("Quit", action: onQuit)
            }
        }
        .padding(14)
        .frame(width: Self.width)
    }

    // MARK: - Token compression

    /// Context compression (Headroom): a switch plus a level picker. The
    /// status line tells the truth about whether Headroom is actually there.
    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11))
                Text("CONTEXT COMPRESSION")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.compressionStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Compress before the model sees it",
                   isOn: $model.tokenCompressionEnabled)
                .font(.system(size: 11))

            Picker("Level", selection: $model.compressionLevel) {
                ForEach(HeadroomCompressionLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.tokenCompressionEnabled)

            Text("Headroom shrinks tool outputs, logs and JSON before they reach the model — same answers, fewer tokens. Local-only; originals stay retrievable.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Code graph

    /// Project indexing (CodeGraph): a switch plus the index-on-load choice.
    /// The status line tells the truth about whether the binary is there.
    private var codeGraphSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                Text("CODE GRAPH")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.codeGraphStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Index projects for coding sessions",
                   isOn: $model.codeGraphEnabled)
                .font(.system(size: 11))

            Toggle("Index on session start",
                   isOn: $model.codeGraphIndexOnLoad)
                .font(.system(size: 11))
                .disabled(!model.codeGraphEnabled)

            Text("Coding agents answer from a prebuilt graph of your project — fewer file reads, fewer tokens, surgical context. Local-only; auto-syncs as you edit.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Understand-Anything

    /// The interactive knowledge graph: a switch plus the analyze-on-load
    /// choice. The status line tells the truth about whether the plugin is
    /// installed.
    private var understandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                Text("KNOWLEDGE GRAPH")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.understandStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Analyze projects into interactive graphs",
                   isOn: $model.understandEnabled)
                .font(.system(size: 11))

            Toggle("Analyze on session start",
                   isOn: $model.understandIndexOnLoad)
                .font(.system(size: 11))
                .disabled(!model.understandEnabled)

            Text("Turns a project into a knowledge graph you can search, trace and click through — interactive dashboard, impact analysis, onboarding tours. Runs the agent pipeline (token cost), so analysis is opt-in.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - NYU coursework

    /// The NYU integration: token + toggles. The token field is a secure entry
    /// so the key never shows while typing; the status line tells the truth
    /// about configuration and the Sync Now button proves it.
    private var nyuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 11))
                Text("NYU COURSEWORK")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.nyuStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Track NYU coursework (Canvas)",
                   isOn: $model.nyuEnabled)
                .font(.system(size: 11))

            SecureField("Canvas API token", text: $model.nyuCanvasToken)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .disabled(!model.nyuEnabled)

            HStack(spacing: 6) {
                Text("Target GPA for grade alerts")
                    .font(.system(size: 11))
                Spacer()
                TextField("0", value: $model.nyuTargetGPA, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(size: 11))
                    .disabled(!model.nyuEnabled)
            }

            Picker("Sync frequency", selection: $model.nyuSyncFrequency) {
                Text("Hourly").tag(1)
                Text("Every 6 hours").tag(6)
                Text("Daily").tag(24)
            }
            .font(.system(size: 11))
            .disabled(!model.nyuEnabled)

            Toggle("Remind 24 hours before due",
                   isOn: $model.nyuRemind24h)
                .font(.system(size: 11))
                .disabled(!model.nyuEnabled)

            Toggle("Remind 1 hour before due",
                   isOn: $model.nyuRemind1h)
                .font(.system(size: 11))
                .disabled(!model.nyuEnabled)

            Toggle("Mirror classes & due dates into Calendar",
                   isOn: $model.nyuCalendarSync)
                .font(.system(size: 11))
                .disabled(!model.nyuEnabled)

            Button {
                Task { @MainActor in
                    _ = await NYUIntegrationManager.shared.syncNow()
                }
            } label: {
                Text("Sync Now")
                    .font(.system(size: 11, weight: .medium))
            }
            .disabled(!model.nyuEnabled || model.nyuCanvasToken.isEmpty)

            Text("Syncs assignments, grades, announcements and class times from canvas.nyu.edu — the Briefing gets what's due and where you stand, and deadline reminders fire 24h / 1h before. The token is a Canvas personal access token (Profile → Settings → Approved Integrations).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Browser automation

    /// Deterministic web automation (browser-use): a switch for Alfred's own
    /// browser steps plus the form-submission gate. The status line tells the
    /// truth about whether the binary is there — and that Chrome must be
    /// running for any task to actually execute.
    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                Text("BROWSER AUTOMATION")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.browserStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Enable browser automation",
                   isOn: $model.browserAutomationEnabled)
                .font(.system(size: 11))

            Toggle("Require confirmation before submitting forms",
                   isOn: $model.browserRequireConfirmation)
                .font(.system(size: 11))
                .disabled(!model.browserAutomationEnabled)

            Text("Routines can check a page and report what it says; Alfred can subscribe you to newsletters. Read-only unless you confirm a submit. Banks, payment sites and adult-content sites are always blocked — no toggle, always on.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Web scraping

    /// Lightweight page fetching (Crawlee): a switch, an engine picker, and a
    /// cache knob. The status line tells the truth about whether the bridge
    /// is installed. Scraping is on by default — it is read-only GET requests
    /// (the same risk class as the briefing's news fetch), unlike browser
    /// automation which fills and submits forms.
    private var scrapingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                Text("WEB SCRAPING")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.scrapingStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Enable web scraping",
                   isOn: $model.scrapingEnabled)
                .font(.system(size: 11))

            Picker("Engine", selection: $model.scrapeMode) {
                ForEach(ScrapeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.scrapingEnabled)

            Picker("Cache", selection: $model.scrapeCacheDuration) {
                ForEach(ScrapeCacheDuration.allCases) { duration in
                    Text(duration.displayName).tag(duration)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140, alignment: .leading)
            .disabled(!model.scrapingEnabled)

            Text("Routine steps fetch pages and search results as text — read-only, no browser needed. Results are cached so repeated checks don't hammer the site. Full-browser mode renders JavaScript but needs Playwright installed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Multi-agent team

    /// Specialized-agent orchestration: a switch (master enable), the
    /// parallelization mode, and the per-agent timeout. The status line tells
    /// the truth about the current mode. Everything here persists through
    /// MultiAgentOrchestrator — this section is just the knob panel.
    private var multiAgentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.3")
                    .font(.system(size: 11))
                Text("MULTI-AGENT")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.multiAgentStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Spawn a team for complex tasks",
                   isOn: $model.multiAgentEnabled)
                .font(.system(size: 11))

            Picker("Parallelization", selection: $model.multiAgentParallelization) {
                ForEach(MultiAgentParallelization.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.multiAgentEnabled)

            Picker("Timeout", selection: $model.multiAgentTimeout) {
                ForEach(AgentTimeout.allCases) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 120, alignment: .leading)
            .disabled(!model.multiAgentEnabled)

            Text("Deep research, weekly planning, job search and code review run through a team of specialized Planning, Research, Code, Review and Writing agents. Each agent is a Hermes instance with its own job; results pass through a shared mailbox so later agents build on earlier work. Parallel mode runs independent stages at once. Trigger with \u{201C}multi: \u{2026}\u{201D} or ask naturally.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Presentations

    /// Presentation generator defaults: deck length, design style, speaker
    /// notes and export format. Persisted through PresentationGeneratorSkill,
    /// which also learns the user's style from every deck it makes.
    private var presentationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 11))
                Text("PRESENTATIONS")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.presentationStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Picker("Default length", selection: $model.presentationDefaultSlides) {
                Text("5 slides").tag(5)
                Text("10 slides").tag(10)
                Text("15 slides").tag(15)
                Text("20 slides").tag(20)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Design style", selection: $model.presentationStyle) {
                ForEach(PresentationStyle.all) { style in
                    Text(style.displayName).tag(style.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140, alignment: .leading)

            Toggle("Include speaker notes",
                   isOn: $model.presentationIncludeNotes)
                .font(.system(size: 11))

            Picker("Export", selection: $model.presentationExportFormat) {
                ForEach(PresentationExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Ask for slides on any topic and Alfred researches it, writes concise bullets and speaker notes, and exports deck.pptx + deck.pdf to ~/.alfred/presentations/. The design style is learned from your decks — set it here and future decks match. Ask for \u{201C}presentation on \u{2026}\u{201D} or \u{201C}make slides for \u{2026}\u{201D}.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Taste (anti-slop text)

    private var tasteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                Text("TASTE")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.tasteStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Polish generic output",
                   isOn: $model.tasteEnabled)
                .font(.system(size: 11))

            Picker("Strength", selection: $model.tasteAggressiveness) {
                ForEach(TasteAggressiveness.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.tasteEnabled)

            Picker("Voice", selection: $model.tasteVoice) {
                ForEach(TasteVoice.allCases) { voice in
                    Text(voice.displayName).tag(voice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 150, alignment: .leading)
            .disabled(!model.tasteEnabled)

            Text("Applies to")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(TasteScope.allCases) { scope in
                Toggle(scope.displayName, isOn: model.binding(for: scope))
                    .font(.system(size: 11))
                    .disabled(!model.tasteEnabled)
            }

            Text("Drafts, routine names and summaries that read generic get rewritten with specificity and your voice. Specific writing is left alone — no model turn is spent on it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - MemPalace (persistent memory)

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                Text("MEMORY")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.memoryStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Learn from what we do together",
                   isOn: $model.memoryEnabled)
                .font(.system(size: 11))

            Picker("Learning", selection: $model.memoryLearningMode) {
                ForEach(MemoryLearningMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .leading)
            .disabled(!model.memoryEnabled)

            Picker("Decay", selection: $model.memoryDecayRate) {
                ForEach(MemoryDecayRate.allCases) { rate in
                    Text(rate.displayName).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 180, alignment: .leading)
            .disabled(!model.memoryEnabled)

            Picker("Use at", selection: $model.memoryConfidenceThreshold) {
                Text("50% confidence").tag(0.5)
                Text("70% confidence").tag(0.7)
                Text("90% confidence").tag(0.9)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.memoryEnabled)

            Text("Never learn")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(MemoryCategory.allCases) { category in
                Toggle(category.displayName, isOn: model.memoryBinding(for: category))
                    .font(.system(size: 11))
                    .disabled(!model.memoryEnabled)
            }

            Text("Alfred keeps the durable preferences, patterns and goals it learns — each carries a confidence that repetition raises and time decays. Memories below the bar are pruned; the people category can be excluded entirely for privacy.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Homework Assistant

    /// The submission-side homework skill: master switch, default mode
    /// (teach vs submit), code style, steps, difficulty and format. All
    /// persisted through HomeworkAssistantSkill, which also owns the
    /// dedicated solver session.
    private var homeworkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "graduationcap")
                    .font(.system(size: 11))
                Text("HOMEWORK")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.homeworkStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .trailing)
            }

            Toggle("Homework Assistant",
                   isOn: $model.homeworkEnabled)
                .font(.system(size: 11))

            Picker("Default mode", selection: $model.homeworkDefaultMode) {
                ForEach(HomeworkMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.homeworkEnabled)

            Picker("Code style", selection: $model.homeworkCodeStyle) {
                ForEach(HomeworkCodeStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 200, alignment: .leading)
            .disabled(!model.homeworkEnabled)

            Picker("Show steps", selection: $model.homeworkShowSteps) {
                ForEach(HomeworkShowSteps.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 200, alignment: .leading)
            .disabled(!model.homeworkEnabled)

            Picker("Difficulty", selection: $model.homeworkDifficulty) {
                ForEach(HomeworkDifficulty.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 200, alignment: .leading)
            .disabled(!model.homeworkEnabled)

            Picker("Format", selection: $model.homeworkFormat) {
                ForEach(HomeworkFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140, alignment: .leading)
            .disabled(!model.homeworkEnabled)

            Text("Asks for help on CS, math or physics problems: teaching mode guides you to the answer yourself, submission mode produces the complete solution in your style, formatted for hand-in. What trips you up is tracked so Alfred gets better at explaining.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Model (cloud vs local)

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                Text("MODEL")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.modeSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Picker("Model", selection: $model.modelMode) {
                ForEach(ModelMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.modeDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - API keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isKeysExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isKeysExpanded ? 90 : 0))
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 11))
                    Text("API KEYS")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(model.activeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isKeysHovering ? Color.primary.opacity(0.06) : .clear)
            )
            .onHover { hovering in isKeysHovering = hovering }
            .help(isKeysExpanded ? "Collapse the key ring" : "Show the key ring")

            if isKeysExpanded {
                ForEach(model.keys.keys) { key in
                    KeyRow(key: key, onSetActive: { model.keys.setActive(id: key.id) },
                           onRemove: { model.keys.remove(id: key.id) })
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Provider", selection: $model.newKeyProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 11))

                    HStack(spacing: 6) {
                        TextField("Label (optional)", text: $model.newKeyLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        TextField("Paste API key", text: $model.newKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("Add") {
                            model.keys.add(provider: model.newKeyProvider,
                                           label: model.newKeyLabel,
                                           key: model.newKey)
                            model.newKey = ""
                            model.newKeyLabel = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Alfred Settings")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    private func color(forPercent percent: Int) -> Color {
        switch percent {
        case ..<20: return .red
        case 20..<50: return .orange
        default: return .green
        }
    }
}

/// One key row: active marker, provider chip, label, usage meter, remove.
private struct KeyRow: View {
    let key: ProviderKey
    let onSetActive: () -> Void
    let onRemove: () -> Void

    private var isActive: Bool { key.id == ProviderKeyRing.shared.activeKeyID }
    private var meter: (percent: Int?, text: String, isEstimate: Bool) {
        UsageTracker.shared.usage(for: key)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSetActive) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Use this key")

            Text(key.provider.displayName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(key.provider == .gemini ? Color.green.opacity(0.15)
                          : Color.blue.opacity(0.15))
                .clipShape(Capsule())
                .lineLimit(1)

            Text(key.label)
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer()

            Text(meter.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(meter.percent.map { color(for: $0) } ?? .secondary)
                .frame(minWidth: 52, alignment: .trailing)
                .help(meter.isEstimate
                      ? "Rough estimate from requests + hermes usage today"
                      : "Quota reported by the provider")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this key")
        }
    }

    private func color(for percent: Int) -> Color {
        switch percent {
        case ..<20: return .red
        case 20..<50: return .orange
        default: return .green
        }
    }
}