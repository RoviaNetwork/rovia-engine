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
        .package(path: "../api"),
        .package(path: "../../core/config")
    ],
    targets: [
        .target(
            name: "RoviaSingBox",
            dependencies: [
                .product(name: "RoviaEngineAPI", package: "api")
            ]
        ),
        .testTarget(
            name: "RoviaSingBoxTests",
            dependencies: [
                "RoviaSingBox",
                .product(name: "RoviaConfig", package: "config")
            ]
        )
    ]
)
