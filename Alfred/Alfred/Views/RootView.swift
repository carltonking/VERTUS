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
    case home, chat, email, calendar, reminders, routines, code, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .chat: return "Chat"
        case .email: return "Email"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .routines: return "Routines"
        case .code: return "Code"
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
        case .routines: return "bolt.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
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
            page(.routines) { RoutinesView() }
            page(.code) { CodeView() }
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
        .task {
            // The live link: connect to the Mac's socket once configured. Discovery
            // is bounded and the client reconnects on its own, so this never blocks
            // the UI and never needs to be called again.
            guard settings.isConfigured else { return }
            await AlfredWebSocketClient.shared.connectToAlfred()
        }
        .task {
            // Mail pushes (sync completions, unread changes) drive the Email tab
            // badge. The store starts consuming them once configured — before the
            // Email tab is ever opened — so new mail lands on the badge.
            guard settings.isConfigured else { return }
            MacMailStore.shared.start()
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
