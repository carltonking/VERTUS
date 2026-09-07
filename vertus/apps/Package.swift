// swift-tools-version: 5.9
//
// VERTUS — one client core, every surface.
//
//   VertusKit  shared library: wire models, HTTP client, fleet SSE stream,
//              per-agent live state, transcript merging, cursor resume.
//              Multiplatform: macOS 13+ AND iOS 16+ (the phone app links
//              this exact target via a local package reference).
//   Vertus     the macOS app: full window (roster, chat, memory, threads,
//              screens, activity, bot editor) + the notch QuickBar menubar
//              extra (⇧⌘J), one FleetStore between them. macOS-only
//              (AppKit panel/notifications live here, not in the kit).
//   VertusPhone (Xcode project, iOS): links VertusKit — the phone has NO
//              client code of its own; everything below the UI is this kit.
//
// Build:          swift build                    (debug)
//                 swift build -c release         (production)
// Bundle:         scripts/build-app.sh           -> dist/Vertus.app
// Phone:          cd VertusPhone && xcodebuild -project VertusPhone.xcodeproj \
//                   -scheme VertusPhone -sdk iphonesimulator build
// Run the tests:  swift test

import PackageDescription

let package = Package(
    name: "VertusApps",
    platforms: [.macOS(.v13), .iOS(.v16)],
    // Explicit product: the phone's Xcode project links VertusKit via
    // XCSwiftPackageProductDependency, which needs a declared product.
    products: [
        .library(name: "VertusKit", targets: ["VertusKit"]),
    ],
    targets: [
        .target(name: "VertusKit"),
        .executableTarget(
            name: "Vertus",
            dependencies: ["VertusKit"]
            // AppKit panel/hotkey/notification code. The package declares iOS
            // for VertusKit's sake; this executable is only ever built for
            // macOS (nothing builds it for iOS).
        ),
        .testTarget(
            name: "VertusKitTests",
            dependencies: ["VertusKit"]
        ),
    ]
)