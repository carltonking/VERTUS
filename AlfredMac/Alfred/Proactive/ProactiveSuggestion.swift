import Foundation

struct ProactiveSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let prompt: String
    let icon: String
}

struct AppContext: Equatable {
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let browserURL: String?
    let browserTitle: String?
}
