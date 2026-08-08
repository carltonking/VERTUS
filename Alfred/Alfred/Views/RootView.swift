//
//  RootView.swift
//  Alfred
//
//  The places Alfred lives on the phone, and the one spot the palette enters the view tree.
//
//  Selection is held here rather than inside any one page, so a page can send you somewhere else —
//  an unconfigured Home needs to hand you to Settings. That wouldn't work if each page owned its
//  navigation alone.
//

import SwiftUI

enum AlfredTab: String, CaseIterable, Identifiable, Hashable {
    case home, chat, email, calendar, reminders, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .chat: return "Chat"
        case .email: return "Email"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .email: return "envelope.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
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
            page(.chat) { ChatView(goBackHome: { selection = .home }) }
            page(.email) { EmailView() }
            page(.calendar) { CalendarView() }
            page(.reminders) { RemindersView() }
            page(.settings) { SettingsView() }
        }
        .safeAreaInset(edge: .bottom) {
            // Chat owns the whole screen while it's open: the composer sits over
            // the inset every other tab gives the bar, so the bar would bury it.
            // Full-screen chat, navigable back to Home via its leading button.
            if selection != .chat {
                AlfredTabBar(selection: $selection)
            }
        }
        .environment(\.palette, .mono)
        .tint(Palette.mono.accentBright)
        .preferredColorScheme(.dark)
        .task {
            // Once the app has a server configured, offer leave-now push reminders.
            // No-op afterward: the check is idempotent.
            guard settings.isConfigured else { return }
            await PushRegistration.shared.request()
        }
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
