import Foundation
import Security

enum PrivacyMode: String, CaseIterable, Codable, Equatable {
    case minimal
    case standard
    case personalized

    var label: String {
        switch self {
        case .minimal: return "Minimal"
        case .standard: return "Standard"
        case .personalized: return "Personalized"
        }
    }

    var description: String {
        switch self {
        case .minimal: return "No learning or personalization"
        case .standard: return "Project awareness + adaptive suggestions"
        case .personalized: return "All learning features enabled"
        }
    }
}

final class AppState: ObservableObject {

    private static let defaultProviderModels: [String: String] = [
        "local": "alfred",
        "openrouter": "meta-llama/llama-3.3-70b-instruct:free",
        "ollama": "phi3:mini",
        "gemini": "gemini-2.5-flash-lite",
        "groq": "llama-3.3-70b-versatile",
    ]

    @Published var selectedProvider: String {
        didSet {
            UserDefaults.standard.set(selectedProvider, forKey: "selectedProvider")
            selectedModel = providerModels[selectedProvider] ?? Self.defaultProviderModels[selectedProvider] ?? "alfred"
        }
    }

    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
            providerModels[selectedProvider] = selectedModel
        }
    }

    var providerModels: [String: String] {
        didSet {
            guard let data = try? JSONEncoder().encode(providerModels) else { return }
            UserDefaults.standard.set(data, forKey: "providerModels")
        }
    }

    @Published var ownerName: String {
        didSet { UserDefaults.standard.set(ownerName, forKey: "ownerName") }
    }

    @Published var isOnboardingComplete: Bool {
        didSet { UserDefaults.standard.set(isOnboardingComplete, forKey: "isOnboardingComplete") }
    }

    @Published var proactiveSuggestionsEnabled: Bool {
        didSet { UserDefaults.standard.set(proactiveSuggestionsEnabled, forKey: "proactiveSuggestionsEnabled") }
    }

    @Published var shellExecutionEnabled: Bool {
        didSet { UserDefaults.standard.set(shellExecutionEnabled, forKey: "shellExecutionEnabled") }
    }

    /// Opt-in: let Alfred drive the Mac's UI ("control my mac …") via the LLM action planner.
    /// Off by default — every run still requires the confirmation dialog and Accessibility, but a
    /// powerful capability shouldn't be on until the user explicitly turns it on.
    @Published var computerControlEnabled: Bool {
        didSet { UserDefaults.standard.set(computerControlEnabled, forKey: "computerControlEnabled") }
    }

    @Published var screenContextEnabled: Bool {
        didSet { UserDefaults.standard.set(screenContextEnabled, forKey: "screenContextEnabled") }
    }

    @Published var screenMonitoringEnabled: Bool

    /// Opt-in proactive watcher: scans new inbound mail/texts, triages whether they need a reply,
    /// and posts a "want me to respond?" notification. Off by default; nothing is ever sent without
    /// an explicit tap + the usual confirm/draft step.
    @Published var inboundWatcherEnabled: Bool {
        didSet { UserDefaults.standard.set(inboundWatcherEnabled, forKey: "inboundWatcherEnabled") }
    }

    /// Opt-in: notify when it's time to leave for an upcoming calendar event that has a location, based
    /// on travel time. Off by default. Needs Location + Calendar. See `DepartureWatcher`.
    @Published var departureRemindersEnabled: Bool {
        didSet { UserDefaults.standard.set(departureRemindersEnabled, forKey: "departureRemindersEnabled") }
    }
    /// Travel mode for the estimate: "walking" or "driving" (free, Apple MKDirections) or "transit"
    /// (Google Routes API — needs a Google Maps key in Keychain, account "googlemaps").
    @Published var departureTravelMode: String {
        didSet { UserDefaults.standard.set(departureTravelMode, forKey: "departureTravelMode") }
    }
    /// Arrive this many minutes before the event starts (folded into "leave by").
    @Published var departureArriveEarlyMinutes: Int {
        didSet { UserDefaults.standard.set(departureArriveEarlyMinutes, forKey: "departureArriveEarlyMinutes") }
    }
    /// Nudge this many minutes before "leave by" — the heads-up to start wrapping up.
    @Published var departurePackupLeadMinutes: Int {
        didSet { UserDefaults.standard.set(departurePackupLeadMinutes, forKey: "departurePackupLeadMinutes") }
    }

    /// User-facing disclosure for the voice-learning opt-in — surface this wherever the toggle is
    /// shown (there is no Settings UI yet; keep it in sync with the toggle's copy).
    static let voiceLearningDisclosure =
        "Learns your writing voice from your sent iMessages and emails, stored on your Mac. " +
        "When Alfred drafts with a cloud model, short snippets of that writing can be sent to that " +
        "model (redaction only removes obvious secrets like passwords or API keys). Use a local " +
        "model (Ollama) to keep everything on-device."

    /// Opt-in: learn Carlton's real writing voice from his SENT iMessages + emails (needs Full Disk
    /// Access for Messages / Automation for Mail / a connected Google account). Off by default. When
    /// on, sent messages are imported as writing samples so drafts sound like his actual voice, not
    /// the commands he types to Alfred. See `voiceLearningDisclosure` for the egress note.
    @Published var voiceLearningFromMessagesEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceLearningFromMessagesEnabled, forKey: "voiceLearningFromMessagesEnabled") }
    }

    /// Opt-in: text Alfred over iMessage. Carlton texts "<trigger> <command>" to HIMSELF and Alfred
    /// replies in the self-chat. Off by default. Needs Full Disk Access (read chat.db), Automation
    /// for Messages (send), and his own iMessage address. Outward actions require a text "yes".
    @Published var imessageBotEnabled: Bool {
        didSet { UserDefaults.standard.set(imessageBotEnabled, forKey: "imessageBotEnabled") }
    }
    /// Trigger word (default "alfred"); a self-message must start with it to be treated as a command.
    @Published var imessageBotTrigger: String {
        didSet { UserDefaults.standard.set(imessageBotTrigger, forKey: "imessageBotTrigger") }
    }
    /// The owner's own iMessage address (phone/email) — identifies the self-chat and where replies go.
    @Published var imessageBotOwnerHandle: String {
        didSet { UserDefaults.standard.set(imessageBotOwnerHandle, forKey: "imessageBotOwnerHandle") }
    }

    /// Opt-in: text Alfred over Telegram (dedicated bot, official Bot API). Off by default. Token
    /// lives in the Keychain (service com.alfred.app, account "telegram"); this is just the toggle.
    @Published var telegramBotEnabled: Bool {
        didSet { UserDefaults.standard.set(telegramBotEnabled, forKey: "telegramBotEnabled") }
    }
    /// The owner's Telegram chat id — the bot acts only on messages from this chat.
    @Published var telegramOwnerChatID: String {
        didSet { UserDefaults.standard.set(telegramOwnerChatID, forKey: "telegramOwnerChatID") }
    }

    /// Hermes: opt-in passive screen-TEXT capture (Accessibility) persisted to the local FTS5
    /// log. Off by default; nothing leaves the Mac.
    @Published var screenTextCaptureEnabled: Bool {
        didSet { UserDefaults.standard.set(screenTextCaptureEnabled, forKey: "screenTextCaptureEnabled") }
    }

    @Published var focusSensitivity: String {
        didSet { UserDefaults.standard.set(focusSensitivity, forKey: "focusSensitivity") }
    }

    @Published var memoryExtractionEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryExtractionEnabled, forKey: "memoryExtractionEnabled") }
    }

    @Published var conversationHistoryEnabled: Bool {
        didSet { UserDefaults.standard.set(conversationHistoryEnabled, forKey: "conversationHistoryEnabled") }
    }

    @Published var memoryRetentionDays: Int {
        didSet { UserDefaults.standard.set(memoryRetentionDays, forKey: "memoryRetentionDays") }
    }

    @Published var privacyMode: PrivacyMode {
        didSet { UserDefaults.standard.set(privacyMode.rawValue, forKey: "privacyMode") }
    }

    /// Blueprint v1 §7 privacy mode: when true, cloud providers are fully disabled —
    /// any cloud-bound command is blocked (never silently sent). Distinct from
    /// `privacyMode` above, which gates on-device learning, not cloud egress.
    @Published var cloudDisabled: Bool {
        didSet { UserDefaults.standard.set(cloudDisabled, forKey: "cloudDisabled") }
    }

    @Published var behavioralLearningEnabled: Bool {
        didSet { UserDefaults.standard.set(behavioralLearningEnabled, forKey: "behavioralLearningEnabled") }
    }

    @Published var projectAwarenessEnabled: Bool {
        didSet { UserDefaults.standard.set(projectAwarenessEnabled, forKey: "projectAwarenessEnabled") }
    }

    @Published var personalContextEnabled: Bool {
        didSet { UserDefaults.standard.set(personalContextEnabled, forKey: "personalContextEnabled") }
    }

    @Published var backupMaxCount: Int {
        didSet { UserDefaults.standard.set(backupMaxCount, forKey: "backupMaxBackupCount") }
    }

    @Published var backupEncryptDefault: Bool {
        didSet { UserDefaults.standard.set(backupEncryptDefault, forKey: "backupEncryptByDefault") }
    }

    @Published var backupAutoEnabled: Bool {
        didSet { UserDefaults.standard.set(backupAutoEnabled, forKey: "autoBackupEnabled") }
    }

    @Published var conversationHistory: [String] = []

    @Published var apiKey: String {
        didSet { Keychain.save(key: "alfred.apiKey", value: apiKey) }
    }

    init() {
        // "local" (bundled Qwen server) was retired in M8 → default + migrate to groq.
        let rawProvider = UserDefaults.standard.string(forKey: "selectedProvider") ?? "groq"
        let removedProviders = ["anthropic", "openai", "cerebras", "mistral", "local"]
        let provider = removedProviders.contains(rawProvider) ? "groq" : rawProvider
        selectedProvider = provider

        if let data = UserDefaults.standard.data(forKey: "providerModels"),
           let dict = try? JSONDecoder().decode([String: String].self, from: data)
        {
            providerModels = dict
        } else {
            providerModels = Self.defaultProviderModels
        }

        let savedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        selectedModel = removedProviders.contains(rawProvider) ? "alfred" : savedModel
        ownerName = UserDefaults.standard.string(forKey: "ownerName") ?? ""
        isOnboardingComplete = UserDefaults.standard.bool(forKey: "isOnboardingComplete")
        proactiveSuggestionsEnabled = UserDefaults.standard.object(forKey: "proactiveSuggestionsEnabled") as? Bool ?? false
        shellExecutionEnabled = UserDefaults.standard.object(forKey: "shellExecutionEnabled") as? Bool ?? false
        screenContextEnabled = UserDefaults.standard.object(forKey: "screenContextEnabled") as? Bool ?? true
        UserDefaults.standard.removeObject(forKey: "screenMonitoringEnabled")
        screenMonitoringEnabled = false
        inboundWatcherEnabled = UserDefaults.standard.bool(forKey: "inboundWatcherEnabled")
        departureRemindersEnabled = UserDefaults.standard.bool(forKey: "departureRemindersEnabled")
        departureTravelMode = UserDefaults.standard.string(forKey: "departureTravelMode") ?? "walking"
        departureArriveEarlyMinutes = UserDefaults.standard.object(forKey: "departureArriveEarlyMinutes") as? Int ?? 10
        departurePackupLeadMinutes = UserDefaults.standard.object(forKey: "departurePackupLeadMinutes") as? Int ?? 30
        voiceLearningFromMessagesEnabled = UserDefaults.standard.bool(forKey: "voiceLearningFromMessagesEnabled")
        imessageBotEnabled = UserDefaults.standard.bool(forKey: "imessageBotEnabled")
        imessageBotTrigger = UserDefaults.standard.string(forKey: "imessageBotTrigger") ?? "alfred"
        imessageBotOwnerHandle = UserDefaults.standard.string(forKey: "imessageBotOwnerHandle") ?? ""
        telegramBotEnabled = UserDefaults.standard.bool(forKey: "telegramBotEnabled")
        telegramOwnerChatID = UserDefaults.standard.string(forKey: "telegramOwnerChatID") ?? ""
        // Default ON: Alfred is meant to learn from your activity. Capture still requires the
        // user to grant Screen Recording permission, and can be turned off in the Profile tab.
        screenTextCaptureEnabled = UserDefaults.standard.object(forKey: "screenTextCaptureEnabled") as? Bool ?? true
        focusSensitivity = UserDefaults.standard.string(forKey: "focusSensitivity") ?? "medium"
        computerControlEnabled = UserDefaults.standard.object(forKey: "computerControlEnabled") as? Bool ?? false
        memoryExtractionEnabled = UserDefaults.standard.object(forKey: "memoryExtractionEnabled") as? Bool ?? false
        conversationHistoryEnabled = UserDefaults.standard.object(forKey: "conversationHistoryEnabled") as? Bool ?? true
        memoryRetentionDays = UserDefaults.standard.object(forKey: "memoryRetentionDays") as? Int ?? 90
        privacyMode = PrivacyMode(rawValue: UserDefaults.standard.string(forKey: "privacyMode") ?? "") ?? .standard
        cloudDisabled = UserDefaults.standard.object(forKey: "cloudDisabled") as? Bool ?? false
        behavioralLearningEnabled = UserDefaults.standard.object(forKey: "behavioralLearningEnabled") as? Bool ?? false
        projectAwarenessEnabled = UserDefaults.standard.object(forKey: "projectAwarenessEnabled") as? Bool ?? true
        personalContextEnabled = UserDefaults.standard.object(forKey: "personalContextEnabled") as? Bool ?? false
        backupMaxCount = UserDefaults.standard.object(forKey: "backupMaxBackupCount") as? Int ?? 10
        backupEncryptDefault = UserDefaults.standard.object(forKey: "backupEncryptByDefault") as? Bool ?? false
        backupAutoEnabled = UserDefaults.standard.object(forKey: "autoBackupEnabled") as? Bool ?? true
        apiKey = Keychain.load(key: "alfred.apiKey") ?? ""
    }
}

enum Keychain {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.alfred.app",
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.alfred.app",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.alfred.app",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
