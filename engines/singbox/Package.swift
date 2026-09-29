// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoviaSingBox",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RoviaSingBox", targets: ["RoviaSingBox"])
    ],
    dependencies: [
        .package(url: "https://github.com/RoviaNetwork/rovia-core.git", exact: "0.1.0")
    ],
    targets: [
        .target(
            name: "RoviaSingBox",
            dependencies: [
                .product(name: "RoviaEngineAPI", package: "rovia-core")
            ]
        ),
        .testTarget(
            name: "RoviaSingBoxTests",
            dependencies: [
                "RoviaSingBox",
                .product(name: "RoviaConfig", package: "rovia-core")
            ]
        )
    ]
)
