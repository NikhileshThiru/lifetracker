// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LifeTrackerCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LifeTrackerCore", targets: ["LifeTrackerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "LifeTrackerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "LifeTrackerCoreTests",
            dependencies: ["LifeTrackerCore"]
        ),
    ]
)
