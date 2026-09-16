// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaradayKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FaradayCore", targets: ["FaradayCore"]),
        .library(name: "FaradayControl", targets: ["FaradayControl"]),
    ],
    targets: [
        .target(
            name: "CFaradaySupport",
            linkerSettings: [.linkedLibrary("bsm")]
        ),
        .target(
            name: "FaradayCore",
            dependencies: ["CFaradaySupport"]
        ),
        .target(
            name: "FaradayControl",
            dependencies: ["FaradayCore"]
        ),
        .testTarget(
            name: "FaradayCoreTests",
            dependencies: ["FaradayCore"]
        ),
        .testTarget(
            name: "FaradayControlTests",
            dependencies: ["FaradayControl"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
