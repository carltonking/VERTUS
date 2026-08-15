// swift-tools-version: 5.9
import PackageDescription

// AlfrediOS: the SwiftUI chat client for Hermes on iPhone/iPad. Shares
// AlfredCore (LLM protocol + router, markdown-vault memory) with the macOS
// app. iOS-safe only — no AppKit, no ScreenCaptureKit, no hotkeys.
let package = Package(
    name: "AlfrediOS",
    platforms: [
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../AlfredCore"),
    ],
    targets: [
        .executableTarget(
            name: "AlfrediOS",
            dependencies: ["AlfredCore"],
            path: "Sources/AlfrediOS"
        ),
    ]
)
