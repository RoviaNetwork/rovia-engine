// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoviaXray",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RoviaXray", targets: ["RoviaXray"]),
        .library(name: "RoviaXrayLive", targets: ["RoviaXrayLive"])
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
        .binaryTarget(
            name: "LibXray",
            url: "https://github.com/RoviaNetwork/rovia-engine/releases/download/libxray-v26.9.9/LibXray.xcframework.zip",
            checksum: "df84739eec41e181153d2c681f84cffc8c50b43ebe117d29e330e7049abee444"
        ),
        .target(
            name: "RoviaXrayLive",
            dependencies: ["RoviaXray", "LibXray"]
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
