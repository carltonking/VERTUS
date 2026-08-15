//
//  SettingsView.swift
//  Alfred
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    private enum SocketTestState: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    @State private var socketTestState: SocketTestState = .idle

    /// The two Mac-backed feature sections each have a manual sync that reports
    /// what the Mac answered, so "Refresh Now" never feels like a dead button.
    private enum RefreshState: Equatable {
        case idle
        case refreshing
        case done(String)
        case failed(String)
    }

    @State private var routinesRefreshState: RefreshState = .idle
    @State private var codeRefreshState: RefreshState = .idle

    // NYU coursework — edited here, sent to the Mac (nyu.set_settings). The
    // phone mirrors the Mac's settings so the fields don't reset on relaunch.
    @State private var nyuEnabled = false
    @State private var nyuCanvasToken = ""
    @State private var nyuTargetGPA = 0.0
    @State private var nyuSyncFrequencyHours = 6
    @State private var nyuRemind24h = true
    @State private var nyuRemind1h = true
    @State private var nyuCalendarSync = false
    @State private var nyuSyncState: RefreshState = .idle

    // Career preferences — edited here, stored on the Mac (career.preferences).
    @State private var careerRoleTypes = ""
    @State private var careerLocations = ""
    @State private var careerMinSalary = 0
    @State private var careerKeywords = ""
    @State private var careerFollowUpDays = 7
    @State private var careerSaveState: RefreshState = .idle

    // Taste (anti-slop) — edited here, stored on the Mac (taste.set_settings).
    @State private var tasteEnabled = true
    @State private var tasteAggressiveness = "moderate"
    @State private var tasteVoice = "matchUser"
    /// The Mac's scope selection, echoed back untouched — the phone doesn't
    /// edit it, but must not silently reset Mac-side exclusions.
    @State private var tasteScopes: [String] = []
    @State private var tasteSaveState: RefreshState = .idle

    // Optimization (DSPy) — edited here, stored on the Mac (optimization.set_settings).
    @State private var optimizationFrequency = "weekly"
    @State private var optimizationMinFeedback = 10
    @State private var optimizationConfidenceThreshold = 0.10
    @State private var optimizationAutoRollback = true
    @State private var optimizationSaveState: RefreshState = .idle

    // MemPalace (persistent memory) — edited here, stored on the Mac
    // (memory.set_settings).
    @State private var memoryEnabled = true
    @State private var memoryLearningMode = "conservative"
    @State private var memoryDecayRate = "slow"
    @State private var memoryConfidenceThreshold = 0.7
    /// The Mac's category exclusions, echoed back untouched — the phone doesn't
    /// edit them, but must not silently reset Mac-side privacy choices.
    @State private var memoryExcludedCategories: [String] = []
    @State private var memorySaveState: RefreshState = .idle

    // Homework Assistant — edited here, stored on the Mac (homework.set_settings).
    @State private var homeworkEnabled = true
    @State private var homeworkDefaultMode = "teach"
    @State private var homeworkCodeStyle = "match_mine"
    @State private var homeworkShowSteps = "always"
    @State private var homeworkDifficulty = "match_level"
    @State private var homeworkFormat = "text"
    @State private var homeworkSaveState: RefreshState = .idle

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section {
                        // The project's actual production alias. "alfredai.vercel.app" is a
                        // different deployment entirely, so offering it as the example sent people
                        // to a host that 404s every endpoint.
                        TextField("alfredassistant.vercel.app", text: $settings.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.host")
                            .onChange(of: settings.host) { testState = .idle }
                    } header: {
                        Text("Address")
                    } footer: {
                        Text("Where Alfred is deployed. Requests go to \(settings.resolvedEndpointDescription).")
                    }

                    Section {
                        SecureField("APP_TOKEN", text: $settings.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.token")
                            .onChange(of: settings.token) { testState = .idle }
                    } header: {
                        Text("App token")
                    } footer: {
                        Text("Must match APP_TOKEN in the deployment's environment. Stored in the iPhone's Keychain, never in a backup.")
                    }

                    Section {
                        TextField("e.g. 192.168.1.40", text: $settings.voiceHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.voiceHost")
                    } header: {
                        Text("Mac address (voice)")
                    } footer: {
                        Text("The Mac's address on this network — where the voice bridge listens on port 8765. Only needed for talking out loud.")
                    }

                    Section {
                        TextField("Auto-discovered", text: $settings.socketHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("settings.socketHost")

                        HStack {
                            Text("Status")
                            Spacer()
                            connectionStatusLabel
                        }

                        Button {
                            runSocketTest()
                        } label: {
                            HStack {
                                Text("Test direct link")
                                Spacer()
                                if socketTestState == .testing { ProgressView() }
                            }
                        }
                        .disabled(socketTestState == .testing)

                        switch socketTestState {
                        case .passed(let detail):
                            Label {
                                Text(detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textSecondary)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(palette.success)
                            }
                        case .failed(let detail):
                            Label {
                                Text(detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textSecondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(palette.danger)
                            }
                        case .idle, .testing:
                            EmptyView()
                        }
                    } header: {
                        Text("Mac address (direct link)")
                    } footer: {
                        Text("The live link to your Mac — streaming chat, briefings and updates without a cloud relay. Left blank, Alfred finds the Mac automatically over mDNS or Tailscale. If you pin an address, prefer the Mac's name (alfred.local, or its Tailscale name) over its IP — iOS blocks plain ws:// connections to IP addresses, and Alfred resolves an IP pin to the Mac's name automatically. The link is plain ws:// (the Mac's server has no TLS), so a pasted wss:// address is downgraded. Leave the port empty for the default (\(AlfredWebSocketClient.defaultPort)).")
                    }

                    connectionSection

                    Section {
                        NavigationLink {
                            EmailSettingsView()
                        } label: {
                            HStack {
                                Label("Email", systemImage: "envelope.fill")
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.textFaint)
                            }
                        }
                    } header: {
                        Text("Mail preferences")
                    } footer: {
                        Text("Scan frequency, drafting tone, signature, and learning — shared with the Mac over the live link.")
                    }

                    Section {
                        Toggle("Enable Routines", isOn: $settings.routinesEnabled)
                            .tint(palette.accent)

                        linkStatusRow

                        Button {
                            refreshRoutines()
                        } label: {
                            HStack {
                                Text("Refresh Now")
                                Spacer()
                                if routinesRefreshState == .refreshing { ProgressView() }
                            }
                        }
                        .disabled(!linkConfigured || routinesRefreshState == .refreshing)

                        refreshResult(routinesRefreshState)
                    } header: {
                        Text("Routines")
                    } footer: {
                        Text("Scheduled workflows run on your Mac and stream their progress here. The list syncs live over the link — Refresh Now just forces a fresh pull.")
                    }

                    Section {
                        Toggle("Enable Code Sessions", isOn: $settings.codeSessionsEnabled)
                            .tint(palette.accent)

                        linkStatusRow

                        Button {
                            refreshCodeSessions()
                        } label: {
                            HStack {
                                Text("Refresh Now")
                                Spacer()
                                if codeRefreshState == .refreshing { ProgressView() }
                            }
                        }
                        .disabled(!linkConfigured || codeRefreshState == .refreshing)

                        refreshResult(codeRefreshState)
                    } header: {
                        Text("Code sessions")
                    } footer: {
                        Text("AlfredCode sessions run on your Mac and stream their output here. Live updates arrive on their own; Refresh Now forces a fresh pull.")
                    }

                    Section {
                        Toggle("Enable Knowledge Graph", isOn: $settings.understandEnabled)
                            .tint(palette.accent)
                        Toggle("Analyze on session start", isOn: $settings.understandIndexOnLoad)
                            .tint(palette.accent)
                            .disabled(!settings.understandEnabled)
                    } header: {
                        Text("Knowledge graph")
                    } footer: {
                        Text("Understand-Anything turns your project into an interactive graph — search it, trace bugs, see what a refactor breaks, and open the visual dashboard from the Code tab. Analysis runs the agent pipeline on the Mac (token cost), so it's opt-in per project.")
                    }

                    Section {
                        Toggle("Track NYU coursework (Canvas)", isOn: $nyuEnabled)
                            .tint(palette.accent)
                        SecureField("Canvas API token", text: $nyuCanvasToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(!nyuEnabled)
                        TextField("Target GPA for grade alerts (0 = off)", value: $nyuTargetGPA, format: .number)
                            .keyboardType(.decimalPad)
                            .disabled(!nyuEnabled)
                        Picker("Sync frequency", selection: $nyuSyncFrequencyHours) {
                            Text("Hourly").tag(1)
                            Text("Every 6 hours").tag(6)
                            Text("Daily").tag(24)
                        }
                        .disabled(!nyuEnabled)
                        Toggle("Remind 24 hours before due", isOn: $nyuRemind24h)
                            .tint(palette.accent)
                            .disabled(!nyuEnabled)
                        Toggle("Remind 1 hour before due", isOn: $nyuRemind1h)
                            .tint(palette.accent)
                            .disabled(!nyuEnabled)
                        Toggle("Mirror classes & due dates into Calendar", isOn: $nyuCalendarSync)
                            .tint(palette.accent)
                            .disabled(!nyuEnabled)
                        Button {
                            syncNYU()
                        } label: {
                            HStack {
                                Text("Save & Sync Now")
                                Spacer()
                                if nyuSyncState == .refreshing { ProgressView() }
                            }
                        }
                        .disabled(!linkConfigured || nyuSyncState == .refreshing || !nyuEnabled)

                        refreshResult(nyuSyncState)
                    } header: {
                        Text("NYU coursework")
                    } footer: {
                        Text("Paste a Canvas personal access token (canvas.nyu.edu → Profile → Settings → Approved Integrations) and Alfred pulls your assignments, grades, announcements and class times. What's due lands in the Briefing; deadline reminders fire 24h and 1h before. The token is sent to your Mac once and stored there.")
                    }

                    Section {
                        TextField("e.g. Internship, Software Engineer", text: $careerRoleTypes)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("e.g. New York, Remote", text: $careerLocations)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Minimum salary (USD per year)", value: $careerMinSalary, format: .number)
                            .keyboardType(.numberPad)
                        TextField("Skills to highlight, e.g. Python, React", text: $careerKeywords)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Follow up after", selection: $careerFollowUpDays) {
                            Text("5 days").tag(5)
                            Text("7 days").tag(7)
                            Text("10 days").tag(10)
                            Text("14 days").tag(14)
                        }

                        Button {
                            saveCareerPreferences()
                        } label: {
                            HStack {
                                Text("Save to Mac")
                                Spacer()
                                if careerSaveState == .refreshing { ProgressView() }
                            }
                        }
                        .disabled(!linkConfigured || careerSaveState == .refreshing)

                        refreshResult(careerSaveState)
                    } header: {
                        Text("Career")
                    } footer: {
                        Text("Your job-hunt profile — the Mac scores every listing against it and schedules follow-ups. Saved on the Mac, shared with the phone.")
                    }

                    Section {
                        Toggle("Learn from what we do together", isOn: $memoryEnabled)
                            .tint(palette.accent)
                            .onChange(of: memoryEnabled) { _, _ in saveMemorySettings() }

                        Picker("Learning", selection: $memoryLearningMode) {
                            Text("Conservative — clear signals only").tag("conservative")
                            Text("Aggressive — learn from anything").tag("aggressive")
                        }
                        .onChange(of: memoryLearningMode) { _, _ in saveMemorySettings() }

                        Picker("Decay", selection: $memoryDecayRate) {
                            Text("Slow — remember everything").tag("slow")
                            Text("Fast — forget quickly").tag("fast")
                        }
                        .onChange(of: memoryDecayRate) { _, _ in saveMemorySettings() }

                        Picker("Use at", selection: $memoryConfidenceThreshold) {
                            Text("50% confidence").tag(0.5)
                            Text("70% confidence").tag(0.7)
                            Text("90% confidence").tag(0.9)
                        }
                        .onChange(of: memoryConfidenceThreshold) { _, _ in saveMemorySettings() }

                        HStack {
                            Text("Saved on Mac")
                            Spacer()
                            if memorySaveState == .refreshing { ProgressView() }
                        }
                        .foregroundStyle(palette.textSecondary)

                        refreshResult(memorySaveState)
                    } header: {
                        Text("Memory")
                    } footer: {
                        Text("Alfred keeps the durable preferences, patterns and goals it learns — each carries a confidence that repetition raises and time decays. What it may learn is set on the Mac.")
                    }

                    Section {
                        Toggle("Homework Assistant", isOn: $homeworkEnabled)
                            .tint(palette.accent)
                            .onChange(of: homeworkEnabled) { _, _ in saveHomeworkSettings() }

                        Picker("Default mode", selection: $homeworkDefaultMode) {
                            Text("Teaching — guide me").tag("teach")
                            Text("Submission — just do it").tag("submit")
                        }
                        .onChange(of: homeworkDefaultMode) { _, _ in saveHomeworkSettings() }

                        Picker("Code style", selection: $homeworkCodeStyle) {
                            Text("Match my past code").tag("match_mine")
                            Text("Generic best practices").tag("generic")
                        }
                        .onChange(of: homeworkCodeStyle) { _, _ in saveHomeworkSettings() }

                        Picker("Show steps", selection: $homeworkShowSteps) {
                            Text("Always show steps").tag("always")
                            Text("Show steps on request").tag("on_request")
                            Text("Never show steps").tag("never")
                        }
                        .onChange(of: homeworkShowSteps) { _, _ in saveHomeworkSettings() }

                        Picker("Difficulty", selection: $homeworkDifficulty) {
                            Text("Match my level").tag("match_level")
                            Text("Challenge me").tag("challenge")
                            Text("Simplify").tag("simplify")
                        }
                        .onChange(of: homeworkDifficulty) { _, _ in saveHomeworkSettings() }

                        Picker("Format", selection: $homeworkFormat) {
                            Text("Text").tag("text")
                            Text("LaTeX").tag("latex")
                            Text("Code").tag("code")
                        }
                        .onChange(of: homeworkFormat) { _, _ in saveHomeworkSettings() }

                        HStack {
                            Text("Saved on Mac")
                            Spacer()
                            if homeworkSaveState == .refreshing { ProgressView() }
                        }
                        .foregroundStyle(palette.textSecondary)

                        refreshResult(homeworkSaveState)
                    } header: {
                        Text("Homework")
                    } footer: {
                        Text("Ask for help on CS, math or physics problems: teaching mode guides you to the answer yourself, submission mode produces the complete solution in your style, formatted for hand-in.")
                    }

                    Section {
                        Toggle("Polish generic output", isOn: $tasteEnabled)
                            .tint(palette.accent)
                            .onChange(of: tasteEnabled) { _, _ in saveTasteSettings() }

                        Picker("Strength", selection: $tasteAggressiveness) {
                            Text("Conservative").tag("conservative")
                            Text("Moderate").tag("moderate")
                            Text("Aggressive").tag("aggressive")
                        }
                        .onChange(of: tasteAggressiveness) { _, _ in saveTasteSettings() }

                        Picker("Voice", selection: $tasteVoice) {
                            Text("Match my style").tag("matchUser")
                            Text("Professional").tag("professional")
                            Text("Casual").tag("casual")
                            Text("Technical").tag("technical")
                        }
                        .onChange(of: tasteVoice) { _, _ in saveTasteSettings() }

                        HStack {
                            Text("Saved on Mac")
                            Spacer()
                            if tasteSaveState == .refreshing { ProgressView() }
                        }
                        .foregroundStyle(palette.textSecondary)

                        refreshResult(tasteSaveState)
                    } header: {
                        Text("Taste")
                    } footer: {
                        Text("Drafts, routine names and summaries that read generic get rewritten with specificity and your voice. Specific writing is left alone — no model turn is spent on it. Where it applies is set on the Mac.")
                    }

                    Section {
                        NavigationLink {
                            OptimizationReportView()
                        } label: {
                            HStack {
                                Label("Alfred Improvement", systemImage: "chart.line.uptrend.xyaxis")
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.textFaint)
                            }
                        }

                        Picker("Auto-optimize", selection: $optimizationFrequency) {
                            Text("Weekly").tag("weekly")
                            Text("Monthly").tag("monthly")
                            Text("Manual").tag("manual")
                        }
                        .onChange(of: optimizationFrequency) { _, _ in saveOptimizationSettings() }

                        Stepper("Ratings before optimizing: \(optimizationMinFeedback)",
                                value: $optimizationMinFeedback, in: 3...100)
                            .onChange(of: optimizationMinFeedback) { _, _ in saveOptimizationSettings() }

                        Stepper("Improvement to require: \(Int((optimizationConfidenceThreshold * 100).rounded()))%",
                                value: $optimizationConfidenceThreshold, in: 0.05...0.30, step: 0.05)
                            .onChange(of: optimizationConfidenceThreshold) { _, _ in saveOptimizationSettings() }

                        Toggle("Roll back on regression", isOn: $optimizationAutoRollback)
                            .tint(palette.accent)
                            .onChange(of: optimizationAutoRollback) { _, _ in saveOptimizationSettings() }

                        HStack {
                            Text("Saved on Mac")
                            Spacer()
                            if optimizationSaveState == .refreshing { ProgressView() }
                        }
                        .foregroundStyle(palette.textSecondary)

                        refreshResult(optimizationSaveState)
                    } header: {
                        Text("Optimization")
                    } footer: {
                        Text("Alfred rates its own output over time and learns what works for you — code style, email tone, summary format — then applies those patterns automatically. Everything stays on your Mac.")
                    }

                    Section {
                        capability("Answer questions", available: true)
                        capability("Read your calendar", available: true)
                        capability("Add calendar events", available: true)
                        capability("Look up news and the web", available: true)
                        capability("Email, syllabus, routines, video", available: false)
                        capability("Texts, files, screen (needs the Mac)", available: false)
                    } header: {
                        Text("What Alfred can do here")
                    } footer: {
                        Text("Greyed-out flows need several messages back and forth, which this app's endpoint can't do yet — they remain on Telegram. Anything needing the Mac itself is declined honestly rather than guessed at.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        // Tint and colour scheme come from RootView, so every tab agrees on them.
        .task { await loadNYUSettings() }
        .task { await loadCareerPreferences() }
        .task { await loadTasteSettings() }
        .task { await loadMemorySettings() }
        .task { await loadHomeworkSettings() }
        .task { await loadOptimizationSettings() }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if testState == .testing { ProgressView() }
                }
            }
            .disabled(!settings.isConfigured || testState == .testing)

            switch testState {
            case .passed(let detail):
                Label {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.success)
                }
            case .failed(let detail):
                Label {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.danger)
                }
            case .idle, .testing:
                EmptyView()
            }
        } footer: {
            Text("Asks Alfred which AI backends are up — proves the address, the token, and that he has a brain behind him.")
        }
    }

    // MARK: - Mac-backed features (Routines / Code)

    /// Whether anything can talk to the Mac right now — the relay is configured
    /// or a socket host is pinned (discovery fills the gap on its own).
    private var linkConfigured: Bool {
        settings.isConfigured || !settings.socketHost.isEmpty
    }

    /// The live link state, rendered from the shared client: "Connected to Mac"
    /// or "Not connected", so the feature rows say what the socket actually is.
    private var linkStatusRow: some View {
        let socket = AlfredWebSocketClient.shared
        return HStack {
            Text("Status")
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: socket.isConnected ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 13))
                    .foregroundStyle(socket.isConnected ? palette.success : palette.textFaint)
                Text(socket.isConnected ? "Connected to Mac" : "Not connected")
                    .font(.system(size: 13))
                    .foregroundStyle(socket.isConnected ? palette.textPrimary : palette.textSecondary)
            }
        }
    }

    /// One-line verdict from a manual sync, shown under the Refresh Now button.
    @ViewBuilder
    private func refreshResult(_ state: RefreshState) -> some View {
        switch state {
        case .done(let detail):
            Label {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(palette.success)
            }
        case .failed(let detail):
            Label {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.danger)
            }
        case .idle, .refreshing:
            EmptyView()
        }
    }

    /// Pull the live routine list and report what came back. A dead link is
    /// called that — not misread as "the Mac has nothing".
    private func refreshRoutines() {
        guard linkConfigured else { return }
        routinesRefreshState = .refreshing
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                routinesRefreshState = .failed("Not connected to the Mac right now.")
                return
            }
            let routines = await AlfredWebSocketClient.shared.listRoutines()
            routinesRefreshState = routines.isEmpty
                ? .done("The Mac has no routines yet — create one there.")
                : .done("\(routines.count) routine\(routines.count == 1 ? "" : "s") on your Mac.")
        }
    }

    /// Pull the live code-session list and report what came back.
    private func refreshCodeSessions() {
        guard linkConfigured else { return }
        codeRefreshState = .refreshing
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                codeRefreshState = .failed("Not connected to the Mac right now.")
                return
            }
            let sessions = await AlfredWebSocketClient.shared.listCodeSessions()
            codeRefreshState = sessions.isEmpty
                ? .done("The Mac has no coding sessions right now.")
                : .done("\(sessions.count) session\(sessions.count == 1 ? "" : "s") on your Mac.")
        }
    }

    // MARK: - Taste settings

    /// Fetch the Mac's taste settings so the toggles reflect what's actually
    /// stored (not the phone's defaults).
    private func loadTasteSettings() async {
        guard linkConfigured, AlfredWebSocketClient.shared.isConnected else { return }
        guard let settings = await AlfredWebSocketClient.shared.tasteSettings() else { return }
        tasteEnabled = settings.enabled
        tasteAggressiveness = settings.aggressiveness
        tasteVoice = settings.voice
        tasteScopes = settings.scopes
    }

    /// Push the taste settings to the Mac on every change.
    private func saveTasteSettings() {
        guard linkConfigured else { return }
        tasteSaveState = .refreshing
        let settings = TasteSettingsPayload(
            enabled: tasteEnabled,
            aggressiveness: tasteAggressiveness,
            voice: tasteVoice,
            scopes: tasteScopes.isEmpty ? ["emails", "code", "routines", "briefing"] : tasteScopes)
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                tasteSaveState = .failed("Not connected to the Mac right now.")
                return
            }
            let saved = await AlfredWebSocketClient.shared.tasteSetSettings(settings)
            tasteSaveState = saved != nil
                ? .done("Saved ✓")
                : .failed("The Mac didn't accept that. Is it awake?")
        }
    }

    // MARK: - Memory settings

    /// Fetch the Mac's MemPalace settings so the toggles reflect what's
    /// actually stored (not the phone's defaults).
    private func loadMemorySettings() async {
        guard linkConfigured, AlfredWebSocketClient.shared.isConnected else { return }
        guard let settings = await AlfredWebSocketClient.shared.memorySettings() else { return }
        memoryEnabled = settings.enabled
        memoryLearningMode = settings.learningMode
        memoryDecayRate = settings.decayRate
        memoryConfidenceThreshold = settings.confidenceThreshold
        memoryExcludedCategories = settings.excludedCategories
    }

    /// Push the memory settings to the Mac on every change.
    private func saveMemorySettings() {
        guard linkConfigured else { return }
        memorySaveState = .refreshing
        let settings = MemorySettingsPayload(
            enabled: memoryEnabled,
            learningMode: memoryLearningMode,
            decayRate: memoryDecayRate,
            confidenceThreshold: memoryConfidenceThreshold,
            excludedCategories: memoryExcludedCategories)
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                memorySaveState = .failed("Not connected to the Mac right now.")
                return
            }
            let saved = await AlfredWebSocketClient.shared.memorySetSettings(settings)
            memorySaveState = saved != nil
                ? .done("Saved ✓")
                : .failed("The Mac didn't accept that. Is it awake?")
        }
    }

    // MARK: - Homework settings

    /// Fetch the Mac's homework settings so the toggles reflect what's
    /// actually stored (not the phone's defaults).
    private func loadHomeworkSettings() async {
        guard linkConfigured, AlfredWebSocketClient.shared.isConnected else { return }
        guard let settings = await AlfredWebSocketClient.shared.homeworkSettings() else { return }
        homeworkEnabled = settings.enabled
        homeworkDefaultMode = settings.defaultMode
        homeworkCodeStyle = settings.codeStyle
        homeworkShowSteps = settings.showSteps
        homeworkDifficulty = settings.difficulty
        homeworkFormat = settings.format
    }

    /// Push the homework settings to the Mac on every change.
    private func saveHomeworkSettings() {
        guard linkConfigured else { return }
        homeworkSaveState = .refreshing
        let settings = HomeworkSettingsPayload(
            enabled: homeworkEnabled,
            defaultMode: homeworkDefaultMode,
            codeStyle: homeworkCodeStyle,
            showSteps: homeworkShowSteps,
            difficulty: homeworkDifficulty,
            format: homeworkFormat)
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                homeworkSaveState = .failed("Not connected to the Mac right now.")
                return
            }
            let saved = await AlfredWebSocketClient.shared.homeworkSetSettings(settings)
            homeworkSaveState = saved != nil
                ? .done("Saved ✓")
                : .failed("The Mac didn't accept that. Is it awake?")
        }
    }

    // MARK: - Optimization settings

    /// Fetch the Mac's optimization-loop config so the controls reflect what's
    /// actually stored (not the phone's defaults).
    private func loadOptimizationSettings() async {
        guard linkConfigured, AlfredWebSocketClient.shared.isConnected else { return }
        guard let settings = await AlfredWebSocketClient.shared.optimizationSettings() else { return }
        optimizationFrequency = settings.frequency
        optimizationMinFeedback = settings.minFeedback
        optimizationConfidenceThreshold = settings.confidenceThreshold
        optimizationAutoRollback = settings.autoRollback
    }

    /// Push the optimization-loop config to the Mac on every change.
    private func saveOptimizationSettings() {
        guard linkConfigured else { return }
        optimizationSaveState = .refreshing
        let settings = OptimizationSettingsPayload(
            frequency: optimizationFrequency,
            minFeedback: optimizationMinFeedback,
            confidenceThreshold: optimizationConfidenceThreshold,
            autoRollback: optimizationAutoRollback,
            lastCompiledAt: 0)
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                optimizationSaveState = .failed("Not connected to the Mac right now.")
                return
            }
            let saved = await AlfredWebSocketClient.shared.optimizationSetSettings(settings)
            optimizationSaveState = saved != nil
                ? .done("Saved ✓")
                : .failed("The Mac didn't accept that. Is it awake?")
        }
    }

    // MARK: - Career preferences

    /// Seed the NYU editor from the phone's mirror of the settings, then sync
    /// the mirror to the Mac so the Mac's state matches what's shown.
    private func loadNYUSettings() async {
        nyuEnabled = settings.nyuEnabled
        nyuCanvasToken = settings.nyuCanvasToken
        nyuTargetGPA = settings.nyuTargetGPA
        nyuSyncFrequencyHours = settings.nyuSyncFrequencyHours
        nyuRemind24h = settings.nyuRemind24h
        nyuRemind1h = settings.nyuRemind1h
        nyuCalendarSync = settings.nyuCalendarSync
        guard linkConfigured, AlfredWebSocketClient.shared.isConnected else { return }
        _ = await pushNYUSettings()
    }

    /// Push the current NYU settings to the Mac (nyu.set_settings) and store
    /// the phone's mirror. Returns whether the Mac accepted them.
    private func pushNYUSettings() async -> Bool {
        let payload = NYUSettingsPayload(
            enabled: nyuEnabled,
            canvasToken: nyuCanvasToken,
            targetGPA: nyuTargetGPA,
            syncFrequencyHours: nyuSyncFrequencyHours,
            remind24h: nyuRemind24h,
            remind1h: nyuRemind1h,
            calendarSyncEnabled: nyuCalendarSync)
        settings.nyuEnabled = nyuEnabled
        settings.nyuCanvasToken = nyuCanvasToken
        settings.nyuTargetGPA = nyuTargetGPA
        settings.nyuSyncFrequencyHours = nyuSyncFrequencyHours
        settings.nyuRemind24h = nyuRemind24h
        settings.nyuRemind1h = nyuRemind1h
        settings.nyuCalendarSync = nyuCalendarSync
        let status = await AlfredWebSocketClient.shared.nyuSetSettings(payload)
        return status != nil
    }

    /// Save the NYU settings to the Mac and force a Canvas sync.
    private func syncNYU() {
        guard linkConfigured else { return }
        nyuSyncState = .refreshing
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                nyuSyncState = .failed("Not connected to the Mac right now.")
                return
            }
            guard await pushNYUSettings() else {
                nyuSyncState = .failed("The Mac didn't accept the settings. Is it awake?")
                return
            }
            guard nyuEnabled, !nyuCanvasToken.isEmpty else {
                nyuSyncState = .done("Settings saved — NYU tracking is off.")
                return
            }
            if let result = await AlfredWebSocketClient.shared.nyuSyncNow() {
                nyuSyncState = result.success ? .done(result.message) : .failed(result.message)
            } else {
                nyuSyncState = .failed("Sync didn't answer — try again in a moment.")
            }
        }
    }

    /// Fetch the Mac's stored profile and fill the editor — so a configured
    /// hunt doesn't get overwritten by defaults on a later edit.
    private func loadCareerPreferences() async {
        guard linkConfigured, AlfredWebSocketClient.shared.isConnected else { return }
        guard let preferences = await AlfredWebSocketClient.shared.careerPreferences() else { return }
        careerRoleTypes = preferences.roleTypes.joined(separator: ", ")
        careerLocations = preferences.locations.joined(separator: ", ")
        careerMinSalary = preferences.minSalary
        careerKeywords = preferences.keywords.joined(separator: ", ")
        careerFollowUpDays = preferences.followUpDays
    }

    private func saveCareerPreferences() {
        guard linkConfigured else { return }
        careerSaveState = .refreshing
        let preferences = JobPreferencesPayload(
            roleTypes: csv(careerRoleTypes),
            locations: csv(careerLocations),
            minSalary: max(0, careerMinSalary),
            desiredCompanies: [],
            keywords: csv(careerKeywords),
            followUpDays: careerFollowUpDays,
            applyThreshold: 4.0)
        Task {
            guard AlfredWebSocketClient.shared.isConnected else {
                careerSaveState = .failed("Not connected to the Mac right now.")
                return
            }
            let saved = await AlfredWebSocketClient.shared.careerSetPreferences(preferences)
            careerSaveState = saved != nil
                ? .done("Saved — \(saved!.roleTypes.count) role type(s), follow-ups after \(saved!.followUpDays) days.")
                : .failed("The Mac didn't accept the profile. Is it awake?")
        }
    }

    /// "Python, React, Swift" → ["Python", "React", "Swift"], empties dropped.
    private func csv(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func capability(_ name: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? palette.success : palette.textFaint)
            Text(name)
                .foregroundStyle(available ? palette.textPrimary : palette.textFaint)
            Spacer()
        }
    }

    private func runTest() {
        testState = .testing
        Task {
            do {
                let reply = try await AlfredClient().testConnection(
                    endpoint: settings.endpoint,
                    token: settings.token
                )
                testState = .passed(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                testState = .failed(description)
            }
        }
    }

    /// The live state of the socket, rendered from the shared client so Settings
    /// and every other tab agree on what they're showing.
    private var connectionStatusLabel: some View {
        let socket = AlfredWebSocketClient.shared
        let (icon, text): (String, String)
        switch socket.state {
        case .idle:
            (icon, text) = ("circle.dashed", "Not connected")
        case .connecting:
            (icon, text) = ("arrow.triangle.2.circlepath", "Connecting…")
        case .connected:
            (icon, text) = ("checkmark.circle.fill", "Connected")
        case .reconnecting(let attempt):
            (icon, text) = ("arrow.triangle.2.circlepath", "Reconnecting… (\(attempt))")
        case .failed(let message):
            (icon, text) = ("exclamationmark.triangle.fill", message)
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(socket.isConnected ? palette.success : palette.textFaint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(socket.isConnected ? palette.textPrimary : palette.textSecondary)
        }
    }

    /// Prove the direct link works end to end: a JSON-RPC ping over the socket.
    private func runSocketTest() {
        socketTestState = .testing
        // Normalise through socketURL so whatever shape was pasted (bare host,
        // host:port, full ws:// URL) resolves to one host+port pair.
        let url = settings.socketURL ?? URL(string: "ws://alfred.local:\(settings.socketPort)")
        let host = url?.host ?? "alfred.local"
        let port = url?.port ?? settings.socketPort
        Task {
            // A pinned IP is ATS-blocked for ws://, so resolve the Mac's Bonjour
            // name first — exactly like the live connection path does.
            let resolved = await TailscaleConnection().resolveSocketEndpoint(manualHost: host, port: port)
            let testHost = resolved?.host ?? host
            let testPort = resolved?.port ?? port
            let ok = await TailscaleConnection().validateConnection(host: testHost, port: testPort)
            socketTestState = ok
                ? .passed("Alfred's Mac answered on ws://\(testHost):\(testPort).")
                : .failed("Nothing answered there. Check the address, make sure the Mac is awake, and that the socket server is running.")
        }
    }
}
