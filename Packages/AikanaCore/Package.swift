// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AikanaCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AikanaCore", targets: ["AikanaCore"]),
        .executable(name: "aikana", targets: ["AikanaCLI"])
    ],
    targets: [
        // The engine: config, collectors, schedule logic and checks.
        // Foundation only. No AppKit or SwiftUI, and no dependency on the app,
        // so this package can be published on its own later.
        .target(name: "AikanaCore"),
        .executableTarget(name: "AikanaCLI", dependencies: ["AikanaCore"]),
        // The fixtures are read from disk by path, so they are not resources of the test bundle.
        .testTarget(name: "AikanaCoreTests", dependencies: ["AikanaCore"], exclude: ["Launchd/Fixtures"])
    ]
)
