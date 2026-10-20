// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenPlayerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenPlayerCore", targets: ["OpenPlayerCore"]),
    ],
    targets: [
        .target(
            name: "OpenPlayerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "OpenPlayerCoreTests", dependencies: ["OpenPlayerCore"]),
    ]
)
