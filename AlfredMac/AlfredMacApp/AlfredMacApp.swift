//
//  AlfredMacApp.swift
//  AlfredMacApp
//
//  The windowed companion app: a native macOS surface mirroring the iOS app's
//  layout (same tabs, same floating capsule tab bar, same palette). Lives in
//  its own executable target so it coexists with the menu-bar Alfred app, whose
//  @main entry (Alfred/App/AlfredApp.swift) is untouched.
//

import SwiftUI

@main
struct AlfredMacApp: App {
    @State private var settings = AppSettings()
    @State private var chat = ChatStore()

    var body: some Scene {
        WindowGroup("Alfred") {
            macOSRootView()
                .environment(settings)
                .environment(chat)
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 900, height: 700)
    }
}
