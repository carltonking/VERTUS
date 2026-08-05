//
//  RootView.swift
//  Alfred
//
//  The places Alfred lives on the phone, and the one spot the chosen theme enters the view tree.
//
//  Selection is held here rather than inside any one page, so a page can send you somewhere else —
//  an unconfigured Home needs to hand you to Settings. That wouldn't work if each page owned its
//  navigation alone.
//

import SwiftUI

enum AlfredTab: String, CaseIterable, Identifiable, Hashable {
    case home, chat, messages, email, calendar, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .chat: return "Chat"
        case .messages: return "Messages"
        case .email: return "Email"
        case .calendar: return "Calendar"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .messages: return "message.fill"
        case .email: return "envelope.fill"
        case .calendar: return "calendar"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    @State private var selection: AlfredTab = .home

    var body: some View {
        ZStack {
            // Each page keeps its own view identity, so switching tabs doesn't reset a half-typed
            // message or a scroll position the way rebuilding a single view would.
            page(.home) { HomeView(selection: $selection) }
            page(.chat) { ChatView() }
            page(.messages) { MessagesView() }
            page(.email) { EmailView() }
            page(.calendar) { CalendarView() }
            page(.settings) { SettingsView() }
        }
        .safeAreaInset(edge: .bottom) {
            AlfredTabBar(selection: $selection)
        }
        .environment(\.palette, settings.theme.palette)
        .tint(settings.theme.palette.accentBright)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: settings.theme)
    }

    @ViewBuilder
    private func page<Content: View>(_ tab: AlfredTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            // Hidden pages must not swallow taps meant for the visible one.
            .allowsHitTesting(selection == tab)
            .accessibilityHidden(selection != tab)
    }
}
