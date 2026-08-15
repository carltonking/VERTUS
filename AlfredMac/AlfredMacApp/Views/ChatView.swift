//
//  ChatView.swift
//  AlfredMacApp
//
//  Ported from the iOS app (Alfred/Alfred/Views/ChatView.swift).
//  The conversation with Alfred — its own tab now that Home is a landing page.
//  macOS adaptations: toolbar items instead of the nav-bar chrome, a sheet for
//  the voice stub instead of a full-screen cover, and the composer's Cmd+Enter
//  send shortcut.
//

import SwiftUI

struct ChatView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var chat
    @Environment(\.palette) private var palette

    /// Chat runs full-screen with the tab bar hidden; this pops back to Home.
    let goBackHome: () -> Void

    @State private var showingClearConfirmation = false
    @State private var showingVoice = false

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                conversation
            }
            .navigationTitle("Chat")
            .modifier(TabToolbar { toolbar })
            .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { chat.clear() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The transcript in this app is deleted. Alfred keeps nothing either way.")
        }
        .sheet(isPresented: $showingVoice) {
            VoiceView()
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        // `chat` is @Observable, so bind through a local copy to hand the composer a Binding
        // to its draft without making the store a @State of this view.
        @Bindable var chat = chat

        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Group {
                    if chat.messages.isEmpty && !chat.isThinking {
                        // Deliberately outside the transcript ScrollView: .defaultScrollAnchor(.bottom)
                        // pins short content to the bottom of the viewport, which would shove this down
                        // against the composer instead of centring it.
                        if hasLink {
                            ConversationEmptyState { prompt in
                                Task { await chat.send(prompt, settings: settings) }
                            }
                        } else {
                            NotConnectedNotice()
                        }
                    } else {
                        transcript(proxy)
                    }
                }
            }

            Composer(text: $chat.draft, isThinking: chat.isThinking) {
                let text = chat.draft
                chat.draft = ""
                Task { await chat.send(text, settings: settings) }
            }
        }
    }

    /// Whether Alfred can be reached at all. The Mac companion's primary
    /// channel is the live socket (discovery fills the gap), so "configured"
    /// here means a relay pin *or* a socket host *or* a live connection —
    /// unlike iOS, which only checks the relay.
    private var hasLink: Bool {
        settings.isConfigured
            || !settings.socketHost.isEmpty
            || AlfredWebSocketClient.shared.isConnected
    }

    private func transcript(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(chat.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        MessageBubble(message: message) {
                            Task { await chat.retry(message, settings: settings) }
                        }

                        // Rate every reply: one tap, and the optimization loop
                        // learns what "good" means for this user.
                        if message.role == .alfred {
                            FeedbackCollectionView(
                                kind: nil,
                                prompt: prompt(for: message),
                                output: message.text)
                                .padding(.horizontal, 4)
                        }
                    }
                    .id(message.id)
                }

                if chat.isThinking {
                    ThinkingIndicator().id(Self.thinkingAnchor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .animation(.easeOut(duration: 0.25), value: chat.messages.count)
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .onChange(of: chat.messages.count) { scrollToEnd(proxy) }
        .onChange(of: chat.isThinking) { scrollToEnd(proxy) }
    }

    /// The user's message that prompted a given Alfred reply — the feedback
    /// example pairs the prompt with the rated output.
    private func prompt(for message: Message) -> String {
        guard let index = chat.messages.firstIndex(of: message) else { return "" }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if chat.messages[i].role == .user { return chat.messages[i].text }
        }
        return ""
    }

    private static let thinkingAnchor = "thinking"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if chat.isThinking {
                proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
            } else if let last = chat.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Chrome

    /// TabToolbar only attaches these while Chat is the selected tab — macOS
    /// merges every mounted page's toolbar into the one window toolbar.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: goBackHome) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accentBright)
            }
            .accessibilityLabel("Back to Home")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingVoice = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(palette.accentBright)
            }
            .accessibilityLabel("Talk to Alfred")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16))
                    .foregroundStyle(palette.textSecondary)
            }
            .disabled(chat.messages.isEmpty)
            .accessibilityLabel("New conversation")
        }
    }
}
