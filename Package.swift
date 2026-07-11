// swift-tools-version: 6.0
// WireframeKit — 3D triangle meshes → 2D hidden-line-removed vector drawings.

import PackageDescription

let package = Package(
    name: "WireframeKit",
    // Minimum deployment for Apple platforms. SwiftPM platform requirements are
    // package-wide; they do not restrict non-Apple platforms, so WireframeCore
    // still builds unconstrained on Linux (constraint C1).
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "WireframeCore", targets: ["WireframeCore"]),
        .library(name: "WireframeModelIO", targets: ["WireframeModelIO"]),
        .library(name: "WireframeGraphics", targets: ["WireframeGraphics"]),
    ],
    targets: [
        // Pure core: Swift standard library ONLY (constraint C1).
        .target(name: "WireframeCore"),

        // Apple-only targets (implemented in M5; placeholders until then).
        .target(name: "WireframeModelIO", dependencies: ["WireframeCore"]),
        .target(name: "WireframeGraphics", dependencies: ["WireframeCore"]),

        .testTarget(
            name: "WireframeCoreTests",
            dependencies: ["WireframeCore"],
            resources: [
                .copy("Resources"),
                .copy("Goldens"),
            ]
        ),
        .testTarget(
            name: "WireframeModelIOTests",
            dependencies: ["WireframeModelIO", "WireframeCore"],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "WireframeGraphicsTests",
            dependencies: ["WireframeGraphics", "WireframeCore"]
        ),
    ]
)
