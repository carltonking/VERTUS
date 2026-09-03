import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String        // "you" | "vertus"
    var text: String
}

struct ChatView: View {
    @State private var client = VertusClient(
        baseURL: URL(string: UserDefaults.standard.string(forKey: "vertus.baseURL")
            ?? "http://100.84.144.109:8787")!,
        token: KeychainStore.load() ?? ""
    )
    @State private var messages: [ChatMessage] = []
    @State private var prompt = ""
    @State private var streaming = false
    @State private var activity: String?
    @State private var showingSettings = false
    @State private var showConnecting = false
    @State private var connectionNote: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !client.isConfigured {
                    setupBanner
                }
                if showConnecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting to the VERTUS hub…").font(.footnote)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                if let connectionNote {
                    HStack {
                        Image(systemName: "wifi.exclamationmark")
                        Text(connectionNote).font(.footnote)
                        Spacer()
                    }
                    .foregroundStyle(Color(white: 0.85))
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color(white: 0.16))
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty && !streaming {
                                emptyState
                            }
                            ForEach(messages) { msg in
                                bubble(for: msg)
                            }
                            if streaming, let activity, !activity.isEmpty {
                                Text("\(activity)…")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                            }
                        }
                        .padding(16)
                        .id("bottom")
                    }
                    .onChange(of: messages.count) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: streaming) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    TextField("Ask VERTUS…", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .disabled(streaming || !client.isConfigured)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || streaming || !client.isConfigured)
                }
                .padding(12)
            }
            .navigationTitle("VERTUS")
            .navigationBarTitleDisplayMode(.inline)
            // VERTUS theme: dark, strictly monochrome — no accent colors.
            .tint(.white)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(client: $client, onReconnect: reconnect)
            }
            .task {
                // Reconnect: load stored token; verify connectivity once.
                guard KeychainStore.load() != nil else { return }
                await verifyAndNote()
            }
        }
    }

    private var setupBanner: some View {
        Button { showingSettings = true } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("VERTUS hub not configured — add the server URL and token from your Mac")
                Spacer()
            }
            .font(.footnote)
            .foregroundStyle(Color(white: 0.85))
            .padding(10)
            .background(Color(white: 0.16))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text("Chat with VERTUS from anywhere.")
                .foregroundStyle(.secondary)
            Text("Conversations run on your Mac and sync with the quick bar and CLI.")
                .font(.footnote).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func bubble(for msg: ChatMessage) -> some View {
        let isUser = msg.role == "you"
        // Monochrome scheme: your messages are light-gray bubbles with black
        // text; VERTUS's are dark-gray bubbles with white text.
        return HStack {
            if isUser { Spacer(minLength: 48) }
            Text(msg.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isUser ? Color(white: 0.85) : Color(white: 0.22))
                .foregroundStyle(isUser ? Color(white: 0.05) : Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming, client.isConfigured else { return }
        prompt = ""
        messages.append(ChatMessage(role: "you", text: text))
        messages.append(ChatMessage(role: "vertus", text: ""))
        streaming = true
        activity = "thinking"
        client.send(text) { event in
            DispatchQueue.main.async {
                switch event {
                case .text(let chunk):
                    if messages.last?.role == "vertus" {
                        messages[messages.count - 1].text += chunk
                    } else {
                        messages.append(ChatMessage(role: "vertus", text: chunk))
                    }
                case .activity(let a):
                    activity = a
                case .done, .error:
                    streaming = false
                    activity = nil
                    if case .error(let message) = event {
                        if messages.last?.role == "vertus", messages.last?.text.isEmpty == true {
                            messages[messages.count - 1].text = "Error: \(message)"
                        } else {
                            messages.append(ChatMessage(role: "vertus", text: "Error: \(message)"))
                        }
                    }
                }
            }
        }
    }

    private func reconnect() {
        showConnecting = true
        connectionNote = nil
        Task {
            let ok = await client.checkHealth()
            await MainActor.run {
                showConnecting = false
                connectionNote = ok ? nil : "Hub unreachable — check Tailscale and that the server is running."
            }
        }
    }

    private func verifyAndNote() async {
        showConnecting = true
        let ok = await client.checkHealth()
        await MainActor.run {
            showConnecting = false
            if !ok { connectionNote = "Hub unreachable — check Tailscale and the server." }
        }
    }
}

struct SettingsView: View {
    @Binding var client: VertusClient
    var onReconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var token: String
    @State private var status = ""

    init(client: Binding<VertusClient>, onReconnect: @escaping () -> Void) {
        _client = client
        self.onReconnect = onReconnect
        _baseURL = State(initialValue: client.wrappedValue.baseURL.absoluteString)
        _token = State(initialValue: client.wrappedValue.token)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Hub") {
                    TextField("Server URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Bearer token (from ~/.vertus/token on your Mac)", text: $token)
                }
                Section {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VERTUS Hub")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        client = VertusClient(
                            baseURL: URL(string: baseURL.trimmingCharacters(in: .whitespaces))
                                ?? URL(string: "http://100.84.144.109:8787")!,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        UserDefaults.standard.set(client.baseURL.absoluteString, forKey: "vertus.baseURL")
                        if !client.token.isEmpty { KeychainStore.save(client.token) } else { KeychainStore.clear() }
                        status = ""
                        dismiss()
                        onReconnect()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
