//
//  HomeView.swift
//  Alfred
//
//  The main page: a greeting, and the conversation with Alfred underneath it.
//
//  The chat lives here rather than in a tab of its own because talking to Alfred *is* the app —
//  Email and Calendar are structured views onto things he can already discuss.
//

import SwiftUI

struct HomeView: View {
    @Binding var selection: AlfredTab

    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var chat

    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background

                if settings.isConfigured {
                    conversation
                } else {
                    NotConnectedState { selection = .settings }
                }
            }
            .navigationTitle("")
            .toolbar { toolbar }
            .toolbarBackground(Theme.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { chat.clear() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The transcript on this phone is deleted. Alfred keeps nothing either way.")
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        // `chat` is @Observable, so bind through a local copy to hand the composer a Binding
        // to its draft without making the store a @State of this view.
        @Bindable var chat = chat

        return ScrollViewReader { proxy in
            Group {
                if chat.messages.isEmpty && !chat.isThinking {
                    // Deliberately outside the ScrollView: .defaultScrollAnchor(.bottom) pins short
                    // content to the bottom of the viewport, which would shove the welcome screen
                    // down against the composer instead of centring it.
                    WelcomeState { prompt in
                        Task { await chat.send(prompt, settings: settings) }
                    }
                } else {
                    transcript(proxy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Composer(text: $chat.draft, isThinking: chat.isThinking) {
                    let text = chat.draft
                    chat.draft = ""
                    Task { await chat.send(text, settings: settings) }
                }
            }
        }
    }

    private func transcript(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(chat.messages) { message in
                    MessageBubble(message: message) {
                        Task { await chat.retry(message, settings: settings) }
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
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .onChange(of: chat.messages.count) { scrollToEnd(proxy) }
        .onChange(of: chat.isThinking) { scrollToEnd(proxy) }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                AlfredMark(lineWidth: 1.4)
                    .frame(width: 20, height: 20)
                Text("Alfred")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
            }
            .disabled(chat.messages.isEmpty)
            .accessibilityLabel("New conversation")
        }
    }
}
