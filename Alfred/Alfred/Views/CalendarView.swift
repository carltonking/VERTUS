//
//  CalendarView.swift
//  Alfred
//

import SwiftUI

struct CalendarView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ComingSoon(
                    icon: "calendar",
                    title: "Calendar",
                    promise: "See what's coming up, and add anything by asking for it in plain words.",
                    blockedOn: "Alfred can already read and write your iCloud calendar — ask him on the Home tab. A grid needs the server to hand back events as data; today /api/app answers in prose written for a chat bubble."
                )
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
