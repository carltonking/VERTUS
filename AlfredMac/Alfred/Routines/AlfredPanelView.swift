import AppKit
import SwiftUI

/// The menu-bar popover panel (weather-widget style) — the control surface opened by clicking
/// the status item. Hosts Routines + the Activity/Privacy log. NOT a window.
struct AlfredPanelView: View {
    let store: MemoryStore
    var screenTextMonitor: ScreenTextMonitor?
    var meetingManager: MeetingCaptureManager?
    var syllabusService: SyllabusImportService?
    var ownerName: String = ""
    var onRunNow: (RoutineRecord) -> Void
    var onQuit: () -> Void
    var onScreenTextToggle: (Bool) -> Void = { _ in }
    @ObservedObject var appState: AppState

    enum Tab: String, CaseIterable {
        case routines = "Routines", school = "School", reminders = "Reminders", profile = "Profile", settings = "Settings"
        var icon: String {
            switch self {
            case .routines: return "clock"
            case .school: return "graduationcap"
            case .reminders: return "line.3.horizontal"
            case .profile: return "person.crop.circle"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var tab: Tab = .routines
    @State private var routines: [RoutineRecord] = []
    @State private var showingAdd = false
    @State private var editingRoutine: RoutineRecord?
    /// Routine ids with a run in flight (shows a spinner instead of last status).
    @State private var runningIDs: Set<Int64> = []
    /// The routine whose output dropdown is expanded, plus its cached run history.
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

    @State private var braveKeyInput = ""
    @State private var braveKeyJustSaved = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Image(systemName: t.icon)
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                            .background(tab == t ? Color.accentColor.opacity(0.15) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t.rawValue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340, height: 460)
        .onAppear(perform: reload)
        .onAppear { if let s = syllabusService, s.phase != .list { tab = .school } } // resume an in-progress import
        .onChange(of: tab) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .alfredRoutineRunDidFinish)) { note in
            // A run (manual, scheduled, or API) finished — clear its spinner and refresh row status.
            if let id = note.object as? Int64 {
                runningIDs.remove(id)
            }
            reload()
        }
        .sheet(isPresented: $showingAdd) {
            AddRoutineSheet(store: store) { reload() }
        }
        .sheet(item: $editingRoutine) { routine in
            AddRoutineSheet(store: store, existing: routine) { reload() }
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
        case .school:
            if let syllabusService {
                CoursesTabView(service: syllabusService)
            } else {
                Text("Set up your AI provider in Settings first.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding()
            }
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
                OwnerConfigStatusView(appState: appState)

                Divider()

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

            fallbackChainNote

            Divider().padding(.vertical, 2)

            Toggle(isOn: $appState.smartRoutingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart routing (auto-pick best model)").font(.system(size: 12, weight: .semibold))
                    Text("Analyzes each prompt on-device and delegates it: Ollama (local) for private prompts, a configured cloud model (Groq/Gemini) for research, recency, or heavy reasoning. Otherwise uses the provider above. Set a cloud key so the cloud half works.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .onChange(of: appState.selectedProvider) { _, _ in
            providerKeyInput = ""; providerKeyJustSaved = false
        }
    }

    /// Shows the automatic fallback order so a silent provider switch never looks like a bug. Save a key
    /// for more than one provider and Alfred drains them in this order as each free tier runs out.
    private var fallbackChainNote: some View {
        let chain = LLMRouter.chainIDs(primary: appState.selectedProvider)
            .map { id in Self.providerChoices.first { $0.id == id }?.label ?? id }
            .joined(separator: " → ")
        return Label(
            "Auto-fallback: \(chain). If one is rate-limited or its key dies, Alfred retries the next one — no interruption. Add keys for more providers to make the chain longer.",
            systemImage: "arrow.triangle.branch"
        )
        .font(.system(size: 10)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
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

            Divider()

            webSearchGroup
        }
    }

    private var webSearchGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Web search (optional Tavily key)").font(.system(size: 11, weight: .semibold))
            Text("Alfred searches with keyless DuckDuckGo for free — no key needed. For more reliable results in routines, add a Tavily key: free, 1,000 searches/month, NO credit card. (Brave also works but now needs a paid plan.)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("tavily api key (optional)", text: $braveKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: braveKeyInput) { _, _ in braveKeyJustSaved = false }
            HStack(spacing: 8) {
                Button("Save key") { saveBraveKey() }
                    .controlSize(.small)
                    .disabled(braveKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if braveKeyJustSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green).labelStyle(.titleAndIcon)
                }
                if let url = URL(string: "https://app.tavily.com") {
                    Link("Get free key ↗", destination: url).font(.system(size: 11))
                }
            }
        }
    }

