// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "alfred-spike",
    platforms: [.macOS(.v13)],
    targets: [
        // Phase 0 de-risk CLI. No external dependencies on purpose:
        // it must build offline and prove the foundation with only Foundation.
        .executableTarget(
            name: "alfred-spike",
            path: "Sources/alfred-spike"
        )
    ]
)
