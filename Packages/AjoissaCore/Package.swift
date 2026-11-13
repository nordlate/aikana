// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AjoissaCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AjoissaCore", targets: ["AjoissaCore"]),
        .executable(name: "ajoissa", targets: ["AjoissaCLI"])
    ],
    targets: [
        // The engine: config, collectors, schedule logic and checks.
        // Foundation only. No AppKit or SwiftUI, and no dependency on the app,
        // so this package can be published on its own later.
        .target(name: "AjoissaCore"),
        .executableTarget(name: "AjoissaCLI", dependencies: ["AjoissaCore"]),
        // The fixtures are read from disk by path, so they are not resources of the test bundle.
        .testTarget(name: "AjoissaCoreTests", dependencies: ["AjoissaCore"], exclude: ["Launchd/Fixtures"])
    ]
)
