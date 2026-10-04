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
