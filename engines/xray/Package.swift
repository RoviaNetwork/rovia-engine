// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoviaXray",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RoviaXray", targets: ["RoviaXray"])
    ],
    dependencies: [
        .package(path: "../api"),
        .package(path: "../../core/config")
    ],
    targets: [
        .target(
            name: "RoviaXray",
            dependencies: [
                .product(name: "RoviaEngineAPI", package: "api")
            ]
        ),
        .testTarget(
            name: "RoviaXrayTests",
            dependencies: [
                "RoviaXray",
                .product(name: "RoviaConfig", package: "config")
            ]
        )
    ]
)
