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
        .package(url: "https://github.com/RoviaNetwork/rovia-core.git", exact: "0.1.0")
    ],
    targets: [
        .target(
            name: "RoviaXray",
            dependencies: [
                .product(name: "RoviaEngineAPI", package: "rovia-core")
            ]
        ),
        .testTarget(
            name: "RoviaXrayTests",
            dependencies: [
                "RoviaXray",
                .product(name: "RoviaConfig", package: "rovia-core")
            ]
        )
    ]
)