    private func saveBraveKey() {
        let key = braveKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        _ = KeychainHelper.save(service: "com.alfred.app", account: "tavily", value: key)
        braveKeyInput = ""
        braveKeyJustSaved = true
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
                statusView(routine, isRunning: isRunning)
                Spacer()
                Button { runNow(routine) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.plain).help("Run now").disabled(isRunning)
                Button { editingRoutine = routine } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("Edit")
                Button { delete(routine) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete")
            }
            if routine.trigger_type == "api", let id = routine.id {
                HStack(spacing: 4) {
                    Image(systemName: "link").font(.caption2)
                    Text("alfred://run?routine=\(id)")
                        .font(.caption2.monospaced()).textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Compact one-line status: running / success / error: <reason>.
    @ViewBuilder
    private func statusView(_ routine: RoutineRecord, isRunning: Bool) -> some View {
        if isRunning {
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
                Text("running").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            switch routine.last_status {
            case "success":
                Text("success").font(.caption2).foregroundStyle(.green)
            case "failed":
                Text("error: \(routine.last_output_summary ?? "unknown")")
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            case "awaiting_confirm":
                Text("awaiting confirmation").font(.caption2).foregroundStyle(.yellow)
            case .some(let s):
                Text(s).font(.caption2).foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }
        }
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

    /// Marks the routine as running, then fires it. The completion notification
    /// (`.alfredRoutineRunDidFinish`) clears the spinner and refreshes the row status.
    private func runNow(_ routine: RoutineRecord) {
        guard let id = routine.id else { return }
        runningIDs.insert(id)
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

}

private struct AddRoutineSheet: View {
    let store: MemoryStore
    let existing: RoutineRecord?
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var prompt: String
    @State private var cron: String
    @State private var cronError: String?
    @State private var triggerType: String

    /// `existing == nil` → create a new routine; otherwise edit it in place (id/created_at/enabled
    /// and run history are preserved; only the edited fields change).
    init(store: MemoryStore, existing: RoutineRecord? = nil, onSave: @escaping () -> Void) {
        self.store = store
        self.existing = existing
        self.onSave = onSave
        _title = State(initialValue: existing?.title ?? "")
        _prompt = State(initialValue: existing?.prompt_text ?? "")
        let existingCron = existing?.schedule_cron ?? ""
        _cron = State(initialValue: existingCron.isEmpty ? "every day at 09:00" : existingCron)
        _cronError = State(initialValue: nil)
        _triggerType = State(initialValue: existing?.trigger_type ?? "schedule")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Routine" : "Edit Routine").font(.title3.bold())

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt — what Alfred should do")
                    .font(.caption).foregroundStyle(.secondary)
                // TextEditor scrolls internally once the prompt outgrows the fixed height, so long
                // prompts stay fully viewable/editable instead of being clipped.
                TextEditor(text: $prompt)
                    .font(.callout)
                    .frame(height: 150)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            Picker("Trigger", selection: $triggerType) {
                Text("Schedule").tag("schedule")
                Text("Manual").tag("manual")
                Text("API").tag("api")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if triggerType == "schedule" {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("When to run — e.g. “every day at 0600”", text: $cron)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: cron) { _, _ in cronError = nil }
                    if let cronError {
                        Text(cronError).font(.caption).foregroundStyle(.red)
                    } else if let preview = schedulePreview {
                        Text(preview).font(.caption2).foregroundStyle(.green)
                    }
                    Text("Plain English works: “every day at 0600”, “weekdays at 8am”, “mondays at 9:30pm”, “every 30 minutes”. Cron (“0 6 * * *”) still works too.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if triggerType == "manual" {
                Text("Runs only when you press play on the routine.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Runs when triggered externally via its alfred://run URL (shown after saving) or play.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text("Read-only routines run automatically. Anything that writes or sends is drafted first, then waits for you to tap “Run now” in a notification.")
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

    /// Live "what this resolves to" for the schedule field: interprets the text as cron or plain
    /// English and shows the resulting cron + next fire time, so the user gets instant feedback.
    private var schedulePreview: String? {
        let trimmed = cron.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expr = CronSchedule(trimmed) != nil ? trimmed : NaturalSchedule.cron(from: trimmed)
        guard let expr, let sched = CronSchedule(expr) else { return nil }
        var line = "→ \(expr)"
        if let next = sched.nextDate(after: Date(), in: .current) {
            line += " · next \(Self.schedulePreviewFormatter.string(from: next))"
        }
        return line
    }

    private static let schedulePreviewFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f
    }()

    private func save() {
        let tz = TimeZone.current
        var cronToSave = ""
        var next: Double?
        if triggerType == "schedule" {
            // Accept raw cron OR plain English ("every day at 0600"). Store the resolved cron so the
            // scheduler stays cron-based — only the input is natural language.
            let trimmed = cron.trimmingCharacters(in: .whitespaces)
            let expr = CronSchedule(trimmed) != nil ? trimmed : (NaturalSchedule.cron(from: trimmed) ?? "")
            guard let schedule = CronSchedule(expr) else {
                cronError = "Couldn't read that schedule. Try “every day at 0600” or cron “0 6 * * *”."
                return
            }
            cronToSave = expr
            next = schedule.nextDate(after: Date(), in: tz)?.timeIntervalSince1970
        }
        if var rec = existing {
            // Edit in place — preserve id, created_at, enabled, and run history.
            rec.title = title
            rec.prompt_text = prompt
            rec.schedule_cron = cronToSave
            rec.timezone = tz.identifier
            rec.trigger_type = triggerType
            rec.next_run_at = next
            store.updateRoutine(rec)
        } else {
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
        }
        onSave()
        dismiss()
    }
}
