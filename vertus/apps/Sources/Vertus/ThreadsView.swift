import SwiftUI
import VertusKit

/// Bot-to-bot conversation sheet: thread list (subject, participants,
/// unread badge, last activity) and per-thread conversation rendered
/// distinctly from the human chat — every message shows sender → recipient,
/// kind, and depth, on a tinted bubble. Opening a thread marks it read.
/// Refreshes live via FleetStore.threads (fed by bot_message events).
struct ThreadsView: View {
    @EnvironmentObject private var store: FleetStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedThreadID: String?
    @State private var messages: [BotMessage] = []
    @State private var loadedThreadID: String?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bot threads")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Refresh") {
                    Task {
                        await store.refreshThreads()
                        if let id = selectedThreadID { await load(id) }
                    }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            if store.threads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No bot-to-bot conversations yet.")
                        .font(.system(size: 13))
                    Text("Bots message each other via the hub; delegated work and its results land here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                HSplitView {
                    // Thread list (left)
                    List(selection: $selectedThreadID) {
                        ForEach(store.threads) { thread in
                            threadRow(thread)
                                .tag(thread.threadId)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 220, idealWidth: 260)

                    // Conversation (right)
                    if let id = selectedThreadID {
                        conversation(id)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("Select a thread")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onChange(of: selectedThreadID) { id in
                    if let id { Task { await load(id) } }
                }
            }
        }
        .onAppear {
            Task { await store.refreshThreads() }
        }
    }

    private func threadRow(_ thread: BotThread) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if thread.unread > 0 {
                    Text("\(thread.unread)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.blue))
                }
            }
            Text(participantsText(thread))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Self.relative(thread.lastMessageAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func conversation(_ threadID: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(threadTitle(threadID))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let err = loadError {
                    Text(err)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(10)
            Divider()
            if loadedThreadID == threadID {
                if messages.isEmpty {
                    VStack(spacing: 6) {
                        Text("No messages in this thread.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                // Newest-first from the API; display ascending.
                                ForEach(messages.reversed(), id: \.msgId) { msg in
                                    botMessageRow(msg)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: messages.count) { _ in
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(messages.first?.msgId, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(white: 0.09))
    }

    /// Visually distinct from the human chat: tinted bubble with explicit
    /// sender → recipient, kind tag, and hop depth.
    private func botMessageRow(_ msg: BotMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(store.displayName(for: msg.fromAgent)) → \(store.displayName(for: msg.toAgent))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(msg.kind == "result" ? Color.green.opacity(0.9)
                                     : msg.kind == "handoff" ? Color.orange.opacity(0.9)
                                     : Color.secondary)
                Text(kindTag(msg))
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(kindColor(msg).opacity(0.18)))
                    .foregroundStyle(kindColor(msg))
                if msg.status != "delivered" {
                    Text(msg.status.replacingOccurrences(of: "dropped_", with: "dropped: "))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("hop \(msg.depth)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text((try? AttributedString(markdown: msg.body,
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(msg.body))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(bubbleColor(msg.kind))
                )
        }
        .padding(.vertical, 1)
    }

    private func kindTag(_ msg: BotMessage) -> String {
        switch msg.kind {
        case "handoff": return "DELEGATED"
        case "result": return "RESULT"
        default: return "MESSAGE"
        }
    }

    private func kindColor(_ msg: BotMessage) -> Color {
        switch msg.kind {
        case "handoff": return .orange
        case "result": return .green
        default: return .blue
        }
    }

    private func bubbleColor(_ kind: String) -> Color {
        switch kind {
        case "handoff": return Color.orange.opacity(0.12)
        case "result": return Color.green.opacity(0.10)
        default: return Color.blue.opacity(0.10)
        }
    }

    private func participantsText(_ thread: BotThread) -> String {
        thread.participants.map { store.displayName(for: $0) }.joined(separator: ", ")
    }

    private func threadTitle(_ threadID: String) -> String {
        store.threads.first { $0.threadId == threadID }?.subject ?? threadID
    }

    private func load(_ threadID: String) async {
        selectedThreadID = threadID
        do {
            messages = try await store.botMessages(threadID: threadID)
            loadedThreadID = threadID
            loadError = nil
            await store.markThreadRead(threadID)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func relative(_ ts: Double) -> String {
        let elapsed = Date().timeIntervalSince1970 - ts
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}