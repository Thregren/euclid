// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Euclid",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TileKit", targets: ["TileKit"]),
        .executable(name: "Euclid", targets: ["EuclidApp"]),
    ],
    targets: [
        .target(name: "TileKit"),
        .executableTarget(
            name: "EuclidApp",
            dependencies: ["TileKit"]
        ),
        .executableTarget(
            name: "TileKitCheck",
            dependencies: ["TileKit"]
        ),
    ]
)
