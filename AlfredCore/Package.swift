// swift-tools-version: 5.9
import PackageDescription

// AlfredCore: the platform-agnostic core shared by the macOS app (AlfredMac)
// and the iOS app (Alfred/). Holds the LLM provider protocol + router, the
// markdown-vault memory store, and the capability protocols. macOS-only
// capabilities (ScreenCaptureKit, Accessibility, shell) live behind
// `#if os(macOS)` so this package compiles on iOS too.
let package = Package(
    name: "AlfredCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AlfredCore", targets: ["AlfredCore"]),
    ],
    targets: [
        .target(
            name: "AlfredCore",
            path: "Sources/AlfredCore"
        ),
        .testTarget(
            name: "AlfredCoreTests",
            dependencies: ["AlfredCore"],
            path: "Tests/AlfredCoreTests"
        ),
    ]
)
