// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Alfred",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Alfred",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
        .testTarget(
            name: "AlfredTests",
            dependencies: ["Alfred"],
            path: "Tests"
        ),
    ]
)
