//
//  EmailView.swift
//  Alfred
//
//  The Email tab, rooted on the Mac-driven unified inbox: every account Himalaya
//  is configured with on the Mac, one list, one place to act. The phone never
//  needs its own IMAP connection — it reads the Mac's cache over the WebSocket
//  and sends actions back as JSON-RPC (`mail.*`).
//
//  The cloud client (the /api/mail relay) is still reachable from the inbox's
//  toolbar menu — "Server mailboxes" — for the older account-management flow,
//  but the Mac inbox is the default because it's the same mail Alfred reads.
//
//  The store lives here so the badge and the tab share one copy of the truth,
//  and its update loop starts with the app (see RootView) so new mail lands on
//  the badge even before this tab is opened.
//

import SwiftUI

struct EmailView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            MacInboxView()
        }
    }
}
