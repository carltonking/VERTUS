//
//  RootView.swift
//  Alfred
//
//  The four places Alfred lives on the phone. Tab selection is held here rather than inside any
//  one tab, so a screen can send you somewhere else — an unconfigured Home needs to hand you to
//  Settings, and it can't do that if each tab owns its own navigation in isolation.
//

import SwiftUI

enum AlfredTab: Hashable {
    case home, email, calendar, settings
}

struct RootView: View {
    @State private var selection: AlfredTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: AlfredTab.home) {
                HomeView(selection: $selection)
            }

            Tab("Email", systemImage: "envelope.fill", value: AlfredTab.email) {
                EmailView()
            }

            Tab("Calendar", systemImage: "calendar", value: AlfredTab.calendar) {
                CalendarView()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: AlfredTab.settings) {
                SettingsView()
            }
        }
        .tint(Theme.accentBright)
        .preferredColorScheme(.dark)
    }
}
