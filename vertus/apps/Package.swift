// swift-tools-version: 5.9
//
// VERTUS macOS — one app, one process.
//
//   VertusKit  shared library: wire models, HTTP client, fleet SSE stream,
//              per-agent live state, transcript merging, cursor resume.
//   Vertus     the app: full window (roster, chat, memory, threads, screens,
//              activity, bot editor) + the notch QuickBar menubar extra
//              (⇧⌘J), one FleetStore between them.
//
// Build:          swift build                    (debug)
//                 swift build -c release         (production)
// Bundle:         scripts/build-app.sh           -> dist/VERTUS.app
// Run the tests:  swift test

import PackageDescription

let package = Package(
    name: "VertusApps",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VertusKit"),
        .executableTarget(
            name: "Vertus",
            dependencies: ["VertusKit"]
        ),
        .testTarget(
            name: "VertusKitTests",
            dependencies: ["VertusKit"]
        ),
    ]
)