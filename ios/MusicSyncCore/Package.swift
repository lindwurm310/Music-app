// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicSyncCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MusicSyncCore", targets: ["MusicSyncCore"]),
    ],
    targets: [
        .target(name: "MusicSyncCore"),
        .testTarget(name: "MusicSyncCoreTests", dependencies: ["MusicSyncCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
