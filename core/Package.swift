// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PauseCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "PauseCore", targets: ["PauseCore"]),
    ],
    targets: [
        .target(name: "PauseCore"),
        .testTarget(
            name: "PauseCoreTests",
            dependencies: ["PauseCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
