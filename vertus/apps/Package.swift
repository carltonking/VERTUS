// swift-tools-version: 5.9
//
// VERTUS macOS apps — one build for both clients.
//
//   VertusKit    shared library: wire models, HTTP client, fleet SSE stream,
//                per-agent live state, transcript merging, cursor resume.
//   VertusBar    the notch QuickBar (menubar app, ⇧⌘J), refactored onto
//                VertusKit.
//   VertusFleet  full-window fleet app (roster, chat, runs, bot editor,
//                background-completion notifications).
//
// Build both apps:   swift build                (debug)
//                    swift build -c release     (production, launchd)
// Run the tests:     swift test
// Bundle Fleet for notifications (needs a real .app):
//                    scripts/make-fleet-app.sh  (uses the debug build)
//                    scripts/make-fleet-app.sh release

import PackageDescription

let package = Package(
    name: "VertusApps",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VertusKit"),
        .executableTarget(
            name: "VertusBar",
            dependencies: ["VertusKit"]
        ),
        .executableTarget(
            name: "VertusFleet",
            dependencies: ["VertusKit"]
        ),
        .testTarget(
            name: "VertusKitTests",
            dependencies: ["VertusKit"]
        ),
    ]
)