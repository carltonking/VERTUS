import SwiftUI

/// AlfrediOS entry point: a full-screen SwiftUI chat client for the Hermes
/// agent — deliberately a chat window, not the macOS floating bar. The whole
/// app is iOS-safe: no AppKit, no ScreenCaptureKit, no Cmd+Shift+J.
@main
struct AlfrediOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppSettings.shared)
        }
    }
}
