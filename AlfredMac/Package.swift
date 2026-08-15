// swift-tools-version: 5.9
import PackageDescription

// Alfred is a client for Hermes Agent: a notch bar and a bridge handing macOS to
// Hermes over MCP. It has no dependencies — GRDB went with Alfred's own memory
// store and Sparkle with its updater, both of which Hermes now owns.
let package = Package(
    name: "Alfred",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Alfred",
            path: "Alfred",
            resources: [
                .process("Resources"),
            ]
        ),
        // The MCP shim Hermes spawns. Deliberately dependency-free and
        // privilege-free: it only relays bytes to the running Alfred.app, which
        // holds the TCC grants. See AlfredMCP/main.swift.
        .executableTarget(
            name: "alfred-mcp",
            path: "AlfredMCP"
        ),
        // The windowed companion app: a native macOS surface that mirrors the
        // iOS app's tab layout. A separate executable so it coexists with
        // the menu-bar Alfred target (which keeps its own @main entry).
        .executableTarget(
            name: "AlfredMacApp",
            path: "AlfredMacApp"
        ),
        .testTarget(
            name: "AlfredTests",
            dependencies: ["Alfred"],
            path: "Tests"
        ),
    ]
)
