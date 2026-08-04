//
//  AlfredApp.swift
//  Alfred
//
//  Created by Carlton King on 8/4/26.
//
//  Alfred on the phone. The brain is the same one Telegram talks to — the always-on cloud app in
//  `api/` — reached over its plain-HTTP front door (api/app.ts) instead of Telegram's protocol.
//

import SwiftUI

@main
struct AlfredApp: App {
    @State private var settings = AppSettings()
    @State private var chat = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(chat)
        }
    }
}
