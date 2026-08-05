//
//  RootView.swift
//  Alfred
//
//  The places Alfred lives on the phone, and the one spot the chosen theme enters the view tree.
//
//  Tab selection is held here rather than inside any one tab, so a screen can send you somewhere
//  else — an unconfigured Home needs to hand you to Settings, and a tapped suggestion needs to open
//  Chat with the answer already on its way. Neither works if each tab owns its navigation alone.
//

import SwiftUI

/// Five, deliberately. iPhone shows at most five tabs and folds the rest into a "More" list — a
/// sixth tab doesn't add a destination, it demotes two of them behind an extra tap. Settings is the
/// one that gives up its slot, since it's configuration rather than a place you work.
enum AlfredTab: Hashable {
    case home, chat, messages, email, calendar
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    @State private var selection: AlfredTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: AlfredTab.home) {
                HomeView(selection: $selection)
            }

            Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: AlfredTab.chat) {
                ChatView()
            }

            Tab("Messages", systemImage: "message.fill", value: AlfredTab.messages) {
                MessagesView()
            }

            Tab("Email", systemImage: "envelope.fill", value: AlfredTab.email) {
                EmailView()
            }

            Tab("Calendar", systemImage: "calendar", value: AlfredTab.calendar) {
                CalendarView()
            }
        }
        .environment(\.palette, settings.theme.palette)
        .tint(settings.theme.palette.accentBright)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: settings.theme)
    }
}
