import SwiftUI
import VertusKit

@main
struct VertusPhoneApp: App {
    @StateObject private var model = PhoneAppModel()
    @State private var notifier: PhoneNotifier?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView(model: model)
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(.white)
                .onAppear {
                    if notifier == nil {
                        let n = PhoneNotifier(store: model.store)
                        notifier = n
                        n.requestAuthorization()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        model.handleSceneActive()
                    }
                }
        }
    }
}

/// Tab root: Agents (roster + chat), Memory, Threads, Settings — the phone
/// keeps the same monochrome VERTUS look as the Mac app.
struct RootTabView: View {
    @ObservedObject var model: PhoneAppModel
    @State private var selection = 0
    /// Agent to open from a notification tap.
    @State private var deepLinkBox: AgentIDBox?

    var body: some View {
        // The store instance is swapped on settings reconfigure; .id(epoch)
        // forces every child to rebuild against the new store.
        TabView(selection: $selection) {
            NavigationStack { RosterView() }
                .tabItem { Label("Agents", systemImage: "person.2.fill") }
                .tag(0)
            NavigationStack { MemoryView() }
                .tabItem { Label("Memory", systemImage: "brain") }
                .tag(1)
            NavigationStack { ThreadsView() }
                .tabItem { Label("Threads", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(2)
            NavigationStack { SettingsView(model: model) }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .id(model.storeEpoch)
        .environmentObject(model.store)
        .onReceive(NotificationCenter.default.publisher(for: .vertusOpenAgent)) { note in
            if let id = note.object as? String {
                deepLinkBox = AgentIDBox(id: id)
                selection = 0
            }
        }
        .sheet(item: $deepLinkBox) { box in
            AgentChatSheet(agentID: box.id)
        }
    }
}

/// Minimal Identifiable wrapper so .sheet(item:) can drive on agent ids.
struct AgentIDBox: Identifiable {
    let id: String
}

struct AgentChatSheet: View {
    let agentID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AgentChatView(agentID: agentID)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}