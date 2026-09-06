import AppKit
import SwiftUI
import UserNotifications
import VertusKit

/// UNUserNotificationCenter.current() raises NSInternalInconsistencyException
/// ("bundleProxyForCurrentProcess is nil") when the process has no app bundle
/// — i.e. a bare binary launched straight from .build/ during development.
/// Degrade cleanly: notifications off, everything else works. The bundled
/// VERTUS.app always gets real banners.
var notificationsAvailable: Bool {
    Bundle.main.bundleURL.pathExtension == "app"
}

// MARK: - Notification service
// Background completion is the point of the fleet: when a run reaches a
// terminal state for an agent that is NOT in the foreground (different
// sidebar selection, another app frontmost, or the window miniaturized),
// post a user notification. Clicking it opens that agent.

final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let store: FleetStore

    @MainActor
    init(store: FleetStore) {
        self.store = store
        super.init()
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        store.onBackgroundCompletion = { [weak self] agent, event in
            self?.notify(agent: agent, event: event)
        }
    }

    @MainActor
    private func notify(agent: Agent, event: WireEvent) {
        guard notificationsAvailable else { return }
        let muted = SharedUIState.mutedAgentIDs().contains(agent.id)
        guard !muted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agent.rosterLabel) finished"
        content.subtitle = event.type == "error" ? "Error" : "Done"
        if event.type == "error" {
            content.body = event.message ?? "run failed"
        } else {
            let activity = store.latestActivityText(for: agent.id) ?? "run completed"
            content.body = String(activity.prefix(120))
        }
        content.userInfo = ["agent_id": agent.id]
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "vertus-completion-\(agent.id)-\(event.runId ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Show while the app is frontmost (banner), don't stack duplicates.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let agentID = response.notification.request.content.userInfo["agent_id"] as? String {
            Task { @MainActor in
                store.selectedAgentID = agentID
                store.foregroundAgentID = agentID
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}

// MARK: - Root

struct FleetRootView: View {
    @EnvironmentObject private var store: FleetStore
    @State private var notifier: CompletionNotifier?
    @State private var showEditor = false
    @State private var showActivity = false
    @State private var editorMode: EditorMode = .create

    enum EditorMode: Identifiable {
        case create
        case edit(Agent)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let a): return "edit-\(a.id)"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            FleetSidebarView(
                onNewAgent: { editorMode = .create; showEditor = true },
                onEditAgent: { agent in editorMode = .edit(agent); showEditor = true },
                onShowActivity: { showActivity = true },
                onShowMemory: { AppDelegate.shared?.showMemoryWindow() }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let id = store.selectedAgentID, let state = store.live[id] {
                AgentChatView(agentID: id, live: state)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No agent selected")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Pick an agent in the roster, or create one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showEditor) {
            AgentEditorView(mode: editorMode)
        }
        .sheet(isPresented: $showActivity) {
            FleetActivityView()
                .frame(width: 720, height: 520)
        }
        .onAppear {
            if notifier == nil { notifier = CompletionNotifier(store: store) }
            store.start()
            store.foregroundAgentID = store.selectedAgentID
        }
        .onChange(of: store.selectedAgentID) { id in
            store.foregroundAgentID = id
        }
    }
}