//
//  EmailView.swift
//  Alfred
//

import SwiftUI

struct EmailView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background

                ComingSoon(
                    icon: "envelope.fill",
                    title: "Email",
                    promise: "Triage what landed, read what matters, and reply in your own voice.",
                    blockedOn: "Alfred already does this over Telegram. Moving it here needs the triage flow to answer without a back-and-forth conversation, since /api/app returns exactly one reply per request."
                )
            }
            .navigationTitle("Email")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
