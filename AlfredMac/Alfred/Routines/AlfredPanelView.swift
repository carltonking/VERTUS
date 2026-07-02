import AppKit
import SwiftUI

/// The menu-bar popover panel (weather-widget style) — the control surface opened by clicking
/// the status item. Hosts Routines + the Activity/Privacy log. NOT a window.
struct AlfredPanelView: View {
    let store: MemoryStore
    var screenTextMonitor: ScreenTextMonitor?
    var meetingManager: MeetingCaptureManager?
    var ownerName: String = ""
    var onRunNow: (RoutineRecord) -> Void
    var onQuit: () -> Void
    var onScreenTextToggle: (Bool) -> Void = { _ in }
    @ObservedObject var appState: AppState

    enum Tab: String, CaseIterable { case routines = "Routines", reminders = "Reminders", profile = "Profile", settings = "Settings" }

    @State private var tab: Tab = .routines
    @State private var routines: [RoutineRecord] = []
    @State private var showingAdd = false
    /// Routine ids with a run in flight (shows a spinner instead of last status).
    @State private var runningIDs: Set<Int64> = []
    /// The routine whose output dropdown is expanded, plus its cached run history.
    @State private var expandedID: Int64?
    @State private var routineRuns: [Int64: [RunRecord]] = [:]
    /// Telegram bot token entry (write-only: we never read the secret back into the field, so the
    /// Keychain isn't touched during rendering). Saved via KeychainHelper so Alfred owns the item.
    @State private var telegramTokenInput = ""
    @State private var telegramTokenJustSaved = false
    /// AI-provider API key entry (write-only, same reasoning). Saved to the Keychain under the
    /// selected provider's account so Alfred owns the item (no access prompt on later reads).
    @State private var providerKeyInput = ""
    @State private var providerKeyJustSaved = false
    /// Google Maps API key entry for transit departure reminders (write-only; saved under account
    /// "googlemaps"). Only needed when travel mode = transit.
    @State private var mapsKeyInput = ""
    @State private var mapsKeyJustSaved = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340, height: 460)
        .onAppear(perform: reload)
        .onChange(of: tab) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .alfredRoutineRunDidFinish)) { note in
            // A run (manual, scheduled, or API) finished — refresh rows + the open dropdown live.
            if let id = note.object as? Int64 {
                runningIDs.remove(id)
                if expandedID == id { routineRuns[id] = store.runsForRoutine(id: id) }
            }
            reload()
        }
        .sheet(isPresented: $showingAdd) {
            AddRoutineSheet(store: store) { reload() }
        }
    }

    private var header: some View {
        HStack {
            Text("Alfred").font(.headline)
            Spacer()
            if tab == .routines {
                Button { showingAdd = true } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .help("New routine")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .routines: routinesContent
        case .reminders: RemindersTabView()
        case .profile: HermesDashboardView(store: store, screenTextMonitor: screenTextMonitor,
                                            meetingManager: meetingManager, ownerName: ownerName,
                                            onScreenTextToggle: onScreenTextToggle)
        case .settings: settingsContent
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $appState.computerControlEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Computer control").font(.system(size: 13, weight: .semibold))
                        Text("Let Alfred operate this Mac when you say “control my mac …”. It reads the on-screen controls and plans the actions with your AI provider.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if appState.computerControlEnabled {
                    Label("Every run shows the exact actions and asks you to confirm before anything happens. Requires Accessibility permission. Passwords, payments and destructive actions are always refused.",
                          systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Toggle(isOn: $appState.shellExecutionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shell execution").font(.system(size: 13, weight: .semibold))
                        Text("Run explicit shell commands you type with `run:` or backticks.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                aiProviderSection

                Divider()

                botsSection

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - AI provider settings

    /// The LLM backends Alfred can use. Changing provider or model takes effect live (LLMRouter
    /// observes AppState); no relaunch needed.
    private static let providerChoices: [(id: String, label: String)] = [
        ("groq", "Groq"), ("openrouter", "OpenRouter"), ("gemini", "Gemini"), ("ollama", "Ollama (local)")
    ]

    private var aiProviderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI PROVIDER")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)

            VStack(alignment: .leading, spacing: 4) {
                Text("Provider").font(.system(size: 11, weight: .semibold))
                Picker("", selection: $appState.selectedProvider) {
                    ForEach(Self.providerChoices, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            labeledField("Model", "model id", text: $appState.selectedModel)

            if appState.selectedProvider == "ollama" {
                Label("Runs on your Mac — no key, unlimited, free.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                providerKeyField
            }
        }
        .onChange(of: appState.selectedProvider) { _, _ in
            providerKeyInput = ""; providerKeyJustSaved = false
        }
    }

    private var providerKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API key").font(.system(size: 11, weight: .semibold))
            SecureField("paste your key", text: $providerKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: providerKeyInput) { _, _ in providerKeyJustSaved = false }
            HStack(spacing: 8) {
                Button("Save key") { saveProviderKey() }
                    .controlSize(.small)
                    .disabled(providerKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if providerKeyJustSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green).labelStyle(.titleAndIcon)
                }
                if let url = providerKeyURL {
                    Link("Get key ↗", destination: url).font(.system(size: 11))
                }
            }
            if appState.selectedProvider == "openrouter" {
                Text("Tip: pick a model ending in “:free” (e.g. meta-llama/llama-3.3-70b-instruct:free). Free tier ≈ 50 requests/day.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerKeyURL: URL? {
        switch appState.selectedProvider {
        case "openrouter": return URL(string: "https://openrouter.ai/keys")
        case "gemini":     return URL(string: "https://aistudio.google.com/apikey")
        case "groq":       return URL(string: "https://console.groq.com/keys")
        default:           return nil
        }
    }

    private func saveProviderKey() {
        let key = providerKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Alfred writes the item (SecItemAdd) under the provider's account, so it owns the Keychain
        // ACL and the provider's later reads never trigger an access prompt.
        _ = KeychainHelper.save(service: "com.alfred.app", account: appState.selectedProvider, value: key)
        providerKeyInput = ""
        providerKeyJustSaved = true
    }

    // MARK: - Assistant & bots settings

    /// Exposes the opt-in "flagship" features (previously reachable only by editing UserDefaults):
    /// the iMessage + Telegram bots, the proactive inbound watcher, and voice learning. Toggling a
    /// flag flips the matching AppState @Published property, whose Combine sink in AlfredApp
    /// starts/stops the corresponding service live.
    private var botsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ASSISTANT & BOTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)

            imessageBotGroup

            Divider()

            telegramBotGroup

            Divider()

            Toggle(isOn: $appState.inboundWatcherEnabled) {
                settingLabel("Proactive inbound watcher",
                             "Watches incoming messages and offers to draft a reply when one looks like it needs one. Needs Full Disk Access.")
            }
            .toggleStyle(.switch)

            Divider()

            departureRemindersGroup

            Divider()

            voiceLearningGroup
        }
    }

    private var departureRemindersGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $appState.departureRemindersEnabled) {
                settingLabel("Departure reminders",
                             "A heads-up when it's time to leave for a calendar event that has a location, based on travel time. Needs Location + Calendar access.")
            }
            .toggleStyle(.switch)

            if appState.departureRemindersEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Travel mode").font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $appState.departureTravelMode) {
                            Text("Walking").tag("walking")
                            Text("Driving").tag("driving")
                            Text("Transit").tag("transit")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    if appState.departureTravelMode == "transit" {
                        mapsKeyField
                    }
                }
            }
        }
    }

    private var mapsKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Google Maps API key").font(.system(size: 11, weight: .semibold))
            SecureField("needed for transit times", text: $mapsKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: mapsKeyInput) { _, _ in mapsKeyJustSaved = false }
            HStack(spacing: 8) {
                Button("Save key") { saveMapsKey() }
                    .controlSize(.small)
                    .disabled(mapsKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if mapsKeyJustSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green).labelStyle(.titleAndIcon)
                }
                if let url = URL(string: "https://console.cloud.google.com/google/maps-apis/credentials") {
                    Link("Get key ↗", destination: url).font(.system(size: 11))
                }
            }
            Text("Apple can't do transit times. Enable the Routes API in Google Cloud; usage stays free but a card is required to create the key.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveMapsKey() {
        let key = mapsKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        _ = KeychainHelper.save(service: "com.alfred.app", account: "googlemaps", value: key)
        mapsKeyInput = ""
        mapsKeyJustSaved = true
    }

    private var imessageBotGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $appState.imessageBotEnabled) {
                settingLabel("iMessage bot",
                             "Text Alfred from your phone in your own iMessage thread. Needs Full Disk Access + Automation for Messages.")
            }
            .toggleStyle(.switch)

            if appState.imessageBotEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Trigger word", "alfred", text: $appState.imessageBotTrigger)
                    labeledField("Your iMessage handle", "+1… or you@icloud.com", text: $appState.imessageBotOwnerHandle)
                }
            }
        }
    }

    private var telegramBotGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $appState.telegramBotEnabled) {
                settingLabel("Telegram bot",
                             "Text Alfred over Telegram — faster than iMessage, replies only to your chat.")
            }
            .toggleStyle(.switch)

            if appState.telegramBotEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Your chat ID", "numeric id from @userinfobot", text: $appState.telegramOwnerChatID)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bot token").font(.system(size: 11, weight: .semibold))
                        SecureField("paste token from @BotFather", text: $telegramTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: telegramTokenInput) { _, _ in telegramTokenJustSaved = false }
                        HStack(spacing: 8) {
                            Button("Save token") { saveTelegramToken() }
                                .controlSize(.small)
                                .disabled(telegramTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            if telegramTokenJustSaved {
                                Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
            }
        }
    }

    private var voiceLearningGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $appState.voiceLearningFromMessagesEnabled) {
                settingLabel("Voice learning",
                             "Learn your writing voice from your sent messages and emails, so drafts sound like you.")
            }
            .toggleStyle(.switch)

            if appState.voiceLearningFromMessagesEnabled {
                Label(AppState.voiceLearningDisclosure, systemImage: "info.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Standard two-line label used inside the settings toggles (title + secondary description).
    private func settingLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A captioned rounded-border text field bound to an AppState string flag.
    private func labeledField(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func saveTelegramToken() {
        let token = telegramTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        // Alfred writes the item itself → it owns the Keychain ACL, so the bot's later reads never
        // trigger an access prompt (the failure mode that silently kept the bot from polling).
        _ = KeychainHelper.save(service: "com.alfred.app", account: "telegram", value: token)
        telegramTokenInput = ""
        telegramTokenJustSaved = true
    }

    // MARK: - Routines tab

    @ViewBuilder
    private var routinesContent: some View {
        if routines.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                Text("No routines yet").font(.subheadline.bold())
                Text("Schedule a prompt that runs silently and notifies you.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(routines, id: \.id) { routine in
                        routineRow(routine)
                    }
                }
                .padding(10)
            }
        }
    }

    private func routineRow(_ routine: RoutineRecord) -> some View {
        let isRunning = routine.id.map { runningIDs.contains($0) } ?? false
        let isExpanded = routine.id != nil && expandedID == routine.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(routine.title.isEmpty ? "Untitled" : routine.title)
                    .font(.subheadline.bold())
                Spacer()
                Toggle("", isOn: Binding(
                    get: { routine.enabled },
                    set: { v in if let id = routine.id { store.setRoutineEnabled(id: id, enabled: v); reload() } }
                ))
                .labelsHidden()
                .controlSize(.mini)
            }
            Text(routine.prompt_text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Label(triggerLabel(routine), systemImage: triggerIcon(routine.trigger_type))
                    .font(.caption2).foregroundStyle(.secondary)
                if isRunning {
                    HStack(spacing: 3) {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                        Text("running…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let status = routine.last_status {
                    Text(status).font(.caption2)
                        .foregroundStyle(status == "success" ? .green : (status == "failed" ? .red : .orange))
                }
                Spacer()
                Button { runNow(routine) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.plain).help("Run now").disabled(isRunning)
                Button { toggleExpanded(routine) } label: {
                    Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.plain).help("Show output")
                Button { delete(routine) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete")
            }
            if isExpanded { routineOutput(routine) }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Per-routine output dropdown

    @ViewBuilder
    private func routineOutput(_ routine: RoutineRecord) -> some View {
        let history = routine.id.map { routineRuns[$0] ?? [] } ?? []
        Divider().padding(.vertical, 2)
        if routine.trigger_type == "api", let id = routine.id {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.caption2)
                Text("alfred://run?routine=\(id)")
                    .font(.caption2.monospaced()).textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
        }
        if history.isEmpty {
            Text("No runs yet — press play to run it now.")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(history, id: \.id) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(Self.statusGlyph(run.status))
                                .font(.caption2).foregroundStyle(Self.statusColor(run.status))
                            Text(Self.timeString(run.started_at))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(runText(run))
                            .font(.caption2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func runText(_ run: RunRecord) -> String {
        if let out = run.output_full, !out.isEmpty { return out }
        if let s = run.output_summary, !s.isEmpty { return s }
        if let e = run.error_text, !e.isEmpty { return e }
        return "(no output)"
    }

    private func triggerIcon(_ trigger: String) -> String {
        switch trigger {
        case "manual": return "hand.tap"
        case "api": return "link"
        default: return "clock"
        }
    }

    private func triggerLabel(_ routine: RoutineRecord) -> String {
        switch routine.trigger_type {
        case "manual": return "Manual"
        case "api": return "API"
        default: return routine.schedule_cron
        }
    }

    private func toggleExpanded(_ routine: RoutineRecord) {
        guard let id = routine.id else { return }
        if expandedID == id {
            expandedID = nil
        } else {
            expandedID = id
            routineRuns[id] = store.runsForRoutine(id: id)
        }
    }

    /// Marks the routine as running, opens its output dropdown, then fires it. The completion
    /// notification (`.alfredRoutineRunDidFinish`) clears the spinner and refreshes the output.
    private func runNow(_ routine: RoutineRecord) {
        guard let id = routine.id else { return }
        runningIDs.insert(id)
        expandedID = id
        routineRuns[id] = store.runsForRoutine(id: id)
        onRunNow(routine)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit Alfred", action: onQuit).controlSize(.small)
        }
        .padding(10)
    }

    // MARK: - Helpers

    private func reload() {
        routines = store.allRoutines()
    }

    private func delete(_ routine: RoutineRecord) {
        if let id = routine.id { store.deleteRoutine(id: id) }
        reload()
    }

    private static func statusGlyph(_ s: String) -> String {
        switch s {
        case "success": return "✓"
        case "failed": return "✗"
        case "blocked": return "⊘"
        default: return "…"
        }
    }

    private static func statusColor(_ s: String) -> Color {
        switch s {
        case "success": return .green
        case "failed": return .red
        case "blocked": return .orange
        default: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private static func timeString(_ epoch: Double) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}

private struct AddRoutineSheet: View {
    let store: MemoryStore
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var prompt = ""
    @State private var cron = "0 9 * * *"
    @State private var cronError: String?
    @State private var triggerType = "schedule"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Routine").font(.title3.bold())

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("Prompt — what Alfred should do", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            Picker("Trigger", selection: $triggerType) {
                Text("Schedule").tag("schedule")
                Text("Manual").tag("manual")
                Text("API").tag("api")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if triggerType == "schedule" {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Schedule (cron: min hour dom mon dow)", text: $cron)
                        .textFieldStyle(.roundedBorder)
                    if let cronError {
                        Text(cronError).font(.caption).foregroundStyle(.red)
                    }
                    Text("e.g. \"0 9 * * *\" daily 9am · \"*/30 * * * *\" every 30 min · \"0 8 * * 1\" Mondays 8am")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if triggerType == "manual" {
                Text("Runs only when you press play on the routine.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Runs when triggered externally via its alfred://run URL (shown after saving) or play.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text("Only read-only routines run unattended; anything that writes or sends is blocked and notified.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        let tz = TimeZone.current
        var cronToSave = ""
        var next: Double?
        if triggerType == "schedule" {
            guard let schedule = CronSchedule(cron) else {
                cronError = "Invalid cron expression."
                return
            }
            cronToSave = cron
            next = schedule.nextDate(after: Date(), in: tz)?.timeIntervalSince1970
        }
        let record = RoutineRecord(
            id: nil,
            title: title,
            prompt_text: prompt,
            schedule_cron: cronToSave,
            timezone: tz.identifier,
            enabled: true,
            policy_class: "unattended-safe",
            trigger_type: triggerType,
            last_run_at: nil,
            next_run_at: next,
            last_status: nil,
            last_output_summary: nil,
            created_at: Date().timeIntervalSince1970
        )
        store.addRoutine(record)
        onSave()
        dismiss()
    }
}
