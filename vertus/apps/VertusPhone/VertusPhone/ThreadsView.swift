import SwiftUI
import VertusKit

/// Bot-to-bot conversations, visually distinct from your own chat: a thread
/// list, then per-thread messages. Refreshed live whenever a bot_message
/// fleet event lands (the store re-fetches the thread list).
struct ThreadsView: View {
    @EnvironmentObject private var store: FleetStore

    var body: some View {
        List {
            if store.threads.isEmpty {
                emptyState
            }
            ForEach(store.threads) { thread in
                NavigationLink(value: thread.threadId) {
                    ThreadRowView(thread: thread)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Bot threads")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { threadID in
            ThreadDetailView(threadID: threadID)
        }
        .task { await store.refreshThreads() }
        .refreshable { await store.refreshThreads() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No bot-to-bot conversations yet")
                .foregroundStyle(.secondary)
            Text("When one of your agents delegates to another, the thread appears here.")
                .font(.footnote).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }
}

struct ThreadRowView: View {
    @EnvironmentObject private var store: FleetStore
    let thread: BotThread

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(thread.subject.isEmpty ? "Untitled thread" : thread.subject)
                    .font(.subheadline).fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if thread.unread > 0 {
                    Text("\(thread.unread)").font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white).foregroundStyle(.black)
                        .clipShape(Capsule())
                }
            }
            Text(participantsLine)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var participantsLine: String {
        thread.participants
            .map { store.displayName(for: $0) }
            .joined(separator: " ↔ ")
    }
}

struct ThreadDetailView: View {
    let threadID: String
    @EnvironmentObject private var store: FleetStore
    @State private var messages: [BotMessage] = []
    @State private var subject = "Thread"
    @State private var errorNote: String?

    var body: some View {
        Group {
            if messages.isEmpty {
                VStack {
                    Text("No messages").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { msg in
                                ThreadBubbleView(msg: msg, store: store)
                                    .id(msg.msgId)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(12)
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle(subject)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            await store.markThreadRead(threadID)
        }
        .alert("VERTUS", isPresented: Binding(
            get: { errorNote != nil },
            set: { if !$0 { errorNote = nil } }
        )) {
            Button("OK") { errorNote = nil }
        } message: {
            Text(errorNote ?? "")
        }
    }

    private func load() async {
        do {
            messages = try await store.botMessages(threadID: threadID)
            if let thread = store.threads.first(where: { $0.threadId == threadID }),
               !thread.subject.isEmpty {
                subject = thread.subject
            }
        } catch {
            errorNote = (error as? VertusError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

struct ThreadBubbleView: View {
    let msg: BotMessage
    @ObservedObject var store: FleetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(store.displayName(for: msg.fromAgent))
                    .font(.caption).bold()
                Text(kindLabel(msg.kind))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(msg.body)
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(white: 0.22))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "handoff": return "handoff"
        case "result": return "result"
        default: return "message"
        }
    }
}