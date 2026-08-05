//
//  ChatView.swift
//  Alfred
//
//  The conversation with Alfred — its own tab now that Home is a landing page.
//

import SwiftUI

struct ChatView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var chat
    @Environment(\.palette) private var palette

    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                if settings.isConfigured {
                    conversation
                } else {
                    NotConnectedNotice()
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
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
                    // content to the bottom of the viewport, which would shove this down against
                    // the composer instead of centring it.
                    ConversationEmptyState { prompt in
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
        ToolbarItem(placement: .topBarTrailing) {
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
