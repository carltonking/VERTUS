import SwiftUI

/// Main screen: a Hermes-style chat (message list + composer), with memory
/// and settings reachable from the toolbar. No floating bar here — this is a
/// full chat client.
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = ChatViewModel(settings: .shared)
    @State private var draft = ""
    @State private var showingSettings = false
    @State private var showingMemory = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                inputBar
            }
            .navigationTitle("Alfred")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingMemory = true
                    } label: {
                        Label("Memory", systemImage: "brain")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingMemory) { MemoryView() }
        }
    }

    // MARK: - Pieces

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if viewModel.isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Hermes is thinking…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Chat with Hermes")
                .font(.headline)
            Text("Serving \(settings.baseURL) · model \(settings.model)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message Alfred…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
            .accessibilityLabel("Send")
        }
        .padding()
    }

    private func send() {
        viewModel.send(draft)
        draft = ""
    }
}

/// One chat bubble; user messages right-aligned and tinted, assistant
/// messages left-aligned on the system background.
private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            Text(message.content)
                .padding(10)
                .background(message.isUser ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(message.isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
            if !message.isUser { Spacer(minLength: 48) }
        }
    }
}
