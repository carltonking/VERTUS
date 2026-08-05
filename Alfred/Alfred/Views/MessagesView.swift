//
//  MessagesView.swift
//  Alfred
//

import SwiftUI

struct MessagesView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ComingSoon(
                    icon: "message.fill",
                    title: "Messages",
                    promise: "See who texted, and answer in your own voice without opening Messages.",
                    blockedOn: "This one is genuinely hard from a phone: iMessage lives in a database only macOS can read, so the cloud brain declines it outright rather than guessing. It needs Alfred on your Mac to be awake and reachable — the reason the Mac app still exists."
                )
            }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
