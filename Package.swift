// swift-tools-version: 6.0
import PackageDescription

// Umbrella for cross-repository consumers (the rovia app): one URL,
// exact pins, no sibling-checkout assumptions. The focussed manifests under
// engines/ stay for day-to-day development and per-package CI.
//
// NOTE: tags in this organization are immutable. v0.2.0 of rovia-core was
// moved once and consequently poisons CLI resolution (SwiftPM holds the
// first-seen revision); it was deleted, and v0.2.1 is the release to use.
let package = Package(
    name: "rovia-engine",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RoviaXray", targets: ["RoviaXray"]),
        .library(name: "RoviaXrayLive", targets: ["RoviaXrayLive"]),
        .library(name: "RoviaSingBox", targets: ["RoviaSingBox"]),
    ],
    dependencies: [
        .package(url: "https://github.com/RoviaNetwork/rovia-core.git", exact: "0.2.3")
    ],
    targets: [
        .target(
            name: "RoviaXray",
            dependencies: [
                .product(name: "RoviaEngineAPI", package: "rovia-core"),
                .product(name: "RoviaConfig", package: "rovia-core"),
            ],
            path: "engines/xray/Sources/RoviaXray"
        ),
        // The pinned libXray build: the artifact is reproduced by rovia's
        // tools/build-engine/xray/build-apple.sh, and this checksum is the
        // digest recorded in that repository's engines.lock.json.
        .binaryTarget(
            name: "LibXray",
            url: "https://github.com/RoviaNetwork/rovia-engine/releases/download/libxray-v26.9.9/LibXray.xcframework.zip",
            checksum: "df84739eec41e181153d2c681f84cffc8c50b43ebe117d29e330e7049abee444"
        ),
        .target(
            name: "RoviaXrayLive",
            dependencies: ["RoviaXray", "LibXray"],
            path: "engines/xray/Sources/RoviaXrayLive"
        ),
        .target(
            name: "RoviaSingBox",
            dependencies: [
                .product(name: "RoviaEngineAPI", package: "rovia-core"),
                .product(name: "RoviaConfig", package: "rovia-core"),
            ],
            path: "engines/singbox/Sources/RoviaSingBox"
        ),
    ]
)
