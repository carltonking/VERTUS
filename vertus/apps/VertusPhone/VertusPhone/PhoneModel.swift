import Foundation
import Combine
import UserNotifications
import VertusKit

// MARK: - Phone config
// Base URL precedence: UserDefaults "vertus.baseURL" (set by the settings
// screen — a phone has no shell to set env vars) > http://127.0.0.1:8787.
// The simulator shares the Mac's loopback, so the default just works there;
// a real device must enter the Mac's Tailscale address once in Settings.
// The old hardcoded tailnet IP is gone — there is no baked-in address.
// Token: Keychain only (the phone cannot read ~/.vertus/token, and the
// sandbox file fallback in ServerConfig.load never exists on iOS).

enum PhoneConfig {
    /// Token precedence mirrors the Mac's ServerConfig: a UserDefaults
    /// override first ("vertus.token" — how the simulator/CI injects a
    /// token via `simctl spawn defaults write`, since the Keychain cannot be
    /// seeded from outside the app), then the Keychain. The Settings screen
    /// always writes the Keychain and clears the override.
    static func load() -> ServerConfig {
        let defaults = UserDefaults.standard
        let base = defaults.string(forKey: "vertus.baseURL")
            ?? "http://127.0.0.1:8787"
        let token = defaults.string(forKey: "vertus.token")
            ?? KeychainStore.load()
            ?? ""
        return ServerConfig(baseURL: base, token: token)
    }

    static func save(baseURL: String, token: String) {
        UserDefaults.standard.set(baseURL, forKey: "vertus.baseURL")
        if token.isEmpty { KeychainStore.clear() } else { KeychainStore.save(token) }
        // The override exists only for external injection; a real save wins.
        UserDefaults.standard.removeObject(forKey: "vertus.token")
    }
}

// MARK: - App model
// The one FleetStore for the app; recreated when settings change (the
// stream cursor persists on disk, so a config change resumes from the last
// seen seq — no gap, no duplicate).

@MainActor
final class PhoneAppModel: ObservableObject {
    @Published var store: FleetStore
    /// Bumped whenever the store instance is swapped; RootTabView keys its
    /// children on this so every view re-binds to the new store.
    @Published private(set) var storeEpoch = 0

    init() {
        let config = PhoneConfig.load()
        store = Self.makeStore(config: config)
        store.start()
    }

    private static func makeStore(config: ServerConfig) -> FleetStore {
        let client = VertusHTTPClient(config: config)
        let stream = FleetStream(config: config, cursor: StreamCursor(processName: "phone"))
        return FleetStore(client: client, stream: stream)
    }

    /// Rebuild the client/stream/store after a settings change.
    func reconfigure() {
        store.stop()
        store = Self.makeStore(config: PhoneConfig.load())
        storeEpoch += 1
        store.start()
    }

    /// iOS suspends the app in the background; the URLSession stream dies
    /// with it. On return to the foreground force a reconnect — the
    /// persisted cursor makes the replay cover exactly the suspended span.
    func handleSceneActive() {
        store.stream.reconnectNow()
    }
}

// MARK: - Notifications
// Local notification on background-run completion, mirroring the Mac app:
// suppressed for the agent whose chat is on screen (foregroundAgentID) and
// for muted agents. On iOS this fires while the app is alive (foreground or
// briefly backgrounded); a fully suspended app learns on resume via the
// unread badge + since= replay, since iOS cannot run code while suspended.

@MainActor
final class PhoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let store: FleetStore

    init(store: FleetStore) {
        self.store = store
        super.init()
        UNUserNotificationCenter.current().delegate = self
        store.onBackgroundCompletion = { [weak self] agent, event in
            self?.notify(agent: agent, event: event)
        }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Degrade silently: the in-app unread badge still works.
        }
    }

    private func notify(agent: Agent, event: WireEvent) {
        let muted = SharedUIState.mutedAgentIDs().contains(agent.id)
        guard !muted else { return }
        let title: String
        let body: String
        switch event.type {
        case "error":
            title = "\(agent.rosterLabel) hit an error"
            body = event.message ?? "The run failed — open VERTUS to see why."
        case "cancelled":
            title = "\(agent.rosterLabel) was stopped"
            body = "The run was cancelled."
        default:
            title = "\(agent.rosterLabel) finished"
            body = latestLine(of: event) ?? "Open VERTUS to see the result."
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["agent_id": agent.id]
        let request = UNNotificationRequest(
            identifier: "run-\(agent.id)-\(event.runId ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func latestLine(of event: WireEvent) -> String? {
        guard let text = event.text else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        return lines.last.map { String($0.prefix(140)) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let agentID = response.notification.request.content.userInfo["agent_id"] as? String
        NotificationCenter.default.post(name: .vertusOpenAgent, object: agentID)
    }
}

extension Notification.Name {
    static let vertusOpenAgent = Notification.Name("vertus.openAgent")
}