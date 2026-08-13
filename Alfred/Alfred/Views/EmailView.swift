//
//  EmailView.swift
//  Alfred
//
//  The Email tab — Apple Mail's three panes with the AI copilot embedded.
//  Every account Himalaya is configured with on the Mac, one unified inbox,
//  one place to act. The phone never needs its own IMAP connection: it reads
//  the Mac's cache over the WebSocket and sends actions back as JSON-RPC
//  (`mail.*`), while the AI layer (classification, summaries, drafts, natural-
//  language search) rides the same socket to Hermes on the Mac.
//
//  The store is a shared singleton so the badge and the tab share one copy of
//  the truth, and its update loop starts with the app (see RootView) so new
//  mail lands on the badge even before this tab is opened.
//

import SwiftUI

struct EmailView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        MailTabView()
    }
}
