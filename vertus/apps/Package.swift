// swift-tools-version: 5.9
//
// VERTUS — the notch QuickBar menubar extra (⇧⌘J): a panel/menu-only
// .accessory app on macOS 13+. VertusKit is macOS-only now (the phone was
// removed from the project; its last tree is preserved out-of-repo).
//
// Build:          swift build                    (debug)
//                 swift build -c release         (production)
// Bundle:         scripts/build-app.sh           -> dist/Vertus.app
// Run the tests:  swift test

import PackageDescription

let package = Package(
    name: "VertusApps",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VertusKit", targets: ["VertusKit"]),
    ],
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
