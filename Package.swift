// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Euclid",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TileKit", targets: ["TileKit"]),
        .library(name: "TileRendering", targets: ["TileRendering"]),
        .executable(name: "Euclid", targets: ["EuclidApp"]),
        .executable(name: "tiletools", targets: ["TileTools"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TileKit", dependencies: ["CSQLite"]),
        .target(name: "TileRendering", dependencies: ["TileKit"]),
        .executableTarget(
            name: "EuclidApp",
            dependencies: ["TileKit", "TileRendering"]
        ),
        .executableTarget(
            name: "TileKitCheck",
            dependencies: ["TileKit", "TileRendering"]
        ),
        .executableTarget(name: "TileKitBench", dependencies: ["TileKit"]),
        .executableTarget(name: "TileTools", dependencies: ["TileKit"]),
    ]
)
