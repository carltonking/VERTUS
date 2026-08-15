//
//  EmailView.swift
//  AlfredMacApp
//
//  The Email tab — Apple Mail's three panes with the AI copilot embedded.
//  Ported from the iOS app (Alfred/Alfred/Views/EmailView.swift). Every
//  account Himalaya is configured with on the Mac, one unified inbox, one
//  place to act. The app reads the Mac's cache over the WebSocket and sends
//  actions back as JSON-RPC (`mail.*`), while the AI layer (classification,
//  summaries, drafts, natural-language search) rides the same socket to Hermes
//  on the Mac.
//
//  The store is a shared singleton so the badge and the tab share one copy of
//  the truth.
//

import SwiftUI

struct EmailView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        MailTabView()
    }
}
